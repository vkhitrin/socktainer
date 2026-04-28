//
// QueryModels.swift
//
// Generated from OpenAPI query parameters. Do not edit by hand.
//

import Vapor

struct ContainerArchiveQuery: Content {
    var path: String

    enum CodingKeys: String, CodingKey {
        case path = "path"
    }
}

struct ContainerArchiveInfoQuery: Content {
    var path: String

    enum CodingKeys: String, CodingKey {
        case path = "path"
    }
}

struct ContainerAttachQuery: Content {
    var detachKeys: String?
    var logs: Bool?
    var stream: Bool?
    var stdin: Bool?
    var stdout: Bool?
    var stderr: Bool?

    enum CodingKeys: String, CodingKey {
        case detachKeys = "detachKeys"
        case logs = "logs"
        case stream = "stream"
        case stdin = "stdin"
        case stdout = "stdout"
        case stderr = "stderr"
    }
}

struct ContainerAttachWebsocketQuery: Content {
    var detachKeys: String?
    var logs: Bool?
    var stream: Bool?
    var stdin: Bool?
    var stdout: Bool?
    var stderr: Bool?

    enum CodingKeys: String, CodingKey {
        case detachKeys = "detachKeys"
        case logs = "logs"
        case stream = "stream"
        case stdin = "stdin"
        case stdout = "stdout"
        case stderr = "stderr"
    }
}

struct ContainerCreateQuery: Content {
    var name: String?
    var platform: String?

    enum CodingKeys: String, CodingKey {
        case name = "name"
        case platform = "platform"
    }
}

struct ContainerDeleteQuery: Content {
    var v: Bool?
    var force: Bool?
    var link: Bool?

    enum CodingKeys: String, CodingKey {
        case v = "v"
        case force = "force"
        case link = "link"
    }
}

struct ContainerInspectQuery: Content {
    var size: Bool?

    enum CodingKeys: String, CodingKey {
        case size = "size"
    }
}

struct ContainerKillQuery: Content {
    var signal: String?

    enum CodingKeys: String, CodingKey {
        case signal = "signal"
    }
}

struct ContainerListQuery: Content {
    var all: Bool?
    var limit: Int?
    var size: Bool?
    var filters: String?

    enum CodingKeys: String, CodingKey {
        case all = "all"
        case limit = "limit"
        case size = "size"
        case filters = "filters"
    }
}

struct ContainerLogsQuery: Content {
    var follow: Bool?
    var stdout: Bool?
    var stderr: Bool?
    var since: Int?
    var until: Int?
    var timestamps: Bool?
    var tail: String?

    enum CodingKeys: String, CodingKey {
        case follow = "follow"
        case stdout = "stdout"
        case stderr = "stderr"
        case since = "since"
        case until = "until"
        case timestamps = "timestamps"
        case tail = "tail"
    }
}

struct ContainerPruneQuery: Content {
    var filters: String?

    enum CodingKeys: String, CodingKey {
        case filters = "filters"
    }
}

struct ContainerRenameQuery: Content {
    var name: String

    enum CodingKeys: String, CodingKey {
        case name = "name"
    }
}

struct ContainerResizeQuery: Content {
    var h: Int
    var w: Int

    enum CodingKeys: String, CodingKey {
        case h = "h"
        case w = "w"
    }
}

struct ContainerRestartQuery: Content {
    var signal: String?
    var t: Int?

    enum CodingKeys: String, CodingKey {
        case signal = "signal"
        case t = "t"
    }
}

struct ContainerStartQuery: Content {
    var detachKeys: String?

    enum CodingKeys: String, CodingKey {
        case detachKeys = "detachKeys"
    }
}

struct ContainerStatsQuery: Content {
    var stream: Bool?
    var oneShot: Bool?

    enum CodingKeys: String, CodingKey {
        case stream = "stream"
        case oneShot = "one-shot"
    }
}

struct ContainerStopQuery: Content {
    var signal: String?
    var t: Int?

    enum CodingKeys: String, CodingKey {
        case signal = "signal"
        case t = "t"
    }
}

struct ContainerTopQuery: Content {
    var psArgs: String?

    enum CodingKeys: String, CodingKey {
        case psArgs = "ps_args"
    }
}

struct ContainerWaitQuery: Content {
    var condition: String?

    enum CodingKeys: String, CodingKey {
        case condition = "condition"
    }
}

struct PutContainerArchiveQuery: Content {
    var path: String
    var noOverwriteDirNonDir: String?
    var copyUIDGID: String?

    enum CodingKeys: String, CodingKey {
        case path = "path"
        case noOverwriteDirNonDir = "noOverwriteDirNonDir"
        case copyUIDGID = "copyUIDGID"
    }
}
