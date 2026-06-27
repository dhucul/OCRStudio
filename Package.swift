// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OCRStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OCRStudio",
            path: "Sources/OCRStudio",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("ImageCaptureCore"),
                .linkedFramework("Vision"),
                .linkedFramework("PDFKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("AppKit")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
