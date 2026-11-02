import ProjectDescription

let deploymentTargets: DeploymentTargets = .iOS("26.0")
/// Built by the Presentation target's "Compile Kotlin Framework" phase (`embedAndSignAppleFrameworkForXcode`).
let paircastSharedFrameworkDir = "$(SRCROOT)/../../shared/umbrella/build/xcode-frameworks/$(CONFIGURATION)/$(SDK_NAME)"

let project = Project(
    name: "Paircast",
    organizationName: "Paircast",
    options: .options(
        defaultKnownRegions: ["en", "zh-Hans"],
        developmentRegion: "en"
    ),
    targets: [
        .target(
            name: "Paircast",
            destinations: .iOS,
            product: .app,
            bundleId: "com.chaisz.tandem",
            deploymentTargets: deploymentTargets,
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "UILaunchScreen": [:],
                // Explicit arm64 — Tuist's default armv7 blocks modern review devices.
                "UIRequiredDeviceCapabilities": ["arm64"],
                "CFBundleDisplayName": "Paircast",
                "CFBundleURLTypes": [
                    [
                        "CFBundleURLName": "com.chaisz.tandem",
                        "CFBundleURLSchemes": ["paircast"],
                    ],
                ],
                "UISupportedInterfaceOrientations": [
                    "UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ],
                "UISupportedInterfaceOrientations~ipad": [
                    "UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationPortraitUpsideDown",
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ],
                "NSPhotoLibraryUsageDescription": "Choose a profile photo and save configuration QR codes",
                "NSPhotoLibraryAddUsageDescription": "Save configuration QR codes to Photos",
                "ITSAppUsesNonExemptEncryption": false,
            ]),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            dependencies: [
                .project(target: "Presentation", path: "../Presentation"),
                .external(name: "VLCKitSPM"),
            ],
            settings: .settings(base: [
                "CODE_SIGN_STYLE": "Manual",
                "DEVELOPMENT_TEAM": "8PHCHYD8X3",
                "CODE_SIGN_IDENTITY": "Apple Distribution",
                "PROVISIONING_PROFILE_SPECIFIER": "Tandem AppStore",
                "EXCLUDED_ARCHS[sdk=iphoneos*]": "armv7 armv7s",
                // PaircastShared ships arm64 simulator only.
                "EXCLUDED_ARCHS[sdk=iphonesimulator*]": "x86_64",
                "FRAMEWORK_SEARCH_PATHS": .array(["$(inherited)", paircastSharedFrameworkDir]),
                "OTHER_LDFLAGS": ["$(inherited)", "-framework", "PaircastShared"],
                "MARKETING_VERSION": "2.0.0",
                "CURRENT_PROJECT_VERSION": "14",
            ])
        ),
        .target(
            name: "PaircastTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.chaisz.tandem.tests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Tests/**"],
            dependencies: [.target(name: "Paircast")],
            settings: .settings(base: ["EXCLUDED_ARCHS[sdk=iphonesimulator*]": "x86_64"])
        ),
    ]
)
