import Foundation
import Darwin

/// Descriptor-relative storage for the app's own profile metadata. Existing
/// ancestors are never chmod'd; only the designated profile directory and its
/// metadata files receive owner-only permissions. Symlinks and hardlinks are
/// rejected instead of followed, including during backup reads and deletion.
public enum SecureProfileStorage {
    public enum StorageError: LocalizedError {
        case invalidPath
        case unsafeItem(String)
        case tooLarge(String)
        case cannotPreserveSession(String)
        case operation(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .invalidPath: return "Invalid profile storage path."
            case .unsafeItem(let path): return "Refusing unsafe profile storage at \(path)."
            case .tooLarge(let path): return "Profile metadata is too large to read safely: \(path)."
            case .cannotPreserveSession(let path): return "Cannot safely preserve saved tabs from the damaged session at \(path). Restore a valid session or select saved tabs for erasure."
            case .operation(let action, let code): return "Profile storage \(action) failed: \(String(cString: strerror(code)))."
            }
        }
    }

    private final class Directory {
        let descriptor: Int32
        let url: URL
        init(_ descriptor: Int32, url: URL) { self.descriptor = descriptor; self.url = url }
        deinit { Darwin.close(descriptor) }
    }

    /// These two root aliases are part of macOS's filesystem layout, not
    /// app-controlled links. No other symlink in a profile path is accepted.
    private static func normalized(_ directory: URL) throws -> URL {
        guard directory.isFileURL else { throw StorageError.invalidPath }
        // Do not resolve or standardize away app-controlled links or `..`
        // components before walking the path with O_NOFOLLOW.
        var path = directory.path
        if path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        else if path == "/tmp" || path.hasPrefix("/tmp/") { path = "/private" + path }
        guard path.hasPrefix("/"), !path.contains("\0") else { throw StorageError.invalidPath }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func checkedName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw StorageError.invalidPath
        }
    }

    private static func restrictAccess(_ descriptor: Int32, mode: mode_t) throws {
        // macOS ACL grants can outlive chmod's POSIX mode changes. Removing
        // only this owned object's extended ACL prevents inherited read grants
        // from silently defeating 0700/0600. Never modify parent ACLs.
        guard let emptyACL = acl_init(0) else { throw StorageError.operation("preparing private permissions", errno) }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        if acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED) != 0, errno != ENOTSUP {
            throw StorageError.operation("removing inherited access grants", errno)
        }
        guard fchmod(descriptor, mode) == 0 else { throw StorageError.operation("restricting permissions", errno) }
    }

    private static func openDirectory(_ directory: URL, create: Bool,
                                      harden: Bool) throws -> Directory? {
        let url = try normalized(directory)
        // Traversal only needs search permission. O_RDONLY on every ancestor
        // incorrectly requests directory enumeration outside the app container,
        // which App Sandbox can deny even when the final profile is permitted.
        var descriptor = Darwin.open("/", O_SEARCH | O_CLOEXEC)
        guard descriptor >= 0 else { throw StorageError.operation("opening root", errno) }
        do {
            for component in url.pathComponents.dropFirst() {
                try checkedName(component)
                var next = openat(descriptor, component, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT {
                    guard create else { Darwin.close(descriptor); return nil }
                    if mkdirat(descriptor, component, mode_t(0o700)) != 0, errno != EEXIST {
                        throw StorageError.operation("creating directory", errno)
                    }
                    next = openat(descriptor, component, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw StorageError.unsafeItem(url.path) }
                Darwin.close(descriptor)
                descriptor = next
            }
            // Only the designated profile directory needs a readable handle
            // for metadata operations and entryNames(), never its ancestors.
            let readable = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard readable >= 0 else { throw StorageError.operation("opening profile directory", errno) }
            Darwin.close(descriptor)
            descriptor = readable
            if harden {
                var info = stat()
                guard fstat(descriptor, &info) == 0 else { throw StorageError.operation("checking directory", errno) }
                guard info.st_uid == geteuid(), url.path != "/" else { throw StorageError.unsafeItem(url.path) }
                try restrictAccess(descriptor, mode: mode_t(0o700))
            }
            return Directory(descriptor, url: url)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Creates missing path components with owner-only permissions and hardens
    /// the designated leaf. It does not change existing parent permissions.
    public static func ensureDirectory(_ directory: URL) throws {
        _ = try openDirectory(directory, create: true, harden: true)
    }

    public static func directoryExists(_ directory: URL) throws -> Bool {
        try openDirectory(directory, create: false, harden: false) != nil
    }

    private static func checkedFile(_ name: String, in directory: Directory,
                                    harden: Bool) throws -> Int32? {
        try checkedName(name)
        let descriptor = openat(directory.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw StorageError.unsafeItem(directory.url.appendingPathComponent(name).path) }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw StorageError.operation("checking file", errno) }
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1 else {
                throw StorageError.unsafeItem(directory.url.appendingPathComponent(name).path)
            }
            if harden { try restrictAccess(descriptor, mode: mode_t(0o600)) }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    public static func validateFiles(named names: [String], in directory: URL) throws {
        guard let handle = try openDirectory(directory, create: false, harden: true) else { return }
        for name in names {
            if let descriptor = try checkedFile(name, in: handle, harden: true) { Darwin.close(descriptor) }
        }
    }

    /// Reading never creates a directory. The size bound also protects the
    /// decoder from an unexpectedly large or attacker-supplied local file.
    public static func readData(named name: String, in directory: URL,
                                maximumBytes: Int = 32 * 1024 * 1024,
                                harden: Bool = true) throws -> Data? {
        guard maximumBytes >= 0 else { throw StorageError.invalidPath }
        guard let handle = try openDirectory(directory, create: false, harden: harden),
              let descriptor = try checkedFile(name, in: handle, harden: harden) else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw StorageError.operation("measuring file", errno) }
        guard info.st_size >= 0, info.st_size <= maximumBytes else {
            throw StorageError.tooLarge(handle.url.appendingPathComponent(name).path)
        }
        var result = Data()
        result.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw StorageError.operation("reading file", errno)
            }
            if count == 0 { break }
            guard result.count <= maximumBytes - count else {
                throw StorageError.tooLarge(handle.url.appendingPathComponent(name).path)
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    public static func writeData(_ data: Data, named name: String, in directory: URL) throws {
        try checkedName(name)
        guard let handle = try openDirectory(directory, create: true, harden: true) else { throw StorageError.invalidPath }
        if let existing = try checkedFile(name, in: handle, harden: true) { Darwin.close(existing) }
        let temporaryName = ".curve-metadata-" + UUID().uuidString
        let descriptor = openat(handle.descriptor, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw StorageError.operation("creating temporary file", errno) }
        defer {
            Darwin.close(descriptor)
            unlinkat(handle.descriptor, temporaryName, 0)
        }
        try restrictAccess(descriptor, mode: mode_t(0o600))
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), raw.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw StorageError.operation("writing file", errno)
                }
                guard count > 0 else { throw StorageError.operation("writing file", EIO) }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw StorageError.operation("syncing file", errno) }
        // Rename replaces the directory entry itself, never a symlink target.
        guard renameat(handle.descriptor, temporaryName, handle.descriptor, name) == 0 else {
            throw StorageError.operation("committing file", errno)
        }
    }

    /// Preflights all leaves before removing any, and never creates a profile.
    public static func removeFiles(named names: [String], in directory: URL) throws {
        guard let handle = try openDirectory(directory, create: false, harden: true) else { return }
        var present: [String] = []
        for name in names {
            if let descriptor = try checkedFile(name, in: handle, harden: true) {
                Darwin.close(descriptor)
                present.append(name)
            }
        }
        for name in present where unlinkat(handle.descriptor, name, 0) != 0 {
            guard errno == ENOENT else { throw StorageError.operation("removing metadata", errno) }
        }
    }

    /// Returns directory entry names without following any entry. Callers must
    /// validate any child directory before reading or writing within it.
    public static func entryNames(in directory: URL) throws -> [String] {
        guard let handle = try openDirectory(directory, create: false, harden: false) else { return [] }
        let duplicate = dup(handle.descriptor)
        guard duplicate >= 0 else { throw StorageError.operation("listing directory", errno) }
        guard let stream = fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw StorageError.operation("listing directory", errno)
        }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw StorageError.operation("listing directory", errno) }
        return result
    }

    /// Installs a prepared profile directory with an exclusive rename, keeping
    /// an existing or concurrently created destination completely unchanged.
    static func installDirectory(_ source: URL, at destination: URL) throws {
        let sourceURL = try normalized(source)
        let destinationURL = try normalized(destination)
        guard sourceURL.deletingLastPathComponent() == destinationURL.deletingLastPathComponent(),
              let parent = try openDirectory(destinationURL.deletingLastPathComponent(), create: false, harden: false),
              try openDirectory(sourceURL, create: false, harden: true) != nil else { throw StorageError.invalidPath }
        try checkedName(sourceURL.lastPathComponent)
        try checkedName(destinationURL.lastPathComponent)
        guard renameatx_np(parent.descriptor, sourceURL.lastPathComponent,
                           parent.descriptor, destinationURL.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw StorageError.operation("installing profile", errno)
        }
    }
}

