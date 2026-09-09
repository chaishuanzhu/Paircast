import ProjectDescription

public extension Project {
    static let paircastOrganizationName = "Paircast"
    static let paircastBundlePrefix = "com.chaisz"
    static let paircastDeploymentTargets: DeploymentTargets = .iOS("26.0")
    static let paircastDestinations: Destinations = .iOS

    static func framework(
        name: String,
        dependencies: [TargetDependency] = [],
        testDependencies: [TargetDependency] = []
    ) -> Project {
        Project(
            name: name,
            organizationName: paircastOrganizationName,
            targets: [
                .target(
                    name: name,
                    destinations: paircastDestinations,
                    product: .staticFramework,
                    bundleId: "\(paircastBundlePrefix).\(name.lowercased())",
                    deploymentTargets: paircastDeploymentTargets,
                    infoPlist: .default,
                    sources: ["Sources/**"],
                    dependencies: dependencies
                ),
                .target(
                    name: "\(name)Tests",
                    destinations: paircastDestinations,
                    product: .unitTests,
                    bundleId: "\(paircastBundlePrefix).\(name.lowercased()).tests",
                    deploymentTargets: paircastDeploymentTargets,
                    infoPlist: .default,
                    sources: ["Tests/**"],
                    dependencies: [.target(name: name)] + testDependencies
                ),
            ],
            schemes: [
                .scheme(
                    name: name,
                    shared: true,
                    buildAction: .buildAction(targets: [.target(name), .target("\(name)Tests")]),
                    testAction: .targets([.testableTarget(target: .target("\(name)Tests"))]),
                    runAction: .runAction(configuration: .debug)
                )
            ]
        )
    }
}
