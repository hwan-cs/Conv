import Foundation

/// XPC interface between the app and the ConversionXPC service.
@objc public protocol ConversionServiceProtocol {
    func ping(withReply reply: @escaping @Sendable (String) -> Void)

    /// P1 spike: paginate HTML into an A4 PDF inside the sandboxed service. Replies with the PDF
    /// or an error description.
    func renderPDF(fromHTML html: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)

    /// Converts a file's contents, named so its format can be told, into `format` (an extension
    /// such as "pdf"). The app passes bytes rather than a URL: the service's sandbox can't open
    /// what the user picked. Replies with the converted bytes or an error description.
    func convert(
        _ data: Data,
        named name: String,
        to format: String,
        withReply reply: @escaping @Sendable (Data?, String?) -> Void
    )
}

public enum ConversionService {
    /// Must match the bundle identifier of the ConversionXPC target.
    public static let serviceName = "com.conv.Conv.ConversionXPC"
}
