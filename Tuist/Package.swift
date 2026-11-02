// swift-tools-version: 6.0
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
    productTypes: [:]
)
#endif

let package = Package(
    name: "Paircast",
    dependencies: [
        // Local wrapper around pre-downloaded VLCKit binary (see Scripts/download-vlckit.sh).
        .package(path: "../Vendor/VLCKitSPM"),
        .package(url: "https://github.com/onevcat/Kingfisher.git", from: "8.0.0"),
    ]
)
