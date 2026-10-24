// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Yuja",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "YujaCore", targets: ["YujaCore"]),
        .executable(name: "yuja", targets: ["yuja"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "YujaCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .executableTarget(
            name: "yuja",
            dependencies: [
                "YujaCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "YujaCoreTests",
            dependencies: [
                "YujaCore",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
    ]
)
