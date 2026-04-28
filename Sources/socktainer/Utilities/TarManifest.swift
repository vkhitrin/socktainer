// Docker `save`/`load` tar archives use `manifest.json`, which is a Docker-specific format
// and not covered by Apple-native OCI models. Keep this local decoder outside generated API models.
struct TarManifest: Codable {
    let config: String?
    let repoTags: [String]?
    let layers: [String]?

    enum CodingKeys: String, CodingKey {
        case config = "Config"
        case repoTags = "RepoTags"
        case layers = "Layers"
    }
}
