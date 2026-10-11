// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wispad",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WispadCore", targets: ["WispadCore"])
    ],
    targets: [
        .target(
            name: "WispadCore",
            path: "Sources/WispadCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "WispadApp",
            dependencies: ["WispadCore"],
            path: "Sources/Wispad",
            exclude: ["AppMain.swift", "Info.plist", "Wispad.entitlements", "Assets.xcassets", "Localizable.xcstrings", "InfoPlist.xcstrings"]
        ),
        .testTarget(
            name: "WispadAppTests",
            dependencies: ["WispadApp"],
            path: "Tests/WispadAppTests"
        ),
        .testTarget(
            name: "WispadCoreTests",
            dependencies: ["WispadCore"],
            path: "Tests/WispadCoreTests"
        )
    ]
)
