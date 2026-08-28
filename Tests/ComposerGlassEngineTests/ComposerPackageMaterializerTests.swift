import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer package materializer")
struct ComposerPackageMaterializerTests {
  @Test("Lock files install exact runtime and development packages")
  func materializesLockFile() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let runtime = try lockedPackage(name: "vendor/runtime", path: "runtime.zip")
    let development = try lockedPackage(name: "vendor/testing", path: "testing.zip")
    let lockFile = try ComposerLockFile(
      contentHash: String(repeating: "0", count: 32),
      packages: [runtime],
      developmentPackages: [development]
    )
    let transport = MaterializerArchiveTransport(payloads: [
      "https://dist.example.test/runtime.zip": makeZIP([
        ZIPTestEntry(name: "runtime/src/Runtime.php", data: Data("runtime".utf8))
      ]),
      "https://dist.example.test/testing.zip": makeZIP([
        ZIPTestEntry(name: "testing/src/Testing.php", data: Data("testing".utf8))
      ]),
    ])
    let materializer = ComposerPackageMaterializer(
      downloader: try ComposerPackageDownloader(
        cacheDirectory: workspace.appendingPathComponent("cache"),
        transport: transport
      )
    )
    let vendorURL = workspace.appendingPathComponent("vendor")

    let result = try await materializer.materialize(lockFile, at: vendorURL)

