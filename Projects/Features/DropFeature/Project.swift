import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.module(.dropFeature, dependencies: [.designSystem, .conversionKit, .platform])
