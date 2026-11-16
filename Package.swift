// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "OpenCloak",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "OpenCloakCore", targets: ["OpenCloakCore"]),
        .executable(name: "OpenCloak", targets: ["OpenCloakApp"])
    ],
    targets: [
        .target(name: "OpenCloakCore"),
        .executableTarget(name: "OpenCloakApp", dependencies: ["OpenCloakCore"]),
        .executableTarget(name: "OpenCloakTests", dependencies: ["OpenCloakCore"], path: "Tests/OpenCloakTests")
    ]
)
