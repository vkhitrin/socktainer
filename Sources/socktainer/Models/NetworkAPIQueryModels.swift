//
// QueryModels.swift
//
// Generated from OpenAPI query parameters. Do not edit by hand.
//

import Vapor

struct NetworkInspectQuery: Content {
    var verbose: Bool?
    var scope: String?

    enum CodingKeys: String, CodingKey {
        case verbose = "verbose"
        case scope = "scope"
    }
}

struct NetworkListQuery: Content {
    var filters: String?

    enum CodingKeys: String, CodingKey {
        case filters = "filters"
    }
}

struct NetworkPruneQuery: Content {
    var filters: String?

    enum CodingKeys: String, CodingKey {
        case filters = "filters"
    }
}
