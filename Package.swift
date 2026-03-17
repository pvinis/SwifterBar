// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwifterBar",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "SwifterBar",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "SwifterBarTests",
            dependencies: ["SwifterBar"]
        ),
    ]
)
