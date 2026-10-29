import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.module(
    .settingsFeature,
    dependencies: [.designSystem, .platform],
    // License texts of the code and fonts Conv ships.
    resources: ["Resources/**"]
)
