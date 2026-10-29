import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.module(
    .documentEngine,
    dependencies: [.conversionKit],
    externalDependencies: [.external(name: "ZIPFoundation")]
)
