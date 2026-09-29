import SwiftUI
import Network

// MARK: - Shared rendering constants

enum Render {
    static let worldSize: Float = 250
    static let worldView: CGFloat = 0.85
    static let charW: CGFloat = 30
    static let charH: CGFloat = 50
    static let headRatio: CGFloat = 0.34
    static let torsoRatio: CGFloat = 0.36
    static let studStep: CGFloat = 22
    static let interp: Float = 0.22

    // 6 colors, deterministic by id
    static let palette: [(r: Double, g: Double, b: Double)] = [
        (0.90, 0.25, 0.25),
        (0.25, 0.45, 0.95),
        (0.95, 0.78, 0.15),
        (0.70, 0.30, 0.90),
        (0.95, 0.55, 0.15),
        (0.15, 0.80, 0.80),
    ]

    static func color(_ id: UInt32) -> Color {
        let c = palette[Int(id) % palette.count]
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}

// MARK: - Models

struct RemotePlayer: Identifiable, Equatable {
    let id: UInt32
    var name: String
    var x: Float
    var y: Float
    var dir: Int
    var renderX: Float
    var renderY: Float
    var renderDir: Float
}

enum ConnectionState: Equatable {
    case disconnected, connecting, connected
    case failed(String)
}

// MARK: - Client

@MainActor
final class GameClient: ObservableObject {
    static let serverHost = "192.168.1.68"
    static let serverPort: UInt16 = 9932

    @Published var state: ConnectionState = .disconnected
    @Published var myId: UInt32 = 0
    @Published var myX: Float = 0
    @Published var myY: Float = 0
    @Published var myDir: Int = 2
    @Published var myRenderDir: Float = 2
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
        myId = 0; myX = 0; myY = 0; myDir = 2
    }

    func send(_ msg: String) {
        guard let conn else { return }
        let data = (msg + "\n").data(using: .utf8)!
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    func move(dx: Float, dy: Float) {
        guard state == .connected else { return }
        myX = min(max(myX + dx, -Render.worldSize), Render.worldSize)
        myY = min(max(myY + dy, -Render.worldSize), Render.worldSize)
        if abs(dx) > 0.01 || abs(dy) > 0.01 {
            myDir = snapDir8(deg: atan2(dy, dx) * 180 / .pi)
        }
        send(String(format: "MOVE %.2f %.2f %d", myX, myY, myDir))
    }

    private func snapDir8(deg: Float) -> Int {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return Int(((d + 22.5) / 45).rounded(.down)) % 8
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
                if parts.count >= 4,
                   let id = UInt32(parts[1]),
                   let x = Float(parts[2]),
                   let y = Float(parts[3]) {
                    myId = id; myX = x; myY = y
                }
            case "JOINED":
                guard parts.count >= 5,
                      let id = UInt32(parts[1]),
                      let x = Float(parts[3]),
                      let y = Float(parts[4]) else { return }
                let d = 2
                upsert(RemotePlayer(id: id, name: parts[2],
                                    x: x, y: y, dir: d,
                                    renderX: x, renderY: y,
                                    renderDir: Float(d)))
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
                          let d = Int(parts[idx + 3]) else { break }
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
                                                    renderDir: Float(d)))
                    }
                }
                players.removeAll { $0.id != myId && !seen.contains($0.id) }
            case "STATE":
                var idx = 2
                while idx + 4 < parts.count {
                    if let id = UInt32(parts[idx]),
                       let x = Float(parts[idx + 2]),
                       let y = Float(parts[idx + 3]),
                       let d = Int(parts[idx + 4]) {
                        let name = parts[idx + 1]
                        if id != myId {
                            upsert(RemotePlayer(id: id, name: name,
                                                x: x, y: y, dir: d,
                                                renderX: x, renderY: y,
                                                renderDir: Float(d)))
                        }
                    }
                    idx += 5
                }
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
        if let i = players.firstIndex(where: { $0.id == p.id }) {
            players[i].x = p.x; players[i].y = p.y; players[i].dir = p.dir
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

    private func stopPing() { pingTimer?.invalidate(); pingTimer = nil }

    private func startTick() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0,
                                         repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let t = Render.interp
        for i in players.indices {
            players[i].renderX += (players[i].x - players[i].renderX) * t
            players[i].renderY += (players[i].y - players[i].renderY) * t
            var dd = Float(players[i].dir) - players[i].renderDir
            while dd > 180 { dd -= 360 }
            while dd < -180 { dd += 360 }
            players[i].renderDir += dd * t * 0.5
        }
        var mydd = Float(myDir) - myRenderDir
        while mydd > 180 { mydd -= 360 }
        while mydd < -180 { mydd += 360 }
        myRenderDir += mydd * t * 0.5
    }

    private func stopTimers() { stopPing(); tickTimer?.invalidate(); tickTimer = nil }
}

