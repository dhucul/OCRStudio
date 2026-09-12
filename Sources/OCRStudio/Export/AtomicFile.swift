import Foundation
import Darwin

/// Publish only complete files. A cancelled/failed producer never replaces an
/// existing destination. The temporary file is on the same volume as the target.
enum AtomicFile {
    static func write(to destination: URL, produce: (URL) throws -> Void) throws {
        try Task.checkCancellation()
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".ocrstudio-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try produce(temporary)
        try Task.checkCancellation()
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func write(_ data: Data, to destination: URL) throws {
        try write(to: destination) { try data.write(to: $0) }
    }
}

/// Await CPU work off the main actor while forwarding parent cancellation.
func cancellableWork<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
    try Task.checkCancellation()
    let worker = Task.detached { try Task.checkCancellation(); return try operation() }
    return try await withTaskCancellationHandler {
        let result = try await worker.value
        try Task.checkCancellation()
        return result
    } onCancel: {
        worker.cancel()
    }
}
