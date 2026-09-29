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
    var renderDir: Float
}

enum ConnectionState: Equatable {
    case disconnected, connecting, connected
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

        let c = NWConnection(host: host, port: port, using: params)
        self.conn = c

        c.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.state = .connected
                    self.send("JOIN \(name)")
                    self.startPing()
                    self.startTick()
                    self.receiveLoop()
                case .failed(let err):
                    self.state = .failed("\(err)")
                case .cancelled:
                    self.state = .disconnected
                    self.stopTimers()
                default: break
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
        myId = 0; myX = 0; myY = 0; myDir = 0
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
                if error == nil { self.receiveLoop() }
                else { self.state = .failed("\(error!)") }
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
                if parts.count >= 2, let id = UInt32(parts[1]) { myId = id }
            case "JOINED":
                guard parts.count >= 6,
                      let id = UInt32(parts[1]),
                      let x = Float(parts[3]),
                      let y = Float(parts[4]),
                      let d = Float(parts[5]) else { return }
                upsert(RemotePlayer(id: id, name: parts[2], x: x, y: y, dir: d,
                                    renderX: x, renderY: y, renderDir: d))
            case "LEFT":
                guard parts.count >= 2, let id = UInt32(parts[1]) else { return }
                players.removeAll { $0.id == id }
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
                                                    renderX: x, renderY: y,
                                                    renderDir: d))
                    }
                }
                players.removeAll { $0.id != myId && !seen.contains($0.id) }
            case "PONG":
                if parts.count >= 2, let ms = Int(parts[1]) {
                    let now = Int(Date().timeIntervalSince1970 * 1000)
                    pingMs = max(0, now - ms)
                }
            default: break
            }
        }
    }

    private func upsert(_ p: RemotePlayer) {
        if let i = players.firstIndex(where: { $0.id == p.id }) { players[i] = p }
        else { players.append(p) }
    }

    private func startPing() {
        stopPing()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.send("PING") }
        }
    }

    private func stopPing() { pingTimer?.invalidate(); pingTimer = nil }

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
                    self.players[i].renderDir += (self.players[i].dir - self.players[i].renderDir) * t
                }
            }
        }
    }

    private func stopTimers() { stopPing(); tickTimer?.invalidate(); tickTimer = nil }
}

struct ContentView: View {
    @StateObject private var client = GameClient()
    @State private var name: String = ""
    @State private var hasJoined = false

