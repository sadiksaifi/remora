// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VNCSmoke",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../../Packages/RemoraKit")],
    targets: [
        .executableTarget(
            name: "VNCSmoke",
            dependencies: [
                .product(name: "VNCSession", package: "RemoraKit"),
                .product(name: "RemoraCore", package: "RemoraKit"),
            ])
    ]
)
