import Vapor

struct NotImplemented {
    static func respond(_ feature: String, _: String) -> Response {
        AppleContainerNotSupported.respond(feature)
    }
}
