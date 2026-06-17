// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Trinity",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Trinity", targets: ["Trinity"])
    ],
    targets: [
        .executableTarget(
            name: "Trinity",
            path: "Sources/Trinity",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
