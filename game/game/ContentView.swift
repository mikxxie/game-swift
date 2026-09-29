import SwiftUI
import Network

struct RemotePlayer: Identifiable, Equatable {
    let id: UInt32
    var name: String
    var x: Float
    var y: Float
    var dir: Float
    var renderX: Float
    var renderY: Float
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

@MainActor
final class GameClient: ObservableObject {
    static let serverHost = "192.168.1.68"
    static let serverPort: UInt16 = 9932
    static let worldMin: Float = -250
    static let worldMax: Float = 250

    @Published var state: ConnectionState = .disconnected
    @Published var myId: UInt32 = 0
    @Published var myX: Float = 0
    @Published var myY: Float = 0
    @Published var myDir: Float = 0
    @Published var players: [RemotePlayer] = []
    @Published var pingMs: Int = 0
    @Published var log: [String] = []

    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "udp.client")
    private var pingTimer: Timer?
    private var tickTimer: Timer?

    func connect(name: String) {
        guard state != .connected && state != .connecting else { return }
        state = .connecting

        let host = NWEndpoint.Host(Self.serverHost)
        let port = NWEndpoint.Port(rawValue: Self.serverPort)!
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .wifi

        let c = NWConnection(host: host, port: port, using: params)
        self.conn = c

        c.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.state = .connected
                    self.appendLog("connected")
                    self.send("JOIN \(name)")
                    self.startPing()
                    self.startTick()
                    self.receiveLoop()
                case .failed(let err):
                    self.state = .failed("\(err)")
                    self.appendLog("failed: \(err)")
                case .cancelled:
                    self.state = .disconnected
                    self.stopTimers()
                default:
                    break
                }
            }
        }

        c.start(queue: queue)
    }

    func disconnect() {
        send("BYE")
        stopTimers()
        conn?.cancel()
        conn = nil
        state = .disconnected
        players.removeAll()
        myId = 0
        myX = 0
        myY = 0
        myDir = 0
    }

    func send(_ msg: String) {
        guard let conn else { return }
        let data = (msg + "\n").data(using: .utf8)!
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    func move(dx: Float, dy: Float) {
        guard state == .connected else { return }
        myX = min(max(myX + dx, Self.worldMin), Self.worldMax)
        myY = min(max(myY + dy, Self.worldMin), Self.worldMax)
        if abs(dx) > 0.001 || abs(dy) > 0.001 {
            myDir = atan2(dy, dx) * 180 / .pi
        }
        send(String(format: "MOVE %.2f %.2f %.2f", myX, myY, myDir))
    }

    private func receiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty,
                   let text = String(data: data, encoding: .utf8) {
                    self.handle(text)
                }
                if error == nil {
                    self.receiveLoop()
                } else {
                    self.state = .failed("\(error!)")
                }
            }
        }
    }

    private func handle(_ text: String) {
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: " ").map(String.init)
            guard let verb = parts.first else { continue }

            switch verb {
            case "WELCOME":
                if parts.count >= 2, let id = UInt32(parts[1]) {
                    myId = id
                    appendLog("id \(id)")
                }
            case "JOINED":
                guard parts.count >= 6,
                      let id = UInt32(parts[1]),
                      let x = Float(parts[3]),
                      let y = Float(parts[4]),
                      let d = Float(parts[5]) else { return }
                let name = parts[2]
                upsert(RemotePlayer(id: id, name: name, x: x, y: y,
                                    dir: d, renderX: x, renderY: y))
                appendLog("\(name) joined")
            case "LEFT":
                guard parts.count >= 2, let id = UInt32(parts[1]) else { return }
                players.removeAll { $0.id == id }
                appendLog("id \(id) left")
            case "SNAP":
                guard parts.count >= 2, let n = Int(parts[1]) else { return }
                var idx = 2
                var seen = Set<UInt32>()
                for _ in 0..<n {
                    guard idx + 3 < parts.count,
                          let id = UInt32(parts[idx]),
                          let x = Float(parts[idx + 1]),
                          let y = Float(parts[idx + 2]),
                          let d = Float(parts[idx + 3]) else { break }
                    idx += 4
                    if id == myId { continue }
                    seen.insert(id)
                    if let i = players.firstIndex(where: { $0.id == id }) {
                        players[i].x = x
                        players[i].y = y
                        players[i].dir = d
                    } else {
                        players.append(RemotePlayer(id: id, name: "player",
                                                    x: x, y: y, dir: d,
                                                    renderX: x, renderY: y))
                    }
                }
                players.removeAll { $0.id != myId && !seen.contains($0.id) }
            case "PONG":
                if parts.count >= 2, let ms = Int(parts[1]) {
                    let now = Int(Date().timeIntervalSince1970 * 1000)
                    pingMs = max(0, now - ms)
                }
            case "ERR":
                appendLog("server: \(line)")
            default:
                break
            }
        }
    }

    private func upsert(_ p: RemotePlayer) {
        if let i = players.firstIndex(where: { $0.id == p.id }) {
            players[i] = p
        } else {
            players.append(p)
        }
    }

    private func startPing() {
        stopPing()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.send("PING") }
        }
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func startTick() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0,
                                         repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for i in self.players.indices {
                    let t: Float = 0.25
                    self.players[i].renderX += (self.players[i].x - self.players[i].renderX) * t
                    self.players[i].renderY += (self.players[i].y - self.players[i].renderY) * t
                }
            }
        }
    }

    private func stopTimers() {
        stopPing()
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func appendLog(_ s: String) {
        log.append(s)
        if log.count > 40 { log.removeFirst(log.count - 40) }
    }
}

