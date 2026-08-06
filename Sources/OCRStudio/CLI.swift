import Foundation
import ImageCaptureCore

/// Headless mode for scripting and verification. Runs the same ingest → OCR →
/// searchable-PDF pipeline as the GUI, with no window or scanner required:
///
///   OCRStudio --ocr <file...> [--out <output.pdf>]
///   OCRStudio --list-scanners        # diagnostic: what ICA can actually see
enum HeadlessCLI {

    private enum CLIError: LocalizedError {
        case noPages
        case outputMatchesInput(URL)

        var errorDescription: String? {
            switch self {
            case .noPages:
                return "No readable pages were produced."
            case .outputMatchesInput(let url):
                return "Output would overwrite input: \(url.path)"
            }
        }
    }

    private final class ExitCodeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Int32 = EXIT_FAILURE

        func set(_ value: Int32) {
            lock.lock()
            storage = value
            lock.unlock()
        }

        func get() -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// Returns an exit status when headless mode was requested, otherwise nil.
    static func runIfRequested() -> Int32? {
        let args = CommandLine.arguments

        if args.contains("--list-scanners") {
            ScannerLister.run()
            return EXIT_SUCCESS
        }

        if args.contains("--scanner-info") {
            ScannerInspector.run()
            return EXIT_SUCCESS
        }

        if let i = args.firstIndex(of: "--ink") {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                return usage("usage: OCRStudio --ink <file>")
            }
            let url = URL(fileURLWithPath: args[i + 1])
            return waitForAsync {
                do {
                    let jobs = JobManager()
                    let pages = try await jobs.process(
                        url: url, settings: Settings(), cropToContent: false
                    )
                    guard !pages.isEmpty else { throw CLIError.noPages }
                    for page in pages {
                        let blank = await jobs.isBlankPage(page)
                        print("\(url.lastPathComponent): blank=\(blank)  "
                              + "lines=\(page.ocr.lines.count)")
                    }
                    return EXIT_SUCCESS
                } catch {
                    writeError("✗ \(error.localizedDescription)")
                    return EXIT_FAILURE
                }
            }
        }

