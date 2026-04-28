//
// QueryModels.swift
//
// Generated from OpenAPI query parameters. Do not edit by hand.
//

import Vapor

struct SwarmLeaveQuery: Content {
    var force: Bool?

    enum CodingKeys: String, CodingKey {
        case force = "force"
    }
}

struct SwarmUpdateQuery: Content {
    var version: Int64
    var rotateWorkerToken: Bool?
    var rotateManagerToken: Bool?
    var rotateManagerUnlockKey: Bool?

    enum CodingKeys: String, CodingKey {
        case version = "version"
        case rotateWorkerToken = "rotateWorkerToken"
        case rotateManagerToken = "rotateManagerToken"
        case rotateManagerUnlockKey = "rotateManagerUnlockKey"
    }
}
