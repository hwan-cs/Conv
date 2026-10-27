import ConversionKit
import Foundation

final class ConversionServiceImpl: NSObject, ConversionServiceProtocol {
    func ping(withReply reply: @escaping @Sendable (String) -> Void) {
        reply("pong")
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ConversionServiceProtocol.self)
        newConnection.exportedObject = ConversionServiceImpl()
        newConnection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
