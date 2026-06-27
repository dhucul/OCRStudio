import Foundation
import ImageCaptureCore

/// Headless mode for scripting and verification. Runs the same ingest → OCR →
/// searchable-PDF pipeline as the GUI, with no window or scanner required:
///
///   OCRStudio --ocr <file...> [--out <output.pdf>]
///   OCRStudio --list-scanners        # diagnostic: what ICA can actually see
enum HeadlessCLI {

    /// Returns true if the app was launched in headless mode (and has now finished).
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments

        if args.contains("--list-scanners") {
            ScannerLister.run()
            return true
        }

        guard let start = args.firstIndex(of: "--ocr") else { return false }

        var inputs: [URL] = []
        var output: URL?
        var i = start + 1
        while i < args.count {
            if args[i] == "--out", i + 1 < args.count {
                output = URL(fileURLWithPath: args[i + 1]); i += 2; continue
            }
            if args[i] == "--crop" { i += 1; continue }   // handled separately
            inputs.append(URL(fileURLWithPath: args[i])); i += 1
        }

        guard !inputs.isEmpty else {
            FileHandle.standardError.write(Data(
                "usage: OCRStudio --ocr <file...> [--out <output.pdf>]\n".utf8))
            return true
        }

        let out = output ?? inputs[0].deletingPathExtension()
            .appendingPathExtension("ocr.pdf")
        let crop = args.contains("--crop")   // emulate scanned-page content crop

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await run(inputs: inputs, output: out, cropToContent: crop)
            semaphore.signal()
        }
        semaphore.wait()
        return true
    }

    private static func run(inputs: [URL], output: URL, cropToContent: Bool) async {
        let jobs = JobManager()
        let settings = Settings.load()

        var pages: [ProcessedPage] = []
        for input in inputs {
            let produced = await jobs.process(url: input, settings: settings,
                                              cropToContent: cropToContent)
            pages.append(contentsOf: produced)
            print("• \(input.lastPathComponent): \(produced.count) page(s)"
                  + (cropToContent ? " [crop]" : ""))
        }
        guard !pages.isEmpty else { print("No pages produced."); return }

        do {
            try await jobs.writeSearchablePDF(pages, to: output)
            print("✓ Searchable PDF → \(output.path)")

            let text = Exporters.plainText(pages.map(\.ocr))
            let textURL = output.deletingPathExtension().appendingPathExtension("txt")
            try? text.write(to: textURL, atomically: true, encoding: .utf8)
            print("✓ Text → \(textURL.path)")

            if let json = try? Exporters.json(pages.map(\.ocr)) {
                let jsonURL = output.deletingPathExtension().appendingPathExtension("json")
                try? json.write(to: jsonURL)
                print("✓ JSON → \(jsonURL.path)")
            }

            let preview = text.prefix(500)
            print("\n----- recognized text (first 500 chars) -----\n\(preview)\n----------------------------------------------")
        } catch {
            print("✗ Failed: \(error.localizedDescription)")
        }
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