struct ContentView: View {
    @StateObject private var client = GameClient()
    @State private var name: String = ""
    @State private var hasJoined = false

    var body: some View {
        ZStack {
            Color(red: 0.15, green: 0.18, blue: 0.25).ignoresSafeArea()
            if hasJoined {
                GameView(client: client, onLeave: {
                    client.disconnect()
                    hasJoined = false
                })
            } else {
                JoinView(name: $name, client: client, onJoin: {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    client.connect(name: n.isEmpty ? "player" : n)
                    hasJoined = true
                })
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct JoinView: View {
    @Binding var name: String
    @ObservedObject var client: GameClient
    var onJoin: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("BLOX ARENA")
                .font(.system(size: 44, weight: .black, design: .rounded))
                .foregroundStyle(.white)

            Text("\(GameClient.serverHost):\(GameClient.serverPort)")
                .font(.footnote.monospaced())
                .foregroundStyle(.gray)

            TextField("your name", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding()
                .background(Color.white.opacity(0.08))
                .cornerRadius(12)
                .foregroundStyle(.white)
                .frame(maxWidth: 320)

            Button(action: onJoin) {
                Text("PLAY")
                    .font(.headline)
                    .frame(maxWidth: 320)
                    .padding()
                    .background(Color(red: 0.3, green: 0.75, blue: 0.35))
                    .foregroundStyle(.white)
                    .cornerRadius(12)
            }

            if case .failed(let msg) = client.state {
                Text("failed: \(msg)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
    }
}

struct GameView: View {
    @ObservedObject var client: GameClient
    var onLeave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("id \(client.myId)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.white)
                    Text(String(format: "%.1f, %.1f", client.myX, client.myY))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.gray)
                }
                Spacer()
                Text("\(client.players.count + 1) online")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white)
                Text("\(client.pingMs)ms")
                    .font(.caption.monospaced())
                    .foregroundStyle(client.pingMs < 80 ? .green : .orange)
                Button("leave", action: onLeave)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.4))

            Arena(client: client)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Pad(client: client)
                .frame(height: 220)
                .padding()
        }
    }
}

struct Arena: View {
    @ObservedObject var client: GameClient

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let scale = min(size.width, size.height) /
                        CGFloat(GameClient.worldMax - GameClient.worldMin) * 1.6

            ZStack {
                Baseplate(size: size, scale: scale)

                ForEach(client.players) { p in
                    Blocky(
                        color: colorFor(p.id),
                        name: p.name,
                        facingDeg: p.dir
                    )
                    .frame(width: 26 * 1.0, height: 44 * 1.0)
                    .position(point(for: p.renderX, p.renderY, in: size, scale: scale))
                }

                Blocky(
                    color: Color(red: 0.35, green: 0.8, blue: 0.4),
                    name: "you",
                    facingDeg: client.myDir
                )
                .frame(width: 26, height: 44)
                .position(point(for: client.myX, client.myY, in: size, scale: scale))
            }
        }
    }

    private func point(for x: Float, _ y: Float,
                       in size: CGSize, scale: CGFloat) -> CGPoint {
        let cx = size.width / 2
        let cy = size.height / 2
        return CGPoint(
            x: cx + CGFloat(x) * scale,
            y: cy - CGFloat(y) * scale
        )
    }

    private func colorFor(_ id: UInt32) -> Color {
        let palette: [Color] = [
            Color(red: 0.85, green: 0.2,  blue: 0.2),
            Color(red: 0.2,  green: 0.4,  blue: 0.9),
            Color(red: 0.95, green: 0.75, blue: 0.1),
            Color(red: 0.65, green: 0.2,  blue: 0.85),
            Color(red: 0.95, green: 0.5,  blue: 0.15),
            Color(red: 0.2,  green: 0.75, blue: 0.75),
        ]
        return palette[Int(id) % palette.count]
    }
}

struct Baseplate: View {
    let size: CGSize
    let scale: CGFloat

