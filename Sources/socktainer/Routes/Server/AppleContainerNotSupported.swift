import Vapor

struct AppleContainerNotSupported {
    static func respond(_ feature: String) -> Response {
        let json = "{\"message\": \"\(feature) is not supported in Apple container\"}"
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        return Response(status: .notImplemented, headers: headers, body: .init(string: json))
    }
}
