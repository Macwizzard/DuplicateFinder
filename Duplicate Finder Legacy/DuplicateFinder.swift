import Foundation
import CommonCrypto

// MARK: - Data model

final class FileEntry {
    let id = UUID()
    let url: URL
    let size: Int64
    let creationDate: Date?
    let modificationDate: Date?

    init(url: URL, size: Int64, creationDate: Date?, modificationDate: Date?) {
        self.url = url
        self.size = size
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }
}

final class DuplicateGroup {
    let id = UUID()
    var files: [FileEntry]
    var keeperID: UUID
    let hash: String
    let size: Int64

    init(files: [FileEntry], keeperID: UUID, hash: String, size: Int64) {
        self.files = files
        self.keeperID = keeperID
        self.hash = hash
        self.size = size
    }

    var duplicates: [FileEntry] {
        return files.filter { $0.id != keeperID }
    }

    var keeper: FileEntry {
        return files.first { $0.id == keeperID } ?? files[0]
    }
}

enum ScanError: Error, LocalizedError {
    case couldNotEnumerate(URL)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .couldNotEnumerate(let url):
            return "Could not enumerate the contents of \(url.path). Check permissions."
        case .cancelled:
            return "Scan cancelled."
        }
    }
}

// MARK: - Scanner
//
// Pre-async-await design:
// - All scanning runs on `workQueue` (serial background queue).
// - Progress and completion callbacks are dispatched to the main queue
//   before being invoked, so the UI layer doesn't have to think about it.
// - Cancellation is a flag protected by `lock`, polled inside the work loop.

final class DuplicateScanner {

    // Tunables
    private static let sampleSize: Int = 64 * 1024            // head/tail sample
    private static let smallFileThreshold: Int64 = 256 * 1024 // skip tiers below this
    private static let fullHashChunk: Int = 256 * 1024        // streaming chunk

    private let workQueue = DispatchQueue(label: "DuplicateScanner.work", qos: .userInitiated)
    private let lock = NSLock()
    private var _cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    /// Begin a scan. Callbacks fire on the main queue.
    func scan(
        directory: URL,
        progress: @escaping (String, Double) -> Void,
        completion: @escaping (Result<[DuplicateGroup], Error>) -> Void
    ) {
        lock.lock(); _cancelled = false; lock.unlock()

        workQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.runScan(directory: directory) { msg, p in
                    DispatchQueue.main.async { progress(msg, p) }
                }
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Core scan

    private func runScan(
        directory: URL,
        progress: (String, Double) -> Void
    ) throws -> [DuplicateGroup] {

        progress("Enumerating files…", 0.0)
        let filesBySize = try enumerateFiles(at: directory, progress: progress)

        let sizeCandidates = filesBySize.filter { $0.value.count > 1 }
        guard !sizeCandidates.isEmpty else { return [] }

        var byFullHash: [String: [FileEntry]] = [:]
        let totalFiles = sizeCandidates.values.reduce(0) { $0 + $1.count }
        var examined = 0

        for (size, files) in sizeCandidates {
            try checkCancelled()

            let survivors: [(FileEntry, String)]
            if size < DuplicateScanner.smallFileThreshold {
                survivors = hashAll(files, examinedSoFar: &examined,
                                    total: totalFiles, progress: progress)
            } else {
                survivors = try tieredHash(files: files,
                                           examinedSoFar: &examined,
                                           total: totalFiles,
                                           progress: progress)
            }

            for (file, hash) in survivors {
                if byFullHash[hash] == nil { byFullHash[hash] = [] }
                byFullHash[hash]!.append(file)
            }
        }

        var result: [DuplicateGroup] = []
        for (hash, files) in byFullHash where files.count > 1 {
            let sorted = files.sorted { a, b in
                (a.creationDate ?? .distantFuture) < (b.creationDate ?? .distantFuture)
            }
            result.append(DuplicateGroup(
                files: sorted,
                keeperID: sorted[0].id,
                hash: hash,
                size: sorted[0].size
            ))
        }
        return result
    }

    // MARK: - Tiered hashing

    private enum HashTier { case head, tail, full }

    private func tieredHash(
        files: [FileEntry],
        examinedSoFar examined: inout Int,
        total: Int,
        progress: (String, Double) -> Void
    ) throws -> [(FileEntry, String)] {

        // Tier 1: head
        var byHead: [String: [FileEntry]] = [:]
        for file in files {
            try checkCancelled()
            examined += 1
            progress("Sampling head of \(file.url.lastPathComponent)…",
                     Double(examined) / Double(total))
            if let h = try? partialHash(at: file.url, tier: .head, fileSize: file.size) {
                if byHead[h] == nil { byHead[h] = [] }
                byHead[h]!.append(file)
            }
        }
        let afterHead = byHead.values.filter { $0.count > 1 }.flatMap { $0 }

        // Tier 2: tail
        var byTail: [String: [FileEntry]] = [:]
        for file in afterHead {
            try checkCancelled()
            progress("Sampling tail of \(file.url.lastPathComponent)…",
                     Double(examined) / Double(total))
            if let h = try? partialHash(at: file.url, tier: .tail, fileSize: file.size) {
                if byTail[h] == nil { byTail[h] = [] }
                byTail[h]!.append(file)
            }
        }
        let afterTail = byTail.values.filter { $0.count > 1 }.flatMap { $0 }

        // Tier 3: full
        var results: [(FileEntry, String)] = []
        for file in afterTail {
            try checkCancelled()
            progress("Hashing \(file.url.lastPathComponent) (\(formatSize(file.size)))…",
                     Double(examined) / Double(total))
            if let h = try? fullHash(at: file.url) {
                results.append((file, h))
            }
        }
        return results
    }

    private func hashAll(
        _ files: [FileEntry],
        examinedSoFar examined: inout Int,
        total: Int,
        progress: (String, Double) -> Void
    ) -> [(FileEntry, String)] {
        var results: [(FileEntry, String)] = []
        for file in files {
            examined += 1
            progress("Hashing \(file.url.lastPathComponent)…",
                     Double(examined) / Double(total))
            if let h = try? fullHash(at: file.url) {
                results.append((file, h))
            }
        }
        return results
    }

    // MARK: - Hash primitives (CommonCrypto SHA-256)
    //
    // We use POSIX file descriptors (open/read/close) because:
    //   1. They give precise control over chunked reads with no autorelease drama
    //   2. They work identically on 10.14 and don't depend on FileHandle's
    //      Swift 5.5+ throwing API which isn't available there.

    private func partialHash(at url: URL, tier: HashTier, fileSize: Int64) throws -> String {
        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)

        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }

