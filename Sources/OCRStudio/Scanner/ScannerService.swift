import Foundation
import ImageCaptureCore
import UniformTypeIdentifiers
import Combine

/// Options for a scan job.
struct ScanJobOptions {
    enum Source { case flatbed, documentFeeder }

    /// Page size for document feeders (sheet-fed scanners). The feeder captures at
    /// this size; a too-small value clips the page, so we default to full width and
    /// let auto-crop trim any margin.
    enum PageSize: String, CaseIterable, Identifiable {
        case letter, a4, legal
        var id: String { rawValue }
        var label: String {
            switch self {
            case .letter: return "US Letter"
            case .a4: return "A4"
            case .legal: return "US Legal"
            }
        }
        var documentType: ICScannerDocumentType {
            switch self {
            case .letter: return .typeUSLetter
            case .a4: return .typeA4
            case .legal: return .typeUSLegal
            }
        }
    }

    var source: Source = .flatbed
    var pageSize: PageSize = .letter
    var dpi: Int = 300
    var color: Bool = true
    var duplex: Bool = false
}

/// A scanner discovered on the system, surfaced to the UI.
struct ScannerInfo: Identifiable, Hashable {
    let id: String          // ICDevice.uuidString
    let name: String
}

/// Explicit phases keep late callbacks from advancing a cancelled handshake.
struct ScanLifecycle {
    enum Phase { case idle, opening, waiting, selecting, scanning, cancelling, closing }
    private(set) var phase: Phase = .idle
    mutating func start() -> Bool { transition(from: .idle, to: .opening) }
    mutating func opened() -> Bool { transition(from: .opening, to: .waiting) }
    mutating func available() -> Bool { transition(from: .waiting, to: .selecting) }
    mutating func selected() -> Bool { transition(from: .selecting, to: .scanning) }
    mutating func cancel() -> Bool {
        guard phase != .idle, phase != .closing, phase != .cancelling else { return false }
        phase = .cancelling
        return true
    }
    mutating func close() -> Bool {
        guard phase != .idle, phase != .closing else { return false }
        phase = .closing
        return true
    }
    mutating func closed() { phase = .idle }
    private mutating func transition(from: Phase, to: Phase) -> Bool {
        guard phase == from else { return false }
        phase = to
        return true
    }
}

/// Drives Epson (and any ICA-registered) scanners via ImageCaptureCore.
///
/// ImageCaptureCore delivers its delegate callbacks on the main run loop and is
/// not documented thread-safe, so this whole object lives on the main thread and
/// is used only from the main actor. The async scan flow is modeled with simple
/// completion closures rather than continuations to keep the delegate dance clear.
final class ScannerService: NSObject, ObservableObject {

    @Published private(set) var scanners: [ScannerInfo] = []
    @Published private(set) var statusMessage: String = "Idle"
    @Published private(set) var isScanning: Bool = false

    private let browser = ICDeviceBrowser()
    private var devicesByID: [String: ICScannerDevice] = [:]
    private var deviceIDs: [ObjectIdentifier: String] = [:]

    // Active job state
    private var activeScanner: ICScannerDevice?
    private var lifecycle = ScanLifecycle()
    private var completionError: Error?
    private var unclosedScanners: Set<ObjectIdentifier> = []
    private var watchdogID = UUID()
    private var jobDirectory: URL?
    private var pendingOptions: ScanJobOptions?
    private var onPage: ((URL) -> Void)?
    private var onComplete: ((Error?) -> Void)?

    /// Fires if the device stops answering mid-handshake. Every exit from a scan
    /// depends on a delegate callback, and a wedged/disconnected unit simply never
    /// sends one — without this the job never completes and the UI stays busy forever.
    private var watchdog: DispatchWorkItem?

    private let downloadsDir: URL

