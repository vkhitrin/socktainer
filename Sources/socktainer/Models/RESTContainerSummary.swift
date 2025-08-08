import Vapor

struct RESTContainerSummary: Content {
    let Id: String
    let Names: [String]
    let Image: String
    let ImageID: String
    let State: String
}

struct RESTContainerListQuery: Content {
    let all: Bool?
}
