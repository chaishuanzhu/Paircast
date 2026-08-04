import ProjectDescription

let deploymentTargets: DeploymentTargets = .iOS("26.0")

let project = Project(
    name: "Tandem",
    organizationName: "Tandem",
    targets: [
        .target(
            name: "Tandem",
            destinations: .iOS,
            product: .app,
            bundleId: "app.tandem.ios",
            deploymentTargets: deploymentTargets,
            infoPlist: .extendingDefault(with: [
                "UILaunchScreen": [:],
                "CFBundleDisplayName": "Tandem",
                "CFBundleURLTypes": [
                    [
                        "CFBundleURLName": "app.tandem.ios",
                        "CFBundleURLSchemes": ["tandem"],
                    ],
                ],
                "NSCameraUsageDescription": "扫描配置二维码与拍摄头像",
                "NSPhotoLibraryUsageDescription": "选择头像与保存配置二维码",
                "NSPhotoLibraryAddUsageDescription": "保存配置分享二维码到相册",
                "NSLocalNetworkUsageDescription": "连接七牛云与腾讯云 IM 服务",
            ]),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            dependencies: [
                .project(target: "Presentation", path: "../Presentation"),
                .project(target: "Data", path: "../Data"),
                .project(target: "Domain", path: "../Domain"),
                .external(name: "VLCKitSPM"),
                .external(name: "ImSDKSPM"),
            ]
        ),
        .target(
            name: "TandemTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "app.tandem.ios.tests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Tests/**"],
            dependencies: [.target(name: "Tandem")]
        ),
    ]
)