    static var recoveryDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OCRStudio/RecoveredScans", isDirectory: true)
    }

    override init() {
        downloadsDir = Self.recoveryDirectory
        super.init()

        browser.delegate = self
        browser.browsedDeviceTypeMask = Self.scannerBrowseMask
    }

    /// Browse for scanners in **every** location — locally attached (USB/TB),
    /// network/Bonjour (WiFi Epson units), shared, Bluetooth, and remote.
    /// Restricting to `.local` misses network scanners, which is the common case.
    static var scannerBrowseMask: ICDeviceTypeMask {
        let raw = ICDeviceTypeMask.scanner.rawValue
            | ICDeviceLocationTypeMask.local.rawValue
            | ICDeviceLocationTypeMask.shared.rawValue
            | ICDeviceLocationTypeMask.bonjour.rawValue
            | ICDeviceLocationTypeMask.bluetooth.rawValue
            | ICDeviceLocationTypeMask.remote.rawValue
        return ICDeviceTypeMask(rawValue: raw) ?? .scanner
    }

    // MARK: Discovery

    func startBrowsing() {
        // Never rebuild discovery under a running job — the active device would be
        // dropped from the list while its delegate callbacks are still arriving.
        guard !isScanning else { return }
        statusMessage = "Looking for scanners…"
        // `start()` on an already-running browser is a no-op and re-announces
        // nothing, so a refresh has to tear the discovery state down first —
        // otherwise the button can never recover a stale list.
        browser.stop()
        devicesByID.removeAll()
        deviceIDs.removeAll()
        scanners.removeAll()
        browser.start()
    }

    func stopBrowsing() {
        browser.stop()
    }

    // MARK: Scanning

    /// Begin a scan. `onPage` fires once per scanned page (file URL of a TIFF);
    /// `onComplete` fires once when the whole job finishes (nil error == success).
    func scan(scannerID: String,
              options: ScanJobOptions,
              onPage: @escaping (URL) -> Void,
              onComplete: @escaping (Error?) -> Void) {
        guard !isScanning else { onComplete(ScannerError.busy); return }
        guard let scanner = devicesByID[scannerID] else { onComplete(ScannerError.notFound); return }

        guard !unclosedScanners.contains(ObjectIdentifier(scanner)) else {
            onComplete(ScannerError.deviceError("The previous scanner session has not closed. Reconnect the scanner."))
            return
        }
        guard lifecycle.start() else { onComplete(ScannerError.busy); return }
        jobDirectory = downloadsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.activeScanner = scanner
        self.pendingOptions = options
        self.onPage = onPage
        self.onComplete = onComplete
        self.isScanning = true

        scanner.delegate = self
        statusMessage = "Opening scanner…"
        armWatchdog()
        scanner.requestOpenSession()
    }

    func cancel() {
        guard lifecycle.cancel() else { return }
        statusMessage = "Cancelling…"
        activeScanner?.cancelScan()
        // Don't trust a wedged device to report its own cancellation.
        armWatchdog(Self.cancelTimeout)
    }

    // MARK: Watchdog

    private static let handshakeTimeout: TimeInterval = 120
    private static let cancelTimeout: TimeInterval = 5

    /// (Re)arm the stall timer. Called at the start of a job and again on every
    /// delegate callback that proves the device is still making progress.
    private func armWatchdog(_ seconds: TimeInterval = ScannerService.handshakeTimeout) {
        watchdog?.cancel()
        let id = UUID()
        watchdogID = id
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isScanning, self.watchdogID == id else { return }
            if self.lifecycle.phase == .closing {
                if let scanner = self.activeScanner {
                    self.unclosedScanners.insert(ObjectIdentifier(scanner))
                }
                self.completionError = self.completionError ?? ScannerError.timedOut
                self.complete()
            } else {
                self.finish(self.lifecycle.phase == .cancelling ? CancellationError() : ScannerError.timedOut)
            }
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func finish(_ error: Error?) {
        let cancelled = lifecycle.phase == .cancelling
        guard lifecycle.close() else { return }
        completionError = cancelled ? CancellationError() : error
        pendingOptions = nil
        statusMessage = "Closing scanner…"
        guard let scanner = activeScanner else { complete(); return }
        armWatchdog(Self.cancelTimeout)
        scanner.requestCloseSession()
    }

    /// Keep the job busy until closure is acknowledged or the device is quarantined.
    private func complete() {
        watchdog?.cancel()
        watchdog = nil
        watchdogID = UUID()
        lifecycle.closed()
        isScanning = false
        let error = completionError
        statusMessage = error == nil ? "Scan complete" : "Scan stopped: \(error!.localizedDescription)"
        let completion = onComplete
        onPage = nil
        onComplete = nil
        pendingOptions = nil
        completionError = nil
        activeScanner = nil
        if let directory = jobDirectory,
           (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: directory)
        }
        jobDirectory = nil
        completion?(error)
    }

    // MARK: Configuration once the unit is selected

    private func configureAndScan(_ scanner: ICScannerDevice) {
        guard scanner === activeScanner, lifecycle.phase == .scanning else { return }
        guard let options = pendingOptions else {
            finish(ScannerError.configuration); return
        }
        do {
            try FileManager.default.createDirectory(
                at: jobDirectory ?? downloadsDir, withIntermediateDirectories: true
            )
        } catch {
            finish(error)
            return
        }
        let unit = scanner.selectedFunctionalUnit

        // Resolution — must be one the unit supports.
        let supported = unit.supportedResolutions
        if supported.contains(options.dpi) {
            unit.resolution = options.dpi
        } else if let nearest = supported.min(by: { abs($0 - options.dpi) < abs($1 - options.dpi) }) {
            unit.resolution = nearest
        }

        unit.pixelDataType = options.color ? .RGB : .gray
        unit.bitDepth = .depth8Bits
        unit.measurementUnit = .inches

        if let adf = unit as? ICScannerFunctionalUnitDocumentFeeder {
            // Sheet-fed: the captured size is governed by documentType, NOT scanArea.
            // Left unset it defaults small and clips the page, so pick a full-width
            // size (auto-crop trims any margin afterwards).
            applyDocumentType(options.pageSize.documentType, to: adf)
            adf.duplexScanningEnabled = options.duplex && adf.supportsDuplexScanning
        } else {
            // Flatbed: scan the whole bed.
            unit.scanArea = CGRect(origin: .zero, size: unit.physicalSize)
        }

        scanner.transferMode = .fileBased
        scanner.downloadsDirectory = jobDirectory ?? downloadsDir
        scanner.documentName = "OCRStudioScan"
        scanner.documentUTI = UTType.tiff.identifier

        statusMessage = "Scanning…"
        scanner.requestScan()
    }

    /// Set the feeder's document type to the desired size, falling back through
    /// common full-width sizes to whatever the scanner actually supports.
    private func applyDocumentType(_ desired: ICScannerDocumentType,
                                   to adf: ICScannerFunctionalUnitDocumentFeeder) {
        let supported = adf.supportedDocumentTypes
        for candidate in [desired, .typeUSLegal, .typeUSLetter, .typeA4]
        where supported.contains(Int(candidate.rawValue)) {
            adf.documentType = candidate
            return
        }
        if let fallback = supported.first, fallback >= 0,
           let documentType = ICScannerDocumentType(rawValue: UInt(fallback)) {
            adf.documentType = documentType
        }
    }

    private func stableID(for scanner: ICScannerDevice) -> String {
        let objectID = ObjectIdentifier(scanner)
        if let existing = deviceIDs[objectID] { return existing }
        let id = scanner.uuidString ?? "scanner-\(UUID().uuidString)"
        deviceIDs[objectID] = id
        return id
    }
}

