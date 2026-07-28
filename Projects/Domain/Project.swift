import ProjectDescription

let deploymentTargets: DeploymentTargets = .iOS("26.0")

let project = Project(
    name: "Domain",
    organizationName: "Tandem",
    targets: [
        .target(
            name: "Domain",
            destinations: .iOS,
            product: .staticFramework,
            bundleId: "app.tandem.domain",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/**"]
        ),
        .target(
            name: "DomainTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "app.tandem.domain.tests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Tests/**"],
            dependencies: [.target(name: "Domain")]
        ),
    ],
    schemes: [
        .scheme(
            name: "Domain",
            shared: true,
            buildAction: .buildAction(targets: [.target("Domain")]),
            testAction: .targets([.testableTarget(target: .target("DomainTests"))])
        ),
    ]
)
