import ProjectDescription

let deploymentTargets: DeploymentTargets = .iOS("26.0")

let project = Project(
    name: "Data",
    organizationName: "Paircast",
    targets: [
        .target(
            name: "Data",
            destinations: .iOS,
            product: .staticFramework,
            bundleId: "com.chaisz.data",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/**"],
            dependencies: [
                .project(target: "Domain", path: "../Domain"),
                .external(name: "ImSDKSPM"),
            ]
        ),
        .target(
            name: "DataTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.chaisz.data.tests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Tests/**"],
            dependencies: [.target(name: "Data")]
        ),
    ],
    schemes: [
        .scheme(
            name: "Data",
            shared: true,
            buildAction: .buildAction(targets: [.target("Data")]),
            testAction: .targets([.testableTarget(target: .target("DataTests"))])
        ),
    ]
)