    #expect(result.packages.map(\.packageName) == ["vendor/runtime", "vendor/testing"])
    #expect(result.packages.map(\.isDevelopment) == [false, true])
    let installed = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(contentsOf: vendorURL.appendingPathComponent("composer/installed.json"))
    )
    let fields = try #require(installed.objectValue)
    #expect(fields["dev"] == .bool(true))
    #expect(fields["dev-package-names"] == .array([.string("vendor/testing")]))
    let packages = try #require(fields["packages"]?.arrayValue)
    let developmentFlags = packages.compactMap(\.objectValue).compactMap {
      $0["dev_requirement"]
    }
    #expect(developmentFlags == [.bool(false), .bool(true)])
  }

  @Test("Lock file installation can exclude development packages")
  func materializesProductionLockFile() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let runtime = try lockedPackage(name: "vendor/runtime", path: "runtime.zip")
    let development = try lockedPackage(name: "vendor/testing", path: "testing.zip")
    let lockFile = try ComposerLockFile(
      contentHash: String(repeating: "0", count: 32),
      packages: [runtime],
      developmentPackages: [development]
    )
    let transport = MaterializerArchiveTransport(payloads: [
      "https://dist.example.test/runtime.zip": makeZIP([
        ZIPTestEntry(name: "runtime/file", data: Data("runtime".utf8))
      ])
    ])
    let materializer = ComposerPackageMaterializer(
      downloader: try ComposerPackageDownloader(
        cacheDirectory: workspace.appendingPathComponent("cache"),
        transport: transport
      )
    )

    let result = try await materializer.materialize(
      lockFile,
      includeDevelopmentPackages: false,
      at: workspace.appendingPathComponent("vendor")
    )

    #expect(result.packages.map(\.packageName) == ["vendor/runtime"])
    #expect(await transport.requestCount == 1)
  }

  @Test("Resolved packages form a deterministic vendor tree with installed metadata")
  func materializesVendorTree() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let packageA = try materializerPackage(name: "vendor/a", path: "a.zip")
    let packageB = try materializerPackage(name: "another/b", path: "b.zip")
    let transport = MaterializerArchiveTransport(payloads: [
      packageA.distURL!.absoluteString: makeZIP([
        ZIPTestEntry(name: "root-a/composer.json", data: Data("{}".utf8)),
        ZIPTestEntry(
          name: "root-a/bin/tool",
          data: Data("tool".utf8),
          unixMode: 0o100755
        ),
      ]),
      packageB.distURL!.absoluteString: makeZIP([
        ZIPTestEntry(name: "root-b/src/B.php", data: Data("B".utf8))
      ]),
    ])
    let downloader = try ComposerPackageDownloader(
      cacheDirectory: workspace.appendingPathComponent("cache"),
      transport: transport
    )
    let materializer = ComposerPackageMaterializer(downloader: downloader)
    let vendorURL = workspace.appendingPathComponent("vendor")

    let result = try await materializer.materialize(
      try resolution(packages: [packageA, packageB]),
      at: vendorURL
    )

    #expect(result.packages.map(\.packageName) == ["another/b", "vendor/a"])
    #expect(
      try Data(contentsOf: vendorURL.appendingPathComponent("another/b/src/B.php"))
        == Data("B".utf8)
    )
    #expect(
      try Data(contentsOf: vendorURL.appendingPathComponent("vendor/a/bin/tool"))
        == Data("tool".utf8)
    )
    let attributes = try FileManager.default.attributesOfItem(
      atPath: vendorURL.appendingPathComponent("vendor/a/bin/tool").path
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    #expect(
      !FileManager.default.fileExists(
        atPath: vendorURL.appendingPathComponent(".composerglass-extraction").path
      )
    )

    let installedURL = vendorURL.appendingPathComponent("composer/installed.json")
    let installed = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(contentsOf: installedURL)
    )
    guard case .object(let fields) = installed,
      case .array(let packages)? = fields["packages"]
    else {
      Issue.record("Expected Composer installed metadata")
      return
    }
    #expect(packages.count == 2)
    #expect(
      packages.compactMap(\.objectValue).compactMap { $0["name"]?.stringValue }
        == ["another/b", "vendor/a"]
    )
    #expect(
      packages.compactMap(\.objectValue).compactMap { $0["install-path"]?.stringValue }
        == ["../another/b", "../vendor/a"]
    )
    #expect(await transport.requestCount == 2)
  }

  @Test("Any package failure rolls back the complete new vendor tree")
  func rollsBackFailedMaterialization() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let packageA = try materializerPackage(name: "vendor/a", path: "a.zip")
    let packageB = try materializerPackage(name: "vendor/b", path: "b.zip")
    let transport = MaterializerArchiveTransport(payloads: [
      packageA.distURL!.absoluteString: makeZIP([
        ZIPTestEntry(name: "root-a/file", data: Data("A".utf8))
      ]),
      packageB.distURL!.absoluteString: Data("not-a-zip".utf8),
    ])
    let materializer = ComposerPackageMaterializer(
      downloader: try ComposerPackageDownloader(
        cacheDirectory: workspace.appendingPathComponent("cache"),
        transport: transport
      )
    )
    let vendorURL = workspace.appendingPathComponent("vendor")

    do {
      _ = try await materializer.materialize(
        try resolution(packages: [packageA, packageB]),
        at: vendorURL
      )
      Issue.record("Expected materialization to fail")
    } catch is ComposerZIPExtractionError {
      #expect(!FileManager.default.fileExists(atPath: vendorURL.path))
    }
  }

  @Test("Unchanged verified packages are cloned without downloading or extracting again")
  func reusesVerifiedPackages() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let package = try lockedPackage(name: "vendor/runtime", path: "runtime.zip")
    let lockFile = try ComposerLockFile(
      contentHash: String(repeating: "0", count: 32),
      packages: [package]
    )
    let payload = makeZIP([
      ZIPTestEntry(name: "runtime/src/Runtime.php", data: Data("runtime".utf8))
    ])
    let transport = MaterializerArchiveTransport(payloads: [
      "https://dist.example.test/runtime.zip": payload
    ])
    let firstMaterializer = ComposerPackageMaterializer(
      downloader: try ComposerPackageDownloader(
        cacheDirectory: workspace.appendingPathComponent("first-cache"),
        transport: transport
      )
    )
    let firstVendorURL = workspace.appendingPathComponent("first-vendor")
    _ = try await firstMaterializer.materialize(lockFile, at: firstVendorURL)
    #expect(await transport.requestCount == 1)

    let secondMaterializer = ComposerPackageMaterializer(
      downloader: try ComposerPackageDownloader(
        cacheDirectory: workspace.appendingPathComponent("second-cache"),
        transport: transport
      )
    )
    let secondVendorURL = workspace.appendingPathComponent("second-vendor")
    let reused = try await secondMaterializer.materialize(
      lockFile,
      at: secondVendorURL,
      reusingPackagesFrom: firstVendorURL
    )

    #expect(reused.packages.map(\.wasReused) == [true])
    #expect(await transport.requestCount == 1)
    #expect(
      try Data(contentsOf: secondVendorURL.appendingPathComponent("vendor/runtime/src/Runtime.php"))
        == Data("runtime".utf8)
    )

    try Data("modified".utf8).write(
      to: firstVendorURL.appendingPathComponent("vendor/runtime/src/Runtime.php")
    )
    let thirdVendorURL = workspace.appendingPathComponent("third-vendor")
    let rebuilt = try await secondMaterializer.materialize(
      lockFile,
      at: thirdVendorURL,
      reusingPackagesFrom: firstVendorURL
    )

    #expect(rebuilt.packages.map(\.wasReused) == [false])
    #expect(await transport.requestCount == 2)
    #expect(
      try Data(contentsOf: thirdVendorURL.appendingPathComponent("vendor/runtime/src/Runtime.php"))
        == Data("runtime".utf8)
    )
  }

  @Test("Package preparation uses bounded concurrency")
  func preparesPackagesConcurrently() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let packages = try (0..<6).map {
      try materializerPackage(name: "vendor/package-\($0)", path: "package-\($0).zip")
    }
    let payloads = Dictionary(uniqueKeysWithValues: packages.map { package in
      (
        package.distURL!.absoluteString,
        makeZIP([
          ZIPTestEntry(
            name: "package/file.php",
            data: Data(package.name.utf8)
          )
        ])
      )
    })
    let transport = MaterializerArchiveTransport(
      payloads: payloads,
      delayNanoseconds: 40_000_000
    )
    let materializer = ComposerPackageMaterializer(
      downloader: try ComposerPackageDownloader(
        cacheDirectory: workspace.appendingPathComponent("cache"),
        transport: transport
      ),
      maximumConcurrentPackages: 3
    )

    _ = try await materializer.materialize(
      try resolution(packages: packages),
      at: workspace.appendingPathComponent("vendor")
    )

    #expect(await transport.maximumConcurrentRequestCount > 1)
    #expect(await transport.maximumConcurrentRequestCount <= 3)
  }

  @Test("Existing destinations and duplicate resolutions fail before downloading")
  func validatesMaterializationDestination() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let package = try materializerPackage(name: "vendor/a", path: "a.zip")
    let transport = MaterializerArchiveTransport(payloads: [:])
    let materializer = ComposerPackageMaterializer(
      downloader: try ComposerPackageDownloader(
        cacheDirectory: workspace.appendingPathComponent("cache"),
        transport: transport
      )
    )
    let existingURL = workspace.appendingPathComponent("existing")
    try FileManager.default.createDirectory(at: existingURL, withIntermediateDirectories: true)

    do {
      _ = try await materializer.materialize(
        try resolution(packages: [package]),
        at: existingURL
      )
      Issue.record("Expected existing destination to fail")
    } catch let error as ComposerPackageMaterializationError {
      #expect(error == .destinationAlreadyExists(existingURL))
    }

    let duplicateURL = workspace.appendingPathComponent("duplicate")
    do {
      _ = try await materializer.materialize(
        try resolution(packages: [package, package]),
        at: duplicateURL
      )
      Issue.record("Expected duplicate package to fail")
    } catch let error as ComposerPackageMaterializationError {
      #expect(error == .duplicatePackage("vendor/a"))
    }
    #expect(!FileManager.default.fileExists(atPath: duplicateURL.path))
    #expect(await transport.requestCount == 0)
  }
}

