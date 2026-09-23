import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer security advisory client")
struct ComposerSecurityAdvisoryClientTests {
  @Test("Packagist source spelling round trips without losing advisory identity")
  func packagistSourceCoding() throws {
    let source = try JSONDecoder().decode(
      ComposerSecurityAdvisorySource.self,
      from: Data(#"{"name":"GitHub","remoteId":"GHSA-example"}"#.utf8)
    )
    #expect(source.remoteID == "GHSA-example")
    let encoded = try JSONEncoder().encode(source)
    let object = try JSONSerialization.jsonObject(with: encoded) as? [String: String]
    #expect(object?["remoteId"] == "GHSA-example")
    #expect(object?["remoteID"] == nil)
  }
  @Test("Audit retains only advisories affecting installed versions")
  func filtersAdvisoriesByInstalledVersion() async throws {
    let transport = AdvisoryStubTransport(
      responseData: Data(
        #"{"advisories":{"vendor/app":[{"advisoryId":"PKSA-test-1","packageName":"vendor/app","title":"Affected","link":"https://example.com/advisory","cve":"CVE-2026-0001","affectedVersions":"<1.2.0","sources":[{"name":"GitHub","remoteId":"GHSA-test"}],"reportedAt":"2026-01-01T00:00:00+00:00","severity":"high"},{"advisoryId":"PKSA-test-2","packageName":"vendor/app","title":"Not affected","link":null,"cve":null,"affectedVersions":">=2.0.0","sources":[],"reportedAt":null,"severity":null}]}}"#
          .utf8
      )
    )
    let client = try ComposerSecurityAdvisoryClient(transport: transport)
    let lock = try ComposerLockFile(
      contentHash: String(repeating: "0", count: 32),
      packages: [try ComposerLockedPackage(name: "vendor/app", version: "1.1.0")]
    )

    let advisories = try await client.audit(lockFile: lock)

    #expect(advisories.map(\.advisoryID) == ["PKSA-test-1"])
    #expect(advisories.first?.severity == "high")
    #expect(advisories.first?.sources.first?.remoteID == "GHSA-test")
    #expect(await transport.requestedURL()?.query?.contains("packages%5B%5D=vendor/app") == true)
  }

  @Test("Unsupported advisory constraints are reported conservatively")
  func retainsUnsupportedConstraints() async throws {
    let transport = AdvisoryStubTransport(
      responseData: Data(
        #"{"advisories":{"vendor/app":[{"advisoryId":"PKSA-test-3","packageName":"vendor/app","title":"Unknown range","link":null,"cve":null,"affectedVersions":"dev-main","sources":[],"reportedAt":null,"severity":null}]}}"#
          .utf8
      )
    )
    let client = try ComposerSecurityAdvisoryClient(transport: transport)
    let lock = try ComposerLockFile(
      contentHash: String(repeating: "0", count: 32),
      packages: [try ComposerLockedPackage(name: "vendor/app", version: "1.0.0")]
    )

    let advisories = try await client.audit(lockFile: lock)

    #expect(advisories.count == 1)
    #expect(advisories.first?.constraintEvaluationSupported == false)
  }
}

private actor AdvisoryStubTransport: ComposerRepositoryTransport {
  let responseData: Data
  private var requestURL: URL?

  init(responseData: Data) {
    self.responseData = responseData
  }

  func response(for request: URLRequest) async throws -> ComposerHTTPResponse {
    requestURL = request.url
    return ComposerHTTPResponse(
      data: responseData,
      statusCode: 200,
      finalURL: request.url!
    )
  }

  func requestedURL() -> URL? {
    requestURL
  }
}
