import Vapor

struct RESTImageSummary: Content {
    let Id: String
    let RepoTags: [String]
    let RepoDigests: [String]
    let Created: Int
    let Size: Int64
    let Labels: [String: String]
}
