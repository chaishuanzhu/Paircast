import ProjectDescription

let deploymentTargets: DeploymentTargets = .iOS("26.0")

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
                .project(target: "Domain", path: "../Domain"),
                .external(name: "VLCKitSPM"),
            ]
        ),
        .target(
            name: "PresentationTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.chaisz.presentation.tests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Tests/**"],
            dependencies: [.target(name: "Presentation")]
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
