import Foundation

/// Watches a folder and reports newly-added files once they are **stable**
/// (size + mtime unchanged across two polls), so files still being copied in are
/// not picked up mid-write. All mutable state is actor-isolated. The handler
/// acknowledges success so failed work is retried rather than silently discarded.
actor WatchFolderService {

    typealias FileHandler = @MainActor @Sendable (URL) async -> Bool

    private var onFile: FileHandler?
    private var pollTask: Task<Void, Never>?
    private var folder: URL?
    private var generation = UUID()
    private var lastSeen: [URL: FileStamp] = [:]
    private var processed: Set<URL> = []

    private struct FileStamp: Equatable, Sendable {
        var size: Int64
        var mtime: TimeInterval
    }

    private static let skippedExtensions: Set<String> = [
        "tmp", "part", "crdownload", "download", "ds_store"
    ]

    func setHandler(_ handler: FileHandler?) {
        onFile = handler
    }

    func start(folder: URL, pollInterval: TimeInterval = 2.0) throws {
        guard pollInterval.isFinite, pollInterval > 0 else {
            throw CocoaError(.validationMissingMandatoryProperty, userInfo: [
                NSLocalizedDescriptionKey: "The watch interval must be greater than zero."
            ])
        }
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        guard values.isDirectory == true, values.isReadable != false else {
            throw CocoaError(.fileReadNoPermission, userInfo: [
                NSFilePathErrorKey: folder.path
            ])
        }

        stop()
        self.folder = folder
        lastSeen.removeAll()
        processed.removeAll()
        try seedExisting(folder)

        let currentGeneration = generation
        pollTask = Task { [weak self] in
            let interval = UInt64((pollInterval * 1_000_000_000).rounded())
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self?.poll(expectedGeneration: currentGeneration)
            }
        }
    }

    func stop() {
        generation = UUID()
        pollTask?.cancel()
        pollTask = nil
        folder = nil
        lastSeen.removeAll()
        processed.removeAll()
    }

    private func seedExisting(_ folder: URL) throws {
        for url in try contents(of: folder) {
            if let stamp = stamp(for: url) {
                lastSeen[url] = stamp
                processed.insert(url)   // ignore pre-existing files; only act on new ones
            }
        }
    }

    private func poll(expectedGeneration: UUID) async {
        guard generation == expectedGeneration, let folder else { return }

        let current: [URL]
        do {
            current = try contents(of: folder)
        } catch {
            return // a transient folder error is retried on the next poll
        }
        let currentSet = Set(current)

        // Drop bookkeeping for files that disappeared. If the same path is created
        // again later, it is a new arrival and must be processed again.
        lastSeen = lastSeen.filter { currentSet.contains($0.key) }
        processed.formIntersection(currentSet)

        for url in current {
            guard generation == expectedGeneration, !Task.isCancelled else { return }
            guard !processed.contains(url), let currentStamp = stamp(for: url) else { continue }

            guard let previous = lastSeen[url], previous == currentStamp else {
                lastSeen[url] = currentStamp
                continue
            }

            // Stable across two polls. Await downstream completion before
            // acknowledging it; failures remain eligible for retry.
            guard let handler = onFile else { continue }
            let succeeded = await handler(url)
            guard generation == expectedGeneration, !Task.isCancelled else { return }
            if succeeded {
                processed.insert(url)
            } else {
                lastSeen[url] = nil
            }
        }
    }

    private func contents(of folder: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        return urls.filter { url in
            let ext = url.pathExtension.lowercased()
            guard !Self.skippedExtensions.contains(ext),
                  FileIngestor.supportedExtensions.contains(ext),
                  !url.deletingPathExtension().lastPathComponent
                    .hasSuffix(JobManager.outputSuffix),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else { return false }
            return true
        }
    }

    private func stamp(for url: URL) -> FileStamp? {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ),
        let size = values.fileSize,
        let mtime = values.contentModificationDate?.timeIntervalSince1970 else {
            return nil
        }
        return FileStamp(size: Int64(size), mtime: mtime)
    }
}
