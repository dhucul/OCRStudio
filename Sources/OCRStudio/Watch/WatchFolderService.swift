import Foundation

/// Watches a folder and reports newly-added files once they are **stable**
/// (size + mtime unchanged across two polls), so files still being copied in are
/// not picked up mid-write. Uses periodic polling on a background queue — simple
/// and robust; a processed-set makes it idempotent across restarts within a run.
final class WatchFolderService {

    var onFile: ((URL) -> Void)?

    private let queue = DispatchQueue(label: "ocrstudio.watchfolder")
    private var timer: DispatchSourceTimer?
    private var folder: URL?
    private var lastSeen: [URL: FileStamp] = [:]
    private var processed: Set<URL> = []

    private struct FileStamp: Equatable {
        var size: Int64
        var mtime: TimeInterval
    }

    private static let skippedExtensions: Set<String> = [
        "tmp", "part", "crdownload", "download", "ds_store"
    ]

    func start(folder: URL, pollInterval: TimeInterval = 2.0) {
        stop()
        self.folder = folder
        // Treat everything already present as "seen" so we only act on new arrivals.
        lastSeen.removeAll()
        processed.removeAll()
        seedExisting(folder)

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        folder = nil
    }

    private func seedExisting(_ folder: URL) {
        for url in contents(of: folder) {
            if let stamp = stamp(for: url) {
                lastSeen[url] = stamp
                processed.insert(url)   // ignore pre-existing files; only act on new ones
            }
        }
    }

    private func poll() {
        guard let folder else { return }
        let current = contents(of: folder)
        let currentSet = Set(current)

        // Drop bookkeeping for files that disappeared.
        lastSeen = lastSeen.filter { currentSet.contains($0.key) }

        for url in current {
            guard !processed.contains(url), let stamp = stamp(for: url) else { continue }
            if let previous = lastSeen[url], previous == stamp {
                // Stable across two polls → ready to process.
                processed.insert(url)
                let handler = onFile
                DispatchQueue.main.async { handler?(url) }
            } else {
                lastSeen[url] = stamp
            }
        }
    }

    private func contents(of folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls.filter { url in
            let ext = url.pathExtension.lowercased()
            guard !Self.skippedExtensions.contains(ext) else { return false }
            guard FileIngestor.supportedExtensions.contains(ext) else { return false }
            // Never re-ingest our own generated outputs, or it cascades (-ocr-ocr.pdf…).
            guard !url.deletingPathExtension().lastPathComponent.hasSuffix(JobManager.outputSuffix)
            else { return false }
            return true
        }
    }

    private func stamp(for url: URL) -> FileStamp? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let mtime = values.contentModificationDate?.timeIntervalSince1970 else { return nil }
        return FileStamp(size: Int64(size), mtime: mtime)
    }
}
