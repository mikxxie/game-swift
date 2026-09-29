import SwiftUI
import Network

enum Render {
    static let worldSize: Float = 250
    static let charW: CGFloat = 34
    static let charH: CGFloat = 54
    static let headRatio: CGFloat = 0.32
    static let torsoRatio: CGFloat = 0.38
    static let studStep: CGFloat = 24
    static let interp: Float = 0.22
    static let zScale: CGFloat = 0.6

    static let isoAngle = Double.pi / 6
    static let isoCos = CGFloat(cos(isoAngle))
    static let isoSin = CGFloat(sin(isoAngle))

    static let palette: [(r: Double, g: Double, b: Double)] = [
        (0.659, 0.259, 0.259),
        (0.259, 0.376, 0.659),
        (0.698, 0.596, 0.243),
        (0.502, 0.290, 0.620),
        (0.698, 0.439, 0.220),
        (0.243, 0.588, 0.588),
    ]

    static func color(_ id: UInt32) -> Color {
        let c = palette[Int(id) % palette.count]
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    static func lighten(_ c: (r: Double, g: Double, b: Double), _ amt: Double) -> Color {
        Color(red: min(1, c.r + amt), green: min(1, c.g + amt), blue: min(1, c.b + amt))
    }

    static func darken(_ c: (r: Double, g: Double, b: Double), _ amt: Double) -> Color {
        Color(red: max(0, c.r - amt), green: max(0, c.g - amt), blue: max(0, c.b - amt))
    }
}

struct Obstacle: Equatable {
    var x: Float
    var y: Float
    var w: Float
    var h: Float
}

struct RemotePlayer: Identifiable, Equatable {
    let id: UInt32
    var name: String
    var x: Float
    var y: Float
    var z: Float
    var dir: Int
    var grounded: Bool
    var renderX: Float
    var renderY: Float
    var renderZ: Float
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

    @Published var state: ConnectionState = .disconnected
    @Published var myId: UInt32 = 0
    @Published var myX: Float = 0
    @Published var myY: Float = 0
    @Published var myZ: Float = 0
    @Published var myDir: Int = 2
    @Published var myRenderX: Float = 0
    @Published var myRenderY: Float = 0
    @Published var myRenderZ: Float = 0
    @Published var myRenderDir: Float = 2
    @Published var players: [RemotePlayer] = []
    @Published var obstacles: [Obstacle] = []
    @Published var pingMs: Int = 0
    @Published var serverReachable: Bool? = nil
    @Published var statusText: String = ""

    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "udp.client")
    private var pingTimer: Timer?
    private var tickTimer: Timer?
    private var lastInputSent: String = ""

    func probeServer() async {
        await MainActor.run {
            self.serverReachable = nil
            self.statusText = "checking server…"
        }

        let host = NWEndpoint.Host(Self.serverHost)
        let port = NWEndpoint.Port(rawValue: Self.serverPort)!
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        let probe = NWConnection(host: host, port: port, using: params)
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resumed = false
            let resumeOnce: (Bool) -> Void = { ok in
                guard !resumed else { return }
                resumed = true
                probe.cancel()
                cont.resume(returning: ok)
            }
            probe.stateUpdateHandler = { s in
                switch s {
                case .ready:
                    probe.send(content: "PING\n".data(using: .utf8)!,
                               completion: .contentProcessed { _ in })
                case .failed, .cancelled:
                    resumeOnce(false)
                default: break
                }
            }
            probe.start(queue: DispatchQueue(label: "udp.probe"))
            probe.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, _ in
                if let data, !data.isEmpty { resumeOnce(true) }
                else { resumeOnce(false) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                resumeOnce(false)
            }
        }

