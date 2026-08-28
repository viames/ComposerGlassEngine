import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer repository client")
struct ComposerRepositoryClientTests {
  @Test("A regular Composer 2 response is decoded without losing metadata")
  func decodesRegularResponse() async throws {
    let transport = StubRepositoryTransport(responses: [
      repositoryResponse(
        #"{"metadata-url":"/p2/%package%.json"}"#,
        url: "https://repo.example.test/packages.json"
      ),
      repositoryResponse(
        #"""
        {
          "packages": {
            "vendor/package": [
              {
                "name": "vendor/package",
                "version": "1.2.3",
                "version_normalized": "1.2.3.0",
                "require": {"php": "^8.3"},
                "dist": {"type": "zip", "url": "https://dist.example.test/package.zip"},
                "custom": {"retained": true}
              }
            ]
          }
        }
        """#,
        url: "https://repo.example.test/p2/vendor/package.json"
      ),
    ])
    let client = try ComposerRepositoryClient(
      repositoryURL: #require(URL(string: "https://repo.example.test")),
      transport: transport
    )

    let packages = try await client.packages(named: "vendor/package")
    let package = try #require(packages.first)

    #expect(packages.count == 1)
    #expect(package.version == "1.2.3")
    #expect(package.normalizedVersion == "1.2.3.0")
    #expect(try package.requirements()["php"] == "^8.3")
    #expect(package.distURL?.absoluteString == "https://dist.example.test/package.zip")
    #expect(package["custom"] == JSONValue.object(["retained": .bool(true)]))

    let requests = await transport.recordedRequests()
    #expect(
      requests.map { $0.url?.absoluteString } == [
        "https://repo.example.test/packages.json",
        "https://repo.example.test/p2/vendor/package.json",
      ])
  }

  @Test("Inline package metadata is available without a p2 request")
  func decodesInlinePackages() async throws {
    let transport = StubRepositoryTransport(responses: [
      repositoryResponse(
        #"""
        {
          "packages": {
            "vendor/package": {
              "2.0.0": {"name": "vendor/package", "version": "2.0.0"},
              "1.0.0": {"name": "vendor/package", "version": "1.0.0"}
            }
          }
        }
        """#,
        url: "https://repo.example.test/packages.json"
      )
    ])
    let client = try ComposerRepositoryClient(
      repositoryURL: #require(URL(string: "https://repo.example.test")),
      transport: transport
    )

    let packages = try await client.packages(named: "vendor/package")

    #expect(packages.map { $0.version } == ["1.0.0", "2.0.0"])
    #expect(await transport.recordedRequests().count == 1)
  }

  @Test("Minified metadata inherits, changes, and unsets fields")
  func expandsMinifiedMetadata() async throws {
    let transport = StubRepositoryTransport(responses: [
      repositoryResponse(
        #"{"metadata-url":"/p2/%package%.json"}"#,
        url: "https://repo.example.test/packages.json"
      ),
      repositoryResponse(
        #"""
        {
          "minified": "composer/2.0",
          "packages": {
            "vendor/package": [
              {
                "name": "vendor/package",
                "version": "2.0.0",
                "version_normalized": "2.0.0.0",
                "require": {"php": "^8.3"},
                "type": "library"
              },
              {
                "version": "1.0.0",
                "version_normalized": "1.0.0.0",
                "require": "__unset"
              }
            ]
          }
        }
        """#,
        url: "https://repo.example.test/p2/vendor/package.json"
      ),
    ])
    let client = try ComposerRepositoryClient(
      repositoryURL: #require(URL(string: "https://repo.example.test")),
      transport: transport
    )

    let packages = try await client.packages(named: "vendor/package")

    #expect(packages.map { $0.version } == ["2.0.0", "1.0.0"])
    #expect(packages[1].name == "vendor/package")
    #expect(packages[1].packageType == "library")
    #expect(try packages[1].requirements().isEmpty)
  }

  @Test("Last-Modified metadata is revalidated with the cached response")
  func revalidatesCachedMetadata() async throws {
    let packageJSON =
      #"{"packages":{"vendor/package":[{"name":"vendor/package","version":"1.0.0"}]}}"#
    let transport = StubRepositoryTransport(responses: [
      repositoryResponse(
        #"{"metadata-url":"/p2/%package%.json"}"#,
        url: "https://repo.example.test/packages.json"
      ),
      repositoryResponse(
        packageJSON,
        url: "https://repo.example.test/p2/vendor/package.json",
        headers: ["Last-Modified": "Wed, 27 Aug 2026 09:00:00 GMT"]
      ),
      repositoryResponse(
        "",
        url: "https://repo.example.test/p2/vendor/package.json",
        statusCode: 304
      ),
    ])
    let client = try ComposerRepositoryClient(
      repositoryURL: #require(URL(string: "https://repo.example.test")),
      transport: transport
    )

    _ = try await client.packages(named: "vendor/package")
    let cachedPackages = try await client.packages(named: "vendor/package")

    #expect(cachedPackages.map { $0.version } == ["1.0.0"])
    let requests = await transport.recordedRequests()
    #expect(
      requests.last?.value(forHTTPHeaderField: "If-Modified-Since")
        == "Wed, 27 Aug 2026 09:00:00 GMT"
    )
  }

  @Test("Fresh metadata can be reused without another network request")
  func reusesFreshCachedMetadata() async throws {
    let transport = StubRepositoryTransport(responses: [
      repositoryResponse(
        #"{"metadata-url":"/p2/%package%.json"}"#,
        url: "https://repo.example.test/packages.json"
      ),
      repositoryResponse(
        #"{"packages":{"vendor/package":[{"name":"vendor/package","version":"1.0.0"}]}}"#,
        url: "https://repo.example.test/p2/vendor/package.json"
      ),
    ])
    let client = try ComposerRepositoryClient(
      repositoryURL: #require(URL(string: "https://repo.example.test")),
      transport: transport,
      metadataCacheValidityInterval: 300
    )

    _ = try await client.packages(named: "vendor/package")
    let cachedPackages = try await client.packages(named: "vendor/package")

    #expect(cachedPackages.map(\.version) == ["1.0.0"])
    #expect(await transport.recordedRequests().count == 2)
  }

  @Test("Fresh metadata persists across repository client instances")
  func persistsFreshMetadata() async throws {
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ComposerRepositoryClientTests-" + UUID().uuidString,
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: cache) }
    let index = repositoryResponse(
      #"{"metadata-url":"/p2/%package%.json"}"#,
      url: "https://repo.example.test/packages.json"
    )
    let firstTransport = StubRepositoryTransport(responses: [
      index,
      repositoryResponse(
        #"{"packages":{"vendor/package":[{"name":"vendor/package","version":"1.0.0"}]}}"#,
        url: "https://repo.example.test/p2/vendor/package.json"
      ),
    ])
    let first = try ComposerRepositoryClient(
      repositoryURL: #require(URL(string: "https://repo.example.test")),
      transport: firstTransport,
      metadataCacheValidityInterval: 300,
      cacheDirectoryURL: cache
    )
    _ = try await first.packages(named: "vendor/package")

    let secondTransport = StubRepositoryTransport(responses: [index])
    let second = try ComposerRepositoryClient(
      repositoryURL: #require(URL(string: "https://repo.example.test")),
      transport: secondTransport,
      metadataCacheValidityInterval: 300,
      cacheDirectoryURL: cache
    )
    let packages = try await second.packages(named: "vendor/package")

    #expect(packages.map(\.version) == ["1.0.0"])
    #expect(await secondTransport.recordedRequests().count == 1)
  }

  @Test("Development metadata uses the Composer tilde-dev endpoint")
  func loadsDevelopmentVersions() async throws {
    let transport = StubRepositoryTransport(responses: [
      repositoryResponse(
        #"{"metadata-url":"p2/%package%.json"}"#,
        url: "https://repo.example.test/private/packages.json"
      ),
      repositoryResponse(
        #"{"packages":{"vendor/package":[{"name":"vendor/package","version":"1.0.0"}]}}"#,
        url: "https://repo.example.test/private/p2/vendor/package.json"
      ),
      repositoryResponse(
        #"{"packages":{"vendor/package":[{"name":"vendor/package","version":"dev-main"}]}}"#,
        url: "https://repo.example.test/private/p2/vendor/package~dev.json"
      ),
    ])
    let client = try ComposerRepositoryClient(
      repositoryURL: #require(URL(string: "https://repo.example.test/private")),
      transport: transport
    )

    let packages = try await client.packages(
      named: "vendor/package",
      includeDevelopmentVersions: true
    )

    #expect(packages.map { $0.version } == ["1.0.0", "dev-main"])
    let requests = await transport.recordedRequests()
    #expect(requests.last?.url?.absoluteString.hasSuffix("package~dev.json") == true)
  }

  @Test("Available package patterns avoid unnecessary requests")
  func skipsUnavailablePackages() async throws {
    let transport = StubRepositoryTransport(responses: [
      repositoryResponse(
        #"{"metadata-url":"/p2/%package%.json","available-package-patterns":["internal/*"]}"#,
        url: "https://repo.example.test/packages.json"
      )
    ])
    let client = try ComposerRepositoryClient(
      repositoryURL: #require(URL(string: "https://repo.example.test")),
      transport: transport
    )

    let packages = try await client.packages(named: "public/package")

    #expect(packages.isEmpty)
    #expect(await transport.recordedRequests().count == 1)

    let index = try await client.loadIndex()
    #expect(index.mayContain(package: "internal/package"))
    #expect(!index.mayContain(package: "public/package"))
  }

  @Test("A package metadata 404 represents an absent package")
  func handlesMissingPackage() async throws {
    let transport = StubRepositoryTransport(responses: [
      repositoryResponse(
        #"{"metadata-url":"/p2/%package%.json"}"#,
        url: "https://repo.example.test/packages.json"
      ),
      repositoryResponse(
        "",
        url: "https://repo.example.test/p2/vendor/missing.json",
        statusCode: 404
      ),
    ])
    let client = try ComposerRepositoryClient(
      repositoryURL: #require(URL(string: "https://repo.example.test")),
      transport: transport
    )

    #expect(try await client.packages(named: "vendor/missing").isEmpty)
    #expect(try await client.packages(named: "vendor/missing").isEmpty)
    #expect(await transport.recordedRequests().count == 2)
  }

  @Test("Repository and redirect URLs must remain HTTPS")
  func rejectsInsecureURLs() async throws {
    let insecureURL = try #require(URL(string: "http://repo.example.test"))
    #expect(throws: ComposerRepositoryError.insecureURL(insecureURL)) {
      try ComposerRepositoryClient(repositoryURL: insecureURL)
    }

    let transport = StubRepositoryTransport(responses: [
      repositoryResponse(
        #"{"metadata-url":"/p2/%package%.json"}"#,
        url: "http://repo.example.test/packages.json"
      )
    ])
    let client = try ComposerRepositoryClient(
      repositoryURL: #require(URL(string: "https://repo.example.test")),
      transport: transport
    )

    let redirectedURL = try #require(
      URL(string: "http://repo.example.test/packages.json")
    )
    await #expect(throws: ComposerRepositoryError.insecureURL(redirectedURL)) {
      try await client.loadIndex()
    }
  }

}

private func repositoryResponse(
  _ body: String,
  url: String,
  statusCode: Int = 200,
  headers: [String: String] = [:]
) -> ComposerHTTPResponse {
  ComposerHTTPResponse(
    data: Data(body.utf8),
    statusCode: statusCode,
    headers: headers,
    finalURL: URL(string: url)!
  )
}

private enum StubRepositoryTransportError: Error {
  case missingResponse
}

private actor StubRepositoryTransport: ComposerRepositoryTransport {
  private var responses: [ComposerHTTPResponse]
  private var requests: [URLRequest] = []

  init(responses: [ComposerHTTPResponse]) {
    self.responses = responses
  }

  func response(for request: URLRequest) async throws -> ComposerHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else {
      throw StubRepositoryTransportError.missingResponse
    }
    return responses.removeFirst()
  }

  func recordedRequests() -> [URLRequest] {
    requests
  }
}
