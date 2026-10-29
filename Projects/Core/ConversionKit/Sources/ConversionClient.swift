import Foundation

/// The app's side of the ConversionXPC connection. NSXPCConnection is safe to use from any thread.
public final class ConversionClient: @unchecked Sendable {
    public struct Failure: Error, Sendable, CustomStringConvertible {
        public let description: String
    }

    private let connection: NSXPCConnection

    public init() {
        connection = NSXPCConnection(serviceName: ConversionService.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: ConversionServiceProtocol.self)
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    /// Converts a file's bytes into `format` in the sandboxed service.
    public func convert(_ data: Data, named name: String, to format: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = Once()
            let service = connection.remoteObjectProxyWithErrorHandler { error in
                // The service crashed or quit (it exits after a timed-out render); launchd relaunches it.
                if resumed.claim() { continuation.resume(throwing: Failure(description: "변환 서비스가 멈췄어요: \(error.localizedDescription)")) }
            } as? ConversionServiceProtocol
            guard let service else {
                if resumed.claim() { continuation.resume(throwing: Failure(description: "변환 서비스에 연결할 수 없어요")) }
                return
            }
            service.convert(data, named: name, to: format) { output, error in
                guard resumed.claim() else { return }
                if let output {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: Failure(description: error ?? "알 수 없는 오류"))
                }
            }
        }
    }
}

/// Lets exactly one of the XPC reply and error handlers resume a continuation.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