        await MainActor.run {
            self.serverReachable = result
            self.statusText = result
                ? "server reachable"
                : "server unreachable — check Wi-Fi and that the server is running"
        }
    }

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
        obstacles.removeAll()
        myId = 0
        myX = 0; myY = 0; myZ = 0
        myRenderX = 0; myRenderY = 0; myRenderZ = 0
        myDir = 2; myRenderDir = 2
        serverReachable = nil
        statusText = ""
    }

    func send(_ msg: String) {
        guard let conn else { return }
        let data = (msg + "\n").data(using: .utf8)!
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    func sendInput(dx: Float, dy: Float) {
        guard state == .connected else { return }
        let key = String(format: "%.3f,%.3f", dx, dy)
        if key == lastInputSent { return }
        lastInputSent = key
        send(String(format: "INPUT %.3f %.3f", dx, dy))
    }

    func sendJump() {
        guard state == .connected else { return }
        send("JUMP")
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
                    myId = id
                    myX = x; myY = y
                    myRenderX = x; myRenderY = y
                }
            case "OBSTACLES":
                guard parts.count >= 2, let n = Int(parts[1]) else { return }
                var idx = 2
                var list: [Obstacle] = []
                for _ in 0..<n {
                    guard idx + 3 < parts.count,
                          let x = Float(parts[idx]),
                          let y = Float(parts[idx + 1]),
                          let w = Float(parts[idx + 2]),
                          let h = Float(parts[idx + 3]) else { break }
                    list.append(Obstacle(x: x, y: y, w: w, h: h))
                    idx += 4
                }
                obstacles = list
            case "JOINED":
                guard parts.count >= 5,
                      let id = UInt32(parts[1]),
                      let x = Float(parts[3]),
                      let y = Float(parts[4]) else { return }
                let name = parts[2]
                let d = 2
                upsert(RemotePlayer(id: id, name: name,
                                    x: x, y: y, z: 0, dir: d, grounded: true,
                                    renderX: x, renderY: y, renderZ: 0,
                                    renderDir: Float(d)))
            case "LEFT":
                guard parts.count >= 2, let id = UInt32(parts[1]) else { return }
                players.removeAll { $0.id == id }
            case "SNAP":
                guard parts.count >= 2, let n = Int(parts[1]) else { return }
                var idx = 2
                var seen = Set<UInt32>()
                for _ in 0..<n {
                    guard idx + 5 < parts.count,
                          let id = UInt32(parts[idx]),
                          let x = Float(parts[idx + 1]),
                          let y = Float(parts[idx + 2]),
                          let z = Float(parts[idx + 3]),
                          let d = Int(parts[idx + 4]),
                          let gRaw = Int(parts[idx + 5]) else { break }
                    idx += 6
                    let g = gRaw == 1
                    if id == myId {
                        myX = x; myY = y; myZ = z
                        myDir = d
                        continue
                    }
                    seen.insert(id)
                    if let i = players.firstIndex(where: { $0.id == id }) {
                        players[i].x = x
                        players[i].y = y
                        players[i].z = z
                        players[i].dir = d
                        players[i].grounded = g
                    } else {
                        players.append(RemotePlayer(id: id, name: "player",
                                                    x: x, y: y, z: z, dir: d,
                                                    grounded: g,
                                                    renderX: x, renderY: y,
                                                    renderZ: z,
                                                    renderDir: Float(d)))
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
        if let i = players.firstIndex(where: { $0.id == p.id }) {
            players[i].x = p.x
            players[i].y = p.y
            players[i].z = p.z
            players[i].dir = p.dir
            players[i].grounded = p.grounded
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
        myRenderX += (myX - myRenderX) * 0.35
        myRenderY += (myY - myRenderY) * 0.35
        myRenderZ += (myZ - myRenderZ) * 0.45

        let t = Render.interp
        for i in players.indices {
            players[i].renderX += (players[i].x - players[i].renderX) * t
            players[i].renderY += (players[i].y - players[i].renderY) * t
            players[i].renderZ += (players[i].z - players[i].renderZ) * 0.3
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
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}

struct JoinView: View {
    @Binding var name: String
    @ObservedObject var client: GameClient
    var onJoin: () -> Void
    @State private var probing = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.42, green: 0.63, blue: 0.96),
                                    Color(red: 0.79, green: 0.88, blue: 0.98)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 22) {
                Text("BLOX ARENA")
                    .font(.system(size: 42, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text("\(GameClient.serverHost):\(GameClient.serverPort)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.gray)

                TextField("your name", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color(red: 0.15, green: 0.16, blue: 0.18))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(red: 0.21, green: 0.22, blue: 0.24), lineWidth: 1))
                    .cornerRadius(10)
                    .foregroundStyle(.white)
                    .frame(width: 260)
                    .multilineTextAlignment(.center)

                Button(action: {
                    probing = true
                    Task {
                        await client.probeServer()
                        probing = false
                        if client.serverReachable == true {
                            onJoin()
                        }
                    }
                }) {
                    Text(probing ? "CHECKING…" : "PLAY")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 260)
                        .padding(12)
                        .background(probing
                                    ? Color(red: 0.24, green: 0.26, blue: 0.29)
                                    : Color(red: 0.29, green: 0.31, blue: 0.34))
                        .foregroundStyle(.white)
                        .cornerRadius(10)
                }
                .disabled(probing)

                if client.serverReachable == false {
                    Text(client.statusText)
                        .font(.caption)
                        .foregroundStyle(Color(red: 0.82, green: 0.54, blue: 0.54))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                } else if case .failed(let msg) = client.state {
                    Text("failed: \(msg)")
                        .font(.caption)
                        .foregroundStyle(Color(red: 0.82, green: 0.54, blue: 0.54))
                }
            }
            .padding(28)
            .background(Color(red: 0.11, green: 0.12, blue: 0.14))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(Color(red: 0.17, green: 0.18, blue: 0.20), lineWidth: 1))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
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
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("id \(client.myId)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Capsule())
                        Text(String(format: "%.1f, %.1f", client.myX, client.myY))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Button("leave", action: onLeave)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Color(red: 0.71, green: 0.24, blue: 0.24).opacity(0.85))
                        .clipShape(Capsule())

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(client.players.count + 1) online")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Capsule())
                        Text("\(client.pingMs) ms")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(client.pingMs < 80 ? Color(red: 0.72, green: 0.90, blue: 0.75)
                                             : client.pingMs < 180 ? Color(red: 0.94, green: 0.88, blue: 0.63)
                                             : Color(red: 0.94, green: 0.69, blue: 0.69))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .background(
                    LinearGradient(colors: [.black.opacity(0.35), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 100)
                        .allowsHitTesting(false),
                    alignment: .top
                )

                Spacer()

                HStack(alignment: .bottom) {
                    Joystick(client: client)
                        .frame(width: 150, height: 150)
                        .padding(.leading, 28)
                        .padding(.bottom, 28)
                    Spacer()
                    JumpButton(client: client)
                        .frame(width: 74, height: 74)
                        .padding(.trailing, 28)
                        .padding(.bottom, 28)
                }
            }
        }
    }
}

