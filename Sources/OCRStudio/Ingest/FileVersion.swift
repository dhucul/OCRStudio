import Foundation

/// Read fresh metadata, bypassing URL resource-value caches. Identity detects
/// atomic replacement even when the replacement has the same size and mtime.
struct FileVersion: Equatable, Sendable {
    let size: UInt64
    let modified: Date
    let created: Date
    let inode: UInt64
    let device: UInt64

    static func read(_ url: URL) throws -> FileVersion {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = a[.size] as? NSNumber,
              let modified = a[.modificationDate] as? Date,
              let created = a[.creationDate] as? Date,
              let inode = a[.systemFileNumber] as? NSNumber,
              let device = a[.systemNumber] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return FileVersion(size: size.uint64Value, modified: modified, created: created,
                           inode: inode.uint64Value, device: device.uint64Value)
    }
}

enum RasterBudget {
    // Original + prepared images retained by a document; transient framework
    // buffers are additional. Multiple foreground imports share this allowance.
    static let maximumBytes = 256 * 1_024 * 1_024
}
