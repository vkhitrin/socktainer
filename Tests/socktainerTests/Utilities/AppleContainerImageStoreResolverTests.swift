import Foundation
import Testing

@testable import socktainer

struct AppleContainerImageStoreResolverTests {
    @Test
    func descriptorExtrasIncludesRawAnnotations() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let parentDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let childDigest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

        let blobDirectory =
            temporaryDirectory
            .appendingPathComponent("content", isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("sha256", isDirectory: true)
        try FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)

        let blobURL = blobDirectory.appendingPathComponent(String(parentDigest.dropFirst("sha256:".count)))
        let descriptorDocument: [String: Any] = [
            "schemaVersion": 2,
            "manifests": [
                [
                    "digest": childDigest,
                    "annotations": [
                        "org.opencontainers.image.base.digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                        "org.opencontainers.image.base.name": "alpine:3.18",
                    ],
                    "data": "ZmFrZS1kYXRh",
                    "artifactType": "application/vnd.example.test",
                ]
            ],
        ]
        let blobData = try JSONSerialization.data(withJSONObject: descriptorDocument, options: [.prettyPrinted])
        try blobData.write(to: blobURL)

        let extras = AppleContainerImageStoreResolver.descriptorExtras(
            appSupportURL: temporaryDirectory,
            parentDigest: parentDigest,
            childDigest: childDigest
        )

        #expect(extras?.data == "ZmFrZS1kYXRh")
        #expect(extras?.artifactType == "application/vnd.example.test")
        #expect(extras?.annotations?["org.opencontainers.image.base.digest"] == "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc")
        #expect(extras?.annotations?["org.opencontainers.image.base.name"] == "alpine:3.18")
    }
}
