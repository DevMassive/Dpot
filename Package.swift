// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Dpot",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Dpot", targets: ["Dpot"])
    ],
    targets: [
        .executableTarget(
            name: "Dpot",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("JavaScriptCore")
            ]),
        .testTarget(
            name: "DpotTests",
            dependencies: ["Dpot"],
            path: "Tests"
        )
    ]
)