private actor MaterializerArchiveTransport: ComposerPackageArchiveTransport {
  private let payloads: [String: Data]
  private let delayNanoseconds: UInt64
  private(set) var requestCount = 0
  private(set) var maximumConcurrentRequestCount = 0
  private var activeRequestCount = 0

  init(payloads: [String: Data], delayNanoseconds: UInt64 = 0) {
    self.payloads = payloads
    self.delayNanoseconds = delayNanoseconds
  }

  func download(
    for request: URLRequest,
    maximumBytes: Int64
  ) async throws -> ComposerPackageArchiveHTTPResponse {
    guard let url = request.url, let payload = payloads[url.absoluteString] else {
      throw URLError(.resourceUnavailable)
    }
    requestCount += 1
    activeRequestCount += 1
    maximumConcurrentRequestCount = max(maximumConcurrentRequestCount, activeRequestCount)
    defer { activeRequestCount -= 1 }
    if delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: delayNanoseconds)
    }
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComposerMaterializer-\(UUID().uuidString).download")
    try payload.write(to: temporaryURL)
    return ComposerPackageArchiveHTTPResponse(
      temporaryFileURL: temporaryURL,
      statusCode: 200,
      headers: ["Content-Length": String(payload.count)],
      finalURL: url
    )
  }
}

private func materializerPackage(
  name: String,
  path: String
) throws -> ComposerRepositoryPackage {
  try ComposerRepositoryPackage(
    name: name,
    version: "1.0.0",
    additionalFields: [
      "dist": .object([
        "type": .string("zip"),
        "url": .string("https://dist.example.test/\(path)"),
        "reference": .string(path),
      ])
    ]
  )
}

private func lockedPackage(
  name: String,
  path: String
) throws -> ComposerLockedPackage {
  try ComposerLockedPackage(
    name: name,
    version: "1.0.0",
    fields: [
      "dist": .object([
        "type": .string("zip"),
        "url": .string("https://dist.example.test/\(path)"),
        "reference": .string(path),
      ])
    ]
  )
}

private func resolution(
  packages: [ComposerRepositoryPackage]
) throws -> ComposerResolutionResult {
  ComposerResolutionResult(
    packages: try packages.map {
      ComposerResolvedPackage(
        package: $0,
        parsedVersion: try ComposerVersion($0.version)
      )
    }
  )
}
