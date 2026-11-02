import ProjectDescription

let deploymentTargets: DeploymentTargets = .iOS("26.0")

/// Output of `embedAndSignAppleFrameworkForXcode` (Gradle root is the parent directory).
let paircastSharedFrameworkDir = "$(SRCROOT)/../shared/umbrella/build/xcode-frameworks/$(CONFIGURATION)/$(SDK_NAME)"

/// Presentation compiles first, so the Kotlin framework is built in its pre-build phase.
let compileKotlinFramework = TargetScript.pre(
    path: "Scripts/xcode-build-shared.sh",
    name: "Compile Kotlin Framework",
    basedOnDependencyAnalysis: false
)

/// PaircastShared ships iosArm64 / iosSimulatorArm64 only.
let simulatorArchs: SettingsDictionary = ["EXCLUDED_ARCHS[sdk=iphonesimulator*]": "x86_64"]

let linkPaircastShared: SettingsDictionary = [
    "FRAMEWORK_SEARCH_PATHS": .array(["$(inherited)", paircastSharedFrameworkDir]),
    "OTHER_LDFLAGS": ["$(inherited)", "-framework", "PaircastShared"],
]

let project = Project(
    name: "Paircast",
    organizationName: "Paircast",
    options: .options(
        automaticSchemesOptions: .disabled,
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
            sources: ["App/Sources/**"],
            resources: ["App/Resources/**"],
            dependencies: [
                .target(name: "Presentation"),
                .external(name: "VLCKitSPM"),
            ],
            settings: .settings(base: simulatorArchs.merging(linkPaircastShared) { $1 }.merging([
                "CODE_SIGN_STYLE": "Manual",
                "DEVELOPMENT_TEAM": "8PHCHYD8X3",
                "CODE_SIGN_IDENTITY": "Apple Distribution",
                "PROVISIONING_PROFILE_SPECIFIER": "Tandem AppStore",
                "EXCLUDED_ARCHS[sdk=iphoneos*]": "armv7 armv7s",
                "MARKETING_VERSION": "2.0.0",
                "CURRENT_PROJECT_VERSION": "14",
            ]) { $1 })
        ),
        .target(
            name: "PaircastTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.chaisz.tandem.tests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["App/Tests/**"],
            dependencies: [.target(name: "Paircast")],
            settings: .settings(base: simulatorArchs)
        ),
        .target(
            name: "Presentation",
            destinations: .iOS,
            product: .staticFramework,
            bundleId: "com.chaisz.presentation",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Presentation/Sources/**"],
            scripts: [compileKotlinFramework],
            dependencies: [
                .external(name: "VLCKitSPM"),
                .external(name: "Kingfisher"),
            ],
            settings: .settings(base: simulatorArchs.merging([
                // Gradle writes outside the script sandbox.
                "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                "FRAMEWORK_SEARCH_PATHS": .array(["$(inherited)", paircastSharedFrameworkDir]),
            ]) { $1 })
        ),
        .target(
            name: "PresentationTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.chaisz.presentation.tests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Presentation/Tests/**"],
            dependencies: [.target(name: "Presentation")],
            settings: .settings(base: simulatorArchs.merging(linkPaircastShared) { $1 })
        ),
    ],
    schemes: [
        .scheme(
            name: "Paircast",
            shared: true,
            buildAction: .buildAction(targets: ["Paircast"]),
            testAction: .targets(["PaircastTests", "PresentationTests"]),
            runAction: .runAction(configuration: .debug, executable: "Paircast"),
            archiveAction: .archiveAction(configuration: .release)
        ),
        .scheme(
            name: "Presentation",
            shared: true,
            buildAction: .buildAction(targets: ["Presentation"]),
            testAction: .targets(["PresentationTests"])
        ),
    ]
)
