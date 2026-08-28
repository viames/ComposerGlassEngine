import Foundation

public enum ComposerValidationIssueCode: String, Equatable, Sendable {
  case lockFileMissing
  case lockFileStale
  case missingPackageName
  case invalidPackageName
  case invalidConstraint
  case duplicateRuntimeAndDevelopmentRequirement
  case unsupportedComposerPlugin
}

public struct ComposerValidationIssue: Equatable, Sendable {
  public let code: ComposerValidationIssueCode
  public let field: String?
  public let package: String?
  public let value: String?

  public init(
    code: ComposerValidationIssueCode,
    field: String? = nil,
    package: String? = nil,
    value: String? = nil
  ) {
    self.code = code
    self.field = field
    self.package = package
    self.value = value
  }
}

public struct ComposerNativeValidationResult: Equatable, Sendable {
  public let errors: [ComposerValidationIssue]
  public let warnings: [ComposerValidationIssue]

  public init(errors: [ComposerValidationIssue], warnings: [ComposerValidationIssue]) {
    self.errors = errors
    self.warnings = warnings
  }

  public var isValid: Bool { errors.isEmpty }
}

public struct ComposerNativePackageInfo: Equatable, Sendable {
  public let name: String
  public let version: String
  public let description: String?
  public let type: String?
  public let isDevelopment: Bool
  public let directRequirement: Bool

  public init(
    name: String,
    version: String,
    description: String?,
    type: String?,
    isDevelopment: Bool,
    directRequirement: Bool
  ) {
    self.name = name
    self.version = version
    self.description = description
    self.type = type
    self.isDevelopment = isDevelopment
    self.directRequirement = directRequirement
  }
}

public struct ComposerNativeOutdatedPackage: Equatable, Sendable {
  public let package: ComposerNativePackageInfo
  public let latestVersion: String
  public let latestCompatibleVersion: String?

  public init(
    package: ComposerNativePackageInfo,
    latestVersion: String,
    latestCompatibleVersion: String?
  ) {
    self.package = package
    self.latestVersion = latestVersion
    self.latestCompatibleVersion = latestCompatibleVersion
  }
}

public enum ComposerNativeInspectorError: Error, Equatable, Sendable {
  case composerManifestMissing(URL)
  case composerLockMissing(URL)
}

