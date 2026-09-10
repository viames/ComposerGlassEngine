import Foundation

public enum ComposerLockGeneratorError: Error, Equatable, Sendable {
  case resolvedPackageMissing(String)
  case invalidResolvedPackage(String)
}

/// Builds a deterministic `composer.lock` document from a root manifest and a
/// completed native resolution. Repository metadata is preserved so the result
/// can be installed without consulting package metadata again.
public struct ComposerLockGenerator: Sendable {
  public let pluginAPIVersion: String

  public init(
    pluginAPIVersion: String = ComposerUpstreamPlatformVersions.pluginAPI
  ) {
    self.pluginAPIVersion = pluginAPIVersion
  }

  public func generate(
    manifest: ComposerManifest,
    manifestData: Data,
    resolution: ComposerResolutionResult
  ) throws -> ComposerLockFile {
    let resolvedByName = Dictionary(
      uniqueKeysWithValues: resolution.packages.map { ($0.package.name, $0.package) }
    )
    let runtimeNames = try reachablePackageNames(
      from: manifest.requirements(),
      resolvedByName: resolvedByName
    )

    var runtime: [ComposerLockedPackage] = []
    var development: [ComposerLockedPackage] = []
    for resolved in resolution.packages {
      let package = resolved.package
      guard !package.name.isEmpty, !package.version.isEmpty else {
        throw ComposerLockGeneratorError.invalidResolvedPackage(package.name)
      }
      let locked = try ComposerLockedPackage(
        name: package.name,
        version: package.version,
        fields: package.fields
      )
      if runtimeNames.contains(package.name) {
        runtime.append(locked)
      } else {
        development.append(locked)
      }
    }

    let runtimeRequirements = try manifest.requirements()
    let developmentRequirements = try manifest.requirements(in: .development)
    var fields: [String: JSONValue] = [
      "_readme": .array([
        .string("This file locks the dependencies of your project to a known state."),
        .string("This file was generated automatically by ComposerGlassEngine."),
      ]),
      "aliases": .array(
        resolution.aliases.map { alias in
          .object([
            "package": .string(alias.package),
            "version": .string(alias.version),
            "alias": .string(alias.alias),
            "alias_normalized": .string(alias.normalizedAlias),
          ])
        }
      ),
      "minimum-stability": .string(manifest.minimumStability ?? "stable"),
      "stability-flags": .object(
        stabilityFlags(in: runtimeRequirements.merging(developmentRequirements) { _, new in new })
      ),
      "prefer-stable": .bool(manifest.preferStable ?? false),
      "prefer-lowest": .bool(false),
      "platform": .object(platformRequirements(in: runtimeRequirements)),
      "platform-dev": .object(platformRequirements(in: developmentRequirements)),
      "plugin-api-version": .string(pluginAPIVersion),
    ]

    if case .object(let config)? = manifest["config"], let platform = config["platform"] {
      fields["platform-overrides"] = platform
    }

    return try ComposerLockFile(
      contentHash: ComposerContentHash.compute(from: manifestData),
      packages: runtime,
      developmentPackages: development,
      fields: fields
    )
  }

  private func reachablePackageNames(
    from rootRequirements: [String: String],
    resolvedByName: [String: ComposerRepositoryPackage]
  ) throws -> Set<String> {
    var reachable = Set<String>()
    var pending = rootRequirements.keys
      .filter { !ComposerPlatformPackage.isPlatformName($0) }
      .sorted()

    while let requiredName = pending.first {
      pending.removeFirst()
      let package: ComposerRepositoryPackage
      if let direct = resolvedByName[requiredName] {
        package = direct
      } else if let provider = resolvedByName.values.sorted(by: { $0.name < $1.name }).first(
        where: {
          ((try? $0.provides()) ?? [:])[requiredName] != nil
            || ((try? $0.replaces()) ?? [:])[requiredName] != nil
        })
      {
        package = provider
      } else {
        throw ComposerLockGeneratorError.resolvedPackageMissing(requiredName)
      }
      guard reachable.insert(package.name).inserted else {
        continue
      }
      let dependencies = try package.requirements().keys
        .filter { !ComposerPlatformPackage.isPlatformName($0) }
        .sorted()
      pending.append(contentsOf: dependencies)
    }
    return reachable
  }

  private func platformRequirements(in requirements: [String: String]) -> [String: JSONValue] {
    requirements.reduce(into: [:]) { result, requirement in
      if ComposerPlatformPackage.isPlatformName(requirement.key) {
        result[requirement.key] = .string(requirement.value)
      }
    }
  }

  private func stabilityFlags(in requirements: [String: String]) -> [String: JSONValue] {
    requirements.reduce(into: [:]) { result, requirement in
      guard let value = Self.stabilityFlagValue(in: requirement.value) else {
        return
      }
      result[requirement.key] = .number(Double(value))
    }
  }

  private static func stabilityFlagValue(in constraint: String) -> Int? {
    guard let marker = constraint.lastIndex(of: "@") else {
      return nil
    }
    switch constraint[constraint.index(after: marker)...].lowercased() {
    case "stable": return 0
    case "rc": return 5
    case "beta": return 10
    case "alpha": return 15
    case "dev": return 20
    default: return nil
    }
  }
}