/// Metadata erasure for normal profiles. Website cookies/cache live in WebKit
/// and must be cleared separately after open windows stop their in-flight work.
public enum ProfilePrivacy {
    private static let names = ["state.json", "state.backup.json", "history.json", "history.backup.json"]

    private static func profileDirectories(in directory: URL) throws -> [URL] {
        guard try SecureProfileStorage.directoryExists(directory) else { return [] }
        var directories = [directory]
        let windows = directory.appendingPathComponent("Windows", isDirectory: true)
        if try SecureProfileStorage.directoryExists(windows) {
            for name in try SecureProfileStorage.entryNames(in: windows) where UUID(uuidString: name) != nil {
                let child = windows.appendingPathComponent(name, isDirectory: true)
                guard try SecureProfileStorage.directoryExists(child) else { continue }
                directories.append(child)
            }
        }
        return directories
    }

    /// Clears history and archives without deleting saved tabs, pins or folders
    /// from closed windows. Every profile is decoded before any content changes.
    /// An unusable primary AND backup fail rather than silently losing pins.
    public static func eraseHistory(in directory: URL) throws {
        let directories = try profileDirectories(in: directory)
        var preserved: [(directory: URL, state: Data?)] = []
        for profile in directories {
            try SecureProfileStorage.validateFiles(named: names, in: profile)
            let primary = try SecureProfileStorage.readData(named: "state.json", in: profile)
            let backup = try SecureProfileStorage.readData(named: "state.backup.json", in: profile)
            let decoded = primary.flatMap { try? JSONDecoder().decode(BrowserState.self, from: $0) }
                ?? backup.flatMap { try? JSONDecoder().decode(BrowserState.self, from: $0) }
            if primary != nil || backup != nil {
                guard var state = decoded else { throw SecureProfileStorage.StorageError.cannotPreserveSession(profile.path) }
                state.archive.removeAll()
                state.repair()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                preserved.append((profile, try encoder.encode(state)))
            } else {
                preserved.append((profile, nil))
            }
        }
        for item in preserved {
            // Write a sanitized primary atomically without backing up the old
            // archive. Keep the original primary if committing the new one fails.
            if let state = item.state {
                try SecureProfileStorage.writeData(state, named: "state.json", in: item.directory)
            }
            try SecureProfileStorage.removeFiles(named: ["state.backup.json", "history.json", "history.backup.json"], in: item.directory)
        }
    }

    public static func eraseSavedSessions(in directory: URL) throws {
        let directories = try profileDirectories(in: directory)
        // If any known metadata entry is unsafe, abort before partial deletion.
        for profile in directories { try SecureProfileStorage.validateFiles(named: names, in: profile) }
        for profile in directories { try SecureProfileStorage.removeFiles(named: names, in: profile) }
    }
}
