import Foundation

enum SocktainerContainerMetadata {
    static let internalLabelPrefix = "com.apple.socktainer.metadata."
    static let containerNameLabel = "com.apple.socktainer.metadata.container-name"
    static let autoRemoveLabel = "com.apple.socktainer.metadata.auto-remove"
    static let openStdinLabel = "com.apple.socktainer.metadata.open-stdin"
    static let attachStdinLabel = "com.apple.socktainer.metadata.attach-stdin"
    static let attachStdoutLabel = "com.apple.socktainer.metadata.attach-stdout"
    static let attachStderrLabel = "com.apple.socktainer.metadata.attach-stderr"
    static let stdinOnceLabel = "com.apple.socktainer.metadata.stdin-once"
    static let cmdLabel = "com.apple.socktainer.metadata.cmd"
    static let entrypointLabel = "com.apple.socktainer.metadata.entrypoint"
    static let healthcheckLabel = "com.apple.socktainer.metadata.healthcheck"
    static let argsEscapedLabel = "com.apple.socktainer.metadata.args-escaped"
    static let stopSignalLabel = "com.apple.socktainer.metadata.stop-signal"
    static let stopTimeoutLabel = "com.apple.socktainer.metadata.stop-timeout"
    static let shellLabel = "com.apple.socktainer.metadata.shell"
    static let exposedPortsLabel = "com.apple.socktainer.metadata.exposed-ports"
    static let volumesLabel = "com.apple.socktainer.metadata.volumes"
    static let networkDisabledLabel = "com.apple.socktainer.metadata.network-disabled"
    static let macAddressLabel = "com.apple.socktainer.metadata.mac-address"
    static let onBuildLabel = "com.apple.socktainer.metadata.on-build"
    static let privilegedLabel = "com.apple.socktainer.metadata.privileged"
    static let publishAllPortsLabel = "com.apple.socktainer.metadata.publish-all-ports"
    static let readonlyRootfsLabel = "com.apple.socktainer.metadata.readonly-rootfs"
    static let restartPolicyLabel = "com.apple.socktainer.metadata.restart-policy"
    static let consoleSizeLabel = "com.apple.socktainer.metadata.console-size"
    static let bindsLabel = "com.apple.socktainer.metadata.binds"

    static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return data.base64EncodedString()
    }

    static func decodeJSON<T: Decodable>(_ value: String?, as type: T.Type) -> T? {
        guard let value, let data = Data(base64Encoded: value) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func userVisibleLabels(from labels: [String: String]) -> [String: String] {
        labels.filter { key, _ in
            !key.hasPrefix(internalLabelPrefix)
        }
    }
}
