import ProjectDescription

public extension Project {
    static let tandemOrganizationName = "Tandem"
    static let tandemBundlePrefix = "com.chaisz"
    static let tandemDeploymentTargets: DeploymentTargets = .iOS("26.0")
    static let tandemDestinations: Destinations = .iOS

    static func framework(
        name: String,
        dependencies: [TargetDependency] = [],
        testDependencies: [TargetDependency] = []
    ) -> Project {
        Project(
            name: name,
            organizationName: tandemOrganizationName,
            targets: [
                .target(
                    name: name,
                    destinations: tandemDestinations,
                    product: .staticFramework,
                    bundleId: "\(tandemBundlePrefix).\(name.lowercased())",
                    deploymentTargets: tandemDeploymentTargets,
                    infoPlist: .default,
                    sources: ["Sources/**"],
                    dependencies: dependencies
                ),
                .target(
                    name: "\(name)Tests",
                    destinations: tandemDestinations,
                    product: .unitTests,
                    bundleId: "\(tandemBundlePrefix).\(name.lowercased()).tests",
                    deploymentTargets: tandemDeploymentTargets,
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