enum ScannerError: LocalizedError {
    case busy, notFound, configuration, timedOut, deviceError(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "A scan is already in progress."
        case .notFound: return "The selected scanner is no longer available."
        case .configuration: return "The scanner could not be configured."
        case .timedOut: return "The scanner stopped responding."
        case .deviceError(let m): return m
        }
    }
}

// MARK: - ICDeviceBrowserDelegate

extension ScannerService: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        devicesByID[stableID(for: scanner)] = scanner
        rebuildScannerList()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if let scanner = device as? ICScannerDevice {
            let objectID = ObjectIdentifier(scanner)
            if let key = deviceIDs.removeValue(forKey: objectID) ?? scanner.uuidString {
                devicesByID[key] = nil
            }
        }
        rebuildScannerList()
    }

    private func rebuildScannerList() {
        scanners = devicesByID.map { (id, dev) in
            ScannerInfo(id: id, name: dev.name ?? "Scanner")
        }
        .sorted { $0.name < $1.name }
        if scanners.isEmpty {
            statusMessage = "No scanners found"
        } else {
            statusMessage = "\(scanners.count) scanner(s) available"
        }
    }
}

// MARK: - ICScannerDeviceDelegate (refines ICDeviceDelegate)

extension ScannerService: ICScannerDeviceDelegate {

