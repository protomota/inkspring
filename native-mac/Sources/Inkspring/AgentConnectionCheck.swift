import Darwin
import Foundation

enum AgentConnectionCheck {
    struct Result: Equatable {
        let toolCount: Int
        let projectCount: Int
    }

    static func run(command: String, workspaceOverride: String?) throws -> Result {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = ["--mcp"]
        let environment = ProcessInfo.processInfo.environment
        var childEnvironment = environment.filter { ["HOME", "PATH", "TMPDIR"].contains($0.key) }
        childEnvironment["INKSPRING_NATIVE_WORKSPACE"] = workspaceOverride
        process.environment = childEnvironment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw WorkspaceError("Couldn’t prepare the local MCP connection.")
        }
        try process.run()
        defer {
            try? writer.close()
            try? reader.close()
            if process.isRunning { process.terminate() }
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + 8_000_000_000
        var pending = Data()
        func send(_ method: String, id: Int? = nil, parameters: [String: Any] = [:]) throws {
            var request: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": parameters]
            if let id { request["id"] = id }
            var line = try JSONSerialization.data(withJSONObject: request)
            line.append(10)
            try writer.write(contentsOf: line)
        }

        func receive(_ id: Int) throws -> [String: Any] {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while pending.count <= 8 * 1024 * 1024 {
                if let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    guard let response = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          response["jsonrpc"] as? String == "2.0", response["id"] as? Int == id,
                          let result = response["result"] as? [String: Any] else {
                        throw WorkspaceError("Inkspring returned an invalid MCP response.")
                    }
                    return result
                }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw WorkspaceError("The local MCP server didn’t respond in time.") }
                var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32((deadline - now + 999_999) / 1_000_000))
                if ready < 0 && errno == EINTR { continue }
                if ready == 0 { throw WorkspaceError("The local MCP server didn’t respond in time.") }
                guard ready > 0 else {
                    throw WorkspaceError("Couldn’t read the local MCP response.")
                }
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(reader.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw WorkspaceError("The local MCP server closed before the connection was verified.")
                }
                pending.append(contentsOf: buffer.prefix(count))
            }
            throw WorkspaceError("The local MCP server returned too much data.")
        }

        let version = "2025-11-25"
        try send("initialize", id: 1, parameters: [
            "protocolVersion": version, "capabilities": [:],
            "clientInfo": ["name": "Inkspring Settings",
                           "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"]
        ])
        let server = try receive(1)
        guard server["protocolVersion"] as? String == version,
              (server["serverInfo"] as? [String: Any])?["name"] as? String == "inkspring" else {
            throw WorkspaceError("The command did not start the Inkspring MCP server.")
        }
        try send("notifications/initialized")
        try send("tools/list", id: 2)
        let catalog = try receive(2)
        guard let tools = catalog["tools"] as? [[String: Any]],
              tools.contains(where: { $0["name"] as? String == "list_projects" }) else {
            throw WorkspaceError("The Inkspring MCP server did not expose its project tool.")
        }
        try send("tools/call", id: 3, parameters: ["name": "list_projects", "arguments": [:]])
        let readback = try receive(3)
        guard readback["isError"] as? Bool != true,
              let items = (readback["structuredContent"] as? [String: Any])?["items"] as? [[String: Any]] else {
            throw WorkspaceError("The MCP server started but couldn’t read the workspace. Check that agent access is enabled.")
        }
        return Result(toolCount: tools.count, projectCount: items.count)
    }
}
