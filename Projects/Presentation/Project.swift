import ProjectDescription

let deploymentTargets: DeploymentTargets = .iOS("26.0")
/// Built by `make shared` (Gradle `assemblePaircastSharedReleaseXCFramework`).
let paircastShared = TargetDependency.xcframework(
    path: "../../shared/umbrella/build/XCFrameworks/release/PaircastShared.xcframework"
)

/// PaircastShared.xcframework ships arm64 simulator only.
let simulatorArm64Only: Settings = .settings(base: ["EXCLUDED_ARCHS[sdk=iphonesimulator*]": "x86_64"])

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
            dependencies: [
                paircastShared,
                .external(name: "VLCKitSPM"),
                .external(name: "Kingfisher"),
            ],
            settings: simulatorArm64Only
        ),
        .target(
            name: "PresentationTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.chaisz.presentation.tests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Tests/**"],
            dependencies: [.target(name: "Presentation"), paircastShared],
            settings: simulatorArm64Only
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
