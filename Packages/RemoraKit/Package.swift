// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoraKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "RemoraCore", targets: ["RemoraCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.2")
    ],
    targets: [
        .target(
            name: "RemoraCore",
            dependencies: [.product(name: "KeychainAccess", package: "KeychainAccess")]
        )
    ],
    swiftLanguageModes: [.v6]
)
