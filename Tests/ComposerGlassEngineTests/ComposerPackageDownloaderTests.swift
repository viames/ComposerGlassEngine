import CryptoKit
import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer package downloader")
struct ComposerPackageDownloaderTests {
  @Test("A verified ZIP is cached and reused without another request")
  func downloadsAndReusesVerifiedArchive() async throws {
    let payload = Data("composer-archive".utf8)
    let cacheDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let transport = StubArchiveTransport(payload: payload)
    let package = try downloadPackage(
      checksum: Insecure.SHA1.hash(data: payload).hexadecimalString
    )
    let downloader = try ComposerPackageDownloader(
      cacheDirectory: cacheDirectory,
      transport: transport,
      limits: ComposerPackageDownloadLimits(maximumArchiveBytes: 1_024)
    )

    let downloaded = try await downloader.archive(for: package)
    let cached = try await downloader.archive(for: package)

    #expect(!downloaded.wasCached)
    #expect(cached.wasCached)
    #expect(downloaded.fileURL == cached.fileURL)
    #expect(downloaded.byteCount == Int64(payload.count))
    #expect(try Data(contentsOf: downloaded.fileURL) == payload)
    #expect(await transport.requestCount == 1)
    #expect(await transport.maximumBytes == 1_024)
    #expect(
      await transport.lastRequest?.value(forHTTPHeaderField: "Accept")
        == "application/zip, application/octet-stream"
    )
  }

  @Test("A checksum mismatch never enters the cache")
  func rejectsChecksumMismatch() async throws {
    let cacheDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let payload = Data("unexpected".utf8)
    let transport = StubArchiveTransport(payload: payload)
    let expected = String(repeating: "a", count: 40)
    let package = try downloadPackage(checksum: expected)
    let downloader = try ComposerPackageDownloader(
      cacheDirectory: cacheDirectory,
      transport: transport
    )

    let error = await downloadError(from: downloader, package: package)

    #expect(
      error
        == .checksumMismatch(
          expected: expected,
          actual: Insecure.SHA1.hash(data: payload).hexadecimalString
        )
    )
    #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).isEmpty)
  }

  @Test("Distribution and redirect URLs must remain HTTPS")
  func rejectsInsecureURLs() async throws {
    let cacheDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let transport = StubArchiveTransport(payload: Data("archive".utf8))
    let insecureURL = try #require(URL(string: "http://dist.example.test/package.zip"))
    let insecurePackage = try downloadPackage(url: insecureURL)
    let downloader = try ComposerPackageDownloader(
      cacheDirectory: cacheDirectory,
      transport: transport
    )

    #expect(
      await downloadError(from: downloader, package: insecurePackage) == .insecureURL(insecureURL))
    #expect(await transport.requestCount == 0)

    let securePackage = try downloadPackage()
    await transport.setFinalURL(insecureURL)
    #expect(
      await downloadError(from: downloader, package: securePackage) == .insecureURL(insecureURL))
  }

  @Test("Declared and observed archive sizes enforce the configured limit")
  func enforcesArchiveSizeLimit() async throws {
    let cacheDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let package = try downloadPackage()

    let declaredTransport = StubArchiveTransport(
      payload: Data("tiny".utf8),
      headers: ["Content-Length": "100"]
    )
    let declaredDownloader = try ComposerPackageDownloader(
      cacheDirectory: cacheDirectory.appendingPathComponent("declared"),
      transport: declaredTransport,
      limits: ComposerPackageDownloadLimits(maximumArchiveBytes: 10)
    )
    #expect(
      await downloadError(from: declaredDownloader, package: package)
        == .archiveTooLarge(limit: 10, actual: 100)
    )

    let actualTransport = StubArchiveTransport(payload: Data(repeating: 0x41, count: 11))
    let actualDownloader = try ComposerPackageDownloader(
      cacheDirectory: cacheDirectory.appendingPathComponent("actual"),
      transport: actualTransport,
      limits: ComposerPackageDownloadLimits(maximumArchiveBytes: 10)
    )
    #expect(
      await downloadError(from: actualDownloader, package: package)
        == .archiveTooLarge(limit: 10, actual: 11)
    )
  }

  @Test("A modified cached archive is reported instead of being trusted")
  func detectsCorruptedCache() async throws {
    let cacheDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let transport = StubArchiveTransport(payload: Data("archive".utf8))
    let package = try downloadPackage()
    let downloader = try ComposerPackageDownloader(
      cacheDirectory: cacheDirectory,
      transport: transport
    )
    let first = try await downloader.archive(for: package)
    try Data("modified".utf8).write(to: first.fileURL)

    let error = await downloadError(from: downloader, package: package)

    #expect(error == .corruptedCache(first.fileURL))
    #expect(await transport.requestCount == 1)
  }

  @Test("HTTP failures do not leave temporary package files in the cache")
  func rejectsUnexpectedStatus() async throws {
    let cacheDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let transport = StubArchiveTransport(
      payload: Data("not-found".utf8),
      statusCode: 404
    )
    let downloader = try ComposerPackageDownloader(
      cacheDirectory: cacheDirectory,
      transport: transport
    )

    #expect(
      await downloadError(from: downloader, package: try downloadPackage())
        == .unexpectedStatus(404)
    )
    #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).isEmpty)
  }

  @Test("Malformed checksums and unsupported archive types fail before networking")
  func validatesDistributionMetadata() async throws {
    let cacheDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let transport = StubArchiveTransport(payload: Data("archive".utf8))
    let downloader = try ComposerPackageDownloader(
      cacheDirectory: cacheDirectory,
      transport: transport
    )

    let malformed = try downloadPackage(checksum: "not-a-sha1")
    #expect(
      await downloadError(from: downloader, package: malformed)
        == .invalidChecksumMetadata("not-a-sha1")
    )

    let tarPackage = try downloadPackage(type: "tar")
    #expect(
      await downloadError(from: downloader, package: tarPackage)
        == .unsupportedDistributionType("tar")
    )
    #expect(await transport.requestCount == 0)
  }

  @Test("Distribution metadata exposes type, reference, and checksum")
  func exposesDistributionMetadata() throws {
    let package = try downloadPackage(checksum: String(repeating: "b", count: 40))

    #expect(package.distType == "zip")
    #expect(package.distReference == "reference-123")
    #expect(package.distChecksum == String(repeating: "b", count: 40))
  }
}

