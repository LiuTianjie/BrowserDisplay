// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BrowserDisplay",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MirrorProtocol",
            targets: ["MirrorProtocol"]
        )
    ],
    targets: [
        .target(name: "MirrorProtocol")
    ]
)
