import XCTest
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import CoreImage
import UniformTypeIdentifiers
@testable import OCRStudio

final class OCRStudioTests: XCTestCase {

    func testGeometryRoundTrip() {
        let normalized = CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.30)
        let pixels = Geometry.pixelRectTopLeft(
            fromNormalized: normalized, width: 1_000, height: 2_000
        )
        XCTAssertEqual(pixels.origin.x, 250, accuracy: 0.001)
        XCTAssertEqual(pixels.origin.y, 1_000, accuracy: 0.001)
        XCTAssertEqual(pixels.width, 500, accuracy: 0.001)
        XCTAssertEqual(pixels.height, 600, accuracy: 0.001)

        let pdf = Geometry.pdfRect(
            fromPixelTopLeft: pixels, imageHeight: 2_000, scale: 0.5
        )
        XCTAssertEqual(pdf.origin.x, 125, accuracy: 0.001)
        XCTAssertEqual(pdf.origin.y, 200, accuracy: 0.001)
        XCTAssertEqual(pdf.width, 250, accuracy: 0.001)
        XCTAssertEqual(pdf.height, 300, accuracy: 0.001)
    }

    func testSettingsDecodeMissingNewKeysWithDefaults() throws {
        let legacy = Data(#"{"recognitionLanguages":["fr-FR"],"rasterDPI":300}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: legacy)

        XCTAssertEqual(settings.recognitionLanguages, ["fr-FR"])
        XCTAssertEqual(settings.rasterDPI, 300)
        XCTAssertTrue(settings.automaticLanguageDetection)
        XCTAssertTrue(settings.detectBarcodes)
        XCTAssertEqual(settings.textLayerPolicy, .ocrIfSparse)
        XCTAssertTrue(settings.autoCropScannedPages)
    }

    func testTextPDFPreservesLogicalPages() throws {
        let output = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: output) }

        try RichTextExport.writeTextPDF(pages: ["First page", "Second page"], to: output)

        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("First page") == true)
        XCTAssertTrue(document.page(at: 1)?.string?.contains("Second page") == true)
    }

    func testDocxDropsForbiddenXMLNoncharacters() throws {
        let forbidden = "before\u{FFFE}middle\u{FFFF}after"
        let data = try DocxWriter.data(pages: [forbidden])

        XCTAssertNil(data.range(of: Data([0xEF, 0xBF, 0xBE])))
        XCTAssertNil(data.range(of: Data([0xEF, 0xBF, 0xBF])))
        XCTAssertNotNil(data.range(of: Data("beforemiddleafter".utf8)))
    }

    func testMultiPageTIFFIngestsEveryFrame() async throws {
        let source = temporaryURL(extension: "tiff")
        defer { try? FileManager.default.removeItem(at: source) }
        let image = try solidImage(width: 12, height: 18)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            source as CFURL, UTType.tiff.identifier as CFString, 2, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let pages = try await FileIngestor().ingest(url: source, dpi: 200)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].image.width, 12)
        XCTAssertEqual(pages[0].image.height, 18)
    }

    func testImageIngestAppliesMetadataOrientation() async throws {
        let source = temporaryURL(extension: "tiff")
        defer { try? FileManager.default.removeItem(at: source) }
        let image = try solidImage(width: 12, height: 18)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            source as CFURL, UTType.tiff.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 6 // 90° clockwise
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let pages = try await FileIngestor().ingest(url: source, dpi: 200)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].image.width, 18)
        XCTAssertEqual(pages[0].image.height, 12)
    }

    func testInvalidPDFDPIThrowsBeforeRasterization() async throws {
        let source = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        try makeTextPDF(at: source, text: "DPI validation")

        do {
            _ = try await FileIngestor().ingest(url: source, dpi: .infinity)
            XCTFail("Expected invalid DPI to throw")
        } catch PipelineError.invalidDPI {
            // Expected.
        }
    }

    func testExistingPDFTextRetainsGeometryAndSearchability() async throws {
        let source = temporaryURL(extension: "pdf")
        let output = temporaryURL(extension: "pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        try makeTextPDF(at: source, text: "Existing searchable text")

        let ingested = try await FileIngestor().ingest(url: source, dpi: 144)
        XCTAssertEqual(ingested.count, 1)
        XCTAssertFalse(ingested[0].existingLines.isEmpty)
        XCTAssertTrue(ingested[0].existingLines.allSatisfy {
            $0.box.width > 0 && $0.box.height > 0
        })

        var settings = Settings()
        settings.textLayerPolicy = .skip
        settings.enhanceContrast = false
        settings.denoise = false
        let manager = JobManager()
        let pages = try await manager.process(url: source, settings: settings)
        try await manager.writeSearchablePDF(pages, to: output)

        let result = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertTrue(result.string?.contains("Existing searchable text") == true)
    }

    func testCorruptInputThrowsInsteadOfProducingNoPages() async throws {
        let source = temporaryURL(extension: "png")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("not an image".utf8).write(to: source)

        do {
            _ = try await JobManager().process(url: source, settings: Settings())
            XCTFail("Expected corrupt input to throw")
        } catch {
            XCTAssertTrue(error is PipelineError)
        }
    }

    func testWatchRetriesFailureAndProcessesRecreatedPath() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRStudioWatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let recorder = AttemptRecorder()
        let watcher = WatchFolderService()
        await watcher.setHandler { _ in await recorder.record() }
        try await watcher.start(folder: folder, pollInterval: 0.03)

        let input = folder.appendingPathComponent("page.png")
        try Data("first".utf8).write(to: input)
        let retriedSuccessfully = await eventually { await recorder.count >= 2 }
        XCTAssertTrue(retriedSuccessfully)

        try FileManager.default.removeItem(at: input)
        try await Task.sleep(nanoseconds: 100_000_000)
        try Data("replacement".utf8).write(to: input)
        let replacementProcessed = await eventually { await recorder.count >= 3 }
        XCTAssertTrue(replacementProcessed)
        await watcher.stop()
    }

    func testWatchRejectsAFileAsFolder() async throws {
        let file = temporaryURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)

        do {
            try await WatchFolderService().start(folder: file, pollInterval: 0.03)
            XCTFail("Expected a non-directory watch path to throw")
        } catch {
            // Expected.
        }
    }

    // MARK: Regressions

    /// A file that never succeeds must keep being retried — a transient fault has
    /// to be able to clear — but the interval has to back off, or the watch folder
    /// re-runs the whole OCR pipeline on every poll.
    func testWatchBacksOffButKeepsRetrying() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRStudioWatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let pollInterval = 0.03
        let recorder = AttemptRecorder(succeedAt: .max)   // never succeeds
        let watcher = WatchFolderService()
        await watcher.setHandler { _ in await recorder.record() }
        try await watcher.start(folder: folder, pollInterval: pollInterval)

        try Data("doomed".utf8).write(to: folder.appendingPathComponent("page.png"))
        let window: TimeInterval = 2
        try await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
        let total = await recorder.count
        await watcher.stop()

        // Backoff here is 0.1s doubling (2× the poll interval), so ~5 attempts fit
        // in the window — against ~66 polls if it retried on every one.
        XCTAssertGreaterThan(total, 3, "must keep retrying, not give up")
        XCTAssertLessThan(total, Int(window / pollInterval) / 4,
                          "must back off, not retry on every poll")
    }

    /// Editing a file that previously failed must clear its backoff — the new
    /// bytes are effectively a fresh arrival.
    func testWatchResetsBackoffWhenFileChanges() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRStudioWatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let recorder = AttemptRecorder(succeedAt: .max)
        let watcher = WatchFolderService()
        await watcher.setHandler { _ in await recorder.record() }
        try await watcher.start(folder: folder, pollInterval: 0.03)

        let input = folder.appendingPathComponent("page.png")
        try Data("first".utf8).write(to: input)
        let firstAttempts = await eventually { await recorder.count >= 2 }
        XCTAssertTrue(firstAttempts)

        // Burn enough attempts that the next retry is seconds away…
        _ = await eventually(timeout: 1) { await recorder.count >= 4 }
        let beforeEdit = await recorder.count

        // …then rewrite it. The edit must be picked up promptly.
        try await Task.sleep(nanoseconds: 60_000_000)
        try Data("second and longer".utf8).write(to: input)
        let retriedPromptly = await eventually(timeout: 1) {
            await recorder.count > beforeEdit
        }
        await watcher.stop()
        XCTAssertTrue(retriedPromptly, "an edited file must not serve out the old backoff")
    }

    /// A password-protected PDF loads fine but renders blank — it must be rejected
    /// rather than silently producing a document of empty sheets.
    func testLockedPDFIsRejected() async throws {
        let source = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        try makeTextPDF(at: source, text: "secret")

        let doc = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertTrue(doc.write(to: source, withOptions: [
            .userPasswordOption: "pw", .ownerPasswordOption: "pw"
        ]))

        do {
            _ = try await FileIngestor().ingest(url: source, dpi: 144)
            XCTFail("Expected a locked PDF to throw")
        } catch PipelineError.lockedFile {
            // Expected.
        }
    }

    /// `CGDataConsumer` accepts unwritable paths and reports nothing, so the
    /// composer has to confirm the file exists before claiming success.
    func testUnwritableDestinationThrowsInsteadOfReportingSuccess() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRStudioRO-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dir.path
            )
            try? FileManager.default.removeItem(at: dir)
        }

        let page = ComposablePage(
            image: SendableImage(cgImage: try solidImage(width: 20, height: 20)),
            ocr: OCRPageResult(lines: [], barcodes: [], imageWidth: 20, imageHeight: 20),
            dpi: 72
        )
        do {
            try await PDFComposer().makeSearchablePDF(
                pages: [page], to: dir.appendingPathComponent("blocked.pdf")
            )
            XCTFail("Expected an unwritable destination to throw")
        } catch {
            // Expected.
        }
    }

    /// A non-finite DPI must not reach the media box — `max(x, 1)` lets NaN through
    /// because every NaN comparison is false.
    func testNonFiniteDPIDoesNotCorruptThePDF() async throws {
        let output = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: output) }

        let page = ComposablePage(
            image: SendableImage(cgImage: try solidImage(width: 100, height: 150)),
            ocr: OCRPageResult(lines: [], barcodes: [], imageWidth: 100, imageHeight: 150),
            dpi: .nan
        )
        try await PDFComposer().makeSearchablePDF(pages: [page], to: output)

        let result = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(result.pageCount, 1)
        let bounds = try XCTUnwrap(result.page(at: 0)?.bounds(for: .mediaBox))
        XCTAssertTrue(bounds.width.isFinite && bounds.width > 0)
        XCTAssertTrue(bounds.height.isFinite && bounds.height > 0)
    }

    /// Re-running OCR must not discard the user's corrections — the inspector
    /// promises those edits drive the exports.
    @MainActor
    func testRerunOCRPreservesUserEdits() throws {
        let image = SendableImage(cgImage: try solidImage(width: 10, height: 10))
        func result(_ text: String) -> OCRPageResult {
            OCRPageResult(
                lines: [OCRLine(text: text, box: .zero, confidence: 1, words: [])],
                barcodes: [], imageWidth: 10, imageHeight: 10
            )
        }

        let page = PageVM(originalImage: image, image: image, dpi: 200,
                          sourceName: "s", ocr: result("recognized"), cropToContent: false)
        XCTAssertEqual(page.editedText, "recognized")

        // Untouched text tracks the new recognition.
        page.ocr = result("re-recognized")
        XCTAssertEqual(page.editedText, "re-recognized")

        // Corrected text survives.
        page.editedText = "my correction"
        page.ocr = result("third pass")
        XCTAssertEqual(page.editedText, "my correction")
    }

    /// One poster-sized sheet shouldn't cost the caller every other page.
    func testOversizedPageIsReportedWhileReadablePagesSurvive() async throws {
        let source = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: source) }

        var huge = CGRect(x: 0, y: 0, width: 20_000, height: 20_000)
        let consumer = try XCTUnwrap(CGDataConsumer(url: source as CFURL))
        let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &huge, nil))
        ctx.beginPDFPage(nil)                      // page 1: far over the pixel cap
        ctx.endPDFPage()
        let normal = CGRect(x: 0, y: 0, width: 300, height: 200)
        ctx.beginPDFPage([kCGPDFContextMediaBox as String:
                          withUnsafeBytes(of: normal) { Data($0) } as CFData] as CFDictionary)
        ctx.endPDFPage()
        ctx.closePDF()

        let report = try await JobManager().processReport(url: source, settings: Settings())
        XCTAssertEqual(report.pages.count, 1)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures[0].contains("Page 1"))
        do {
            _ = try await JobManager().process(url: source, settings: Settings())
            XCTFail("Strict callers must not acknowledge an incomplete document")
        } catch PipelineError.incompleteDocument { }

    }

    func testCLIRejectsSidecarAsPDFAndInputAliases() throws {
        let source = temporaryURL(extension: "pdf")
        let alias = temporaryURL(extension: "pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: alias)
        }
        try makeTextPDF(at: source, text: "Source must survive")
        for ext in ["txt", "json", "png", ""] {
            XCTAssertThrowsError(try HeadlessCLI.validateOutput(source.deletingPathExtension()
                .appendingPathExtension(ext), inputs: [source]))
        }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        XCTAssertThrowsError(try HeadlessCLI.validateOutput(alias, inputs: [source]))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.linkItem(at: source, to: alias)
        XCTAssertThrowsError(try HeadlessCLI.validateOutput(alias, inputs: [source]))
        XCTAssertNoThrow(try HeadlessCLI.validateOutput(temporaryURL(extension: "pdf"), inputs: [source]))
    }

    func testWatchOutputNamesSeparateExtensionsAndDirectories() {
        let directory = URL(fileURLWithPath: "/output")
        let sources = ["/one/invoice.png", "/one/invoice.pdf", "/two/invoice.pdf"]
        let outputs = sources.map { JobManager.outputURL(for: URL(fileURLWithPath: $0), directory: directory) }
        XCTAssertEqual(Set(outputs).count, sources.count)
        XCTAssertTrue(outputs.allSatisfy { $0.deletingPathExtension().lastPathComponent.hasSuffix("-ocr") })
    }

    func testAtomicFailurePreservesPreviousOutputAndRemovesTemporary() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("document.pdf")
        let original = Data("previous complete document".utf8)
        try original.write(to: output)
        XCTAssertThrowsError(try AtomicFile.write(to: output) { temporary in
            try Data("partial".utf8).write(to: temporary)
            throw CocoaError(.fileWriteOutOfSpace)
        })
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["document.pdf"])
    }

    func testPDFVerificationRejectsTruncatedAndWrongPageCount() throws {
        let output = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        try RichTextExport.writeTextPDF(pages: ["First", "Second"], to: output)
        XCTAssertNoThrow(try PDFComposer.verifyWritten(output, expectedPages: 2))
        XCTAssertThrowsError(try PDFComposer.verifyWritten(output, expectedPages: 3))
        let data = try Data(contentsOf: output)
        try data.prefix(data.count / 2).write(to: output)
        XCTAssertThrowsError(try PDFComposer.verifyWritten(output))
    }

    func testCancellationReachesDetachedWriterBeforePublication() async throws {
        let output = temporaryURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: output) }
        let original = Data("original".utf8)
        try original.write(to: output)
        let gate = WorkerGate()
        let task = Task {
            try await cancellableWork {
                gate.arriveAndWait()
                try AtomicFile.write(Data("replacement".utf8), to: output)
            }
        }
        let began = await eventually { gate.hasArrived }
        XCTAssertTrue(began)
        task.cancel()
        gate.release()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    func testScannerCancellationBlocksEveryLaterHandshakeStep() {
        for advance in 0...3 {
            var flow = ScanLifecycle()
            XCTAssertTrue(flow.start())
            if advance >= 1 { XCTAssertTrue(flow.opened()) }
            if advance >= 2 { XCTAssertTrue(flow.available()) }
            if advance >= 3 { XCTAssertTrue(flow.selected()) }
            XCTAssertTrue(flow.cancel())
            XCTAssertFalse(flow.opened())
            XCTAssertFalse(flow.available())
            XCTAssertFalse(flow.selected())
            XCTAssertEqual(flow.phase, .cancelling)
            XCTAssertTrue(flow.close())
            XCTAssertFalse(flow.start(), "Cannot reopen before closure")
            flow.closed()
            XCTAssertTrue(flow.start())
        }
    }

    func testRasterBudgetReportsFailureBeforeDecodingNextPage() async throws {
        let source = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        try RichTextExport.writeTextPDF(pages: ["One", "Two"], to: source)
        var settings = Settings()
        settings.rasterDPI = 72
        settings.enhanceContrast = false
        settings.denoise = false
        settings.detectBarcodes = false
        settings.textLayerPolicy = .skip
        // Enough for exactly one pair of 612 x 792 RGBA rasters, including stride padding.
        let report = try await JobManager().processReport(url: source, settings: settings,
                                                         maximumRetainedBytes: 4_000_000)
        XCTAssertEqual(report.pages.count, 1)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures[0].contains("memory limit"))
    }

    func testContentCropPreservesUnrecognizedInkAndLowConfidenceBoxes() async throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 50, y: 20, width: 60, height: 40)) // unrecognized figure
        let source = SendableImage(cgImage: try XCTUnwrap(ctx.makeImage()))
        let result = OCRPageResult(lines: [
            OCRLine(text: "Title", box: CGRect(x: 40, y: 40, width: 80, height: 20), confidence: 1, words: []),
            OCRLine(text: "Faint", box: CGRect(x: 25, y: 150, width: 10, height: 10), confidence: 0.1, words: [])
        ], barcodes: [], imageWidth: 200, imageHeight: 300)
        let (cropped, adjusted) = await JobManager().contentCropped(image: source, result: result)
        XCTAssertLessThan(cropped.width, source.width)
        XCTAssertEqual(try inkPixels(source.cgImage), try inkPixels(cropped.cgImage))
        let bounds = CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height)
        XCTAssertTrue(adjusted.lines.allSatisfy { bounds.contains($0.box) })
    }

    func testDeskewOptionRefreshesExistingTextGeometry() async throws {
        let source = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        try makeTextPDF(at: source, text: "Fresh geometry after deskew")
        var settings = Settings()
        settings.textLayerPolicy = .skip
        settings.autoCropDeskew = true
        let pages = try await JobManager().process(url: source, settings: settings)
        XCTAssertTrue(pages[0].ocr.fullText.contains("geometry"))
        XCTAssertFalse(pages[0].ocr.lines.flatMap(\.words).isEmpty,
                       "Fresh recognition must replace source PDF line geometry")
    }

    func testExistingTextStillDetectsQRCode() async throws {
        let source = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("ocrstudio-barcode".utf8), forKey: "inputMessage")
        let qr = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 5, y: 5))
        let image = try XCTUnwrap(CIContext().createCGImage(qr, from: qr.extent))
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let consumer = try XCTUnwrap(CGDataConsumer(url: source as CFURL))
        let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: CGRect(x: 80, y: 40, width: 240, height: 240))
        ctx.textPosition = CGPoint(x: 20, y: 350)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Existing document text", attributes: [
            .font: CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        ])), ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        var settings = Settings()
        settings.textLayerPolicy = .skip
        settings.enhanceContrast = false
        settings.denoise = false
        let pages = try await JobManager().process(url: source, settings: settings)
        XCTAssertTrue(pages[0].ocr.barcodes.contains { $0.payload == "ocrstudio-barcode" })
        XCTAssertTrue(pages[0].ocr.lines.allSatisfy { $0.words.isEmpty })
    }

    func testSidecarRetryDoesNotRewriteSuccessfulPDF() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.pdf")
        try makeTextPDF(at: input, text: "Keep the successful PDF while retrying text")
        let pdf = JobManager.outputURL(for: input, directory: folder)
        let text = pdf.deletingPathExtension().appendingPathExtension("txt")
        try FileManager.default.createDirectory(at: text, withIntermediateDirectories: false)
        var settings = Settings()
        settings.textLayerPolicy = .skip
        settings.detectBarcodes = false
        let manager = JobManager()
        do { _ = try await manager.autoProcess(url: input, settings: settings); XCTFail("Sidecar failure must surface") }
        catch { }
        let writtenVersion = try FileVersion.read(pdf)
        try FileManager.default.removeItem(at: text)
        _ = try await manager.autoProcess(url: input, settings: settings)
        XCTAssertEqual(try FileVersion.read(pdf), writtenVersion)
        XCTAssertTrue(try String(contentsOf: text, encoding: .utf8).contains("successful PDF"))
    }

    func testWatcherReprocessesVersionChangedDuringHandler() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = AttemptRecorder(succeedAt: 1)
        let gate = AsyncGate()
        let watcher = WatchFolderService()
        await watcher.setHandler { _ in
            _ = await recorder.record()
            if await recorder.count == 1 { await gate.wait() }
            return true
        }
        try await watcher.start(folder: folder, pollInterval: 0.03)
        let input = folder.appendingPathComponent("page.png")
        try Data("first".utf8).write(to: input)
        let began = await eventually { await recorder.count == 1 }
        XCTAssertTrue(began)
        try Data("replacement".utf8).write(to: input, options: .atomic)
        await gate.release()
        let repeated = await eventually { await recorder.count >= 2 }
        XCTAssertTrue(repeated)
        await watcher.stop()
    }

    func testWatcherRecognizesAtomicReplacementAfterSuccess() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = AttemptRecorder(succeedAt: 1)
        let watcher = WatchFolderService()
        await watcher.setHandler { _ in await recorder.record() }
        try await watcher.start(folder: folder, pollInterval: 0.03)
        let input = folder.appendingPathComponent("page.png")
        try Data("first".utf8).write(to: input)
        let began = await eventually { await recorder.count == 1 }
        XCTAssertTrue(began)
        let first = try FileVersion.read(input)
        try Data("other".utf8).write(to: input, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: first.modified], ofItemAtPath: input.path)
        let repeated = await eventually { await recorder.count >= 2 }
        XCTAssertTrue(repeated)
        await watcher.stop()
    }

    func testStoppingWatcherCancelsHandlerPublication() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = AttemptRecorder(succeedAt: 1)
        let gate = AsyncGate()
        let watcher = WatchFolderService()
        let output = folder.appendingPathComponent("result.txt")
        await watcher.setHandler { _ in
            _ = await recorder.record()
            await gate.wait()
            do { try AtomicFile.write(Data("late output".utf8), to: output) }
            catch { }
            _ = await recorder.record()
            return true
        }
        try await watcher.start(folder: folder, pollInterval: 0.03)
        try Data("source".utf8).write(to: folder.appendingPathComponent("page.png"))
        let began = await eventually { await recorder.count == 1 }
        XCTAssertTrue(began)
        await watcher.stop()
        await gate.release()
        let ended = await eventually { await recorder.count == 2 }
        XCTAssertTrue(ended)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    @MainActor
    func testCancelledScanKeepsCapturesRecoverable() throws {
        let source = temporaryURL(extension: "tiff")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("captured bytes".utf8).write(to: source)
        let model = AppModel()
        model.finishScan(captured: [source], error: CancellationError(), settings: Settings())
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.recoveryFiles.contains(source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testScannerFailureStillImportsSuccessfulCaptures() async throws {
        let source = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        try makeTextPDF(at: source, text: "Successful capture before feeder jam")
        let model = AppModel()
        var settings = Settings()
        settings.textLayerPolicy = .skip
        settings.autoCropScannedPages = false
        settings.detectBarcodes = false
        model.finishScan(captured: [source], error: ScannerError.timedOut, settings: settings)
        for _ in 0..<200 where model.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.pages.count, 1)
        XCTAssertTrue(model.pages.first?.isScanned == true)
        XCTAssertTrue(model.status.contains("Scanner stopped"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testRerunUsesCurrentScanCropPreference() async throws {
        let model = AppModel()
        model.settings.enhanceContrast = false
        model.settings.denoise = false
        model.settings.autoCropScannedPages = false
        let image = SendableImage(cgImage: try solidImage(width: 100, height: 100))
        let page = PageVM(originalImage: image, image: image, dpi: 72, sourceName: "scan",
                          ocr: nil, cropToContent: true)
        page.isScanned = true
        model.pages = [page]
        model.rerunOCR()
        for _ in 0..<200 where model.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(page.cropToContent)
        XCTAssertTrue(page.isScanned)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func inkPixels(_ image: CGImage) throws -> Int {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.height).reduce(0) { total, y in
            total + (0..<image.width).filter { data[y * ctx.bytesPerRow + $0 * 4] < 200 }.count
        }
    }

    private func eventually(
        timeout: TimeInterval = 2,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return await condition()
    }

    private func temporaryURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRStudioTest-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    private func solidImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeTextPDF(at url: URL, text: String) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(
            consumer: consumer, mediaBox: &mediaBox, nil
        ))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 36, y: 120)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font]
        )
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage()
        context.closePDF()
    }
}

private actor AttemptRecorder {
    private(set) var count = 0
    private let succeedAt: Int

    init(succeedAt: Int = 2) { self.succeedAt = succeedAt }

    func record() -> Bool {
        count += 1
        return count >= succeedAt
    }
}

private final class WorkerGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var arrived = false
    private var released = false
    var hasArrived: Bool { condition.lock(); defer { condition.unlock() }; return arrived }
    func arriveAndWait() {
        condition.lock()
        arrived = true
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
