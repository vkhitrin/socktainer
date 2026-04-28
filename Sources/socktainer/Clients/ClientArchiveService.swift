import ContainerAPIClient
import ContainerResource
import ContainerSandboxServiceClient
import Containerization
import ContainerizationArchive
import ContainerizationEXT4
import Darwin
import Foundation
import NIO
import SystemPackage
import Vapor

/// Extension to add convenience computed properties for EXT4.Inode
extension EXT4.Inode {
    /// Full 64-bit file size
    var size: Int64 {
        Int64(sizeLow) | (Int64(sizeHigh) << 32)
    }

    /// Full 32-bit user ID
    var fullUid: UInt32 {
        UInt32(uid) | (UInt32(uidHigh) << 16)
    }

    /// Full 32-bit group ID
    var fullGid: UInt32 {
        UInt32(gid) | (UInt32(gidHigh) << 16)
    }

    /// Check if this is a directory
    var isDirectory: Bool {
        (mode & 0xF000) == 0x4000
    }

    /// Check if this is a regular file
    var isRegularFile: Bool {
        (mode & 0xF000) == 0x8000
    }

    /// Check if this is a symbolic link
    var isSymlink: Bool {
        (mode & 0xF000) == 0xA000
    }

    /// Permission bits only (without file type)
    var permissions: UInt16 {
        mode & 0x0FFF
    }
}

/// Errors specific to archive operations
enum ClientArchiveError: Error, LocalizedError {
    case containerNotFound(id: String)
    case pathNotFound(path: String)
    case rootfsNotFound(id: String)
    case invalidPath(path: String)
    case operationFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .containerNotFound(let id):
            return "Container not found: \(id)"
        case .pathNotFound(let path):
            return "Path not found in container: \(path)"
        case .rootfsNotFound(let id):
            return "Rootfs not found for container: \(id)"
        case .invalidPath(let path):
            return "Invalid path: \(path)"
        case .operationFailed(let message):
            return "Archive operation failed: \(message)"
        }
    }
}

/// File stat information for the X-Docker-Container-Path-Stat header
struct PathStat: Codable {
    let name: String
    let size: Int64
    let mode: UInt32
    let mtime: String
    let linkTarget: String

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case mode
        case mtime
        case linkTarget
    }
}

/// Protocol for archive operations on containers
protocol ClientArchiveProtocol: Sendable {
    /// Get the path to a container's rootfs
    func getRootfsPath(containerId: String) -> URL

    /// Get stat information for a file or directory inside a container.
    func statPath(containerId: String, path: String) async throws -> PathStat

    /// Read a file or directory from a container's filesystem and return as tar data
    func getArchive(containerId: String, path: String) async throws -> (tarData: Data, stat: PathStat)

    /// Extract a tar archive into a container's filesystem at the specified path
    func putArchive(containerId: String, path: String, tarPath: URL, noOverwriteDirNonDir: Bool, containerIsRunning: Bool) async throws
}

/// Service for performing archive operations on container filesystems
struct ClientArchiveService: ClientArchiveProtocol {
    private let appSupportPath: URL
    private static let guestWriteChunkSize = 1024 * 1024

    private struct RuntimeConfigurationSnapshot: Decodable {
        let containerRootFilesystem: Filesystem?
    }

    private struct RunningContainerSandboxSession {
        let sandbox: SandboxClient
        let agent: Vminitd
        let group: MultiThreadedEventLoopGroup
        let guestRootfsPath: String
    }

    init(appSupportPath: URL) {
        self.appSupportPath = appSupportPath
    }

    private func bundlePath(containerId: String) -> URL {
        appSupportPath
            .appendingPathComponent("containers")
            .appendingPathComponent(containerId)
    }

    private func runtimeConfigurationPath(containerId: String) -> URL {
        bundlePath(containerId: containerId)
            .appendingPathComponent("runtime-configuration.json")
    }

    private func containerConfiguration(containerId: String) throws -> ContainerConfiguration {
        try Bundle(path: bundlePath(containerId: containerId)).configuration
    }

