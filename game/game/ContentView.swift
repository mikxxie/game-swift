import SwiftUI
import Network

// MARK: - Models

struct RemotePlayer: Identifiable, Equatable {
    let id: UInt32
    var name: String
    var x: Float
    var y: Float
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
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
    @Published var players: [RemotePlayer] = []
    @Published var pingMs: Int = 0
    @Published var log: [String] = []

    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "udp.client")
    private var pingTimer: Timer?

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
                    self.appendLog("connected to \(Self.serverHost):\(Self.serverPort)")
                    self.send("JOIN \(name)")
                    self.startPing()
                    self.receiveLoop()
                case .failed(let err):
                    self.state = .failed("\(err)")
                    self.appendLog("failed: \(err)")
                case .cancelled:
                    self.state = .disconnected
                    self.stopPing()
                default:
                    break
                }
            }
        }

        c.start(queue: queue)
    }

    func disconnect() {
        send("BYE")
        stopPing()
        conn?.cancel()
        conn = nil
        state = .disconnected
        players.removeAll()
        myId = 0
    }

    func send(_ msg: String) {
        guard let conn else { return }
        let data = (msg + "\n").data(using: .utf8)!
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    func move(dx: Float, dy: Float) {
        guard state == .connected else { return }
        myX += dx
        myY += dy
        send(String(format: "MOVE %.2f %.2f", myX, myY))
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
                    appendLog("joined as id \(id)")
                }
            case "JOINED":
                guard parts.count >= 5,
                      let id = UInt32(parts[1]),
                      let x = Float(parts[3]),
                      let y = Float(parts[4]) else { return }
                let name = parts[2]
                upsert(RemotePlayer(id: id, name: name, x: x, y: y))
                appendLog("\(name) joined")
            case "LEFT":
                guard parts.count >= 2, let id = UInt32(parts[1]) else { return }
                players.removeAll { $0.id == id }
                appendLog("id \(id) left")
            case "SNAP":
                guard parts.count >= 2, let n = Int(parts[1]) else { return }
                var idx = 2
                var updated: [RemotePlayer] = []
                updated.reserveCapacity(n)
                for _ in 0..<n {
                    guard idx + 2 < parts.count,
                          let id = UInt32(parts[idx]),
                          let x = Float(parts[idx + 1]),
                          let y = Float(parts[idx + 2]) else { break }
                    idx += 3
                    if id == myId { continue }
                    let existingName = players.first(where: { $0.id == id })?.name ?? "player"
                    updated.append(RemotePlayer(id: id, name: existingName, x: x, y: y))
                }
                for p in updated { upsert(p) }
                players.removeAll { p in
                    !updated.contains(where: { $0.id == p.id }) && p.id != myId
                }
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

    private func appendLog(_ s: String) {
        log.append(s)
        if log.count > 40 { log.removeFirst(log.count - 40) }
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var client = GameClient()
    @State private var name: String = ""
    @State private var hasJoined = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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
            Text("UDP Arena")
                .font(.system(size: 42, weight: .black, design: .rounded))
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
                Text("JOIN")
                    .font(.headline)
                    .frame(maxWidth: 320)
                    .padding()
                    .background(Color.green)
                    .foregroundStyle(.black)
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
            .background(Color.white.opacity(0.06))

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
    let worldRange: Float = 200

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color(white: 0.08)

                Grid()

                ForEach(client.players) { p in
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Text(p.name)
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .offset(y: -22)
                        )
                        .position(point(for: p.x, p.y, in: size))
                }

                Circle()
                    .fill(Color.green)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .position(point(for: client.myX, client.myY, in: size))
            }
        }
    }

    private func point(for x: Float, _ y: Float, in size: CGSize) -> CGPoint {
        let nx = CGFloat(x / worldRange)
        let ny = CGFloat(y / worldRange)
        return CGPoint(
            x: size.width  * (0.5 + nx * 0.5),
            y: size.height * (0.5 - ny * 0.5)
        )
    }
}

struct Grid: View {
    var body: some View {
        GeometryReader { geo in
            let step: CGFloat = 40
            Path { p in
                var x: CGFloat = 0
                while x <= geo.size.width {
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: geo.size.height))
                    x += step
                }
                var y: CGFloat = 0
                while y <= geo.size.height {
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    y += step
                }
            }
            .stroke(Color.white.opacity(0.05), lineWidth: 1)
        }
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
            .background(Circle().fill(pressing ? Color.green : Color.white.opacity(0.12)))
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
