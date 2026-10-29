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

/// Files Conv opens, without claiming to be their default app, and the outputs it writes beside
/// them. `NSIsRelatedItemType` is what lets the sandboxed app create "보고서.pdf" next to "보고서.docx".
let documentTypes: Plist.Value = [
    [
        "CFBundleTypeName": "Convertible File",
        "CFBundleTypeRole": "Viewer",
        "LSHandlerRank": "None",
        "LSItemContentTypes": ["org.openxmlformats.wordprocessingml.document", "public.image"],
        "CFBundleTypeExtensions": ["docx", "hwp", "hwpx", "heic", "heif", "jpg", "jpeg", "png", "webp", "tiff", "tif", "gif", "bmp", "avif"],
    ],
    [
        "CFBundleTypeName": "Converted File",
        "CFBundleTypeRole": "Editor",
        "LSHandlerRank": "None",
        "LSItemContentTypes": ["com.adobe.pdf", "public.jpeg", "public.png", "public.heic", "public.tiff", "com.compuserve.gif", "com.microsoft.bmp", "public.avif"],
        "CFBundleTypeExtensions": ["pdf", "jpg", "png", "heic", "tiff", "gif", "bmp", "avif"],
        "NSIsRelatedItemType": true,
    ],
]

let app = Target.target(
    name: "Conv",
    destinations: .macOS,
    product: .app,
    bundleId: appBundleID,
    deploymentTargets: Conv.deploymentTargets,
    infoPlist: .extendingDefault(with: version.merging([
        "CFBundleDisplayName": "Conv",
        "LSApplicationCategoryType": "public.app-category.utilities",
        "CFBundleDocumentTypes": documentTypes,
    ]) { $1 }),
    sources: ["App/Sources/**"],
    entitlements: sandbox,
    dependencies: [
        .module(.dropFeature),
        .module(.menuBarFeature),
        .module(.settingsFeature),
        .module(.conversionKit),
        .module(.platform),
        .target(name: "ConversionXPC"),
        .target(name: "ConvFinderSync"),
    ],
    settings: .settings(base: Conv.baseSettings)
)

/// Runs the engines out of process so a crashing parser never takes the app down.
/// WebKit's helper processes only launch from a sandboxed host that may use the network,
/// even when the HTML is local.
let conversionSandbox: Entitlements = .dictionary([
    "com.apple.security.app-sandbox": true,
    "com.apple.security.files.user-selected.read-write": true,
    "com.apple.security.network.client": true,
])

let conversionXPC = Target.target(
    name: "ConversionXPC",
    destinations: .macOS,
    product: .xpc,
    bundleId: "\(appBundleID).ConversionXPC",
    deploymentTargets: Conv.deploymentTargets,
    infoPlist: .extendingDefault(with: version.merging([
        // WebKit needs a real main run loop, not the default dispatch_main.
        "XPCService": ["ServiceType": "Application", "RunLoopType": "NSRunLoop"],
    ]) { $1 }),
    sources: ["XPC/Sources/**"],
    entitlements: conversionSandbox,
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