    /// Get the path to a container's rootfs.ext4 file
    func getRootfsPath(containerId: String) -> URL {
        bundlePath(containerId: containerId)
            .appendingPathComponent("rootfs.ext4")
    }

    private func resolveRootfsPath(containerId: String) throws -> URL {
        func runtimeRootfsPath() throws -> URL? {
            let runtimeConfigPath = runtimeConfigurationPath(containerId: containerId)
            guard FileManager.default.fileExists(atPath: runtimeConfigPath.path) else {
                return nil
            }

            let data = try FileIOUtility.readData(at: runtimeConfigPath)
            let runtimeConfiguration = try JSONDecoder().decode(RuntimeConfigurationSnapshot.self, from: data)
            if let filesystem = runtimeConfiguration.containerRootFilesystem, filesystem.isBlock,
                FileManager.default.fileExists(atPath: filesystem.source)
            {
                return URL(fileURLWithPath: filesystem.source)
            }
            return nil
        }

        let directRootfsPath = getRootfsPath(containerId: containerId)
        if FileManager.default.fileExists(atPath: directRootfsPath.path) {
            return directRootfsPath
        }

        if let runtimeRootfsPath = try runtimeRootfsPath() {
            return runtimeRootfsPath
        }

        let bundle = Bundle(path: bundlePath(containerId: containerId))
        if let filesystem = try? bundle.containerRootfs, filesystem.isBlock,
            FileManager.default.fileExists(atPath: filesystem.source)
        {
            return URL(fileURLWithPath: filesystem.source)
        }

        throw ClientArchiveError.rootfsNotFound(id: containerId)
    }

    private func normalizedPathStat(reader: EXT4.EXT4Reader, path: String) throws -> (String, PathStat) {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        guard reader.exists(FilePath(normalizedPath)) else {
            throw ClientArchiveError.pathNotFound(path: normalizedPath)
        }

        let (_, inode) = try reader.stat(FilePath(normalizedPath), followSymlinks: false)
        let pathStat = PathStat(
            name: (normalizedPath as NSString).lastPathComponent,
            size: inode.size,
            mode: UInt32(inode.permissions),
            mtime: DockerTimestampUtility.pathStatTimestamp(Date(timeIntervalSince1970: TimeInterval(inode.mtime))),
            linkTarget: inode.isSymlink ? (readSymlinkTarget(reader: reader, path: normalizedPath) ?? "") : ""
        )

        return (normalizedPath, pathStat)
    }

