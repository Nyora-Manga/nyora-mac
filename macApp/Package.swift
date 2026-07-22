// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nyora",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "Nyora", targets: ["NyoraApp"]),
    ],
    dependencies: [
        // Native ONNX Runtime for on-device manga colorization (manga-colorization-v2),
        // run directly in Swift instead of the web/WKWebView onnxruntime-web path.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", from: "1.19.0"),
    ],
    targets: [
        .executableTarget(
            name: "NyoraApp",
            dependencies: [
                .target(name: "ConcurrencyShim"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Nyora/NyoraApp",
            resources: [
                .process("Assets.xcassets"),
                // The web OCR pipeline (harness + bridge + verbatim tl-worker.js), served
                // same-origin by OcrAssetServer to a hidden WKWebView. Copied (not processed)
                // so the JS/HTML ship byte-for-byte.
                .copy("Resources/ocr"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // Define DEBUG only in debug builds so `#if DEBUG` reliably gates
                // dev-only UI (e.g. status toasts) out of release/prod builds.
                .define("DEBUG", .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "ConcurrencyShim",
            path: "Nyora/ConcurrencyShim",
            linkerSettings: [
                .linkedLibrary("swift_Concurrency"),
                .unsafeFlags(["-L/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib/swift"]),
            ]
        ),
    ]
)
