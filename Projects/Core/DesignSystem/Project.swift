import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.module(
    .designSystem,
    testDependencies: [.external(name: "SnapshotTesting")],
    resources: ["Resources/**"]
)
