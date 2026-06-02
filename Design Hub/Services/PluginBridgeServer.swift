import Foundation
import Network
import Combine

// WebSocket server that listens on localhost:49152 for connections from the
// Photoshop (UXP) and Illustrator (CEP) plugins.

@MainActor
final class PluginBridgeServer: ObservableObject {

    nonisolated static let defaultPort: UInt16 = 49152

    // Emits every valid PluginMessage received from any connected plugin.
    let messagePublisher = PassthroughSubject<PluginMessage, Never>()

    @Published private(set) var connectedApps: Set<String> = []

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // JS Date.toISOString() produces fractional seconds ("…T02:18:00.000Z").
        // Swift's plain .iso8601 strategy rejects them, so we use a custom formatter.
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = fmt.date(from: s) { return date }
            // Fallback: without fractional seconds
            let fmt2 = ISO8601DateFormatter()
            fmt2.formatOptions = [.withInternetDateTime]
            if let date = fmt2.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Cannot decode date: \(s)")
        }
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // MARK: - Lifecycle

    func start(port: UInt16 = PluginBridgeServer.defaultPort) {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            return
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }

        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[PluginBridge] Listener failed: \(error)")
            }
        }

        listener.start(queue: .main)
        print("[PluginBridge] Listening on port \(port)")
    }

    func stop() {
        listener?.cancel()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        connectedApps.removeAll()
    }

    // MARK: - Commands → plugin

    func requestSnapshot() {
        guard let data = try? encoder.encode(PluginCommand(type: .requestSnapshot)) else { return }
        broadcast(data)
    }

    // MARK: - Private

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            Task { @MainActor [weak self] in
                switch state {
                case .failed, .cancelled: self?.remove(connection)
                default: break
                }
            }
        }

        connection.start(queue: .main)
        receive(from: connection)
    }

    private func receive(from connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.handle(data)
                }
                if error == nil {
                    self.receive(from: connection)
                } else {
                    self.remove(connection)
                }
            }
        }
    }

    private func handle(_ data: Data) {
        do {
            let message = try decoder.decode(PluginMessage.self, from: data)
            connectedApps.insert(message.app.rawValue)
            messagePublisher.send(message)
        } catch {
            print("[PluginBridge] Decode failed: \(error)")
            if let raw = String(data: data, encoding: .utf8) {
                print("[PluginBridge] Raw data: \(raw.prefix(300))")
            }
        }
    }

    private func broadcast(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])
        for connection in connections.values {
            connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }

    private func remove(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }
}
