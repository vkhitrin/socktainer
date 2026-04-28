//
// QueryModels.swift
//
// Generated from OpenAPI query parameters. Do not edit by hand.
//

import Vapor

struct SystemDataUsageQuery: Content {
    var type: [String]?

    enum CodingKeys: String, CodingKey {
        case type = "type"
    }
}

struct SystemEventsQuery: Content {
    var since: String?
    var until: String?
    var filters: String?

    enum CodingKeys: String, CodingKey {
        case since = "since"
        case until = "until"
        case filters = "filters"
    }
}