struct JumpButton: View {
    @ObservedObject var client: GameClient
    @State private var pressed = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(pressed ? 0.28 : 0.14))
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 2))
            Text("JUMP")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
        .scaleEffect(pressed ? 0.95 : 1.0)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        pressed = true
                        client.sendJump()
                    }
                }
                .onEnded { _ in
                    pressed = false
                }
        )
    }
}

struct Arena: View {
    @ObservedObject var client: GameClient

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let camScale = min(size.width, size.height) /
                           CGFloat(Render.worldSize * 0.9)

            ZStack {
                LinearGradient(colors: [Color(red: 0.588, green: 0.686, blue: 0.784),
                                        Color(red: 0.804, green: 0.855, blue: 0.902)],
                               startPoint: .top, endPoint: .bottom)

                Baseplate(size: size, camScale: camScale,
                          camX: client.myRenderX, camY: client.myRenderY)

                ObstaclesLayer(size: size, camScale: camScale,
                               obstacles: client.obstacles,
                               camX: client.myRenderX, camY: client.myRenderY)

                let sorted = client.players.sorted { ($0.renderX + $0.renderY) < ($1.renderX + $1.renderY) }
                ForEach(sorted) { p in
                    CharSprite(id: p.id, name: p.name, isYou: false,
                               x: p.renderX, y: p.renderY, z: p.renderZ,
                               dir: p.renderDir,
                               size: size, camScale: camScale,
                               centerX: client.myRenderX, centerY: client.myRenderY)
                }

                CharSprite(id: client.myId, name: "you", isYou: true,
                           x: client.myRenderX, y: client.myRenderY, z: client.myRenderZ,
                           dir: client.myRenderDir,
                           size: size, camScale: camScale,
                           centerX: client.myRenderX, centerY: client.myRenderY)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }
}