    // ICDeviceDelegate — required
    func didRemove(_ device: ICDevice) {
        guard device === activeScanner else { return }
        // The device is already torn down — clear it so `finish` doesn't try to
        // close a session on it.
        activeScanner = nil
        if lifecycle.phase == .closing {
            completionError = completionError ?? ScannerError.notFound
            complete()
        } else { finish(ScannerError.notFound) }
    }

    func device(_ device: ICDevice, didEncounterError error: Error?) {
        guard isScanning, device === activeScanner else { return }
        finish(error ?? ScannerError.deviceError("Unknown error"))
    }

    // ICDeviceDelegate — optional
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard isScanning, device === activeScanner else { return }
        if lifecycle.phase == .cancelling { finish(CancellationError()); return }
        guard lifecycle.phase == .opening else { return }
        if let error { finish(error); return }
        guard lifecycle.opened() else { return }
        armWatchdog()
        // Otherwise wait for `scannerDeviceDidBecomeAvailable`.
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        if error == nil { unclosedScanners.remove(ObjectIdentifier(device)) }
        guard device === activeScanner, lifecycle.phase == .closing else { return }
        if let error {
            unclosedScanners.insert(ObjectIdentifier(device))
            completionError = completionError ?? error
        }
        complete()
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        // Some devices signal readiness here; the scanner-specific callback below
        // is the authoritative gate, so we wait for it.
    }

    // ICScannerDeviceDelegate
    func scannerDeviceDidBecomeAvailable(_ scanner: ICScannerDevice) {
        guard isScanning, scanner === activeScanner else { return }
        guard lifecycle.available(), let options = pendingOptions else { return }
        armWatchdog()   // progress — the device is alive

        let available = scanner.availableFunctionalUnitTypes.compactMap {
            ICScannerFunctionalUnitType(rawValue: $0.uintValue)
        }
        let requested: ICScannerFunctionalUnitType =
            options.source == .documentFeeder ? .documentFeeder : .flatbed
        // Use the requested unit if present, else whatever the scanner actually has
        // (e.g. a feeder-only document scanner has no flatbed).
        let type = available.contains(requested) ? requested : (available.first ?? requested)

        statusMessage = "Preparing scanner…"
        scanner.requestSelect(type)
    }

    func scannerDevice(_ scanner: ICScannerDevice,
                       didSelect functionalUnit: ICScannerFunctionalUnit,
                       error: Error?) {
        guard isScanning, scanner === activeScanner else { return }
        guard lifecycle.phase == .selecting else { return }
        if let error { finish(error); return }
        guard lifecycle.selected() else { return }
        armWatchdog()
        configureAndScan(scanner)
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        guard isScanning, scanner === activeScanner else { return }
        guard lifecycle.phase == .scanning || lifecycle.phase == .cancelling else { return }
        if lifecycle.phase == .scanning { armWatchdog() }
        onPage?(url)     // one call per page (e.g. each ADF / duplex side)
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        guard isScanning, scanner === activeScanner else { return }
        guard lifecycle.phase == .scanning || lifecycle.phase == .cancelling else { return }
        finish(error)
    }
}
