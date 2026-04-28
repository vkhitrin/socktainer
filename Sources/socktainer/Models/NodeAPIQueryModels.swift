//
// QueryModels.swift
//
// Generated from OpenAPI query parameters. Do not edit by hand.
//

import Vapor

struct NodeDeleteQuery: Content {
    var force: Bool?

    enum CodingKeys: String, CodingKey {
        case force = "force"
    }
}

struct NodeListQuery: Content {
    var filters: String?

    enum CodingKeys: String, CodingKey {
        case filters = "filters"
    }
}

struct NodeUpdateQuery: Content {
    var version: Int64

    enum CodingKeys: String, CodingKey {
        case version = "version"
    }
}