// MARK: - Views

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
            LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.22),
                                    Color(red: 0.02, green: 0.03, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 26) {
                Text("BLOX ARENA")
                    .font(.system(size: 46, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(colors: [.white, Color(red: 0.45, green: 0.95, blue: 0.6)],
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

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let scale = min(size.width, size.height) /
                        CGFloat(Render.worldSize * 2) * Render.worldView

            ZStack {
                LinearGradient(colors: [Color(red: 0.42, green: 0.63, blue: 0.96),
                                        Color(red: 0.79, green: 0.88, blue: 0.98)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                Baseplate(size: size, scale: scale)

                let sorted = client.players.sorted { $0.renderY > $1.renderY }
                ForEach(sorted) { p in
                    BlockyChar(id: p.id, name: p.name, isYou: false,
                               facing: p.renderDir)
                        .frame(width: Render.charW, height: Render.charH)
                        .position(point(for: p.renderX, p.renderY, in: size, scale: scale))
                }

                BlockyChar(id: client.myId, name: "you", isYou: true,
                           facing: client.myRenderDir)
                    .frame(width: Render.charW, height: Render.charH)
                    .position(point(for: client.myX, client.myY, in: size, scale: scale))
            }
        }
    }

    private func point(for x: Float, _ y: Float,
                       in size: CGSize, scale: CGFloat) -> CGPoint {
        CGPoint(x: size.width / 2 + CGFloat(x) * scale,
                y: size.height / 2 - CGFloat(y) * scale)
    }
}

struct Baseplate: View {
    let size: CGSize
    let scale: CGFloat

    var body: some View {
        Canvas { ctx, canvasSize in
            let cx = canvasSize.width / 2
            let cy = canvasSize.height / 2
            let half = CGFloat(Render.worldSize) * scale
            let rect = CGRect(x: cx - half, y: cy - half,
                              width: half * 2, height: half * 2)

            ctx.fill(Path(rect),
                     with: .color(Color(red: 0.42, green: 0.58, blue: 0.36)))

            let step = Render.studStep * scale
            if step > 5 {
                var x = rect.minX
                while x <= rect.maxX {
                    var y = rect.minY
                    while y <= rect.maxY {
                        let c = CGRect(x: x - step * 0.3,
                                       y: y - step * 0.3,
                                       width: step * 0.6,
                                       height: step * 0.6)
                        ctx.fill(Path(ellipseIn: c),
                                 with: .color(Color(red: 0.35, green: 0.5, blue: 0.3)))
                        y += step
                    }
                    x += step
                }
            }

            var grid = Path()
            var gx = rect.minX
            while gx <= rect.maxX {
                grid.move(to: CGPoint(x: gx, y: rect.minY))
                grid.addLine(to: CGPoint(x: gx, y: rect.maxY))
                gx += 50 * scale
            }
            var gy = rect.minY
            while gy <= rect.maxY {
                grid.move(to: CGPoint(x: rect.minX, y: gy))
                grid.addLine(to: CGPoint(x: rect.maxX, y: gy))
                gy += 50 * scale
            }
            ctx.stroke(grid, with: .color(.black.opacity(0.06)), lineWidth: 1)

            let border = rect.insetBy(dx: -4, dy: -4)
            ctx.stroke(Path(border),
                       with: .color(Color(red: 0.25, green: 0.35, blue: 0.22)),
                       lineWidth: 8)
        }
    }
}

struct BlockyChar: View {
    let id: UInt32
    let name: String
    let isYou: Bool
    let facing: Float

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let headH = h * Render.headRatio
            let torsoH = h * Render.torsoRatio
            let legH = h - headH - torsoH - 4
            let bodyColor = isYou ? Color(red: 0.35, green: 0.85, blue: 0.45)
                                  : Render.color(id)

            VStack(spacing: 2) {
                ZStack {
                    Rectangle()
                        .fill(bodyColor)
                        .overlay(Rectangle().stroke(.black.opacity(0.55), lineWidth: 1.2))
                    Face(facing: facing)
                }
                .frame(width: w * 0.9, height: headH)

                ZStack {
                    Rectangle()
                        .fill(bodyColor)
                        .overlay(Rectangle().stroke(.black.opacity(0.55), lineWidth: 1.2))
                    Text(String(name.prefix(6)))
                        .font(.system(size: max(6, w * 0.24), weight: .black))
                        .foregroundStyle(.white)
                }
                .frame(width: w, height: torsoH)

                HStack(spacing: 2) {
                    Rectangle()
                        .fill(bodyColor)
                        .overlay(Rectangle().stroke(.black.opacity(0.55), lineWidth: 1.2))
                    Rectangle()
                        .fill(bodyColor)
                        .overlay(Rectangle().stroke(.black.opacity(0.55), lineWidth: 1.2))
                }
                .frame(width: w, height: legH)
            }
            .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
            .overlay(
                isYou ? RoundedRectangle(cornerRadius: 4)
                    .stroke(.white.opacity(0.85), lineWidth: 2) : nil
            )
        }
    }
}

struct Face: View {
    let facing: Float

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let rad = Double(facing) * .pi / 180
            let dx = CGFloat(cos(rad))
            let dy = -CGFloat(sin(rad))
            let eyeSize: CGFloat = max(2.5, w * 0.13)
            let off = w * 0.14

            HStack(spacing: w * 0.2) {
                Circle().fill(.black).frame(width: eyeSize, height: eyeSize)
                Circle().fill(.black).frame(width: eyeSize, height: eyeSize)
            }
            .offset(x: dx * off, y: dy * off * 0.6 - h * 0.05)
        }
    }
}