struct Baseplate: View {
    let size: CGSize
    let camScale: CGFloat
    let camX: Float
    let camY: Float

    var body: some View {
        Canvas { ctx, _ in
            let cx = size.width / 2
            let cy = size.height / 2

            func toScreen(_ wx: Float, _ wy: Float) -> CGPoint {
                let rx = wx - camX
                let ry = wy - camY
                let ix = (CGFloat(rx) - CGFloat(ry)) * Render.isoCos
                let iy = (CGFloat(rx) + CGFloat(ry)) * Render.isoSin
                return CGPoint(x: cx + ix * camScale, y: cy + iy * camScale)
            }

            let corners = [
                toScreen(-Render.worldSize, -Render.worldSize),
                toScreen( Render.worldSize, -Render.worldSize),
                toScreen( Render.worldSize,  Render.worldSize),
                toScreen(-Render.worldSize,  Render.worldSize),
            ]

            var plate = Path()
            plate.move(to: corners[0])
            for i in 1..<4 { plate.addLine(to: corners[i]) }
            plate.closeSubpath()

            ctx.fill(plate, with: .color(Color(red: 0.478, green: 0.580, blue: 0.392)))

            ctx.drawLayer { layer in
                layer.clip(to: plate)

                let stepWorld = Float(Render.studStep)
                var wx = -Render.worldSize
                while wx <= Render.worldSize {
                    var wy = -Render.worldSize
                    while wy <= Render.worldSize {
                        let p = toScreen(wx, wy)
                        let r = camScale * CGFloat(stepWorld) * 0.30
                        if r > 2 {
                            let rect = CGRect(x: p.x - r, y: p.y - r * 0.55,
                                              width: r * 2, height: r * 1.1)
                            layer.fill(Path(ellipseIn: rect),
                                       with: .color(Color(red: 0.376, green: 0.478, blue: 0.314)))

                            let rect2 = CGRect(x: p.x - r * 0.75 - r * 0.15,
                                               y: p.y - r * 0.40 - r * 0.2,
                                               width: r * 1.5, height: r * 0.8)
                            layer.fill(Path(ellipseIn: rect2),
                                       with: .color(Color(red: 0.541, green: 0.635, blue: 0.439)))
                        }
                        wy += stepWorld
                    }
                    wx += stepWorld
                }
            }

            var boundary = Path()
            boundary.move(to: corners[0])
            for i in 1..<4 { boundary.addLine(to: corners[i]) }
            boundary.closeSubpath()
            ctx.stroke(boundary,
                       with: .color(Color(red: 0.227, green: 0.282, blue: 0.188).opacity(0.9)),
                       lineWidth: 4)
        }
    }
}

struct ObstaclesLayer: View {
    let size: CGSize
    let camScale: CGFloat
    let obstacles: [Obstacle]
    let camX: Float
    let camY: Float

