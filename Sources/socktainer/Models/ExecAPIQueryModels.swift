//
// QueryModels.swift
//
// Generated from OpenAPI query parameters. Do not edit by hand.
//

import Vapor

struct ExecResizeQuery: Content {
    var h: Int
    var w: Int

    enum CodingKeys: String, CodingKey {
        case h = "h"
        case w = "w"
    }
}