    var body: some View {
        ZStack {
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
        .ignoresSafeArea()
    }
}

struct JoinView: View {
    @Binding var name: String
    @ObservedObject var client: GameClient
    var onJoin: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.08, green: 0.1, blue: 0.18),
                                    Color(red: 0.02, green: 0.03, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 26) {
                Text("BLOX ARENA")
                    .font(.system(size: 46, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(colors: [.white, Color(red: 0.4, green: 0.9, blue: 0.5)],
                                       startPoint: .top, endPoint: .bottom))

                Text("\(GameClient.serverHost):\(GameClient.serverPort)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.gray)

                TextField("your name", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding()
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(14)
                    .foregroundStyle(.white)
                    .frame(maxWidth: 320)

                Button(action: onJoin) {
                    Text("PLAY")
                        .font(.headline)
                        .frame(maxWidth: 320)
                        .padding()
                        .background(
                            LinearGradient(colors: [Color(red: 0.35, green: 0.85, blue: 0.4),
                                                    Color(red: 0.2, green: 0.65, blue: 0.3)],
                                           startPoint: .top, endPoint: .bottom))
                        .foregroundStyle(.white)
                        .cornerRadius(14)
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
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
}

struct GameView: View {
    @ObservedObject var client: GameClient
    var onLeave: () -> Void

    var body: some View {
        ZStack {
            Arena(client: client)

            VStack {
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
                .padding(.top, 44)
                .padding(.bottom, 8)
                .background(
                    LinearGradient(colors: [.black.opacity(0.6), .clear],
                                   startPoint: .top, endPoint: .bottom))
                Spacer()
                Joystick(client: client)
                    .frame(width: 160, height: 160)
                    .padding(.bottom, 40)
            }
        }
        .ignoresSafeArea()
    }
}

struct Arena: View {
    @ObservedObject var client: GameClient
    let scaleFactor: CGFloat = 0.85

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let scale = min(size.width, size.height) /
                        CGFloat(GameClient.worldMax - GameClient.worldMin) * scaleFactor

            ZStack {
                Sky()
                Baseplate(size: size, scale: scale, worldSize: size)

                let sorted = client.players.sorted {
                    $0.renderY > $1.renderY
                }
                ForEach(sorted) { p in
                    BlockyChar(color: colorFor(p.id),
                               name: p.name,
                               isYou: false,
                               facing: p.renderDir)
                        .frame(width: 34, height: 56)
                        .position(point(for: p.renderX, p.renderY, in: size, scale: scale))
                }

                BlockyChar(color: Color(red: 0.35, green: 0.85, blue: 0.45),
                           name: "you",
                           isYou: true,
                           facing: client.myDir)
                    .frame(width: 34, height: 56)
                    .position(point(for: client.myX, client.myY, in: size, scale: scale))
            }
        }
    }

    private func point(for x: Float, _ y: Float,
                       in size: CGSize, scale: CGFloat) -> CGPoint {
        CGPoint(x: size.width / 2 + CGFloat(x) * scale,
                y: size.height / 2 - CGFloat(y) * scale)
    }

    private func colorFor(_ id: UInt32) -> Color {
        let palette: [Color] = [
            Color(red: 0.9,  green: 0.25, blue: 0.25),
            Color(red: 0.25, green: 0.45, blue: 0.95),
            Color(red: 0.95, green: 0.78, blue: 0.15),
            Color(red: 0.7,  green: 0.25, blue: 0.9),
            Color(red: 0.95, green: 0.55, blue: 0.15),
            Color(red: 0.2,  green: 0.8,  blue: 0.8),
        ]
        return palette[Int(id) % palette.count]
    }
}

struct Sky: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.4, green: 0.6, blue: 0.95),
                                Color(red: 0.75, green: 0.85, blue: 0.98)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

struct Baseplate: View {
    let size: CGSize
    let scale: CGFloat
    let worldSize: CGSize

    var body: some View {
        Canvas { ctx, canvasSize in
            let cx = canvasSize.width / 2
            let cy = canvasSize.height / 2
            let half = CGFloat(GameClient.worldMax) * scale
            let rect = CGRect(x: cx - half, y: cy - half,
                              width: half * 2, height: half * 2)

            ctx.fill(Path(rect),
                     with: .color(Color(red: 0.42, green: 0.58, blue: 0.36)))

            let studStep = 22 * scale
            if studStep > 5 {
                var x = rect.minX
                while x <= rect.maxX {
                    var y = rect.minY
                    while y <= rect.maxY {
                        let c = CGRect(x: x - studStep * 0.3,
                                       y: y - studStep * 0.3,
                                       width: studStep * 0.6,
                                       height: studStep * 0.6)
                        ctx.fill(Path(ellipseIn: c),
                                 with: .color(Color(red: 0.35,
                                                     green: 0.5,
                                                     blue: 0.3)))
                        y += studStep
                    }
                    x += studStep
                }
            }

            let border = rect.insetBy(dx: -6, dy: -6)
            ctx.stroke(Path(border),
                       with: .color(Color(red: 0.25, green: 0.35, blue: 0.22)),
                       lineWidth: 8)

            for i in stride(from: rect.minX, to: rect.maxX, by: 100 * scale) {
                var p = Path()
                p.move(to: CGPoint(x: i, y: rect.minY))
                p.addLine(to: CGPoint(x: i, y: rect.maxY))
                ctx.stroke(p, with: .color(Color.black.opacity(0.05)), lineWidth: 1)
            }
            for i in stride(from: rect.minY, to: rect.maxY, by: 100 * scale) {
                var p = Path()
                p.move(to: CGPoint(x: rect.minX, y: i))
                p.addLine(to: CGPoint(x: rect.maxX, y: i))
                ctx.stroke(p, with: .color(Color.black.opacity(0.05)), lineWidth: 1)
            }
        }
    }
}

struct BlockyChar: View {
    let color: Color
    let name: String
    let isYou: Bool
    let facing: Float

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let headH = h * 0.34
            let torsoH = h * 0.36
            let legH = h - headH - torsoH - 4

            VStack(spacing: 2) {
                ZStack {
                    Rectangle()
                        .fill(color)
                    Rectangle()
                        .stroke(Color.black.opacity(0.55), lineWidth: 1.2)
                    Face(facing: facing, size: headH)
                }
                .frame(width: w * 0.9, height: headH)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)

                ZStack {
                    Rectangle()
                        .fill(color)
                    Rectangle()
                        .stroke(Color.black.opacity(0.55), lineWidth: 1.2)
                    Text(shortName)
                        .font(.system(size: max(6, w * 0.24), weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
                }
                .frame(width: w, height: torsoH)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)

                HStack(spacing: 2) {
                    Rectangle()
                        .fill(color.opacity(0.9))
                        .overlay(Rectangle().stroke(Color.black.opacity(0.55), lineWidth: 1.2))
                    Rectangle()
                        .fill(color.opacity(0.9))
                        .overlay(Rectangle().stroke(Color.black.opacity(0.55), lineWidth: 1.2))
                }
                .frame(width: w, height: legH)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            }
            .overlay(
                isYou ?
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white.opacity(0.8), lineWidth: 2) : nil
            )
        }
    }

    private var shortName: String {
        String(name.prefix(6))
    }
}

