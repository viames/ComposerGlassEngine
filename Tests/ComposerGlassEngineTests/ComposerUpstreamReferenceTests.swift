import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer upstream reference")
struct ComposerUpstreamReferenceTests {
  @Test("The public baseline matches the machine-readable repository manifest")
  func matchesRepositoryManifest() throws {
    let manifestURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("COMPOSER-UPSTREAM.json")
    let decoded = try JSONDecoder().decode(
      ComposerUpstreamReference.self,
      from: Data(contentsOf: manifestURL)
    )

    #expect(decoded == .current)
  }

  @Test("The baseline identifies an immutable Composer source revision")
  func identifiesImmutableSourceRevision() {
    let reference = ComposerUpstreamReference.current
    let commitCharacters = CharacterSet(charactersIn: reference.composer.commit)

    #expect(reference.schemaVersion == 1)
    #expect(reference.composer.version == reference.composer.tag)
    #expect(reference.composer.commit.count == 40)
    #expect(commitCharacters.isSubset(of: CharacterSet(charactersIn: "0123456789abcdef")))
    #expect(reference.composer.releaseURL.hasSuffix("/" + reference.composer.tag))
    #expect(!reference.implementedAreas.isEmpty)
    #expect(
      Set(reference.implementedAreas).isDisjoint(
        with: Set(reference.intentionallyUnsupportedAreas)
      )
    )
  }
}
