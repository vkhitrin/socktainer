import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import Logging
import SystemPackage

enum ArchiveUtilityError: Error {
    case invalidPath
    case archiveCreationFailed(String)
    case archiveReadFailed(String)
    case archiveWriteFailed(String)
    case entryReadFailed(String)
    case rejectedArchiveEntries([String])
}

extension ArchiveUtilityError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "Invalid archive path"
        case .archiveCreationFailed(let reason):
            return "Failed to create archive reader: \(reason)"
        case .archiveReadFailed(let reason):
            return "Failed to read archive: \(reason)"
        case .archiveWriteFailed(let reason):
            return "Failed to write archive: \(reason)"
        case .entryReadFailed(let reason):
            return "Failed to read archive entry: \(reason)"
        case .rejectedArchiveEntries(let paths):
            return "Rejected archive entries: \(paths.joined(separator: ", "))"
        }
    }
}

struct ArchiveUtility {
    static func extract(tarPath: URL, to destination: URL) throws {
        let archiveReader = try makeArchiveReader(file: tarPath)
        try ensureDirectoryExists(at: destination)

        do {
            let rejectedPaths = try archiveReader.extractContents(to: destination)
            if !rejectedPaths.isEmpty {
                throw ArchiveUtilityError.rejectedArchiveEntries(rejectedPaths)
            }
        } catch {
            if let error = error as? ArchiveUtilityError {
                throw error
            }
            throw ArchiveUtilityError.archiveReadFailed(error.localizedDescription)
        }
    }

    static func extractBuildContext(tarPath: URL, to destination: URL, logger: Logger? = nil) throws {
        let archiveReader = try makeArchiveReader(file: tarPath)
        try ensureDirectoryExists(at: destination)

        do {
            try extractBuildContextFallback(reader: archiveReader, to: destination, logger: logger)
        } catch {
            throw ArchiveUtilityError.archiveReadFailed(String(describing: error))
        }
    }

    static func create(tarPath: URL, from source: URL) throws {
        try ensurePathExists(source)
        let writer = try makeArchiveWriter(file: tarPath)

        do {
            try writer.archiveDirectory(source)
            try writer.finishEncoding()
        } catch {
            throw ArchiveUtilityError.archiveWriteFailed(error.localizedDescription)
        }
    }

    static func createImageTar(tarPath: URL, from source: URL) throws {
        try ensurePathExists(source)
        let writer = try makeArchiveWriter(file: tarPath)

        do {
            try archiveDirectoryContents(source, with: writer)
            try writer.finishEncoding()
        } catch {
            throw ArchiveUtilityError.archiveWriteFailed(error.localizedDescription)
        }
    }

    static func destinationPath(for entryPath: String?, under destinationPath: String) -> String? {
        guard var entryPath else {
            return nil
        }

        if entryPath.hasPrefix("./") {
            entryPath = String(entryPath.dropFirst(1))
        }
        if entryPath == "." || entryPath == "/" {
            return destinationPath
        }
        if !entryPath.hasPrefix("/") {
            entryPath = "/" + entryPath
        }

        if destinationPath == "/" {
            return entryPath
        }

        return destinationPath + entryPath
    }

