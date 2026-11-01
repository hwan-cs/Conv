import AppKit
import Foundation
import Observation

/// The last conversions, newest first, kept across launches for the menu bar's "최근".
@MainActor
@Observable
public final class ConversionHistory {
    public static let shared = ConversionHistory()

    public struct Entry: Codable, Identifiable, Equatable, Sendable {
        public var id = UUID()
        public let inputName: String
        public let outputExtension: String
        public let output: URL
        public let date: Date

        public var inputExtension: String { (inputName as NSString).pathExtension.lowercased() }
    }

    public private(set) var entries: [Entry] = []

    private static let key = "ConversionHistory"
    private static let limit = 20
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    /// - Parameter format: The format made, when `output` doesn't say: a folder of a PDF's pages.
    public func record(input: URL, output: URL, format: String? = nil) {
        let ext = format ?? output.pathExtension.lowercased()
        let entry = Entry(inputName: input.lastPathComponent, outputExtension: ext, output: output, date: .now)
        entries = Array(([entry] + entries).prefix(Self.limit))
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }

    /// Shows the converted file in Finder.
    public func reveal(_ entry: Entry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.output])
    }
}