    var body: some View {
        Canvas { ctx, _ in
            let cx = size.width / 2
            let cy = size.height / 2

            func toScreen(_ wx: Float, _ wy: Float) -> CGPoint {
                let rx = wx - camX
                let ry = wy - camY
                let ix = (CGFloat(rx) - CGFloat(ry)) * Render.isoCos
                let iy = (CGFloat(rx) + CGFloat(ry)) * Render.isoSin
                return CGPoint(x: cx + ix * camScale, y: cy + iy * camScale)
            }

            for b in obstacles {
                let bl = toScreen(b.x, b.y)
                let br = toScreen(b.x + b.w, b.y)
                let tr = toScreen(b.x + b.w, b.y + b.h)
                let tl = toScreen(b.x, b.y + b.h)

                let heightPx = camScale * 18 * Render.zScale

                var leftSide = Path()
                leftSide.move(to: bl)
                leftSide.addLine(to: br)
                leftSide.addLine(to: CGPoint(x: br.x, y: br.y + heightPx))
                leftSide.addLine(to: CGPoint(x: bl.x, y: bl.y + heightPx))
                leftSide.closeSubpath()
                ctx.fill(leftSide, with: .color(Color(red: 0.353, green: 0.353, blue: 0.384)))

                var rightSide = Path()
                rightSide.move(to: br)
                rightSide.addLine(to: tr)
                rightSide.addLine(to: CGPoint(x: tr.x, y: tr.y + heightPx))
                rightSide.addLine(to: CGPoint(x: br.x, y: br.y + heightPx))
                rightSide.closeSubpath()
                ctx.fill(rightSide, with: .color(Color(red: 0.235, green: 0.235, blue: 0.267)))

                var topFace = Path()
                topFace.move(to: CGPoint(x: tl.x, y: tl.y - heightPx))
                topFace.addLine(to: CGPoint(x: tr.x, y: tr.y - heightPx))
                topFace.addLine(to: CGPoint(x: br.x, y: br.y - heightPx))
                topFace.addLine(to: CGPoint(x: bl.x, y: bl.y - heightPx))
                topFace.closeSubpath()
                ctx.fill(topFace, with: .color(Color(red: 0.627, green: 0.627, blue: 0.659)))
                ctx.stroke(topFace, with: .color(.black.opacity(0.35)), lineWidth: 1)
            }
        }
    }
}

struct CharSprite: View {
    let id: UInt32
    let name: String
    let isYou: Bool
    let x: Float
    let y: Float
    let z: Float
    let dir: Float
    let size: CGSize
    let camScale: CGFloat
    let centerX: Float
    let centerY: Float

    var body: some View {
        let screen = worldToScreen(x, y, z)
        let col = isYou
            ? (r: 0.372, g: 0.588, b: 0.412)
            : Render.palette[Int(id) % Render.palette.count]
        let scale = camScale * 0.55
        let w = Render.charW * scale
        let totalH = Render.charH * scale

        ZStack {
            let ground = worldToScreen(x, y, 0)
            let zPix = CGFloat(z) * Render.zScale * camScale
            let shadowAlpha = max(0.06, 0.22 - Double(z) * 0.004)
            let shadowScale = max(0.5, 1 - CGFloat(z) * 0.005)

            Ellipse()
                .fill(Color.black.opacity(shadowAlpha))
                .frame(width: w * 1.1 * shadowScale, height: w * 0.56 * shadowScale)
                .position(x: ground.x, y: ground.y)

            CharBody(color: col, name: name, isYou: isYou, facing: dir)
                .frame(width: w, height: totalH)
                .position(x: screen.x, y: screen.y - totalH / 2 - zPix)
        }
    }

    private func worldToScreen(_ wx: Float, _ wy: Float, _ wz: Float) -> CGPoint {
        let rx = wx - centerX
        let ry = wy - centerY
        let ix = (CGFloat(rx) - CGFloat(ry)) * Render.isoCos
        let iy = (CGFloat(rx) + CGFloat(ry)) * Render.isoSin
        let lift = CGFloat(wz) * Render.zScale * camScale
        return CGPoint(x: size.width / 2 + ix * camScale,
                       y: size.height / 2 + iy * camScale - lift)
    }
}

struct CharBody: View {
    let color: (r: Double, g: Double, b: Double)
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