        if let i = args.firstIndex(of: "--make-docx") {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                return usage("usage: OCRStudio --make-docx <output.docx>")
            }
            let destination = URL(fileURLWithPath: args[i + 1])
            do {
                let sample = ["Linux_Commands", "systemctl --master-disable",
                              "This opening paragraph ends like a sentence."]
                let data = try RichTextExport.wordData(from: [sample.joined(separator: "\n")])
                try data.write(to: destination, options: .atomic)
                print("wrote \(destination.path) (\(data.count) bytes)")
                return EXIT_SUCCESS
            } catch {
                writeError("✗ Failed to write DOCX: \(error.localizedDescription)")
                return EXIT_FAILURE
            }
        }

        guard let start = args.firstIndex(of: "--ocr") else { return nil }

        var inputs: [URL] = []
        var output: URL?
        var crop = false
        var index = start + 1
        while index < args.count {
            switch args[index] {
            case "--out":
                guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                    return usage("usage: OCRStudio --ocr <file...> [--out <output.pdf>] [--crop]")
                }
                output = URL(fileURLWithPath: args[index + 1])
                index += 2
            case "--crop":
                crop = true
                index += 1
            default:
                guard !args[index].hasPrefix("--") else {
                    return usage("unknown option: \(args[index])")
                }
                inputs.append(URL(fileURLWithPath: args[index]))
                index += 1
            }
        }

        guard !inputs.isEmpty else {
            return usage("usage: OCRStudio --ocr <file...> [--out <output.pdf>] [--crop]")
        }

        let destination = output ?? inputs[0].deletingPathExtension()
            .appendingPathExtension("ocr.pdf")
        let parsedInputs = inputs
        let shouldCrop = crop
        return waitForAsync {
            await run(inputs: parsedInputs, output: destination, cropToContent: shouldCrop)
        }
    }

    private static func waitForAsync(
        _ operation: @escaping @Sendable () async -> Int32
    ) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ExitCodeBox()
        Task.detached {
            result.set(await operation())
            semaphore.signal()
        }
        // Never park the main thread outright: `main.swift` is Swift 6 top-level
        // code and therefore @MainActor, so a bare `wait()` deadlocks anything
        // downstream that needs to hop back to the main actor.
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return result.get()
    }

    /// Pump the main run loop briefly so in-flight ImageCaptureCore requests
    /// (notably `requestCloseSession`) reach the device before `exit()`.
    fileprivate static func drainRunLoop(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
    }

    private static func run(inputs: [URL],
                            output: URL,
                            cropToContent: Bool) async -> Int32 {
        let normalizedOutput = output.standardizedFileURL
        if inputs.map(\.standardizedFileURL).contains(normalizedOutput) {
            writeError("✗ \(CLIError.outputMatchesInput(output).localizedDescription)")
            return EXIT_FAILURE
        }

        do {
            let jobs = JobManager()
            let settings = Settings.load()
            var pages: [ProcessedPage] = []
            var failed = 0
            for input in inputs {
                // Keep what succeeded — one unreadable file shouldn't discard the
                // pages already recognized from the rest of the batch.
                do {
                    let produced = try await jobs.process(
                        url: input, settings: settings, cropToContent: cropToContent
                    )
                    pages.append(contentsOf: produced)
                    print("• \(input.lastPathComponent): \(produced.count) page(s)"
                          + (cropToContent ? " [crop]" : ""))
                } catch {
                    failed += 1
                    writeError("• \(input.lastPathComponent): skipped — "
                               + error.localizedDescription)
                }
            }
            guard !pages.isEmpty else { throw CLIError.noPages }

            try await jobs.writeSearchablePDF(pages, to: output)
            print("✓ Searchable PDF → \(output.path)")

            let text = Exporters.plainText(pages.map(\.ocr))
            let textURL = output.deletingPathExtension().appendingPathExtension("txt")
            try text.write(to: textURL, atomically: true, encoding: .utf8)
            print("✓ Text → \(textURL.path)")

            let json = try Exporters.json(pages.map(\.ocr))
            let jsonURL = output.deletingPathExtension().appendingPathExtension("json")
            try json.write(to: jsonURL, options: .atomic)
            print("✓ JSON → \(jsonURL.path)")

            let preview = text.prefix(500)
            print("\n----- recognized text (first 500 chars) -----\n\(preview)\n----------------------------------------------")
            // Partial success is still a failure for scripting purposes.
            return failed == 0 ? EXIT_SUCCESS : EXIT_FAILURE
        } catch {
            writeError("✗ Failed: \(error.localizedDescription)")
            return EXIT_FAILURE
        }
    }

    private static func usage(_ message: String) -> Int32 {
        writeError(message)
        return 64 // EX_USAGE
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Standalone scanner-discovery diagnostic. Browses every location for ~8s and
/// prints each device ICA reports, with its transport/location, so we can tell
/// whether a scanner is visible at all and whether it's USB vs network.
final class ScannerLister: NSObject, ICDeviceBrowserDelegate {
    private var count = 0
    private let browser = ICDeviceBrowser()

    static func run() {
        let lister = ScannerLister()
        lister.browser.delegate = lister
        lister.browser.browsedDeviceTypeMask = ScannerService.scannerBrowseMask
        print("Browsing for scanners (all locations) for 8 seconds…\n")
        lister.browser.start()

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
        }
        lister.browser.stop()
        HeadlessCLI.drainRunLoop(1)
        print("\nDone — \(lister.count) scanner(s) found.")
        if lister.count == 0 {
            print("""

            No scanners reported by ImageCaptureCore. Checklist:
              • Is the scanner powered on and on the same Wi-Fi/network (or USB-connected)?
              • Does Apple's "Image Capture" app (in /Applications) see it? If not, it's a
                system/driver/network issue, not this app.
              • For network Epson units, confirm the connection in "Epson Scan 2".
              • macOS may need scanner permission for this app (System Settings ▸ Privacy).
            """)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        count += 1
        print("• \(device.name ?? "(unnamed)")")
        print("    transport: \(device.transportType ?? "unknown")")
        print("    uuid:      \(device.uuidString ?? "—")")
        print("    isScanner: \(device is ICScannerDevice)")
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
}

/// Opens the first scanner, selects the flatbed, and prints its geometry
/// (physical size, default scan area, supported resolutions) so we can see why
/// scans come out clipped/wrong-sized. Times out so it never hangs.
final class ScannerInspector: NSObject, ICDeviceBrowserDelegate, ICScannerDeviceDelegate {
    private let browser = ICDeviceBrowser()
    private var scanner: ICScannerDevice?
    private var done = false

    static func run() {
        let insp = ScannerInspector()
        insp.browser.delegate = insp
        insp.browser.browsedDeviceTypeMask = ScannerService.scannerBrowseMask
        print("Looking for a scanner (15s)…")
        insp.browser.start()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && !insp.done {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        if !insp.done { print("Timed out — no scanner, or a session couldn't be opened from the CLI.") }
        insp.scanner?.requestCloseSession()
        insp.browser.stop()
        // Let the close-session request actually reach the device — otherwise the
        // process exits first and the scanner reports "busy" on the next run.
        HeadlessCLI.drainRunLoop(2)
    }

    func deviceBrowser(_ b: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard scanner == nil, let s = device as? ICScannerDevice else { return }
        scanner = s
        print("Found: \(s.name ?? "?")  transport: \(s.transportType ?? "?")")
        s.delegate = self
        s.requestOpenSession()
    }
    func deviceBrowser(_ b: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
    func didRemove(_ device: ICDevice) {}
    func device(_ device: ICDevice, didEncounterError error: Error?) {
        print("device error: \(error?.localizedDescription ?? "?")")
        scanner?.requestCloseSession()
        done = true
    }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { print("open-session error: \(error.localizedDescription)"); done = true }
        else { print("session opened; waiting for available…") }
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    func scannerDeviceDidBecomeAvailable(_ s: ICScannerDevice) {
        let types = s.availableFunctionalUnitTypes.map { $0.intValue }
        print("available functional unit types: \(types)  (0=flatbed, 3=feeder)")
        // Select whatever the device actually has (this one is feeder-only).
        let t = ICScannerFunctionalUnitType(rawValue: types.first.map(UInt.init) ?? 0) ?? .flatbed
        s.requestSelect(t)
    }
    func scannerDevice(_ s: ICScannerDevice, didSelect unit: ICScannerFunctionalUnit, error: Error?) {
        if let error {
            print("select error: \(error.localizedDescription)")
            s.requestCloseSession()
            done = true
            return
        }
        unit.measurementUnit = .inches
        print("--- unit geometry ---")
        print("unit.type:              \(unit.type.rawValue)")
        print("physicalSize (inches):  \(unit.physicalSize)")

        if let adf = unit as? ICScannerFunctionalUnitDocumentFeeder {
            print("documentType (before): \(adf.documentType.rawValue)")
            print("documentSize (before): \(adf.documentSize.width) x \(adf.documentSize.height) in")
            let supported = adf.supportedDocumentTypes
            print("USLetter supported: \(supported.contains(Int(ICScannerDocumentType.typeUSLetter.rawValue)))  "
                  + "A4: \(supported.contains(Int(ICScannerDocumentType.typeA4.rawValue)))  "
                  + "Legal: \(supported.contains(Int(ICScannerDocumentType.typeUSLegal.rawValue)))")
            adf.documentType = .typeUSLetter
            print("documentType (after):  \(adf.documentType.rawValue)  (3 = USLetter)")
            print("documentSize (after):  \(adf.documentSize.width) x \(adf.documentSize.height) in  <-- should be ~8.5 x 11")
        } else {
            print("scanArea (default):     \(unit.scanArea)")
        }
        s.requestCloseSession()
        done = true
    }
}
