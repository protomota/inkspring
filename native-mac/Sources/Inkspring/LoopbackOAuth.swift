import AppKit
import Network

@MainActor
final class LoopbackOAuth {
    private let callback: URL
    private let state: String
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var completing = false

    init(callback: URL, state: String) {
        self.callback = callback
        self.state = state
    }

    func wait(opening url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: 43821)
            do {
                let listener = try NWListener(using: parameters)
                self.listener = listener
                self.continuation = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            if !NSWorkspace.shared.open(url) { self.finish(.failure(WorkspaceError("Couldn’t open the browser."))) }
                        case .failed:
                            self.finish(.failure(WorkspaceError("The local sign-in port is unavailable. Finish any other Inkspring sign-in and try again.")))
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.accept(connection) }
                }
                listener.start(queue: .main)
                timeout = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(600))
                    if !Task.isCancelled { self.finish(.failure(WorkspaceError("Sign-in timed out. Connect again."))) }
                }
            } catch {
                continuation.resume(throwing: WorkspaceError("Couldn’t open the local sign-in callback."))
            }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func accept(_ connection: NWConnection) {
        guard continuation != nil, !completing, connections.count < 8 else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: .main)
        receive(connection, bytes: Data())
    }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var received = bytes
                if let data { received.append(data) }
                if received.count > 16_384 || error != nil {
                    self.reply(connection, callback: nil)
                } else if let end = received.range(of: Data("\r\n\r\n".utf8)) {
                    let headers = String(decoding: received[..<end.lowerBound], as: UTF8.self)
                    self.reply(connection, callback: self.parse(headers))
                } else if done {
                    self.reply(connection, callback: nil)
                } else {
                    self.receive(connection, bytes: received)
                }
            }
        }
    }

    func parse(_ headers: String) -> URL? {
        let lines = headers.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        guard request.count == 3, request[0] == "GET", ["HTTP/1.0", "HTTP/1.1"].contains(request[2]),
              request[1].hasPrefix("/oauth/"),
              let url = URL(string: "http://127.0.0.1:43821" + request[1]), url.path == callback.path,
              url.fragment == nil,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter({ $0.name == "state" }).map(\.value) == [state] else { return nil }
        let fields = lines.dropFirst().map { $0.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) } }
        let hosts = fields.filter { $0.first?.lowercased() == "host" }
        guard hosts.count == 1, hosts[0].count == 2, hosts[0][1] == "127.0.0.1:43821",
              !fields.contains(where: { $0.first?.lowercased() == "origin" }) else { return nil }
        return url
    }

    private func reply(_ connection: NWConnection, callback: URL?) {
        let accepted = callback != nil && !completing
        if accepted { completing = true }
        let status = accepted ? "200 OK" : "400 Bad Request"
        let page = accepted ? "Return to Inkspring to finish connecting." : "The sign-in return was not accepted."
        let body = "<!doctype html><title>Inkspring</title><p>" + page + "</p>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                connection.cancel()
                self?.connections.removeValue(forKey: ObjectIdentifier(connection))
                if accepted, let callback { self?.finish(.success(callback)) }
            }
        })
    }

    private func finish(_ result: Result<URL, Error>) {
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
