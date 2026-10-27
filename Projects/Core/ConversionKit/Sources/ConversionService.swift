import Foundation

/// XPC interface between the app and the ConversionXPC service.
@objc public protocol ConversionServiceProtocol {
    func ping(withReply reply: @escaping @Sendable (String) -> Void)
}

public enum ConversionService {
    /// Must match the bundle identifier of the ConversionXPC target.
    public static let serviceName = "com.conv.Conv.ConversionXPC"
}
