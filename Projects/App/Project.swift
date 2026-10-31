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
    // Folders allowed for Finder's menu stay allowed across launches.
    "com.apple.security.files.bookmarks.app-scope": true,
])

/// Files Conv opens, without claiming to be their default app, and the outputs it writes beside
/// them. `NSIsRelatedItemType` is what lets the sandboxed app create "보고서.pdf" next to "보고서.docx".
/// The entries have no `CFBundleTypeName`: Finder shows a claiming app's name as a file's kind
/// when the default app gives none (it showed "Converted File" for every .mp4), and without one it
/// falls back to the type's own description, "MPEG-4 movie".
let documentTypes: Plist.Value = [
    [
        "CFBundleTypeRole": "Viewer",
        "LSHandlerRank": "None",
        "LSItemContentTypes": [
            "org.openxmlformats.wordprocessingml.document", "net.daringfireball.markdown",
            "public.image", "public.movie", "public.audio",
        ],
        // HWP has no system type to name.
        "CFBundleTypeExtensions": ["hwp", "hwpx"],
    ],
    [
        "CFBundleTypeRole": "Editor",
        "LSHandlerRank": "None",
        "LSItemContentTypes": [
            "com.adobe.pdf", "public.jpeg", "public.png", "public.heic", "public.tiff", "com.compuserve.gif",
            "com.microsoft.bmp", "public.avif", "public.mpeg-4", "com.apple.quicktime-movie",
            "com.apple.m4a-audio", "public.mp3", "com.microsoft.waveform-audio", "public.aiff-audio", "public.html",
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
    // LAME is embedded as a dynamic library in the service's Frameworks folder.
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
    // An app extension can't link a static framework, so it compiles the two ConversionKit files
    // it needs: the same format table the app uses, and the notification's name.
    sources: [
        "FinderSync/Sources/**",
        "../Core/ConversionKit/Sources/Formats.swift",
        "../Core/ConversionKit/Sources/FinderFormatNotification.swift",
    ],
    // Sends paths only; the app reads them through folders the user allowed in Settings.
    entitlements: .dictionary(["com.apple.security.app-sandbox": true]),
    dependencies: [.sdk(name: "FinderSync", type: .framework)],
    settings: .settings(base: Conv.baseSettings)
)

let project = Project(
    name: "App",
    targets: [app, conversionXPC, finderSync]
)
