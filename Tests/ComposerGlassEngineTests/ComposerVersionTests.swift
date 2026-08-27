import Testing

@testable import ComposerGlassEngine

@Suite("Composer version")
struct ComposerVersionTests {
  @Test("Numeric components are normalized")
  func normalizesNumericComponents() throws {
    let version = try ComposerVersion("v2.4")

    #expect(version.major == 2)
    #expect(version.minor == 4)
    #expect(version.patch == 0)
    #expect(version.build == 0)
  }

  @Test("Stability follows Composer ordering")
  func comparesStability() throws {
    let development = try ComposerVersion("1.0.0-dev")
    let alpha = try ComposerVersion("1.0.0-alpha2")
    let beta = try ComposerVersion("1.0.0-beta1")
    let releaseCandidate = try ComposerVersion("1.0.0-RC1")
    let stable = try ComposerVersion("1.0.0")

    #expect(development < alpha)
    #expect(alpha < beta)
    #expect(beta < releaseCandidate)
    #expect(releaseCandidate < stable)
  }

  @Test("Build metadata does not affect precedence")
  func ignoresBuildMetadata() throws {
    #expect(try ComposerVersion("1.2.3+one") == ComposerVersion("1.2.3+two"))
  }

  @Test("Branches are explicit unsupported input")
  func rejectsBranchVersions() {
    #expect(throws: ComposerVersionError.unsupportedBranch("dev-main")) {
      try ComposerVersion("dev-main")
    }
  }
}
