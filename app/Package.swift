// swift-tools-version:5.9
//
// Ferry.app — the menu bar shell over the ferry CLI.
// Built by `make app`, which assembles the .app bundle around this binary.

import PackageDescription

let package = Package(
    name: "Ferry",
    platforms: [.macOS(.v13)],   // MenuBarExtra and SMAppService both need 13
    targets: [
        .executableTarget(name: "Ferry", path: "Sources/Ferry")
    ]
)
