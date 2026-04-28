//
// QueryModels.swift
//
// Generated from OpenAPI query parameters. Do not edit by hand.
//

import Vapor

struct VolumeDeleteQuery: Content {
    var force: Bool?

    enum CodingKeys: String, CodingKey {
        case force = "force"
    }
}

struct VolumeListQuery: Content {
    var filters: String?

    enum CodingKeys: String, CodingKey {
        case filters = "filters"
    }
}

struct VolumePruneQuery: Content {
    var filters: String?

    enum CodingKeys: String, CodingKey {
        case filters = "filters"
    }
}

struct VolumeUpdateQuery: Content {
    var version: Int64

    enum CodingKeys: String, CodingKey {
        case version = "version"
    }
}
