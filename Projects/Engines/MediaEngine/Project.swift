import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.module(
    .mediaEngine,
    dependencies: [.conversionKit],
    // LAME 3.100 (LGPL), linked dynamically; rebuilt by Vendor/build-lame.sh.
    externalDependencies: [.xcframework(path: "Vendor/LAME.xcframework")]
)