    var body: some View {
        Canvas { ctx, canvasSize in
            let cx = canvasSize.width / 2
            let cy = canvasSize.height / 2
            let minX = CGFloat(GameClient.worldMin) * scale
            let maxX = CGFloat(GameClient.worldMax) * scale
            let minY = CGFloat(GameClient.worldMin) * scale
            let maxY = CGFloat(GameClient.worldMax) * scale

            let rect = CGRect(
                x: cx + minX,
                y: cy - maxY,
                width: maxX - minX,
                height: maxY - minY
            )

            ctx.fill(Path(rect), with: .color(Color(red: 0.35, green: 0.5, blue: 0.3)))

            let studStep = 20 * scale
            if studStep > 4 {
                var x = rect.minX
                while x <= rect.maxX {
                    var y = rect.minY
                    while y <= rect.maxY {
                        let c = CGRect(x: x - studStep * 0.28,
                                       y: y - studStep * 0.28,
                                       width: studStep * 0.56,
                                       height: studStep * 0.56)
                        ctx.fill(Path(ellipseIn: c),
                                 with: .color(Color(red: 0.3, green: 0.44, blue: 0.26)))
                        y += studStep
                    }
                    x += studStep
                }
            }

            let border = rect.insetBy(dx: -4, dy: -4)
            ctx.stroke(Path(border),
                       with: .color(Color(red: 0.2, green: 0.3, blue: 0.18)),
                       lineWidth: 6)
        }
    }
}

struct Blocky: View {
    let color: Color
    let name: String
    let facingDeg: Float

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let headH = h * 0.38
            let torsoH = h * 0.42
            let legH = h - headH - torsoH

            VStack(spacing: 1) {
                ZStack {
                    Rectangle()
                        .fill(color.opacity(0.95))
                    Rectangle()
                        .stroke(Color.black.opacity(0.6), lineWidth: 1)
                    Face(facingDeg: facingDeg)
                }
                .frame(width: w * 0.85, height: headH)

                ZStack {
                    Rectangle()
                        .fill(color)
                    Rectangle()
                        .stroke(Color.black.opacity(0.6), lineWidth: 1)
                    Text(shortName)
                        .font(.system(size: max(6, w * 0.28), weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: w, height: torsoH)

                HStack(spacing: 1) {
                    Rectangle()
                        .fill(color.opacity(0.85))
                        .overlay(Rectangle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                    Rectangle()
                        .fill(color.opacity(0.85))
                        .overlay(Rectangle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                }
                .frame(width: w, height: legH)
            }
        }
    }

    private var shortName: String {
        let s = name.prefix(6)
        return String(s)
    }
}

struct Face: View {
    let facingDeg: Float

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let dx = CGFloat(cos(Double(facingDeg) * .pi / 180))
            let dy = CGFloat(sin(Double(facingDeg) * .pi / 180))

            let eyeOff: CGFloat = w * 0.22
            let eyeSize: CGFloat = max(2, w * 0.14)

            HStack(spacing: w * 0.2) {
                eye
                    .frame(width: eyeSize, height: eyeSize)
                eye
                    .frame(width: eyeSize, height: eyeSize)
            }
            .offset(x: dx * w * 0.08, y: dy * h * 0.12 - h * 0.1)
        }
    }

    private var eye: some View {
        Circle().fill(Color.black)
    }
}

struct Pad: View {
    @ObservedObject var client: GameClient
    let step: Float = 6

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let cx = geo.size.width / 2
            let cy = geo.size.height / 2
            let r = s / 2 - 10

            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: r * 2, height: r * 2)
                    .position(x: cx, y: cy)

                ForEach(Direction.allCases, id: \.self) { dir in
                    PadButton(symbol: dir.symbol) {
                        let v = dir.vector
                        client.move(dx: v.x * step, dy: v.y * step)
                    }
                    .position(x: cx + dir.offset.x * r * 0.68,
                              y: cy + dir.offset.y * r * 0.68)
                }
            }
        }
    }
}

struct PadButton: View {
    let symbol: String
    let action: () -> Void
    @State private var pressing = false
    @State private var timer: Timer?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 68, height: 68)
            .background(Circle().fill(pressing ?
                Color(red: 0.3, green: 0.75, blue: 0.35) :
                Color.white.opacity(0.12)))
            .scaleEffect(pressing ? 0.92 : 1.0)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in start() }
                    .onEnded { _ in stop() }
            )
    }

    private func start() {
        guard timer == nil else { return }
        pressing = true
        action()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            action()
        }
    }

    private func stop() {
        pressing = false
        timer?.invalidate()
        timer = nil
    }
}

enum Direction: CaseIterable {
    case up, down, left, right

    var symbol: String {
        switch self {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        }
    }

    var vector: (x: Float, y: Float) {
        switch self {
        case .up: return (0, 1)
        case .down: return (0, -1)
        case .left: return (-1, 0)
        case .right: return (1, 0)
        }
    }

    var offset: (x: CGFloat, y: CGFloat) {
        switch self {
        case .up: return (0, -1)
        case .down: return (0, 1)
        case .left: return (-1, 0)
        case .right: return (1, 0)
        }
    }
}

#Preview {
    ContentView()
}
