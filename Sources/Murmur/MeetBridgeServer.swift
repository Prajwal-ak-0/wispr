import Foundation
import Network

struct BrowserMeetEvent: Codable {
    let kind: String
    let title: String?
    let url: String?
}

final class MeetBridgeServer: @unchecked Sendable {
    static let port: NWEndpoint.Port = 49_413
    var onEvent: ((BrowserMeetEvent) -> Void)?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ai.murmur.meet-bridge")

    func start() {
        do {
            let parameters = NWParameters.tcp
            let listener = try NWListener(using: parameters, on: Self.port)
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { Log.error("Meet bridge failed: \(error)") }
            }
            listener.start(queue: queue)
            self.listener = listener
            Log.info("Google Meet bridge listening on 127.0.0.1:\(Self.port)")
        } catch { Log.error("Meet bridge unavailable: \(error.localizedDescription)") }
    }

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint,
              host == .ipv4(.loopback) || host == .ipv6(.loopback) else { connection.cancel(); return }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel(); return
            }
            let body = request.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            if request.hasPrefix("POST /event "), let payload = body.data(using: .utf8),
               let event = try? JSONDecoder().decode(BrowserMeetEvent.self, from: payload) {
                self.onEvent?(event)
                self.respond(connection, status: "200 OK", body: "{\"ok\":true}")
            } else if request.hasPrefix("GET /health ") {
                self.respond(connection, status: "200 OK", body: "{\"status\":\"ready\"}")
            } else {
                self.respond(connection, status: "400 Bad Request", body: "{\"ok\":false}")
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
