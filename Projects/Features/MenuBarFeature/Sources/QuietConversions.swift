import AppKit
import ConversionKit
import Observation
import Platform
import UserNotifications

/// Conversions picked in Finder's menu, run without a window: the menu bar item shows how far
/// along they are and a notification says when they're done. A click on it shows the results.
@MainActor
@Observable
public final class QuietConversions: NSObject {
    public static let shared = QuietConversions()

    public struct Job: Identifiable, Equatable {
        public let id = UUID()
        public let files: [URL]
        public let format: String
    }

    /// The batch being converted, with its file index and that file's progress.
    public private(set) var current: Job?
    public private(set) var fileIndex = 0
    public private(set) var fileProgress: Double = 0

    /// 0…1 over the whole batch in progress.
    public var progress: Double {
        guard let current else { return 0 }
        return (Double(fileIndex) + fileProgress) / Double(max(current.files.count, 1))
    }

    /// Why a file wasn't converted, for the notification.
    private struct Reason: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    private var queue: [Job] = []
    private let client = ConversionClient()

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    public func convert(_ files: [URL], to format: String) {
        guard !files.isEmpty else { return }
        queue.append(Job(files: files, format: format))
        // Asked on first use, by those who use Finder's menu.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if current == nil { Task { await drain() } }
    }

    private func drain() async {
        while !queue.isEmpty {
            let job = queue.removeFirst()
            current = job
            var written: [URL] = []
            var failures: [(URL, String)] = []
            for (index, file) in job.files.enumerated() {
                fileIndex = index
                fileProgress = 0
                switch await convert(file, to: job.format) {
                case .success(let output):
                    written.append(output)
                    ConversionHistory.shared.record(input: file, output: output)
                case .failure(let reason):
                    failures.append((file, reason.text))
                }
            }
            current = nil
            notify(job: job, written: written, failures: failures)
        }
    }

    private func convert(_ file: URL, to format: String) async -> Result<URL, Reason> {
        let converted: FileHandle
        do {
            converted = try await client.convert(file, to: format) { fraction in
                Task { @MainActor [weak self] in self?.fileProgress = fraction }
            }
        } catch let error as ConversionClient.Failure {
            return .failure(Reason(error.description))
        } catch {
            return .failure(Reason("파일을 읽을 수 없어요"))
        }
        defer { try? converted.close() }
        do {
            return .success(try SiblingWriter.copyKeepingBoth(converted, nextTo: file, extension: format))
        } catch {
            return .failure(Reason("저장하지 못했어요"))
        }
    }

    private func notify(job: Job, written: [URL], failures: [(URL, String)]) {
        let content = UNMutableNotificationContent()
        let format = job.format.uppercased()
        if failures.isEmpty {
            content.title = written.count == 1 ? "\(format)로 바꿨어요" : "\(written.count)개를 \(format)로 바꿨어요"
            content.body = written.count == 1 ? written[0].lastPathComponent : written.map(\.lastPathComponent).joined(separator: ", ")
        } else if written.isEmpty {
            content.title = "바꾸지 못했어요"
            content.body = failures.map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n")
        } else {
            content.title = "\(job.files.count)개 중 \(written.count)개를 \(format)로 바꿨어요"
            content.body = failures.map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n")
        }
        // A click shows the results, or the originals if none were made.
        content.userInfo = ["reveal": (written.isEmpty ? job.files : written).map(\.path)]
        content.sound = failures.isEmpty ? nil : .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil))
    }
}

extension QuietConversions: UNUserNotificationCenterDelegate {
    /// Shown even while Conv is the active app.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let paths = response.notification.request.content.userInfo["reveal"] as? [String] ?? []
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(filePath: $0) })
        }
    }
}
