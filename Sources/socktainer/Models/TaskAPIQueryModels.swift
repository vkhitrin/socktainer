//
// QueryModels.swift
//
// Generated from OpenAPI query parameters. Do not edit by hand.
//

import Vapor

struct TaskListQuery: Content {
    var filters: String?

    enum CodingKeys: String, CodingKey {
        case filters = "filters"
    }
}

struct TaskLogsQuery: Content {
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
