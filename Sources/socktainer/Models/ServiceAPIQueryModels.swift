//
// QueryModels.swift
//
// Generated from OpenAPI query parameters. Do not edit by hand.
//

import Vapor

struct ServiceInspectQuery: Content {
    var insertDefaults: Bool?

    enum CodingKeys: String, CodingKey {
        case insertDefaults = "insertDefaults"
    }
}

struct ServiceListQuery: Content {
    var filters: String?
    var status: Bool?

    enum CodingKeys: String, CodingKey {
        case filters = "filters"
        case status = "status"
    }
}

struct ServiceLogsQuery: Content {
    var details: Bool?
    var follow: Bool?
    var stdout: Bool?
    var stderr: Bool?
    var since: Int?
    var timestamps: Bool?
    var tail: String?

    enum CodingKeys: String, CodingKey {
        case details = "details"
        case follow = "follow"
        case stdout = "stdout"
        case stderr = "stderr"
        case since = "since"
        case timestamps = "timestamps"
        case tail = "tail"
    }
}

struct ServiceUpdateQuery: Content {
    var version: Int
    var registryAuthFrom: String?
    var rollback: String?

    enum CodingKeys: String, CodingKey {
        case version = "version"
        case registryAuthFrom = "registryAuthFrom"
        case rollback = "rollback"
    }
}
