import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.module(
    .documentEngine,
    dependencies: [.conversionKit],
    externalDependencies: [.external(name: "ZIPFoundation")],
    // Nanum Gothic and Myeongjo (SIL OFL) stand in for Hangul's faces.
    resources: ["Resources/**"]
)
