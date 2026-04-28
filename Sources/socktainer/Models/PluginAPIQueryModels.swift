//
// QueryModels.swift
//
// Generated from OpenAPI query parameters. Do not edit by hand.
//

import Vapor

struct GetPluginPrivilegesQuery: Content {
    var remote: String

    enum CodingKeys: String, CodingKey {
        case remote = "remote"
    }
}

struct PluginCreateQuery: Content {
    var name: String

    enum CodingKeys: String, CodingKey {
        case name = "name"
    }
}

struct PluginDeleteQuery: Content {
    var force: Bool?

    enum CodingKeys: String, CodingKey {
        case force = "force"
    }
}

struct PluginDisableQuery: Content {
    var force: Bool?

    enum CodingKeys: String, CodingKey {
        case force = "force"
    }
}

struct PluginEnableQuery: Content {
    var timeout: Int?

    enum CodingKeys: String, CodingKey {
        case timeout = "timeout"
    }
}

struct PluginListQuery: Content {
    var filters: String?

    enum CodingKeys: String, CodingKey {
        case filters = "filters"
    }
}

struct PluginPullQuery: Content {
    var remote: String
    var name: String?

    enum CodingKeys: String, CodingKey {
        case remote = "remote"
        case name = "name"
    }
}

struct PluginUpgradeQuery: Content {
    var remote: String

    enum CodingKeys: String, CodingKey {
        case remote = "remote"
    }
}