struct Joystick: View {
    @ObservedObject var client: GameClient
    @State private var offset: CGSize = .zero
    @State private var timer: Timer?

    let knobSize: CGFloat = 62

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2

            ZStack {
                Circle()
                    .fill(.white.opacity(0.10))
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 2))
                    .frame(width: size, height: size)

                Circle()
                    .fill(RadialGradient(
                        colors: [.white.opacity(0.95),
                                 Color(red: 0.35, green: 0.85, blue: 0.5)],
                        center: .topLeading, startRadius: 2, endRadius: knobSize))
                    .frame(width: knobSize, height: knobSize)
                    .offset(offset)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
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
                        withAnimation(.spring(response: 0.2)) { offset = .zero }
                        timer?.invalidate(); timer = nil
                    }
            )
        }
    }

    private func applyMove(dx: CGFloat, dy: CGFloat, maxR: CGFloat) {
        let nx = dx / maxR
        let ny = dy / maxR
        guard sqrt(nx*nx + ny*ny) > 0.1 else { return }
        let speed: Float = 6
        client.move(dx: Float(nx) * speed, dy: Float(-ny) * speed)
    }

    private func startTimer(maxR: CGFloat) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in applyMove(dx: offset.width, dy: offset.height, maxR: maxR) }
        }
    }
}

#Preview {
    ContentView()
}
