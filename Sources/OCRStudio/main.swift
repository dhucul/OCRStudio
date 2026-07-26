import Foundation

// Headless pipeline mode (`--ocr …`) runs and exits; otherwise launch the GUI.
if let status = HeadlessCLI.runIfRequested() {
    exit(status)
} else {
    OCRStudioApp.main()
}