struct Face: View {
    let facing: Float
    let size: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let rad = Double(facing) * .pi / 180
            let dx = CGFloat(cos(rad))
            let dy = -CGFloat(sin(rad))

            let eyeSize: CGFloat = max(2.5, w * 0.13)
            let off = w * 0.16

            HStack(spacing: w * 0.2) {
                Circle().fill(Color.black)
                    .frame(width: eyeSize, height: eyeSize)
                Circle().fill(Color.black)
                    .frame(width: eyeSize, height: eyeSize)
            }
            .offset(x: dx * off, y: dy * off * 0.6 - h * 0.05)
        }
    }
}

struct Joystick: View {
    @ObservedObject var client: GameClient
    @State private var offset: CGSize = .zero
    @State private var active = false
    @State private var timer: Timer?

    let knobSize: CGFloat = 60

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2

            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 2))
                    .frame(width: size, height: size)

                Circle()
                    .fill(
                        RadialGradient(colors: [Color.white.opacity(0.95),
                                                Color(red: 0.35, green: 0.85, blue: 0.5)],
                                       center: .topLeading,
                                       startRadius: 2,
                                       endRadius: knobSize)
                    )
                    .frame(width: knobSize, height: knobSize)
                    .offset(offset)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        active = true
                        let cx = geo.size.width / 2
                        let cy = geo.size.height / 2
                        var dx = v.location.x - cx
                        var dy = v.location.y - cy
                        let d = sqrt(dx*dx + dy*dy)
                        let maxR = radius - knobSize / 2
                        if d > maxR {
                            dx *= maxR / d
                            dy *= maxR / d
                        }
                        offset = CGSize(width: dx, height: dy)
                        applyMove(dx: dx, dy: dy, maxR: maxR)
                        startTimer(maxR: maxR)
                    }
                    .onEnded { _ in
                        active = false
                        withAnimation(.spring(response: 0.2)) { offset = .zero }
                        timer?.invalidate(); timer = nil
                    }
            )
        }
    }

    private func applyMove(dx: CGFloat, dy: CGFloat, maxR: CGFloat) {
        let nx = dx / maxR
        let ny = dy / maxR
        let magnitude = sqrt(nx*nx + ny*ny)
        guard magnitude > 0.1 else { return }
        let speed: Float = 7
        client.move(dx: Float(nx) * speed, dy: Float(-ny) * speed)
    }

    private func startTimer(maxR: CGFloat) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                applyMove(dx: offset.width, dy: offset.height, maxR: maxR)
            }
        }
    }
}

#Preview {
    ContentView()
}
