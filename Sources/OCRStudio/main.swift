import Foundation

// Headless pipeline mode (`--ocr …`) runs and exits; otherwise launch the GUI.
if !HeadlessCLI.runIfRequested() {
    OCRStudioApp.main()
}