            let front = Color(red: color.r, green: color.g, blue: color.b)
            let top = Render.lighten(color, 0.11)
            let dark = Render.darken(color, 0.16)

            VStack(spacing: 2) {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(front)
                    Rectangle().fill(top).frame(height: headH * 0.22)
                    Rectangle().fill(dark).frame(width: w * 0.14)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Rectangle().stroke(.black.opacity(0.4), lineWidth: 1.1)
                    Face(facing: facing)
                }
                .frame(width: w * 0.9, height: headH)
                .frame(maxWidth: .infinity)

                ZStack(alignment: .topLeading) {
                    Rectangle().fill(front)
                    Rectangle().fill(top).frame(height: torsoH * 0.18)
                    Rectangle().fill(dark).frame(width: w * 0.14)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Rectangle().stroke(.black.opacity(0.4), lineWidth: 1.1)
                    if !isYou {
                        Text(String(name.prefix(8)))
                            .font(.system(size: max(7, w * 0.22), weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: w, height: torsoH)

                HStack(spacing: 2) {
                    ZStack(alignment: .top) {
                        Rectangle().fill(front)
                        Rectangle().fill(top).frame(height: legH * 0.15)
                        Rectangle().stroke(.black.opacity(0.4), lineWidth: 1.1)
                    }
                    ZStack(alignment: .top) {
                        Rectangle().fill(front)
                        Rectangle().fill(top).frame(height: legH * 0.15)
                        Rectangle().stroke(.black.opacity(0.4), lineWidth: 1.1)
                    }
                }
                .frame(width: w, height: legH)
            }
            .overlay(
                isYou ? Rectangle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.8)
                    .frame(width: w * 1.16, height: h + 6)
                    .offset(x: -w * 0.08, y: -3) : nil
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
            let facingAway = dy < -0.3
            let eyeSize: CGFloat = max(1.4, w * 0.07)
            let off = w * 0.08
            let spacing = w * 0.18

            if !facingAway {
                HStack(spacing: spacing) {
                    Circle().fill(Color.black.opacity(0.85))
                        .frame(width: eyeSize, height: eyeSize)
                    Circle().fill(Color.black.opacity(0.85))
                        .frame(width: eyeSize, height: eyeSize)
                }
                .position(x: w / 2 + dx * off,
                          y: h * 0.55 + dy * off * 0.6)
            }
        }
    }
}

struct Joystick: View {
    @ObservedObject var client: GameClient
    @State private var offset: CGSize = .zero
    @State private var timer: Timer?

    let knobSize: CGFloat = 58

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2

            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .overlay(Circle().stroke(Color.white.opacity(0.20), lineWidth: 2))
                    .frame(width: size, height: size)

                Circle()
                    .fill(Color(red: 0.90, green: 0.90, blue: 0.90).opacity(0.9))
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
                        applyInput(dx: dx, dy: dy, maxR: maxR)
                        startTimer(maxR: maxR)
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.2)) { offset = .zero }
                        timer?.invalidate()
                        timer = nil
                        client.sendInput(dx: 0, dy: 0)
                    }
            )
        }
    }

    private func applyInput(dx: CGFloat, dy: CGFloat, maxR: CGFloat) {
        let nx = dx / maxR
        let ny = dy / maxR
        guard sqrt(nx*nx + ny*ny) > 0.12 else {
            client.sendInput(dx: 0, dy: 0)
            return
        }
        let screenUp = Float(-ny)
        let screenRight = Float(nx)
        let wx = (screenRight / Float(Render.isoCos) + screenUp / Float(Render.isoSin)) * 0.5
        let wy = (-screenRight / Float(Render.isoCos) + screenUp / Float(Render.isoSin)) * 0.5
        client.sendInput(dx: wx, dy: wy)
    }

    private func startTimer(maxR: CGFloat) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                applyInput(dx: offset.width, dy: offset.height, maxR: maxR)
            }
        }
    }
}

#Preview {
    ContentView()
}