private actor StubArchiveTransport: ComposerPackageArchiveTransport {
  private let payload: Data
  private let statusCode: Int
  private let headers: [String: String]
  private var configuredFinalURL: URL
  private(set) var requestCount = 0
  private(set) var lastRequest: URLRequest?
  private(set) var maximumBytes: Int64?

  init(
    payload: Data,
    statusCode: Int = 200,
    headers: [String: String] = [:],
    finalURL: URL = URL(string: "https://dist.example.test/package.zip")!
  ) {
    self.payload = payload
    self.statusCode = statusCode
    self.headers = headers
    self.configuredFinalURL = finalURL
  }

  func download(
    for request: URLRequest,
    maximumBytes: Int64
  ) async throws -> ComposerPackageArchiveHTTPResponse {
    requestCount += 1
    lastRequest = request
    self.maximumBytes = maximumBytes
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComposerGlassEngine-\(UUID().uuidString).download")
    try payload.write(to: temporaryURL)
    return ComposerPackageArchiveHTTPResponse(
      temporaryFileURL: temporaryURL,
      statusCode: statusCode,
      headers: headers,
      finalURL: configuredFinalURL
    )
  }

  func setFinalURL(_ url: URL) {
    configuredFinalURL = url
  }
}

private func downloadPackage(
  url: URL = URL(string: "https://dist.example.test/package.zip")!,
  type: String = "zip",
  checksum: String? = nil
) throws -> ComposerRepositoryPackage {
  var distribution: [String: JSONValue] = [
    "type": .string(type),
    "url": .string(url.absoluteString),
    "reference": .string("reference-123"),
  ]
  distribution["shasum"] = checksum.map(JSONValue.string)
  return try ComposerRepositoryPackage(
    name: "vendor/package",
    version: "1.2.3",
    additionalFields: ["dist": .object(distribution)]
  )
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("ComposerGlassEngineTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func downloadError(
  from downloader: ComposerPackageDownloader,
  package: ComposerRepositoryPackage
) async -> ComposerPackageDownloadError? {
  do {
    _ = try await downloader.archive(for: package)
    Issue.record("Expected package download to fail")
    return nil
  } catch let error as ComposerPackageDownloadError {
    return error
  } catch {
    Issue.record("Unexpected error: \(error)")
    return nil
  }
}

extension Digest {
  fileprivate var hexadecimalString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
