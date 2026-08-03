// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImSDKSPM",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "ImSDKSPM", targets: ["ImSDKSPM"]),
    ],
    targets: [
        .binaryTarget(
            name: "ImSDK_Plus",
            path: "ImSDK_Plus.xcframework"
        ),
        .target(
            name: "ImSDKSPM",
            dependencies: ["ImSDK_Plus"],
            path: "Sources/ImSDKSPM",
            linkerSettings: [
                .linkedFramework("UIKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreTelephony"),
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
