// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nyora",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "Nyora", targets: ["NyoraApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/google/GoogleSignIn-iOS.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "NyoraApp",
            dependencies: [
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
                .target(name: "ConcurrencyShim"),
            ],
            path: "Nyora/NyoraApp",
            resources: [
                .process("Assets.xcassets"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
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
