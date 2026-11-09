import Foundation
import CryptoKit

// MARK: - Data model

struct FileEntry: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let size: Int64
    let creationDate: Date?
    let modificationDate: Date?
}

struct DuplicateGroup: Identifiable {
    let id = UUID()
    var files: [FileEntry]          // all byte-identical files; at least 2
    var keeperID: UUID              // which file in `files` is the "original" to keep
    let hash: String
    let size: Int64                 // size of each file in bytes

    /// How many files here are eligible for trashing. O(1): exactly one file in
    /// `files` is the keeper, so this never needs to build `duplicates`.
    /// Use this instead of `duplicates.count` anywhere a view can re-evaluate.
    var duplicateCount: Int { files.count - 1 }

    /// Bytes reclaimable from this group. Every file in the group is the same
    /// size, so this is independent of which one is the keeper — safe as a sort key.
    var reclaimableBytes: Int64 { size * Int64(duplicateCount) }

    /// Everything in `files` that isn't the keeper — these are eligible for trashing.
    var duplicates: [FileEntry] {
        files.filter { $0.id != keeperID }
    }

    /// The currently designated original.
    var keeper: FileEntry {
        files.first { $0.id == keeperID } ?? files[0]
    }
}

enum ScanError: LocalizedError {
    case couldNotEnumerate(URL)

    var errorDescription: String? {
        switch self {
        case .couldNotEnumerate(let url):
            return "Could not enumerate the contents of \(url.path). Check permissions."
        }
    }
}

// MARK: - Scanner

/// Cancellation has to be settable from outside the actor's executor.
/// `scan` holds the actor for long stretches, so an actor-isolated `cancel()`
/// would simply queue behind the scan it was meant to stop and not be
/// delivered until that scan had already finished.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}

