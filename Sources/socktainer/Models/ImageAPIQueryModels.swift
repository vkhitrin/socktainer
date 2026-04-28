//
// QueryModels.swift
//
// Generated from OpenAPI query parameters. Do not edit by hand.
//

import Vapor

struct BuildPruneQuery: Content {
    var keepStorage: Int64?
    var reservedSpace: Int64?
    var maxUsedSpace: Int64?
    var minFreeSpace: Int64?
    var all: Bool?
    var filters: String?

    enum CodingKeys: String, CodingKey {
        case keepStorage = "keep-storage"
        case reservedSpace = "reserved-space"
        case maxUsedSpace = "max-used-space"
        case minFreeSpace = "min-free-space"
        case all = "all"
        case filters = "filters"
    }
}

struct ImageBuildQuery: Content {
    var dockerfile: String?
    var t: String?
    var extrahosts: String?
    var remote: String?
    var q: Bool?
    var nocache: Bool?
    var cachefrom: String?
    var pull: String?
    var rm: Bool?
    var forcerm: Bool?
    var memory: Int?
    var memswap: Int?
    var cpushares: Int?
    var cpusetcpus: String?
    var cpuperiod: Int?
    var cpuquota: Int?
    var buildargs: String?
    var shmsize: Int?
    var squash: Bool?
    var labels: String?
    var networkmode: String?
    var platform: String?
    var target: String?
    var outputs: String?
    var version: String?

    enum CodingKeys: String, CodingKey {
        case dockerfile = "dockerfile"
        case t = "t"
        case extrahosts = "extrahosts"
        case remote = "remote"
        case q = "q"
        case nocache = "nocache"
        case cachefrom = "cachefrom"
        case pull = "pull"
        case rm = "rm"
        case forcerm = "forcerm"
        case memory = "memory"
        case memswap = "memswap"
        case cpushares = "cpushares"
        case cpusetcpus = "cpusetcpus"
        case cpuperiod = "cpuperiod"
        case cpuquota = "cpuquota"
        case buildargs = "buildargs"
        case shmsize = "shmsize"
        case squash = "squash"
        case labels = "labels"
        case networkmode = "networkmode"
        case platform = "platform"
        case target = "target"
        case outputs = "outputs"
        case version = "version"
    }
}

struct ImageCommitQuery: Content {
    var container: String?
    var repo: String?
    var tag: String?
    var comment: String?
    var author: String?
    var pause: Bool?
    var changes: String?

    enum CodingKeys: String, CodingKey {
        case container = "container"
        case repo = "repo"
        case tag = "tag"
        case comment = "comment"
        case author = "author"
        case pause = "pause"
        case changes = "changes"
    }
}

struct ImageCreateQuery: Content {
    var fromImage: String?
    var fromSrc: String?
    var repo: String?
    var tag: String?
    var message: String?
    var changes: [String]?
    var platform: String?

    enum CodingKeys: String, CodingKey {
        case fromImage = "fromImage"
        case fromSrc = "fromSrc"
        case repo = "repo"
        case tag = "tag"
        case message = "message"
        case changes = "changes"
        case platform = "platform"
    }
}

struct ImageDeleteQuery: Content {
    var force: Bool?
    var noprune: Bool?
    var platforms: [String]?

    enum CodingKeys: String, CodingKey {
        case force = "force"
        case noprune = "noprune"
        case platforms = "platforms"
    }
}

struct ImageGetQuery: Content {
    var platform: String?

    enum CodingKeys: String, CodingKey {
        case platform = "platform"
    }
}

struct ImageGetAllQuery: Content {
    var names: [String]?
    var platform: String?

    enum CodingKeys: String, CodingKey {
        case names = "names"
        case platform = "platform"
    }
}

struct ImageHistoryQuery: Content {
    var platform: String?

    enum CodingKeys: String, CodingKey {
        case platform = "platform"
    }
}

struct ImageInspectQuery: Content {
    var manifests: Bool?
    var platform: String?

    enum CodingKeys: String, CodingKey {
        case manifests = "manifests"
        case platform = "platform"
    }
}

struct ImageListQuery: Content {
    var all: Bool?
    var filters: String?
    var sharedSize: Bool?
    var digests: Bool?
    var manifests: Bool?

    enum CodingKeys: String, CodingKey {
        case all = "all"
        case filters = "filters"
        case sharedSize = "shared-size"
        case digests = "digests"
        case manifests = "manifests"
    }
}

struct ImageLoadQuery: Content {
    var quiet: Bool?
    var platform: String?

    enum CodingKeys: String, CodingKey {
        case quiet = "quiet"
        case platform = "platform"
    }
}

struct ImagePruneQuery: Content {
    var filters: String?

    enum CodingKeys: String, CodingKey {
        case filters = "filters"
    }
}

struct ImagePushQuery: Content {
    var tag: String?
    var platform: String?

    enum CodingKeys: String, CodingKey {
        case tag = "tag"
        case platform = "platform"
    }
}

struct ImageSearchQuery: Content {
    var term: String
    var limit: Int?
    var filters: String?

    enum CodingKeys: String, CodingKey {
        case term = "term"
        case limit = "limit"
        case filters = "filters"
    }
}

struct ImageTagQuery: Content {
    var repo: String?
    var tag: String?

    enum CodingKeys: String, CodingKey {
        case repo = "repo"
        case tag = "tag"
    }
}
