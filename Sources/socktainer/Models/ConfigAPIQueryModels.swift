//
// QueryModels.swift
//
// Generated from OpenAPI query parameters. Do not edit by hand.
//

import Vapor

struct ConfigListQuery: Content {
    var filters: String?

    enum CodingKeys: String, CodingKey {
        case filters = "filters"
    }
}

struct ConfigUpdateQuery: Content {
    var version: Int64

    enum CodingKeys: String, CodingKey {
        case version = "version"
    }
}