actor DuplicateScanner {

    /// Size of the head/tail samples used to eliminate non-matching files cheaply.
    private static let sampleSize: Int64 = 64 * 1024

    /// Below this size, skip the head/tail tiers — just full-hash.
    private static let smallFileThreshold: Int64 = sampleSize * 4  // 256 KiB

    /// Hashing is CPU-bound, so cap the work in flight at the core count rather
    /// than fanning out one task per candidate file.
    private static let concurrencyLimit =
        max(2, ProcessInfo.processInfo.activeProcessorCount)

    /// Minimum gap between progress callbacks. Each callback hops to the main
    /// actor and mutates view state, so reporting once per file floods the run
    /// loop on a large scan and starves the UI.
    private static let progressInterval: CFAbsoluteTime = 0.1

    /// How the progress bar is split across the three tiers. Tier 3 reads whole
    /// files, so it carries most of the weight.
    private static let tierWeights = (head: 0.25, tail: 0.15, full: 0.60)

    private let cancelFlag = CancelFlag()
    private var lastProgressTime: CFAbsoluteTime = 0

    /// Stop the in-flight scan. Deliberately `nonisolated` so it takes effect
    /// immediately rather than waiting for `scan` to return — see `CancelFlag`.
    nonisolated func cancel() {
        cancelFlag.set(true)
    }

    /// Scan `directory` recursively and return groups of byte-identical files.
    ///
    /// Tiered detection:
    ///   1. Group by size (free, from directory enumeration).
    ///   2. For size-collisions on large files: group by head-hash (first 64 KB).
    ///   3. Then by tail-hash (last 64 KB).
    ///   4. Only then do a full SHA-256 on the survivors.
    ///
    /// Each tier runs across *every* size-group at once rather than one group at
    /// a time. Processing per-group would cap parallelism at the size of the
    /// group — typically a handful of files — and impose a barrier per group.
    func scan(
        directory: URL,
        progress: @Sendable @escaping (String, Double) -> Void
    ) async throws -> [DuplicateGroup] {
        cancelFlag.set(false)
        lastProgressTime = 0

        // 1. Enumerate files, grouping by size
        report(0.0, to: progress, force: true) { "Enumerating files…" }
        let filesBySize = try enumerateFiles(at: directory, progress: progress)

        // Only sizes with 2+ files can possibly contain duplicates
        let sizeCandidates = filesBySize.filter { $0.value.count > 1 }
        guard !sizeCandidates.isEmpty else { return [] }

        // Small files are cheaper to hash outright than to triage, so they skip
        // straight to tier 3.
        var needFullHash: [FileEntry] = []
        var large: [FileEntry] = []
        for (size, files) in sizeCandidates {
            if size < Self.smallFileThreshold {
                needFullHash.append(contentsOf: files)
            } else {
                large.append(contentsOf: files)
            }
        }

        let w = Self.tierWeights

        if !large.isEmpty {
            // Tier 1: head sample.
            let heads = try await mapConcurrently(
                large, base: 0, share: w.head, progress: progress,
                label: { "Sampling head of \($0.url.lastPathComponent)…" },
                hash: { try? Self.partialHash(at: $0.url, tier: .head, fileSize: $0.size) })
            let afterHead = collisions(in: heads)

            // Tier 2: tail sample on whatever still matches.
            let tails = try await mapConcurrently(
                afterHead, base: w.head, share: w.tail, progress: progress,
                label: { "Sampling tail of \($0.url.lastPathComponent)…" },
                hash: { try? Self.partialHash(at: $0.url, tier: .tail, fileSize: $0.size) })
            needFullHash.append(contentsOf: collisions(in: tails))
        }

        // Tier 3: full SHA-256 on the survivors. If there was no triage phase
        // the bar should still start at zero.
        let triageWeight = large.isEmpty ? 0.0 : w.head + w.tail
        let hashed = try await mapConcurrently(
            needFullHash, base: triageWeight, share: 1.0 - triageWeight, progress: progress,
            label: { "Hashing \($0.url.lastPathComponent) (\(Self.formatSize($0.size)))…" },
            hash: { try? Self.fullHash(at: $0.url) })

        var byFullHash: [String: [FileEntry]] = [:]
        for (file, hash) in hashed {
            byFullHash[hash, default: []].append(file)
        }

        // 3. Build duplicate groups. Default keeper = oldest creation date.
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

    // MARK: - Parallel tier driver

    /// Run `hash` over `files` across up to `concurrencyLimit` tasks at once,
    /// reporting into the `base ..< base + share` slice of the progress bar.
    ///
    /// The hash primitives are `static` and touch no actor state, so the child
    /// tasks run on the cooperative pool in parallel; only the bookkeeping comes
    /// back to the actor.
    private func mapConcurrently(
        _ files: [FileEntry],
        base: Double,
        share: Double,
        progress: @Sendable (String, Double) -> Void,
        label: @escaping @Sendable (FileEntry) -> String,
        hash: @escaping @Sendable (FileEntry) -> String?
    ) async throws -> [(FileEntry, String)] {
        guard !files.isEmpty else { return [] }

        var results: [(FileEntry, String)] = []
        results.reserveCapacity(files.count)
        var completed = 0

        try await withThrowingTaskGroup(of: (FileEntry, String?).self) { group in
            var next = 0

            func enqueue(_ file: FileEntry) {
                group.addTask {
                    // Cancellation is cooperative, so a queued child still runs;
                    // bail out cheaply instead of reading the file.
                    if Task.isCancelled { return (file, nil) }
                    return (file, hash(file))
                }
            }

            while next < min(Self.concurrencyLimit, files.count) {
                enqueue(files[next])
                next += 1
            }

            while let (file, digest) = try await group.next() {
                completed += 1
                if let digest { results.append((file, digest)) }
                report(base + share * Double(completed) / Double(files.count),
                       to: progress) { label(file) }
                try checkCancelled()
                if next < files.count {
                    enqueue(files[next])
                    next += 1
                }
            }
        }
        return results
    }

    /// Keep only the files whose (size, partial-hash) key is shared with at
    /// least one other file; the rest cannot have a duplicate.
    ///
    /// Size is part of the key because the tiers now run across every size-group
    /// at once, so a matching head or tail sample alone no longer implies the
    /// two files are the same length.
    private func collisions(in hashed: [(FileEntry, String)]) -> [FileEntry] {
        var buckets: [String: [FileEntry]] = [:]
        for (file, hash) in hashed {
            buckets["\(file.size):\(hash)", default: []].append(file)
        }
        return buckets.values.filter { $0.count > 1 }.flatMap { $0 }
    }

    // MARK: - Hash primitives

    private enum HashTier {
        case head, tail, full
    }

    /// Hash the first or last `sampleSize` bytes of a file.
    /// Wrapped in autoreleasepool to release the Data buffer promptly.
    private static func partialHash(at url: URL, tier: HashTier, fileSize: Int64) throws -> String {
        try autoreleasepool {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var hasher = SHA256()
            let sample = sampleSize

            switch tier {
            case .head:
                if let data = try handle.read(upToCount: Int(sample)) {
                    hasher.update(data: data)
                }
            case .tail:
                let offset = max(0, fileSize - sample)
                try handle.seek(toOffset: UInt64(offset))
                if let data = try handle.read(upToCount: Int(sample)) {
                    hasher.update(data: data)
                }
            case .full:
                return try fullHash(at: url)
            }

            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Hash the entire file in 256 KiB chunks.
    /// Each chunk is wrapped in its own autoreleasepool so the backing memory
    /// is freed every iteration instead of accumulating until the function exits.
    /// Critical for very large files on low-RAM systems.
    private static func fullHash(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunk = 256 * 1024  // 256 KiB

        while true {
            let done: Bool = try autoreleasepool {
                guard let data = try handle.read(upToCount: chunk), !data.isEmpty else {
                    return true  // EOF
                }
                hasher.update(data: data)
                return false
            }
            if done { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Enumeration

    private func enumerateFiles(
        at directory: URL,
        progress: @Sendable (String, Double) -> Void
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
            // Enumeration can run for minutes on a large tree, so honour both
            // the explicit flag and task cancellation here, not just the flag.
            try checkCancelled()
            count += 1
            if count % 250 == 0 {
                report(0.0, to: progress) { "Enumerating… \(count) files found" }
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
            filesBySize[Int64(size), default: []].append(entry)
        }
        return filesBySize
    }

    // MARK: - Helpers

    /// Forward a progress update, but no more often than `progressInterval`.
    /// `message` is a closure so the (per-file) string interpolation is skipped
    /// entirely on the calls we throttle away.
    private func report(
        _ fraction: Double,
        to progress: @Sendable (String, Double) -> Void,
        force: Bool = false,
        message: () -> String
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        guard force || now - lastProgressTime >= Self.progressInterval else { return }
        lastProgressTime = now
        progress(message(), fraction)
    }

    private func checkCancelled() throws {
        if cancelFlag.isSet { throw CancellationError() }
        try Task.checkCancellation()
    }

    private static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
