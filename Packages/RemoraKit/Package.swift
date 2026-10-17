// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoraKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "RemoraCore", targets: ["RemoraCore"]),
        .library(name: "RDPSession", targets: ["RDPSession"])
    ],
    dependencies: [
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.2")
    ],
    targets: [
        .binaryTarget(name: "FreeRDP", path: "../../Vendor/build/FreeRDP.xcframework"),
        .target(
            name: "CFreeRDPBridge",
            dependencies: ["FreeRDP"],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreServices"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo")
            ]
        ),
        .target(
            name: "RDPSession",
            dependencies: ["RemoraCore", "CFreeRDPBridge"]
        ),
        .target(
            name: "RemoraCore",
            dependencies: [.product(name: "KeychainAccess", package: "KeychainAccess")]
        ),
        .testTarget(name: "RemoraCoreTests", dependencies: ["RemoraCore", "CFreeRDPBridge"])
    ],
    swiftLanguageModes: [.v6]
)
