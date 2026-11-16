// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "Nopal",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NopalCore", targets: ["NopalCore"]),
        .executable(name: "Nopal", targets: ["NopalApp"])
    ],
    targets: [
        .target(name: "NopalCore"),
        .executableTarget(name: "NopalApp", dependencies: ["NopalCore"]),
        .executableTarget(name: "NopalTests", dependencies: ["NopalCore"], path: "Tests/NopalTests")
    ]
)