        var buffer = [UInt8](repeating: 0, count: DuplicateScanner.sampleSize)

        switch tier {
        case .head:
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                CC_SHA256_Update(&ctx, buffer, CC_LONG(n))
            }
        case .tail:
            let offset = max(0, fileSize - Int64(DuplicateScanner.sampleSize))
            if lseek(fd, off_t(offset), SEEK_SET) < 0 {
                throw POSIXError(.EIO)
            }
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                CC_SHA256_Update(&ctx, buffer, CC_LONG(n))
            }
        case .full:
            return try fullHash(at: url)
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &ctx)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fullHash(at url: URL) throws -> String {
        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)

        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }

        var buffer = [UInt8](repeating: 0, count: DuplicateScanner.fullHashChunk)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            CC_SHA256_Update(&ctx, buffer, CC_LONG(n))
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &ctx)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Enumeration

    private func enumerateFiles(
        at directory: URL,
        progress: (String, Double) -> Void
    ) throws -> [Int64: [FileEntry]] {
        let keys: [URLResourceKey] = [
            .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
            .creationDateKey, .contentModificationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ScanError.couldNotEnumerate(directory)
        }

        var filesBySize: [Int64: [FileEntry]] = [:]
        var count = 0

        for case let fileURL as URL in enumerator {
            if isCancelled { throw ScanError.cancelled }
            count += 1
            if count % 250 == 0 {
                progress("Enumerating… \(count) files found", 0.0)
            }

            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size > 0 else {
                continue
            }

            let entry = FileEntry(
                url: fileURL,
                size: Int64(size),
                creationDate: values.creationDate,
                modificationDate: values.contentModificationDate
            )
            if filesBySize[Int64(size)] == nil { filesBySize[Int64(size)] = [] }
            filesBySize[Int64(size)]!.append(entry)
        }
        return filesBySize
    }

    // MARK: - Helpers

    private func checkCancelled() throws {
        if isCancelled { throw ScanError.cancelled }
    }

    private func formatSize(_ bytes: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
