import ProjectDescription
import ProjectDescriptionHelpers

let appBundleID = "\(Conv.bundleIDPrefix).Conv"
/// Embedded bundles must carry the same version as the app.
let version: [String: Plist.Value] = [
    "CFBundleShortVersionString": "1.0.0",
    "CFBundleVersion": "2",
]
let localizable: ResourceFileElement = "Localization/Localizable.xcstrings"

let sandbox: Entitlements = .dictionary([
    "com.apple.security.app-sandbox": true,
    "com.apple.security.files.user-selected.read-write": true,
    // Folders allowed for Finder's menu stay allowed across launches.
    "com.apple.security.files.bookmarks.app-scope": true,
])

let documentTypes: Plist.Value = [
    [
        "CFBundleTypeRole": "Viewer",
        "LSHandlerRank": "None",
        "LSItemContentTypes": [
            "org.openxmlformats.wordprocessingml.document", "net.daringfireball.markdown",
            "public.image", "public.movie", "public.audio",
            "public.comma-separated-values-text",
            "org.openxmlformats.spreadsheetml.sheet",
            "public.svg-image",
        ],
        "CFBundleTypeExtensions": ["hwp", "hwpx"],
    ],
    [
        "CFBundleTypeRole": "Editor",
        "LSHandlerRank": "None",
        "LSItemContentTypes": [
            "com.adobe.pdf", "public.jpeg", "public.png", "public.heic", "public.tiff", "com.compuserve.gif",
            "com.microsoft.bmp", "public.avif", "public.mpeg-4", "com.apple.quicktime-movie",
            "com.apple.m4a-audio", "public.mp3", "com.microsoft.waveform-audio", "public.aiff-audio", "public.html",
            "org.openxmlformats.wordprocessingml.document",
            "org.openxmlformats.spreadsheetml.sheet",
            "public.comma-separated-values-text",
        ],
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
        "NSHumanReadableCopyright": "Copyright © 2026 Jung Hwan Park",
        "ITSAppUsesNonExemptEncryption": false,
        "CFBundleDocumentTypes": documentTypes,
    ]) { $1 }),
    sources: ["App/Sources/**"],
    resources: ["App/Resources/**", localizable],
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
        "XPCService": ["ServiceType": "Application", "RunLoopType": "NSRunLoop"],
    ]) { $1 }),
    sources: ["XPC/Sources/**"],
    resources: [localizable],
    entitlements: conversionSandbox,
    dependencies: [
        .module(.conversionKit),
        .module(.imageEngine),
        .module(.pdfEngine),
        .module(.documentEngine),
        .module(.hwpEngine),
        .module(.mediaEngine),
    ],
    settings: .settings(base: Conv.baseSettings.merging(["LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"]]) { $1 })
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
    sources: [
        "FinderSync/Sources/**",
        "../Core/ConversionKit/Sources/Formats.swift",
        "../Core/ConversionKit/Sources/FinderFormatNotification.swift",
    ],
    resources: [localizable],
    entitlements: .dictionary(["com.apple.security.app-sandbox": true]),
    dependencies: [.sdk(name: "FinderSync", type: .framework)],
    settings: .settings(base: Conv.baseSettings)
)

let project = Project(
    name: "App",
    options: .options(defaultKnownRegions: ["en", "ko"], developmentRegion: "en"),
    targets: [app, conversionXPC, finderSync]
)