    func statPath(containerId: String, path: String) async throws -> PathStat {
        let rootfsPath = try resolveRootfsPath(containerId: containerId)
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))
        let (_, stat) = try normalizedPathStat(reader: reader, path: path)
        return stat
    }

    /// Read a file or directory from a container's filesystem and return as tar data
    /// This implementation reads only the requested path directly, avoiding full filesystem export.
    func getArchive(containerId: String, path: String) async throws -> (tarData: Data, stat: PathStat) {
        let rootfsPath = try resolveRootfsPath(containerId: containerId)

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))
        let (normalizedPath, pathStat) = try normalizedPathStat(reader: reader, path: path)

        // Create temporary directory for tar creation
        let tempDir = FileManager.default.temporaryDirectory
        let sessionId = UUID().uuidString
        let stagingDir = tempDir.appendingPathComponent("\(sessionId)-staging")
        let tarPath = tempDir.appendingPathComponent("\(sessionId).tar")

        defer {
            try? FileManager.default.removeItem(at: stagingDir)
            try? FileManager.default.removeItem(at: tarPath)
        }

        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        // Extract the requested path to the staging directory
        try extractPathToDirectory(reader: reader, sourcePath: normalizedPath, destDir: stagingDir)

        // Create tar archive from the staging directory
        try ArchiveUtility.create(tarPath: tarPath, from: stagingDir)

        // Read the tar data
        let tarData = try FileIOUtility.readData(at: tarPath)

        return (tarData: tarData, stat: pathStat)
    }

    /// Extract a tar archive into a container's filesystem at the specified path
    func putArchive(containerId: String, path: String, tarPath: URL, noOverwriteDirNonDir: Bool, containerIsRunning: Bool) async throws {
        let rootfsPath = try resolveRootfsPath(containerId: containerId)

        // Normalize the destination path
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))
        try validateArchiveEntries(
            reader: reader,
            tarPath: tarPath,
            destinationPath: normalizedPath,
            noOverwriteDirNonDir: noOverwriteDirNonDir
        )

        if containerIsRunning {
            try await putArchiveInGuest(
                containerId: containerId,
                destinationPath: normalizedPath,
                inputTarPath: tarPath
            )
            return
        }

        try await putArchiveFallback(
            rootfsPath: rootfsPath,
            destinationPath: normalizedPath,
            inputTarPath: tarPath
        )
    }

    private func writeGuestFile(
        agent: Vminitd,
        path: String,
        data: Data,
        mode: UInt32
    ) async throws {
        // Containerization 0.31.0 started chunking large file writes in ContentWriter.
        // Mirror that here for live archive extraction so we do not push an entire file
        // through a single guest-agent gRPC payload when copying into a running container.
        if data.isEmpty {
            let flags = WriteFileFlags(createParentDirectories: true, append: false, create: true)
            try await agent.writeFile(path: path, data: data, flags: flags, mode: mode)
            return
        }

        var offset = 0
        var isFirstChunk = true
        while offset < data.count {
            let end = min(offset + Self.guestWriteChunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            let flags = WriteFileFlags(
                createParentDirectories: true,
                append: !isFirstChunk,
                create: isFirstChunk
            )
            try await agent.writeFile(path: path, data: chunk, flags: flags, mode: mode)
            offset = end
            isFirstChunk = false
        }
    }

    private func putArchiveInGuest(
        containerId: String,
        destinationPath: String,
        inputTarPath: URL
    ) async throws {
        let session = try await createRunningContainerSandboxSession(containerId: containerId)
        defer {
            Swift.Task {
                try? await session.agent.close()
                try? await session.group.shutdownGracefully()
            }
        }

        let archiveReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: inputTarPath
        )

        let rootfsPath = try resolveRootfsPath(containerId: containerId)
        let existingReader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))

        var knownDirectories: Set<String> = ["/", destinationPath]

        func ensureDirectory(_ path: String, mode: UInt16 = 0o755) async throws {
            guard path != "/", !knownDirectories.contains(path) else {
                return
            }

            let parentPath = (path as NSString).deletingLastPathComponent
            let normalizedParent = parentPath.isEmpty ? "/" : parentPath
            try await ensureDirectory(normalizedParent, mode: 0o755)
            // NOTE: Apple's live guest agent exposes mkdir but does not provide
            // a chmod/chown path for directories here. We create the directory
            // in guest space and rely on the default guest permissions.
            try await session.agent.mkdir(
                path: session.guestRootfsPath + path,
                all: false,
                perms: UInt32(mode)
            )
            knownDirectories.insert(path)
        }

        try await ensureDirectory(destinationPath, mode: 0o755)

        func existingPathIsDirectory(_ path: String) throws -> Bool {
            guard existingReader.exists(FilePath(path)) else {
                return false
            }
            let (_, inode) = try existingReader.stat(FilePath(path), followSymlinks: false)
            return inode.isDirectory
        }

        func pathExists(_ path: String) -> Bool {
            existingReader.exists(FilePath(path))
        }

        for (entry, data) in archiveReader {
            guard let fullPath = ArchiveUtility.destinationPath(for: entry.path, under: destinationPath) else {
                continue
            }

            let parentPath = (fullPath as NSString).deletingLastPathComponent
            let normalizedParent = parentPath.isEmpty ? "/" : parentPath

            switch entry.fileType {
            case .directory:
                if try existingPathIsDirectory(fullPath) || knownDirectories.contains(fullPath) {
                    knownDirectories.insert(fullPath)
                    continue
                }
                try await ensureDirectory(fullPath, mode: entry.permissions)
            case .regular:
                try await ensureDirectory(normalizedParent, mode: 0o755)
                guard !pathExists(fullPath) else {
                    // NOTE: In the Apple containerization version socktainer is
                    // pinned to, the live guest agent exposes writeFile but not
                    // a truncate-or-replace file copy API. Reject overwrites for
                    // running containers instead of corrupting file contents.
                    throw ClientArchiveError.operationFailed(
                        message: "Overwriting existing files in a running container is not yet supported for \(fullPath)"
                    )
                }
                try await writeGuestFile(
                    agent: session.agent,
                    path: session.guestRootfsPath + fullPath,
                    data: data,
                    mode: UInt32(entry.permissions)
                )
            case .symbolicLink:
                // NOTE: Apple exposes live file copy APIs for running containers,
                // but the guest agent does not expose symlink creation. Reject
                // these uploads for running containers instead of mutating the
                // backing ext4 image under a live guest.
                throw ClientArchiveError.operationFailed(
                    message: "Symlinks are not supported for archive extraction into a running container at \(fullPath)"
                )
            default:
                throw ClientArchiveError.operationFailed(
                    message: "Archive entry type \(entry.fileType) is not supported for archive extraction into a running container at \(fullPath)"
                )
            }
        }

        try await session.agent.sync()
    }

    private func createRunningContainerSandboxSession(containerId: String) async throws -> RunningContainerSandboxSession {
        let configuration = try containerConfiguration(containerId: containerId)
        let sandbox = try await SandboxClient.create(id: containerId, runtime: configuration.runtimeHandler)
        let connection = try await sandbox.dial(Vminitd.port)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let agent = try Vminitd(connection: connection, group: group)
        return RunningContainerSandboxSession(
            sandbox: sandbox,
            agent: agent,
            group: group,
            guestRootfsPath: "/run/container/\(containerId)/rootfs"
        )
    }

    /// Fallback PUT using full read-modify-write approach
    private func putArchiveFallback(
        rootfsPath: URL,
        destinationPath: String,
        inputTarPath: URL
    ) async throws {
        // Create temporary files for the operation
        let tempDir = FileManager.default.temporaryDirectory
        let sessionId = UUID().uuidString
        let exportedTarPath = tempDir.appendingPathComponent("\(sessionId)-export.tar")
        let newRootfsPath = tempDir.appendingPathComponent("\(sessionId)-rootfs.ext4")

        defer {
            try? FileManager.default.removeItem(at: exportedTarPath)
            try? FileManager.default.removeItem(at: newRootfsPath)
        }

        // Step 1: Export existing filesystem to tar
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))
        try reader.export(archive: FilePath(exportedTarPath.path))

        // Step 2: Get the size of the existing rootfs to create a new one of similar size
        let rootfsAttributes = try FileManager.default.attributesOfItem(atPath: rootfsPath.path)
        let rootfsSize = (rootfsAttributes[.size] as? UInt64) ?? (2 * 1024 * 1024 * 1024)  // Default 2GB

        // Step 3: Create a new ext4 formatter
        // Use a minimum size that can accommodate the filesystem
        let minSize = max(rootfsSize, 256 * 1024)  // At least 256KB
        let formatter = try EXT4.Formatter(
            FilePath(newRootfsPath.path),
            blockSize: 4096,
            minDiskSize: minSize
        )

        // Step 4: Unpack the existing filesystem
        let existingReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: exportedTarPath
        )
        try await formatter.unpack(reader: existingReader)

        // Step 5: Unpack the new tar at the specified destination path
        try ArchiveUtility.unpack(
            tarPath: inputTarPath,
            to: formatter,
            destinationPath: destinationPath
        )

        // Step 6: Finalize the new filesystem
        try formatter.close()

        // Step 7: Atomically replace the old rootfs with the new one
        let backupPath = rootfsPath.appendingPathExtension("backup")
        try? FileManager.default.removeItem(at: backupPath)

        // Move old rootfs to backup
        try FileManager.default.moveItem(at: rootfsPath, to: backupPath)

        do {
            // Move new rootfs into place
            try FileManager.default.moveItem(at: newRootfsPath, to: rootfsPath)
            // Remove backup on success
            try? FileManager.default.removeItem(at: backupPath)
        } catch {
            // Restore backup on failure
            try? FileManager.default.moveItem(at: backupPath, to: rootfsPath)
            throw ClientArchiveError.operationFailed(message: "Failed to replace rootfs: \(error.localizedDescription)")
        }
    }

    /// Read symlink target using the reader's public API
    private func readSymlinkTarget(reader: EXT4.EXT4Reader, path: String) -> String? {
        guard let data = try? reader.readFile(at: FilePath(path), followSymlinks: false) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func validateArchiveEntries(
        reader: EXT4.EXT4Reader,
        tarPath: URL,
        destinationPath: String,
        noOverwriteDirNonDir: Bool
    ) throws {
        let archiveReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: tarPath
        )

        for (entry, _) in archiveReader.makeStreamingIterator() {
            guard let fullPath = ArchiveUtility.destinationPath(for: entry.path, under: destinationPath) else {
                continue
            }

            guard noOverwriteDirNonDir, reader.exists(FilePath(fullPath)) else {
                continue
            }

            let (_, inode) = try reader.stat(FilePath(fullPath))
            let existingIsDirectory = inode.isDirectory
            let incomingIsDirectory = entry.fileType == .directory

            if existingIsDirectory != incomingIsDirectory {
                throw ClientArchiveError.operationFailed(
                    message: "Refusing to overwrite \(existingIsDirectory ? "directory" : "non-directory") at \(fullPath)"
                )
            }
        }
    }

    /// Extract a path from the ext4 filesystem to a local directory
    private func extractPathToDirectory(reader: EXT4.EXT4Reader, sourcePath: String, destDir: URL) throws {
        // Inspect the raw inode first so broken symlinks can still be archived
        // as symlink entries instead of failing the whole directory export.
        let (_, inode) = try reader.stat(FilePath(sourcePath), followSymlinks: false)
        let baseName = sourcePath == "/" ? nil : (sourcePath as NSString).lastPathComponent

        if inode.isDirectory {
            let dirDest: URL
            if let baseName {
                dirDest = destDir.appendingPathComponent(baseName)
                try FileManager.default.createDirectory(at: dirDest, withIntermediateDirectories: true)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: inode.permissions)],
                    ofItemAtPath: dirDest.path
                )
            } else {
                dirDest = destDir
            }

            // Recursively extract contents
            let entries = try reader.listDirectory(FilePath(sourcePath))
            for entry in entries {
                let childPath = sourcePath == "/" ? "/\(entry)" : "\(sourcePath)/\(entry)"
                try extractPathToDirectory(reader: reader, sourcePath: childPath, destDir: dirDest)
            }
        } else if inode.isRegularFile {
            // Read file contents
            let fileData = try reader.readFile(at: FilePath(sourcePath))
            guard let baseName else {
                throw ClientArchiveError.invalidPath(path: sourcePath)
            }
            let fileDest = destDir.appendingPathComponent(baseName)

            // Write file
            try fileData.write(to: fileDest)

            // Set permissions and modification time
            let mtimeDate = Date(timeIntervalSince1970: TimeInterval(inode.mtime))
            try FileManager.default.setAttributes(
                [
                    .posixPermissions: NSNumber(value: inode.permissions),
                    .modificationDate: mtimeDate,
                ],
                ofItemAtPath: fileDest.path
            )
        } else if inode.isSymlink {
            // Read symlink target
            if let target = readSymlinkTarget(reader: reader, path: sourcePath) {
                guard let baseName else {
                    throw ClientArchiveError.invalidPath(path: sourcePath)
                }
                let linkDest = destDir.appendingPathComponent(baseName)
                try FileManager.default.createSymbolicLink(atPath: linkDest.path, withDestinationPath: target)
            }
        }
        // Skip other file types (devices, fifos, sockets)
    }

}
