import Foundation

/// The app's side of the ConversionXPC connection. NSXPCConnection is safe to use from any thread.
public final class ConversionClient: @unchecked Sendable {
    public struct Failure: Error, Sendable, CustomStringConvertible {
        public let description: String
    }

    private let connection: NSXPCConnection
    private let progress = ProgressRouter()

    public init() {
        connection = NSXPCConnection(serviceName: ConversionService.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: ConversionServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: ConversionProgressProtocol.self)
        connection.exportedObject = progress
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    /// Converts the file at `input` into `format` in the sandboxed service, and returns the result
    /// open for reading. The caller must be able to read `input` (security scope already started).
    /// - Parameter onProgress: Called with 0…1 as the service reports it, on an XPC queue.
    public func convert(
        _ input: URL,
        to format: String,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> FileHandle {
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        let job = UUID().uuidString
        progress.register(job, onProgress)
        defer { progress.unregister(job) }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Once()
            let service = connection.remoteObjectProxyWithErrorHandler { error in
                // The service crashed or quit (it exits after a timed-out render); launchd relaunches it.
                if resumed.claim() { continuation.resume(throwing: Failure(description: "변환 서비스가 멈췄어요: \(error.localizedDescription)")) }
            } as? ConversionServiceProtocol
            guard let service else {
                if resumed.claim() { continuation.resume(throwing: Failure(description: "변환 서비스에 연결할 수 없어요")) }
                return
            }
            service.convert(handle, named: input.lastPathComponent, to: format, job: job) { output, error in
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

/// Receives the service's progress reports and hands each to its job's handler.
private final class ProgressRouter: NSObject, ConversionProgressProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable (Double) -> Void] = [:]

    func register(_ job: String, _ handler: @escaping @Sendable (Double) -> Void) {
        lock.withLock { handlers[job] = handler }
    }

    func unregister(_ job: String) {
        lock.withLock { _ = handlers.removeValue(forKey: job) }
    }

    func report(job: String, fraction: Double) {
        let handler = lock.withLock { handlers[job] }
        handler?(min(max(fraction, 0), 1))
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
