import Foundation
import Vapor

enum JSONResponseUtility {
    static func response(
        object: Any,
        status: HTTPStatus = .ok,
        contentType: String = "application/json; charset=utf-8",
        options: JSONSerialization.WritingOptions = []
    ) throws -> Response {
        let data = try JSONSerialization.data(withJSONObject: object, options: options)
        let response = Response(status: status)
        response.headers.replaceOrAdd(name: .contentType, value: contentType)
        response.body = .init(data: data)
        return response
    }
}
