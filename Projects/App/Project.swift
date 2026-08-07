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
            bundleId: "com.chaisz.tandem",
            deploymentTargets: deploymentTargets,
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "UILaunchScreen": [:],
                "CFBundleDisplayName": "Tandem",
                "CFBundleURLTypes": [
                    [
                        "CFBundleURLName": "com.chaisz.tandem",
                        "CFBundleURLSchemes": ["tandem"],
                    ],
                ],
                "UISupportedInterfaceOrientations": [
                    "UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ],
                "NSCameraUsageDescription": "扫描配置二维码与拍摄头像",
                "NSPhotoLibraryUsageDescription": "选择头像与保存配置二维码",
                "NSPhotoLibraryAddUsageDescription": "保存配置分享二维码到相册",
                "NSLocalNetworkUsageDescription": "连接七牛云与腾讯云 IM 服务",
                "ITSAppUsesNonExemptEncryption": false,
            ]),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            dependencies: [
                .project(target: "Presentation", path: "../Presentation"),
                .project(target: "Data", path: "../Data"),
                .project(target: "Domain", path: "../Domain"),
                .external(name: "VLCKitSPM"),
                .external(name: "ImSDKSPM"),
            ],
            settings: .settings(base: [
                "CODE_SIGN_STYLE": "Manual",
                "DEVELOPMENT_TEAM": "8PHCHYD8X3",
                "CODE_SIGN_IDENTITY": "Apple Distribution",
                "PROVISIONING_PROFILE_SPECIFIER": "Tandem AppStore",
                "EXCLUDED_ARCHS[sdk=iphoneos*]": "armv7 armv7s",
                "MARKETING_VERSION": "1.0",
                "CURRENT_PROJECT_VERSION": "2",
            ])
        ),
        .target(
            name: "TandemTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.chaisz.tandem.tests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Tests/**"],
            dependencies: [.target(name: "Tandem")]
        ),
    ]
)
