import Foundation
import Network
import Combine

/// Minimal loopback HTTP server used by the browser extension to hand
/// downloads (URL + headers/cookies/user-agent) to the app.
final class LocalControlServer: ObservableObject {
    static let shared = LocalControlServer()

    @Published var isRunning = false
    @Published var activePort: UInt16 = 8765

    var handler: ((String, [String: Any]) -> [String: Any])?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "LocalControlServer", attributes: .concurrent)

    private init() {}

    func start(port: UInt16) {
        stop()
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
            let newListener = try NWListener(using: parameters, on: endpointPort)
            listener = newListener
            newListener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            newListener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    self?.isRunning = (state == .ready)
                    if state == .ready {
                        self?.activePort = port
                    }
                }
            }
            newListener.start(queue: queue)
            activePort = port
        } catch {
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
        }
    }

    private func handle(_ connection: NWConnection) {
        let context = ConnectionContext(connection: connection)
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: queue)
        receive(connection: connection, context: context)
    }

    private func receive(connection: NWConnection, context: ConnectionContext) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                context.buffer.append(data)
            }
            if let response = self.tryParse(context) {
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receive(connection: connection, context: context)
        }
    }

    private func tryParse(_ context: ConnectionContext) -> Data? {
        guard let headerRange = context.buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        guard let head = String(data: context.buffer[..<headerRange.lowerBound], encoding: .utf8) else {
            return errorResponse("Bad request")
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return errorResponse("Bad request")
        }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            return errorResponse("Bad request")
        }
        let method = parts[0]
        let path = parts[1]

        var contentLength = 0
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerRange.upperBound
        guard context.buffer.count >= bodyStart + contentLength else {
            return nil
        }

        let bodyData = context.buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        var json: [String: Any] = [:]
        if !bodyData.isEmpty {
            if let parsed = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                json = parsed
            }
        }

        var responseBody: [String: Any]
        if method == "GET" && path == "/api/ping" {
            responseBody = handler?(path, json) ?? ["ok": true]
        } else if method == "POST" || method == "GET" {
            responseBody = handler?(path, json) ?? ["ok": false, "error": "Unhandled path: \(path)"]
        } else {
            responseBody = ["ok": false, "error": "Method not allowed"]
        }

        let payload = (try? JSONSerialization.data(withJSONObject: responseBody)) ?? Data("{}".utf8)
        let status = (responseBody["ok"] as? Bool == true) ? "200 OK" : "400 Bad Request"
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(payload.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var out = Data(response.utf8)
        out.append(payload)
        return out
    }

    private func errorResponse(_ message: String) -> Data {
        let payload = Data("{\"ok\":false,\"error\":\"\(message)\"}".utf8)
        var response = "HTTP/1.1 400 Bad Request\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(payload.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var out = Data(response.utf8)
        out.append(payload)
        return out
    }

    private final class ConnectionContext {
        let connection: NWConnection
        var buffer = Data()

        init(connection: NWConnection) {
            self.connection = connection
        }
    }
}
