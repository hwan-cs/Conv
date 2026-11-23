import Foundation
import ZIPFoundation

enum OOXMLNamespace {
    static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
    static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let v = "urn:schemas-microsoft-com:vml"
    static let wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
    static let wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"
    static let pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
}

enum PackageXML {
    enum XMLError: Error {
        case documentTypeDeclaration
    }

    /// Refuses DTDs, which OOXML forbids: entity expansion can turn kilobytes into gigabytes.
    static func root(_ data: Data) throws -> XMLElement? {
        let prolog = data.prefix(65_536)
        let declarations = [Data("<!DOCTYPE".utf8), Data("<!DOCTYPE".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })]
        guard declarations.allSatisfy({ prolog.range(of: $0) == nil }) else {
            throw XMLError.documentTypeDeclaration
        }
        return try XMLDocument(data: transitional(data)).rootElement()
    }

    /// Strict OOXML namespaces (`purl.oclc.org/ooxml/X/Y`) read as Transitional (`schemas.openxmlformats.org/X/2006/Y`).
    static func transitional(_ data: Data) -> Data {
        guard data.range(of: Data("http://purl.oclc.org/ooxml/".utf8)) != nil else {
            return data
        }
        let strict = /http:\/\/purl\.oclc\.org\/ooxml\/([A-Za-z]+)\//
        let xml = String(decoding: data, as: UTF8.self)
        return Data(xml.replacing(strict) { "http://schemas.openxmlformats.org/\($0.1)/2006/" }.utf8)
    }
}

/// The zip container of a .docx and its main document part.
struct DocxPackage {
    enum PackageError: Error {
        case notADocx
        case passwordProtected
    }

    private let archive: Archive
    let documentPath: String
    /// Relationship id → package path, for the main document part.
    let relationships: [String: String]

    init(url: URL) throws {
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw Self.isEncrypted(url) ? PackageError.passwordProtected : PackageError.notADocx
        }
        let packageRels = try Self.relationships(in: archive, for: "")
        documentPath = packageRels.values.first { $0.hasSuffix(".xml") && $0.contains("document") } ?? "word/document.xml"
        relationships = try Self.relationships(in: archive, for: documentPath)
    }

    /// A password-protected Office file is an OLE container with an `EncryptionInfo` stream, not a zip.
    static func isEncrypted(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        else {
            return false
        }
        return data.range(of: Data("EncryptionInfo".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })) != nil
    }

    func data(at path: String) throws -> Data? {
        try Self.data(in: archive, at: path)
    }

    func xml(at path: String) throws -> XMLElement? {
        guard let data = try data(at: path) else {
            return nil
        }
        return try PackageXML.root(Self.protectingBlankText(data))
    }

    /// Relationship id → package path, for any part (e.g. fontTable.xml's embedded fonts).
    func relationships(forPart part: String) throws -> [String: String] {
        try Self.relationships(in: archive, for: part)
    }

    /// Parts referenced from the main document by relationship type suffix, e.g. "styles".
    func partPath(ofType type: String) throws -> String? {
        guard let rels = try xml(at: Self.relsPath(for: documentPath)) else {
            return nil
        }
        return rels.elements
            .first { ($0.attribute(forName: "Type")?.stringValue ?? "").hasSuffix("/\(type)") }
            .flatMap { $0.attribute(forName: "Target")?.stringValue }
            .map { Self.resolve($0, relativeTo: documentPath) }
    }

    /// Prefixed to whitespace-only `<w:t>` text, which XMLDocument (libxml2) drops whatever the options;
    /// Word puts the space between two words in its own run all the time. Readers strip it again.
    static let blankTextMarker = "\u{E000}"

    private static func protectingBlankText(_ data: Data) -> Data {
        let blankText = /(<w:t(?: [^>]*)?>)([ \t\u{3000}]+)(<\/w:t>)/
        let xml = String(decoding: data, as: UTF8.self)
        guard xml.contains(blankText) else {
            return data
        }
        return Data(xml.replacing(blankText) { "\($0.1)\(blankTextMarker)\($0.2)\($0.3)" }.utf8)
    }

    static func data(in archive: Archive, at path: String) throws -> Data? {
        guard let entry = archive[path] ?? looseEntry(in: archive, at: path) else {
            return nil
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    /// Some tools write part names with backslashes or in another case.
    private static func looseEntry(in archive: Archive, at path: String) -> Entry? {
        let wanted = path.lowercased()
        return archive.first { $0.path.replacingOccurrences(of: "\\", with: "/").lowercased() == wanted }
    }

    private static func relationships(in archive: Archive, for part: String) throws -> [String: String] {
        guard let data = try data(in: archive, at: relsPath(for: part)),
              let root = try PackageXML.root(data) else {
            return [:]
        }
        var result: [String: String] = [:]
        for rel in root.elements where rel.attribute(forName: "TargetMode")?.stringValue != "External" {
            guard let id = rel.attribute(forName: "Id")?.stringValue,
                  let target = rel.attribute(forName: "Target")?.stringValue else {
                continue
            }
            result[id] = resolve(target, relativeTo: part)
        }
        return result
    }

    /// `word/document.xml` → `word/_rels/document.xml.rels`; the package itself → `_rels/.rels`.
    static func relsPath(for part: String) -> String {
        let url = URL(filePath: "/" + part)
        let directory = part.isEmpty ? "" : url.deletingLastPathComponent().path().dropFirst()
        return "\(directory)_rels/\(part.isEmpty ? "" : url.lastPathComponent).rels"
    }

    static func resolve(_ target: String, relativeTo part: String) -> String {
        if target.hasPrefix("/") {
            return String(target.dropFirst())
        }
        let base = URL(filePath: "/" + part).deletingLastPathComponent()
        return String(base.appending(path: target).standardized.path().dropFirst())
    }
}

extension XMLElement {
    var elements: [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }
    }

    func children(_ name: String, in namespace: String = OOXMLNamespace.w) -> [XMLElement] {
        elements.filter { $0.localName == name && $0.uri == namespace }
    }

    func child(_ name: String, in namespace: String = OOXMLNamespace.w) -> XMLElement? {
        elements.first { $0.localName == name && $0.uri == namespace }
    }

    func firstDescendant(_ name: String, in namespace: String) -> XMLElement? {
        for element in elements {
            if element.localName == name && element.uri == namespace {
                return element
            }
            if let found = element.firstDescendant(name, in: namespace) {
                return found
            }
        }
        return nil
    }

    /// `w:val`-style attribute.
    func value(_ name: String = "val", in namespace: String = OOXMLNamespace.w) -> String? {
        attribute(forLocalName: name, uri: namespace)?.stringValue
    }

    func number(_ name: String = "val") -> Double? {
        value(name).flatMap(Double.init)
    }

    /// OOXML toggles: `<w:b/>` is on, `<w:b w:val="0"/>` is off.
    var isOn: Bool {
        !["0", "false", "off", "none"].contains(value() ?? "1")
    }
}