public actor ComposerNativeInspector {
  private let source: any ComposerPackageSource
  private let fileManager: FileManager

  public init(source: any ComposerPackageSource) {
    self.source = source
    self.fileManager = FileManager()
  }

  public func validate(projectDirectoryURL: URL) throws -> ComposerNativeValidationResult {
    let manifestURL = projectDirectoryURL.appendingPathComponent("composer.json")
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      throw ComposerNativeInspectorError.composerManifestMissing(manifestURL)
    }
    let manifestData = try Data(contentsOf: manifestURL)
    let manifest = try ComposerManifest.decode(from: manifestData)
    var errors: [ComposerValidationIssue] = []
    var warnings: [ComposerValidationIssue] = []

    if let name = manifest.name {
      if !ComposerPackageName.isValid(name) || name != name.lowercased() {
        errors.append(.init(code: .invalidPackageName, field: "name", value: name))
      }
    } else {
      warnings.append(.init(code: .missingPackageName, field: "name"))
    }

    let sections: [ComposerRequirementSection] = [
      .runtime, .development, .conflict, .provide, .replace,
    ]
    for section in sections {
      for (package, value) in try manifest.requirements(in: section).sorted(by: { $0.key < $1.key })
      {
        if !ComposerPackageName.isValid(package) || package != package.lowercased() {
          errors.append(
            .init(code: .invalidPackageName, field: section.rawValue, package: package)
          )
        } else if value != "self.version", (try? ComposerConstraint.parse(value)) == nil {
          errors.append(
            .init(
              code: .invalidConstraint,
              field: section.rawValue,
              package: package,
              value: value
            )
          )
        }
      }
    }
    let runtimeNames = Set(try manifest.requirements().keys)
    let developmentNames = Set(try manifest.requirements(in: .development).keys)
    for package in runtimeNames.intersection(developmentNames).sorted() {
      warnings.append(
        .init(code: .duplicateRuntimeAndDevelopmentRequirement, package: package)
      )
    }

    let lockURL = projectDirectoryURL.appendingPathComponent("composer.lock")
    if !fileManager.fileExists(atPath: lockURL.path) {
      warnings.append(.init(code: .lockFileMissing, field: "composer.lock"))
    } else {
      let lock = try ComposerLockFile.decode(from: Data(contentsOf: lockURL))
      if try !lock.isFresh(for: manifestData) {
        errors.append(.init(code: .lockFileStale, field: "composer.lock"))
      }
      let packages = try lock.packages() + lock.packages(in: .development)
      for package in packages where package.packageType?.lowercased() == "composer-plugin" {
        warnings.append(.init(code: .unsupportedComposerPlugin, package: package.name))
      }
    }
    return ComposerNativeValidationResult(errors: errors, warnings: warnings)
  }

  public func show(projectDirectoryURL: URL) throws -> [ComposerNativePackageInfo] {
    let manifest = try readManifest(in: projectDirectoryURL)
    let lock = try readLock(in: projectDirectoryURL)
    let runtimeRoots = Set(try manifest.requirements().keys)
    let developmentRoots = Set(try manifest.requirements(in: .development).keys)
    let runtime = try lock.packages().map {
      packageInfo($0, development: false, directNames: runtimeRoots)
    }
    let development = try lock.packages(in: .development).map {
      packageInfo($0, development: true, directNames: developmentRoots)
    }
    return (runtime + development).sorted { $0.name < $1.name }
  }

  public func outdated(
    projectDirectoryURL: URL
  ) async throws -> [ComposerNativeOutdatedPackage] {
    let manifest = try readManifest(in: projectDirectoryURL)
    let installed = try show(projectDirectoryURL: projectDirectoryURL)
    let rootConstraints = try manifest.requirements().merging(
      manifest.requirements(in: .development)
    ) { runtime, _ in runtime }
    var result: [ComposerNativeOutdatedPackage] = []
    for package in installed {
      try Task.checkCancellation()
      let versions = try await source.packages(
        named: package.name,
        includeDevelopmentVersions: false
      ).compactMap { metadata -> (ComposerRepositoryPackage, ComposerVersion)? in
        guard let version = try? ComposerVersion(metadata.normalizedVersion ?? metadata.version)
        else {
          return nil
        }
        return (metadata, version)
      }.sorted { $0.1 > $1.1 }
      guard let latest = versions.first, latest.0.version != package.version else {
        continue
      }
      let compatible: String?
      if let rootConstraint = rootConstraints[package.name],
        let constraint = try? ComposerConstraint.parse(rootConstraint)
      {
        compatible = versions.first(where: { constraint.matches($0.1) })?.0.version
      } else {
        compatible = latest.0.version
      }
      result.append(
        ComposerNativeOutdatedPackage(
          package: package,
          latestVersion: latest.0.version,
          latestCompatibleVersion: compatible
        )
      )
    }
    return result.sorted { $0.package.name < $1.package.name }
  }

  private func readManifest(in projectURL: URL) throws -> ComposerManifest {
    let url = projectURL.appendingPathComponent("composer.json")
    guard fileManager.fileExists(atPath: url.path) else {
      throw ComposerNativeInspectorError.composerManifestMissing(url)
    }
    return try ComposerManifest.decode(from: Data(contentsOf: url))
  }

  private func readLock(in projectURL: URL) throws -> ComposerLockFile {
    let url = projectURL.appendingPathComponent("composer.lock")
    guard fileManager.fileExists(atPath: url.path) else {
      throw ComposerNativeInspectorError.composerLockMissing(url)
    }
    return try ComposerLockFile.decode(from: Data(contentsOf: url))
  }

  private func packageInfo(
    _ package: ComposerLockedPackage,
    development: Bool,
    directNames: Set<String>
  ) -> ComposerNativePackageInfo {
    ComposerNativePackageInfo(
      name: package.name,
      version: package.version,
      description: package.packageDescription,
      type: package.packageType,
      isDevelopment: development,
      directRequirement: directNames.contains(package.name)
    )
  }
}
