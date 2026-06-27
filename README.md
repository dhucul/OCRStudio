# OCR Studio

A native macOS app that scans documents on your Epson (or any ICA-registered)
scanner, OCRs them on-device with Apple's Vision framework, and exports
**searchable PDFs**, plain text, Markdown, and JSON — with **zero external
dependencies**. It also OCRs PDFs and images you already have, and can watch a
folder to auto-process anything dropped in.

Built entirely on system frameworks: **ImageCaptureCore** (scanning),
**Vision** (OCR + barcode detection + document segmentation), **Core Image**
(preprocessing), **PDFKit** (reading PDFs), and **CoreGraphics/CoreText**
(searchable-PDF output).

## Features

- **Scan** from a flatbed or document feeder (ADF), with duplex, selectable DPI,
  and color/grayscale — multi-page jobs land as one document.
- **OCR existing files** — PDFs (rasterized per page) and images
  (PNG/JPEG/TIFF/HEIC/…).
- **Searchable PDF** export: the original image with an invisible, selectable,
  aligned text layer (the ocrmypdf technique).
- **Text / Markdown / JSON** export — JSON includes per-line & per-word boxes
  and confidence.
- **Barcode / QR** detection (payload + symbology + location).
- **Image preprocessing** to boost accuracy: enhance contrast, denoise,
  grayscale, and optional document auto-crop/deskew (Vision segmentation +
  Core Image perspective correction).
- **Watch folder**: drop a file in, get a searchable PDF + text sidecar out.

## Requirements

- macOS 14+ (developed/tested on macOS 26, Apple Silicon).
- Xcode command-line tools / Swift 6 toolchain (already present on this machine).

## Build & run

```bash
# Build a real .app bundle and sign it
./scripts/make-app.sh release
open "dist/OCR Studio.app"
```

The bundle is **ad-hoc signed** by default — it runs fine locally, but macOS may
re-prompt for scanner permission after each rebuild. To make the permission
grant stick, create a stable signing identity once:

```bash
./scripts/create-signing-cert.sh    # optional; see the script header if it can't auto-create
```

### Development build

```bash
swift build            # debug build at .build/debug/OCRStudio
swift run OCRStudio    # launch the GUI directly
```

## Headless / scripting mode

The same pipeline runs without the GUI or a scanner — handy for automation and
verification:

```bash
.build/debug/OCRStudio --ocr page1.png page2.pdf --out result.pdf
# writes result.pdf (searchable), result.txt, and result.json
```

## How it works

```
Source (scan | file)  →  Preprocess (Core Image / Vision)  →  OCR (Vision)
                                                                   │
                          ┌────────────────────────────────────────┤
                          ▼                                         ▼
            Searchable PDF (CoreGraphics + invisible CoreText)   Text / Markdown / JSON
```

Architecture (see `Sources/OCRStudio/`):

| Module | Role |
| --- | --- |
| `Scanner/ScannerService` | ImageCaptureCore device browse + scan (runs on the main thread) |
| `Ingest/FileIngestor` | Rasterize PDFs (PDFKit) and decode images (ImageIO) |
| `Imaging/Preprocessor` | Core Image cleanup + Vision document segmentation |
| `OCR/OCRService` | Vision text + barcode recognition → `Sendable` value models |
| `PDF/PDFComposer` | Searchable PDF (image + invisible aligned text layer) |
| `Export/Exporters` | Text / Markdown / JSON |
| `Watch/WatchFolderService` | Polls a folder, debounces, emits stable new files |
| `Pipeline/JobManager` | Orchestrates ingest → preprocess → OCR → export |
| `Models/*`, `Views/*` | `Sendable` models, coordinate helpers, SwiftUI UI |

Coordinate spaces (Vision normalized/bottom-left ↔ image pixels/top-left ↔ PDF
points/bottom-left) are all converted in one place: `Models/Geometry.swift`.

## Notes & limitations

- The live scanner path requires the Epson powered on and not held open by Epson
  Scan 2; it is driven via ImageCaptureCore and gated on the device becoming
  available.
- The watch folder uses periodic polling with a size/mtime stability check
  (robust against partial writes); it processes only files added after watching
  starts.
- For born-digital PDFs that already contain text, the default policy re-OCRs
  only when the existing text looks sparse (configurable in Settings).
