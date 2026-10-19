// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoraKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "RemoraCore", targets: ["RemoraCore"]),
        .library(name: "RemoraControl", targets: ["RemoraControl"]),
        .library(name: "RDPSession", targets: ["RDPSession"]),
        .library(name: "VNCSession", targets: ["VNCSession"])
    ],
    dependencies: [
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.2")
    ],
    targets: [
        .binaryTarget(name: "LibVNCClient", path: "../../Vendor/build/LibVNCClient.xcframework"),
        .target(name: "CVNCBridge", dependencies: ["LibVNCClient", "FreeRDP"], linkerSettings: [.linkedLibrary("z")]),
        .target(name: "VNCSession", dependencies: ["RemoraCore", "CVNCBridge", "CFreeRDPBridge"]),
        .testTarget(name: "VNCSessionTests", dependencies: ["VNCSession"]),
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
        .target(name: "RemoraControl"),
        .testTarget(name: "RemoraControlTests", dependencies: ["RemoraControl"]),
        .target(
            name: "RDPSession",
            dependencies: ["RemoraCore", "CFreeRDPBridge"]
        ),
        .target(
            name: "RemoraCore",
            dependencies: [.product(name: "KeychainAccess", package: "KeychainAccess")]
        ),
        .testTarget(name: "RemoraCoreTests", dependencies: ["RemoraCore", "CFreeRDPBridge"], resources: [.copy("CursorReference")])
    ],
    swiftLanguageModes: [.v6]
)
