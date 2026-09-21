import Testing

@testable import ComposerGlassEngine

@Suite("Composer constraints")
struct ComposerConstraintTests {
  @Test(arguments: [
    ("^1.2.3", "1.9.0", true),
    ("^1.2.3", "2.0.0", false),
    ("^0.2.3", "0.2.9", true),
    ("^0.2.3", "0.3.0", false),
    ("^0", "0.9.0", true),
    ("^0", "1.0.0", false),
    ("^0.0", "0.0.99", true),
    ("^0.0", "0.1.0", false),
    ("~1.2.3", "1.2.99", true),
    ("~1.2.3", "1.3.0", false),
    ("~1.2", "1.9.0", true),
    ("~1.2", "2.0.0", false),
    ("1.2.*", "1.2.99", true),
    ("1.2.*", "1.3.0", false),
    (">=1.0 <2.0", "1.8.0", true),
    (">=1.0 <2.0", "2.0.0", false),
    (">= 5.3.0", "5.3.0", true),
    (">= 5.3.0", "5.2.9", false),
    ("1.0 - 2.0", "2.0.9", true),
    ("1.0 - 2.0", "2.1.0", false),
    ("^2.0 || ^3.0", "3.4.5", true),
    ("^2.0 || ^3.0", "4.0.0", false),
    ("^3.0@beta", "3.1.0", true),
    ("^1.0", "1.0.0-beta1", true),
    ("^1.0", "2.0.0-beta1", false),
    (">=1.0", "1.0.0-beta1", true),
    ("<2.0", "2.0.0-beta1", false),
    ("1.2.*", "1.2.0-beta1", true),
  ])
  func matchesExpectedResult(
    _ constraintText: String,
    _ versionText: String,
    _ expected: Bool
  ) throws {
    let constraint = try ComposerConstraint.parse(constraintText)
    let version = try ComposerVersion(versionText)

    #expect(constraint.matches(version) == expected)
  }

  @Test("Malformed OR expressions are rejected")
  func rejectsMalformedOr() {
    #expect(throws: ComposerConstraintError.self) {
      try ComposerConstraint.parse("^1.0 ||")
    }
  }

  @Test("Numeric development aliases and inline aliases are accepted")
  func acceptsDevelopmentAliases() throws {
    let version = ComposerVersion(
      major: 1,
      minor: 2,
      patch: 9_999_999,
      build: 9_999_999,
      stability: .development
    )

    #expect(try ComposerConstraint.parse("1.2.x-dev").matches(version))
    #expect(try ComposerConstraint.parse("dev-main as 1.2.x-dev").matches(version))
  }
}
