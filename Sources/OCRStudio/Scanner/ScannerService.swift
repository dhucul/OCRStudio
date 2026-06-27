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

    // Active job state
    private var activeScanner: ICScannerDevice?
    private var pendingOptions: ScanJobOptions?
    private var onPage: ((URL) -> Void)?
    private var onComplete: ((Error?) -> Void)?

    private let downloadsDir: URL

    override init() {
        downloadsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRStudioScans", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

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
        statusMessage = "Looking for scanners…"
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

        self.activeScanner = scanner
        self.pendingOptions = options
        self.onPage = onPage
        self.onComplete = onComplete
        self.isScanning = true

        scanner.delegate = self
        statusMessage = "Opening scanner…"
        scanner.requestOpenSession()
    }

    func cancel() {
        activeScanner?.cancelScan()
    }

    private func finish(_ error: Error?) {
        isScanning = false
        statusMessage = error == nil ? "Scan complete" : "Scan failed: \(error!.localizedDescription)"
        let completion = onComplete
        onPage = nil
        onComplete = nil
        pendingOptions = nil
        activeScanner?.requestCloseSession()
        activeScanner = nil
        completion?(error)
    }

    // MARK: Configuration once the unit is selected

    private func configureAndScan(_ scanner: ICScannerDevice) {
        guard let options = pendingOptions else {
            finish(ScannerError.configuration); return
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
        scanner.downloadsDirectory = downloadsDir
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
    }
}

enum ScannerError: LocalizedError {
    case busy, notFound, configuration, deviceError(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "A scan is already in progress."
        case .notFound: return "The selected scanner is no longer available."
        case .configuration: return "The scanner could not be configured."
        case .deviceError(let m): return m
        }
    }
}

// MARK: - ICDeviceBrowserDelegate

extension ScannerService: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        devicesByID[scanner.uuidString ?? scanner.name ?? UUID().uuidString] = scanner
        rebuildScannerList()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if let scanner = device as? ICScannerDevice, let key = scanner.uuidString {
            devicesByID[key] = nil
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
        if device === activeScanner { finish(ScannerError.notFound) }
    }

    func device(_ device: ICDevice, didEncounterError error: Error?) {
        if device === activeScanner { finish(error ?? ScannerError.deviceError("Unknown error")) }
    }

    // ICDeviceDelegate — optional
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { finish(error) }
        // Otherwise wait for `scannerDeviceDidBecomeAvailable`.
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        // Session closed; nothing further required.
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        // Some devices signal readiness here; the scanner-specific callback below
        // is the authoritative gate, so we wait for it.
    }

    // ICScannerDeviceDelegate
    func scannerDeviceDidBecomeAvailable(_ scanner: ICScannerDevice) {
        guard let options = pendingOptions else { return }

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
        if let error { finish(error); return }
        configureAndScan(scanner)
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        onPage?(url)     // one call per page (e.g. each ADF / duplex side)
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        finish(error)
    }
}
