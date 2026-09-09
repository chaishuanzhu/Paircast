import ProjectDescription

let deploymentTargets: DeploymentTargets = .iOS("26.0")

let project = Project(
    name: "Paircast",
    organizationName: "Paircast",
    options: .options(
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
                "CURRENT_PROJECT_VERSION": "3",
            ])
        ),
        .target(
            name: "PaircastTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.chaisz.tandem.tests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Tests/**"],
            dependencies: [.target(name: "Paircast")]
        ),
    ]
)
