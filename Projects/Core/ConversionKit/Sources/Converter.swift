import Foundation
import UniformTypeIdentifiers

/// Converts one file into another format. Each engine module provides its own converters.
public protocol Converter: Sendable {
    static var inputs: [UTType] { get }
    static var outputs: [UTType] { get }

    func convert(_ input: URL, to type: UTType, options: ConvertOptions) async throws -> URL
}

/// User-facing options for a conversion. Filled in as engines need them.
public struct ConvertOptions: Sendable, Equatable {
    public init() {}
}
