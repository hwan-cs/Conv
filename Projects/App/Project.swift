import ProjectDescription
import ProjectDescriptionHelpers

let appBundleID = "\(Conv.bundleIDPrefix).Conv"
/// Embedded bundles must carry the same version as the app.
let version: [String: Plist.Value] = [
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1",
]
let sandbox: Entitlements = .dictionary([
    "com.apple.security.app-sandbox": true,
    "com.apple.security.files.user-selected.read-write": true,
])

let app = Target.target(
    name: "Conv",
    destinations: .macOS,
    product: .app,
    bundleId: appBundleID,
    deploymentTargets: Conv.deploymentTargets,
    infoPlist: .extendingDefault(with: version.merging([
        "CFBundleDisplayName": "Conv",
        "LSApplicationCategoryType": "public.app-category.utilities",
    ]) { $1 }),
    sources: ["App/Sources/**"],
    entitlements: sandbox,
    dependencies: [
        .module(.dropFeature),
        .module(.menuBarFeature),
        .module(.settingsFeature),
        .module(.conversionKit),
        .target(name: "ConversionXPC"),
        .target(name: "ConvFinderSync"),
    ],
    settings: .settings(base: Conv.baseSettings)
)

/// Runs the engines out of process so a crashing parser never takes the app down.
let conversionXPC = Target.target(
    name: "ConversionXPC",
    destinations: .macOS,
    product: .xpc,
    bundleId: "\(appBundleID).ConversionXPC",
    deploymentTargets: Conv.deploymentTargets,
    infoPlist: .extendingDefault(with: version.merging([
        "XPCService": ["ServiceType": "Application"],
    ]) { $1 }),
    sources: ["XPC/Sources/**"],
    entitlements: sandbox,
    dependencies: [
        .module(.conversionKit),
        .module(.imageEngine),
        .module(.pdfEngine),
        .module(.documentEngine),
        .module(.hwpEngine),
        .module(.mediaEngine),
    ],
    settings: .settings(base: Conv.baseSettings)
)

let finderSync = Target.target(
    name: "ConvFinderSync",
    destinations: .macOS,
    product: .appExtension,
    bundleId: "\(appBundleID).FinderSync",
    deploymentTargets: Conv.deploymentTargets,
    infoPlist: .extendingDefault(with: version.merging([
        "CFBundleDisplayName": "Conv",
        "NSExtension": [
            "NSExtensionPointIdentifier": "com.apple.FinderSync",
            "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).FinderSync",
        ],
    ]) { $1 }),
    sources: ["FinderSync/Sources/**"],
    entitlements: .dictionary(["com.apple.security.app-sandbox": true]),
    dependencies: [.sdk(name: "FinderSync", type: .framework)],
    settings: .settings(base: Conv.baseSettings)
)

let project = Project(
    name: "App",
    targets: [app, conversionXPC, finderSync]
)
