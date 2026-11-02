import ProjectDescription

let deploymentTargets: DeploymentTargets = .iOS("26.0")

/// Compiles the KMP umbrella (`PaircastShared.framework`) for the active configuration before Swift sources.
let buildPaircastShared = TargetScript.pre(
    path: "../../Scripts/xcode-build-shared.sh",
    name: "Compile Kotlin Framework",
    basedOnDependencyAnalysis: false
)

let paircastSharedFrameworkDir = "$(SRCROOT)/../../shared/umbrella/build/xcode-frameworks/$(CONFIGURATION)/$(SDK_NAME)"

/// PaircastShared ships iosArm64 / iosSimulatorArm64 only; Gradle needs to write outside the script sandbox.
let presentationSettings: Settings = .settings(base: [
    "EXCLUDED_ARCHS[sdk=iphonesimulator*]": "x86_64",
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    "FRAMEWORK_SEARCH_PATHS": .array(["$(inherited)", paircastSharedFrameworkDir]),
])

let testSettings: Settings = .settings(base: [
    "EXCLUDED_ARCHS[sdk=iphonesimulator*]": "x86_64",
    "FRAMEWORK_SEARCH_PATHS": .array(["$(inherited)", paircastSharedFrameworkDir]),
    "OTHER_LDFLAGS": ["$(inherited)", "-framework", "PaircastShared"],
])

let project = Project(
    name: "Presentation",
    organizationName: "Paircast",
    targets: [
        .target(
            name: "Presentation",
            destinations: .iOS,
            product: .staticFramework,
            bundleId: "com.chaisz.presentation",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/**"],
            scripts: [buildPaircastShared],
            dependencies: [
                .external(name: "VLCKitSPM"),
                .external(name: "Kingfisher"),
            ],
            settings: presentationSettings
        ),
        .target(
            name: "PresentationTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.chaisz.presentation.tests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Tests/**"],
            dependencies: [.target(name: "Presentation")],
            settings: testSettings
        ),
    ],
    schemes: [
        .scheme(
            name: "Presentation",
            shared: true,
            buildAction: .buildAction(targets: [.target("Presentation")]),
            testAction: .targets([.testableTarget(target: .target("PresentationTests"))])
        ),
    ]
)
