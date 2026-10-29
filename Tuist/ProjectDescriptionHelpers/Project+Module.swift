import ProjectDescription

public enum Conv {
    public static let bundleIDPrefix = "com.conv"
    public static let deploymentTargets: DeploymentTargets = .macOS("14.0")

    /// Distributed directly (Developer ID, notarized), not through the App Store.
    public static let developmentTeam = "6DXT245L5T"

    public static let baseSettings: SettingsDictionary = [
        "SWIFT_VERSION": "6.0",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "DEAD_CODE_STRIPPING": "YES",
        "DEVELOPMENT_TEAM": .string(developmentTeam),
        // Notarization requires the hardened runtime.
        "ENABLE_HARDENED_RUNTIME": "YES",
    ]
}

extension Project {
    /// A framework module plus its unit test target.
    public static func module(
        _ module: Module,
        dependencies: [Module] = [],
        externalDependencies: [TargetDependency] = [],
        testDependencies: [TargetDependency] = [],
        resources: ResourceFileElements? = nil
    ) -> Project {
        let forbidden = Set(dependencies).subtracting(module.allowedDependencies)
        precondition(
            forbidden.isEmpty,
            "\(module.rawValue) (\(module.layer.rawValue)) must not depend on \(forbidden.map(\.rawValue).sorted())"
        )

        let name = module.rawValue
        let framework = Target.target(
            name: name,
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "\(Conv.bundleIDPrefix).\(name)",
            deploymentTargets: Conv.deploymentTargets,
            sources: ["Sources/**"],
            resources: resources,
            dependencies: dependencies.map { .module($0) } + externalDependencies,
            settings: .settings(base: Conv.baseSettings)
        )
        let tests = Target.target(
            name: "\(name)Tests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "\(Conv.bundleIDPrefix).\(name)Tests",
            deploymentTargets: Conv.deploymentTargets,
            sources: ["Tests/**"],
            dependencies: [.target(name: name)] + testDependencies,
            settings: .settings(base: Conv.baseSettings)
        )
        return Project(
            name: name,
            options: .options(automaticSchemesOptions: .enabled(codeCoverageEnabled: true)),
            targets: [framework, tests]
        )
    }
}
