import Foundation

struct CatalogEntry: Decodable, Identifiable, Sendable {
    let id: String
    let src: String
    let label: String
    let size: String
    let preview: String
    let hasPreview: Bool
    let artboard: String
    let artboardMode: String
    let stateMachine: String
    let trigger: String?
    let version: Int?
    let number: Int?
    let fileSize: Int?
    let parameters: [CatalogParameter]
    let notes: [String]

    var displayName: String {
        guard number != nil, let separator = label.firstIndex(of: " ") else { return label }
        return String(label[label.index(after: separator)...])
    }
}

struct CatalogParameter: Decodable, Sendable {
    let token: String
    let kind: String
    let name: String
    let defaultValue: String?

    enum CodingKeys: String, CodingKey {
        case token, kind, name
        case defaultValue = "default"
    }
}

struct CatalogDiagnostic: Decodable, Sendable {
    let severity: String
    let line: Int
    let field: String
    let message: String
}

struct CatalogSnapshot: Decodable, Sendable {
    let entries: [CatalogEntry]
    let diagnostics: [CatalogDiagnostic]
    let revision: String
}

struct CatalogFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CatalogConfiguration: Sendable {
    let root: URL
    let python: URL

    static func current() throws -> Self {
        var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var python = URL(fileURLWithPath: "/usr/bin/python3")
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            guard ["--root", "--python"].contains(argument), !arguments.isEmpty else {
                throw CatalogFailure(message: "Usage: CatalogManager [--root path] [--python executable]")
            }
            let value = URL(fileURLWithPath: arguments.removeFirst()).standardizedFileURL
            if argument == "--root" { root = value } else { python = value }
        }
        return Self(root: root, python: python)
    }
}

enum CatalogBridge {
    private struct Response: Decodable {
        let version: Int
        let success: Bool
        let data: CatalogSnapshot?
        let error: String?
    }

    static func load(_ configuration: CatalogConfiguration) async throws -> CatalogSnapshot {
        let task = Task.detached {
            let process = Process()
            process.executableURL = configuration.python
            process.currentDirectoryURL = configuration.root
            process.arguments = ["-B", configuration.root.appendingPathComponent("catalog_cli.py").path]
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            let request = try JSONSerialization.data(withJSONObject: [
                "version": 1, "command": "load", "root": configuration.root.path
            ])
            let (stdout, stderr) = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try process.run()
                if Task.isCancelled { process.terminate() }
                async let outputData = Task.detached {
                    output.fileHandleForReading.readDataToEndOfFile()
                }.value
                async let errorData = Task.detached {
                    errors.fileHandleForReading.readDataToEndOfFile()
                }.value
                if !Task.isCancelled {
                    try input.fileHandleForWriting.write(contentsOf: request)
                }
                input.fileHandleForWriting.closeFile()
                process.waitUntilExit()
                let data = await outputData
                let errors = String(decoding: await errorData, as: UTF8.self)
                try Task.checkCancellation()
                return (data, errors)
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let response: Response
            do {
                response = try decoder.decode(Response.self, from: stdout)
            } catch {
                throw CatalogFailure(message: "Invalid catalog response (exit \(process.terminationStatus)): \(stderr)\n\(error.localizedDescription)")
            }
            guard response.version == 1 else {
                throw CatalogFailure(message: "Unsupported catalog protocol version.")
            }
            guard process.terminationStatus == 0, response.success, let snapshot = response.data else {
                throw CatalogFailure(message: response.error ?? "Catalog command failed: \(stderr)")
            }
            guard stderr.isEmpty else {
                throw CatalogFailure(message: "Catalog command reported an error: \(stderr)")
            }
            return snapshot
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
