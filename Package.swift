// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RCSPACFileParser",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "RCSPACFileParser",
            targets: ["RCSPACFileParser"]
        ),
        .executable(
            name: "har-analyzer",
            targets: ["har-analyzer"]
        ),
        .executable(
            name: "pac-inspector-app",
            targets: ["pac-inspector-app"]
        )
    ],
    targets: [
        .target(
            name: "RCSPACFileParser"
        ),
        .executableTarget(
            name: "har-analyzer",
            dependencies: ["RCSPACFileParser"]
        ),
        .executableTarget(
            name: "pac-inspector-app",
            dependencies: ["RCSPACFileParser"],
            exclude: ["AppInfo.plist", "AppIcon.icns", "Help.html"]
        ),
        .testTarget(
            name: "RCSPACFileParserTests",
            dependencies: ["RCSPACFileParser"]
        )
    ]
)
