import Foundation

/// The helper's whole XPC surface: one method, JSON-encoded HelperEnvelope in, JSON-encoded HelperResponse out.
/// Keeping it to Data means NSXPC never decodes app-supplied object graphs in the root process.
@objc public protocol HelperXPCProtocol {
    func handle(_ envelope: Data, reply: @escaping (Data) -> Void)
}
