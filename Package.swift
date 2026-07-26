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
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("ImageCaptureCore"),
                .linkedFramework("Vision"),
                .linkedFramework("PDFKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "OCRStudioTests",
            dependencies: ["OCRStudio"],
            path: "Tests/OCRStudioTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
