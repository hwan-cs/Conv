import Foundation

/// XPC interface between the app and the ConversionXPC service.
@objc public protocol ConversionServiceProtocol {
    func ping(withReply reply: @escaping @Sendable (String) -> Void)

    /// P1 spike: paginate HTML into an A4 PDF inside the sandboxed service. Replies with the PDF
    /// or an error description.
    func renderPDF(fromHTML html: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)

    /// Converts the file open in `input`, named so its format can be told, into `format` (an
    /// extension such as "pdf"). Replies with the result open for reading, or an error description.
    /// File handles rather than URLs or bytes: the service's sandbox can't open what the user
    /// picked, and a video doesn't fit in a message.
    /// Progress goes to the app's `ConversionProgressProtocol` object, tagged with `job`.
    func convert(
        _ input: FileHandle,
        named name: String,
        to format: String,
        job: String,
        withReply reply: @escaping @Sendable (FileHandle?, String?) -> Void
    )

    /// Makes one file of several, in order: images and PDFs into one PDF. At most
    /// `ConversionService.combineLimit` at a time, so the descriptors fit.
    func combine(
        _ inputs: [FileHandle],
        named names: [String],
        to format: String,
        job: String,
        withReply reply: @escaping @Sendable (FileHandle?, String?) -> Void
    )

    /// Makes each page of a PDF into an image of `format`. Replies with them as `PackedFiles`.
    func convertPages(
        _ input: FileHandle,
        named name: String,
        to format: String,
        job: String,
        withReply reply: @escaping @Sendable (FileHandle?, String?) -> Void
    )
}

/// What the app exports back over the same connection, for the service to report progress.
@objc public protocol ConversionProgressProtocol {
    /// `fraction` runs from 0 to 1.
    func report(job: String, fraction: Double)
}

public enum ConversionService {
    /// Must match the bundle identifier of the ConversionXPC target.
    public static let serviceName = "com.conv.Conv.ConversionXPC"

    /// Files sent to `combine` in one message.
    public static let combineLimit = 64

    /// The service's interface, with the classes its arrays may hold.
    public static func interface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: ConversionServiceProtocol.self)
        let combine = #selector(ConversionServiceProtocol.combine(_:named:to:job:withReply:))
        interface.setClasses(NSSet(array: [NSArray.self, FileHandle.self]) as! Set<AnyHashable>, for: combine, argumentIndex: 0, ofReply: false)
        interface.setClasses(NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>, for: combine, argumentIndex: 1, ofReply: false)
        return interface
    }
}
