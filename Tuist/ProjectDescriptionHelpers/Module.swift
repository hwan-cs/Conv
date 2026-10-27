import ProjectDescription

/// Every framework module in Conv, grouped by layer.
/// Dependencies may only point downward; `Project.module` enforces this at generate time.
public enum Module: String, CaseIterable, Sendable {
    // Core
    case designSystem = "DesignSystem"
    case conversionKit = "ConversionKit"
    case platform = "Platform"

    // Engines
    case imageEngine = "ImageEngine"
    case pdfEngine = "PDFEngine"
    case documentEngine = "DocumentEngine"
    case hwpEngine = "HWPEngine"
    case mediaEngine = "MediaEngine"

    // Features
    case dropFeature = "DropFeature"
    case menuBarFeature = "MenuBarFeature"
    case settingsFeature = "SettingsFeature"

    public enum Layer: String, Sendable {
        case core = "Core"
        case engine = "Engines"
        case feature = "Features"
    }

    public var layer: Layer {
        switch self {
        case .designSystem, .conversionKit, .platform:
            return .core
        case .imageEngine, .pdfEngine, .documentEngine, .hwpEngine, .mediaEngine:
            return .engine
        case .dropFeature, .menuBarFeature, .settingsFeature:
            return .feature
        }
    }

    public var path: Path {
        .relativeToRoot("Projects/\(layer.rawValue)/\(rawValue)")
    }

    /// Modules this module is allowed to depend on.
    var allowedDependencies: Set<Module> {
        switch layer {
        case .core:
            // Platform may record conversions, so it can see ConversionKit.
            return self == .platform ? [.conversionKit] : []
        case .engine:
            return [.conversionKit]
        case .feature:
            return [.designSystem, .conversionKit, .platform]
        }
    }
}

extension TargetDependency {
    public static func module(_ module: Module) -> TargetDependency {
        .project(target: module.rawValue, path: module.path)
    }
}
