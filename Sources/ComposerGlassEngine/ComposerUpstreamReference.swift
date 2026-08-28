import Foundation

/// The immutable upstream release used to define and review the engine's
/// Composer-compatible behavior.
public struct ComposerUpstreamRelease: Codable, Equatable, Sendable {
  public let version: String
  public let releaseDate: String
  public let tag: String
  public let commit: String
  public let repositoryURL: String
  public let releaseURL: String
  public let changelogURL: String

  public init(
    version: String,
    releaseDate: String,
    tag: String,
    commit: String,
    repositoryURL: String,
    releaseURL: String,
    changelogURL: String
  ) {
    self.version = version
    self.releaseDate = releaseDate
    self.tag = tag
    self.commit = commit
    self.repositoryURL = repositoryURL
    self.releaseURL = releaseURL
    self.changelogURL = changelogURL
  }
}

/// Versioned metadata connecting an engine release to the exact Composer
/// source revision used for behavioral compatibility work.
public struct ComposerUpstreamReference: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let engineVersion: String
  public let verifiedOn: String
  public let compatibilityProfile: String
  public let composer: ComposerUpstreamRelease
  public let implementedAreas: [String]
  public let intentionallyUnsupportedAreas: [String]

  public init(
    schemaVersion: Int,
    engineVersion: String,
    verifiedOn: String,
    compatibilityProfile: String,
    composer: ComposerUpstreamRelease,
    implementedAreas: [String],
    intentionallyUnsupportedAreas: [String]
  ) {
    self.schemaVersion = schemaVersion
    self.engineVersion = engineVersion
    self.verifiedOn = verifiedOn
    self.compatibilityProfile = compatibilityProfile
    self.composer = composer
    self.implementedAreas = implementedAreas
    self.intentionallyUnsupportedAreas = intentionallyUnsupportedAreas
  }

  /// Update this value and `COMPOSER-UPSTREAM.json` together whenever the
  /// compatibility baseline moves to another Composer release.
  public static let current = ComposerUpstreamReference(
    schemaVersion: 1,
    engineVersion: "0.1.0",
    verifiedOn: "2026-08-27",
    compatibilityProfile: "app-store-safe-native-subset",
    composer: ComposerUpstreamRelease(
      version: "2.10.2",
      releaseDate: "2026-07-01",
      tag: "2.10.2",
      commit: "8d4439f572a97670a9edc039eb3b093cc976b4bc",
      repositoryURL: "https://github.com/composer/composer",
      releaseURL: "https://github.com/composer/composer/releases/tag/2.10.2",
      changelogURL: "https://github.com/composer/composer/blob/2.10.2/CHANGELOG.md"
    ),
    implementedAreas: [
      "autoload-generation",
      "audit",
      "dependency-resolution",
      "distribution-download-and-extraction",
      "install",
      "lock-generation",
      "manifest-and-lock-formats",
      "packagist-v2-metadata",
      "platform-packages",
      "require-and-remove",
      "update-all-and-selected",
      "validate-show-and-outdated",
      "version-and-constraint-semantics",
    ],
    intentionallyUnsupportedAreas: [
      "artifact-repositories",
      "composer-self-update",
      "path-repositories",
      "plugin-execution",
      "script-execution",
      "source-installations",
    ]
  )
}
