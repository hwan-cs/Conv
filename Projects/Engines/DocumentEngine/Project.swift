import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.module(
    .documentEngine,
    dependencies: [.conversionKit],
    externalDependencies: [.external(name: "ZIPFoundation"), .external(name: "Markdown")],
    // Nanum Gothic and Myeongjo (SIL OFL) stand in for Hangul's faces.
    resources: ["Resources/**"]
)