    private static func ensurePathExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ArchiveUtilityError.invalidPath
        }
    }

    private static func ensureDirectoryExists(at url: URL) throws {
        try ensurePathExists(url.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func makeArchiveReader(file: URL) throws -> ArchiveReader {
        try ensurePathExists(file)
        do {
            return try ArchiveReader(file: file)
        } catch {
            throw ArchiveUtilityError.archiveCreationFailed(error.localizedDescription)
        }
    }

    private static func makeArchiveWriter(file: URL) throws -> ArchiveWriter {
        do {
            return try ArchiveWriter(
                format: .paxRestricted,
                filter: .none,
                file: file
            )
        } catch {
            throw ArchiveUtilityError.archiveCreationFailed(error.localizedDescription)
        }
    }

    static func unpack(
        tarPath: URL,
        to formatter: EXT4.Formatter,
        destinationPath targetPath: String
    ) throws {
        let archiveReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: tarPath
        )

        let bufferSize = 128 * 1024
        let reusableBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bufferSize)
        defer { reusableBuffer.deallocate() }

        for (entry, streamReader) in archiveReader.makeStreamingIterator() {
            guard let fullPath = destinationPath(for: entry.path, under: targetPath) else {
                continue
            }

            let filePath = FilePath(fullPath)
            let ts = FileTimestamps(
                access: entry.contentAccessDate,
                modification: entry.modificationDate,
                creation: entry.creationDate
            )

            switch entry.fileType {
            case .directory:
                try formatter.create(
                    path: filePath,
                    mode: EXT4.Inode.Mode(.S_IFDIR, entry.permissions),
                    ts: ts,
                    uid: entry.owner,
                    gid: entry.group,
                    xattrs: entry.xattrs
                )
            case .regular:
                try formatter.create(
                    path: filePath,
                    mode: EXT4.Inode.Mode(.S_IFREG, entry.permissions),
                    ts: ts,
                    buf: streamReader,
                    uid: entry.owner,
                    gid: entry.group,
                    xattrs: entry.xattrs,
                    fileBuffer: reusableBuffer
                )
            case .symbolicLink:
                let symlinkTarget = entry.symlinkTarget.map { FilePath($0) }
                try formatter.create(
                    path: filePath,
                    link: symlinkTarget,
                    mode: EXT4.Inode.Mode(.S_IFLNK, entry.permissions),
                    ts: ts,
                    uid: entry.owner,
                    gid: entry.group,
                    xattrs: entry.xattrs
                )
            default:
                continue
            }
        }
    }

    private static func extractBuildContextFallback(reader: ArchiveReader, to destination: URL, logger: Logger?) throws {
        let fileManager = FileManager.default
        var hardlinks: [(link: URL, target: URL)] = []
        var entryCount = 0

        for (entry, entryData) in reader {
            entryCount += 1
            guard let memberPath = entry.path else {
                logger?.info("Build context extractor reached terminal empty-path entry at #\(entryCount); stopping iteration")
                break
            }
            guard let relativePath = normalizedRelativePath(memberPath) else {
                logger?.info("Build context extractor skipping entry #\(entryCount) with invalid normalized path: \(memberPath)")
                continue
            }

            let destinationURL = destination.appendingPathComponent(relativePath, isDirectory: false)
            logger?.info("Build context extractor handling entry #\(entryCount): \(memberPath) [\(entry.fileType.rawValue)]")

            if let hardlinkTarget = entry.hardlink,
                let normalizedTarget = normalizedRelativePath(hardlinkTarget)
            {
                try ensureParentDirectory(for: destinationURL)
                try removeExistingItem(at: destinationURL)
                hardlinks.append(
                    (
                        link: destinationURL,
                        target: destination.appendingPathComponent(normalizedTarget, isDirectory: false)
                    ))
                logger?.info("Build context extractor deferred hardlink for \(memberPath) -> \(hardlinkTarget)")
                continue
            }

            switch entry.fileType {
            case .directory:
                try removeExistingItemIfNonDirectory(at: destinationURL)
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            case .regular:
                try ensureParentDirectory(for: destinationURL)
                try removeExistingItem(at: destinationURL)
                let created = fileManager.createFile(atPath: destinationURL.path, contents: entryData)
                guard created else {
                    throw ArchiveUtilityError.archiveWriteFailed(
                        "failed to create extracted file at \(destinationURL.path)"
                    )
                }
            case .symbolicLink:
                guard let target = entry.symlinkTarget else {
                    continue
                }
                try ensureParentDirectory(for: destinationURL)
                try removeExistingItem(at: destinationURL)
                try fileManager.createSymbolicLink(atPath: destinationURL.path, withDestinationPath: target)
            default:
                logger?.info("Build context extractor ignoring unsupported entry #\(entryCount): \(memberPath)")
                continue
            }
        }

        for hardlink in hardlinks {
            try ensureParentDirectory(for: hardlink.link)
            try removeExistingItem(at: hardlink.link)
            try fileManager.linkItem(at: hardlink.target, to: hardlink.link)
            logger?.info("Build context extractor created hardlink \(hardlink.link.lastPathComponent) -> \(hardlink.target.lastPathComponent)")
        }
        logger?.info("Build context extractor finished after \(entryCount) entries")
    }

    private static func normalizedRelativePath(_ rawPath: String) -> String? {
        let components = rawPath.split(separator: "/", omittingEmptySubsequences: true)
        var normalized: [Substring] = []

        for component in components {
            if component == "." {
                continue
            }
            if component == ".." {
                guard !normalized.isEmpty else {
                    return nil
                }
                normalized.removeLast()
                continue
            }
            normalized.append(component)
        }

        guard !normalized.isEmpty else {
            return nil
        }

        return normalized.map(String.init).joined(separator: "/")
    }

    private static func ensureParentDirectory(for url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private static func removeExistingItem(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func removeExistingItemIfNonDirectory(at url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return
        }
        if !isDirectory.boolValue {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func archiveDirectoryContents(_ dir: URL, with writer: ArchiveWriter) throws {
        let fileManager = FileManager.default
        let dirPath = FilePath(dir.path)
        let transaction = writer.makeTransactionWriter()

        guard let enumerator = fileManager.enumerator(atPath: dirPath.string) else {
            throw POSIXError(.ENOTDIR)
        }

        let relativePaths = (enumerator.allObjects as? [String] ?? []).sorted()

        for relativePath in relativePaths {
            let fullPath = dirPath.appending(relativePath)

            var statInfo = stat()
            guard lstat(fullPath.string, &statInfo) == 0 else {
                let errNo = errno
                let err = POSIXErrorCode(rawValue: errNo) ?? .EINVAL
                throw ArchiveUtilityError.archiveWriteFailed(
                    "lstat failed for '\(fullPath)': \(POSIXError(err))"
                )
            }

            let mode = statInfo.st_mode
            let uid = statInfo.st_uid
            let gid = statInfo.st_gid
            var size: Int64 = 0
            let type: URLFileResourceType

            if (mode & S_IFMT) == S_IFREG {
                type = .regular
                size = Int64(statInfo.st_size)
            } else if (mode & S_IFMT) == S_IFDIR {
                type = .directory
            } else if (mode & S_IFMT) == S_IFLNK {
                type = .symbolicLink
            } else {
                continue
            }

            #if os(macOS)
            let created = Date(timeIntervalSince1970: Double(statInfo.st_ctimespec.tv_sec))
            let access = Date(timeIntervalSince1970: Double(statInfo.st_atimespec.tv_sec))
            let modified = Date(timeIntervalSince1970: Double(statInfo.st_mtimespec.tv_sec))
            #else
            let created = Date(timeIntervalSince1970: Double(statInfo.st_ctim.tv_sec))
            let access = Date(timeIntervalSince1970: Double(statInfo.st_atim.tv_sec))
            let modified = Date(timeIntervalSince1970: Double(statInfo.st_mtim.tv_sec))
            #endif

            let entry = WriteEntry()
            if type == .symbolicLink {
                let targetPath = try fileManager.destinationOfSymbolicLink(atPath: fullPath.string)
                let symlinkParent = fullPath.removingLastComponent()
                let resolvedFull = symlinkParent.appending(targetPath).lexicallyNormalized()
                guard resolvedFull.starts(with: dirPath) else {
                    continue
                }
                entry.symlinkTarget = targetPath
            }

            entry.path = relativePath
            entry.size = size
            entry.creationDate = created
            entry.modificationDate = modified
            entry.contentAccessDate = access
            entry.fileType = type
            entry.group = gid
            entry.owner = uid
            entry.permissions = mode

            if type == .regular {
                let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 4 * 1024 * 1024, alignment: 1)
                guard let baseAddress = buf.baseAddress else {
                    throw ArchiveUtilityError.archiveWriteFailed(
                        "cannot create temporary buffer"
                    )
                }
                defer { buf.deallocate() }
                let fd = Foundation.open(fullPath.string, O_RDONLY)
                guard fd >= 0 else {
                    let err = POSIXErrorCode(rawValue: errno) ?? .EINVAL
                    throw ArchiveUtilityError.archiveWriteFailed(
                        "cannot open file \(fullPath.string) for reading: \(err)"
                    )
                }
                defer { close(fd) }
                try transaction.writeHeader(entry: entry)
                while true {
                    let n = read(fd, baseAddress, 4 * 1024 * 1024)
                    if n == 0 { break }
                    if n < 0 {
                        let err = POSIXErrorCode(rawValue: errno) ?? .EIO
                        throw ArchiveUtilityError.archiveWriteFailed(
                            "failed to read from file \(fullPath.string): \(err)"
                        )
                    }
                    try transaction.writeChunk(data: UnsafeRawBufferPointer(start: baseAddress, count: n))
                }
                try transaction.finish()
            } else {
                try writer.writeEntry(entry: entry, data: nil)
            }
        }
    }
}
