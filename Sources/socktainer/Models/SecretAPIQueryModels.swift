//
// QueryModels.swift
//
// Generated from OpenAPI query parameters. Do not edit by hand.
//

import Vapor

struct SecretListQuery: Content {
    var filters: String?

    enum CodingKeys: String, CodingKey {
        case filters = "filters"
    }
}

struct SecretUpdateQuery: Content {
    var version: Int64

    enum CodingKeys: String, CodingKey {
        case version = "version"
    }
}
