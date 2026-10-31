import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.module(
    .settingsFeature,
    dependencies: [.designSystem, .platform],
    // Shows whether Finder's menu is on and opens the switch for it.
    externalDependencies: [.sdk(name: "FinderSync", type: .framework)],
    // License texts of the code and fonts Conv ships.
    resources: ["Resources/**"]
)
