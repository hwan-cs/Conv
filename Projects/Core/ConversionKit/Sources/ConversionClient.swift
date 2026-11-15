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
        connection.remoteObjectInterface = ConversionService.interface()
        connection.exportedInterface = NSXPCInterface(with: ConversionProgressProtocol.self)
        connection.exportedObject = progress
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    /// Converts the file at `input` into `format` in the sandboxed service, and returns the result open for reading.
    /// - Parameter onProgress: Called with 0…1 as the service reports it, on an XPC queue.
    public func convert(
        _ input: URL,
        to format: String,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> FileHandle {
        let handle = try FileHandle(forReadingFrom: input)
        defer {
            try? handle.close()
        }
        return try await call(onProgress) { service, job, reply in
            service.convert(handle, named: input.lastPathComponent, to: format, job: job, withReply: reply)
        }
    }

    /// Each page of the PDF at `input` as an image of `format`.
    public func convertPages(
        _ input: URL,
        to format: String,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> PackedFiles.Reader {
        let handle = try FileHandle(forReadingFrom: input)
        defer {
            try? handle.close()
        }
        let packed = try await call(onProgress) { service, job, reply in
            service.convertPages(handle, named: input.lastPathComponent, to: format, job: job, withReply: reply)
        }
        return try PackedFiles.Reader(packed)
    }

    /// The files at `inputs` made into one `format` file, in order.
    public func combine(
        _ inputs: [URL],
        to format: String,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> FileHandle {
        let limit = ConversionService.combineLimit
        let chunks = stride(from: 0, to: inputs.count, by: limit).map { Array(inputs[$0..<min($0 + limit, inputs.count)]) }
        var parts: [FileHandle] = []
        for (index, chunk) in chunks.enumerated() {
            let handles = try chunk.map {
                try FileHandle(forReadingFrom: $0)
            }
            defer {
                for handle in handles {
                    try? handle.close()
                }
            }
            let part = try await combine(handles, named: chunk.map(\.lastPathComponent), to: format) { fraction in
                onProgress((Double(index) + fraction) / Double(chunks.count))
            }
            parts.append(part)
        }
        while parts.count > 1 {
            let next = parts.prefix(limit)
            let part = try await combine(Array(next), named: next.map { _ in "part.\(format)" }, to: format)
            for handle in next { try? handle.close() }
            parts = [part] + parts.dropFirst(next.count)
        }
        guard let combined = parts.first else { throw Failure(description: String(localized: "합칠 파일이 없어요")) }
        return combined
    }

    private func combine(
        _ handles: [FileHandle],
        named names: [String],
        to format: String,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> FileHandle {
        try await call(onProgress) { service, job, reply in
            service.combine(
                handles,
                named: names,
                to: format,
                job: job,
                withReply: reply
            )
        }
    }

    /// Sends one request, with progress routed to `onProgress`, and waits for its reply.
    private func call(
        _ onProgress: @escaping @Sendable (Double) -> Void,
        _ send: (ConversionServiceProtocol, String, @escaping @Sendable (FileHandle?, String?) -> Void) -> Void
    ) async throws -> FileHandle {
        let job = UUID().uuidString
        progress.register(job, onProgress)
        defer {
            progress.unregister(job)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Once()
            let service = connection.remoteObjectProxyWithErrorHandler { error in
                if resumed.claim() {
                    continuation.resume(throwing: Failure(description: String(localized: "변환 서비스가 멈췄어요: \(error.localizedDescription)")))
                }
            } as? ConversionServiceProtocol
            
            guard let service else {
                if resumed.claim() {
                    continuation.resume(throwing: Failure(description: String(localized: "변환 서비스에 연결할 수 없어요")))
                }
                return
            }
            send(service, job) { output, error in
                guard resumed.claim() else {
                    return
                }
                if let output {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: Failure(description: error ?? String(localized: "알 수 없는 오류")))
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
            defer {
                done = true
            }
            return !done
        }
    }
}
