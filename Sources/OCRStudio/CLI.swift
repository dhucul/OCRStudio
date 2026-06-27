import Foundation

/// Headless mode for scripting and verification. Runs the same ingest → OCR →
/// searchable-PDF pipeline as the GUI, with no window or scanner required:
///
///   OCRStudio --ocr <file...> [--out <output.pdf>]
enum HeadlessCLI {

    /// Returns true if the app was launched in headless mode (and has now finished).
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let start = args.firstIndex(of: "--ocr") else { return false }

        var inputs: [URL] = []
        var output: URL?
        var i = start + 1
        while i < args.count {
            if args[i] == "--out", i + 1 < args.count {
                output = URL(fileURLWithPath: args[i + 1]); i += 2; continue
            }
            inputs.append(URL(fileURLWithPath: args[i])); i += 1
        }

        guard !inputs.isEmpty else {
            FileHandle.standardError.write(Data(
                "usage: OCRStudio --ocr <file...> [--out <output.pdf>]\n".utf8))
            return true
        }

        let out = output ?? inputs[0].deletingPathExtension()
            .appendingPathExtension("ocr.pdf")

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await run(inputs: inputs, output: out)
            semaphore.signal()
        }
        semaphore.wait()
        return true
    }

    private static func run(inputs: [URL], output: URL) async {
        let jobs = JobManager()
        let settings = Settings.load()

        var pages: [ProcessedPage] = []
        for input in inputs {
            let produced = await jobs.process(url: input, settings: settings)
            pages.append(contentsOf: produced)
            print("• \(input.lastPathComponent): \(produced.count) page(s)")
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
