import CryptoKit
import Foundation

public enum ComposerPackageDownloadError: Error, Equatable, Sendable {
  case invalidCacheDirectory(URL)
  case missingDistributionURL(package: String, version: String)
  case insecureURL(URL)
  case unsupportedDistributionType(String?)
  case invalidChecksumMetadata(String)
  case invalidResponse
  case unexpectedStatus(Int)
  case archiveTooLarge(limit: Int64, actual: Int64?)
  case checksumMismatch(expected: String, actual: String)
  case corruptedCache(URL)
}

public struct ComposerPackageDownloadLimits: Equatable, Sendable {
  public let maximumArchiveBytes: Int64

  public init(maximumArchiveBytes: Int64 = 512 * 1_024 * 1_024) {
    self.maximumArchiveBytes = max(1, maximumArchiveBytes)
  }
}

public struct ComposerPackageArchiveHTTPResponse: Sendable {
  public let temporaryFileURL: URL
  public let statusCode: Int
  public let headers: [String: String]
  public let finalURL: URL

  public init(
    temporaryFileURL: URL,
    statusCode: Int,
    headers: [String: String] = [:],
    finalURL: URL
  ) {
    self.temporaryFileURL = temporaryFileURL
    self.statusCode = statusCode
    self.headers = headers.reduce(into: [:]) { result, item in
      result[item.key.lowercased()] = item.value
    }
    self.finalURL = finalURL
  }

  public func header(named name: String) -> String? {
    headers[name.lowercased()]
  }
}

public protocol ComposerPackageArchiveTransport: Sendable {
  func download(
    for request: URLRequest,
    maximumBytes: Int64
  ) async throws -> ComposerPackageArchiveHTTPResponse
}

public struct URLSessionComposerPackageArchiveTransport: ComposerPackageArchiveTransport {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func download(
    for request: URLRequest,
    maximumBytes: Int64
  ) async throws
    -> ComposerPackageArchiveHTTPResponse
  {
    let delegate = ComposerDownloadLimitDelegate(maximumBytes: maximumBytes)
    let temporaryFileURL: URL
    let response: URLResponse
    do {
      (temporaryFileURL, response) = try await session.download(
        for: request,
        delegate: delegate
      )
    } catch {
      if let actual = delegate.exceededByteCount {
        throw ComposerPackageDownloadError.archiveTooLarge(
          limit: maximumBytes,
          actual: actual
        )
      }
      throw error
    }
    guard let response = response as? HTTPURLResponse, let finalURL = response.url else {
      throw ComposerPackageDownloadError.invalidResponse
    }
    let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
      guard let name = item.key as? String else {
        return
      }
      result[name] = String(describing: item.value)
    }
    return ComposerPackageArchiveHTTPResponse(
      temporaryFileURL: temporaryFileURL,
      statusCode: response.statusCode,
      headers: headers,
      finalURL: finalURL
    )
  }
}

public struct ComposerDownloadedPackageArchive: Equatable, Sendable {
  public let packageName: String
  public let version: String
  public let fileURL: URL
  public let sha256: String
  public let byteCount: Int64
  public let wasCached: Bool

  public init(
    packageName: String,
    version: String,
    fileURL: URL,
    sha256: String,
    byteCount: Int64,
    wasCached: Bool
  ) {
    self.packageName = packageName
    self.version = version
    self.fileURL = fileURL
    self.sha256 = sha256
    self.byteCount = byteCount
    self.wasCached = wasCached
  }
}

/// Downloads ZIP distributions into a verified persistent cache without
/// invoking curl, PHP, Composer, a shell, or downloaded package code.
public actor ComposerPackageDownloader {
  private struct Digests: Sendable {
    let sha1: String
    let sha256: String
    let byteCount: Int64
  }

  private let cacheDirectory: URL
  private let transport: any ComposerPackageArchiveTransport
  private let limits: ComposerPackageDownloadLimits
  private let fileManager: FileManager

  public init(
    cacheDirectory: URL,
    transport: any ComposerPackageArchiveTransport = URLSessionComposerPackageArchiveTransport(),
    limits: ComposerPackageDownloadLimits = ComposerPackageDownloadLimits()
  ) throws {
    guard cacheDirectory.isFileURL else {
      throw ComposerPackageDownloadError.invalidCacheDirectory(cacheDirectory)
    }
    self.cacheDirectory = cacheDirectory.standardizedFileURL
    self.transport = transport
    self.limits = limits
    self.fileManager = FileManager()
  }

  public func archive(
    for package: ComposerRepositoryPackage
  ) async throws -> ComposerDownloadedPackageArchive {
    guard let distributionURL = package.distURL else {
      throw ComposerPackageDownloadError.missingDistributionURL(
        package: package.name,
        version: package.version
      )
    }
    try Self.validateSecure(distributionURL)
    guard package.distType?.lowercased() == "zip" else {
      throw ComposerPackageDownloadError.unsupportedDistributionType(package.distType)
    }
    let expectedSHA1 = try Self.normalizedSHA1(package.distChecksum)

    try fileManager.createDirectory(
      at: cacheDirectory,
      withIntermediateDirectories: true
    )
    let cacheKey = Self.cacheKey(for: package, distributionURL: distributionURL)
    let archiveURL = cacheDirectory.appendingPathComponent(cacheKey + ".zip")
    let checksumURL = cacheDirectory.appendingPathComponent(cacheKey + ".sha256")

    if fileManager.fileExists(atPath: archiveURL.path) {
      return try await cachedArchive(
        package: package,
        archiveURL: archiveURL,
        checksumURL: checksumURL,
        expectedSHA1: expectedSHA1
      )
    }

    var request = URLRequest(url: distributionURL)
    request.httpMethod = "GET"
    request.setValue("application/zip, application/octet-stream", forHTTPHeaderField: "Accept")
    let response = try await transport.download(
      for: request,
      maximumBytes: limits.maximumArchiveBytes
    )
    let temporaryURL = response.temporaryFileURL
    defer {
      try? fileManager.removeItem(at: temporaryURL)
    }

    try Self.validateSecure(response.finalURL)
    guard response.statusCode == 200 else {
      throw ComposerPackageDownloadError.unexpectedStatus(response.statusCode)
    }
    if let contentLength = response.header(named: "content-length").flatMap(Int64.init),
      contentLength > limits.maximumArchiveBytes
    {
      throw ComposerPackageDownloadError.archiveTooLarge(
        limit: limits.maximumArchiveBytes,
        actual: contentLength
      )
    }

    let digests = try await Self.digests(for: temporaryURL)
    guard digests.byteCount <= limits.maximumArchiveBytes else {
      throw ComposerPackageDownloadError.archiveTooLarge(
        limit: limits.maximumArchiveBytes,
        actual: digests.byteCount
      )
    }
    if let expectedSHA1, expectedSHA1 != digests.sha1 {
      throw ComposerPackageDownloadError.checksumMismatch(
        expected: expectedSHA1,
        actual: digests.sha1
      )
    }

    do {
      try fileManager.moveItem(at: temporaryURL, to: archiveURL)
      try Data(digests.sha256.utf8).write(to: checksumURL, options: .atomic)
    } catch {
      try? fileManager.removeItem(at: archiveURL)
      try? fileManager.removeItem(at: checksumURL)
      throw error
    }

    return ComposerDownloadedPackageArchive(
      packageName: package.name,
      version: package.version,
      fileURL: archiveURL,
      sha256: digests.sha256,
      byteCount: digests.byteCount,
      wasCached: false
    )
  }

  private func cachedArchive(
    package: ComposerRepositoryPackage,
    archiveURL: URL,
    checksumURL: URL,
    expectedSHA1: String?
  ) async throws -> ComposerDownloadedPackageArchive {
    guard let storedData = fileManager.contents(atPath: checksumURL.path),
      let storedSHA256 = String(data: storedData, encoding: .utf8),
      Self.isHexDigest(storedSHA256, length: 64)
    else {
      throw ComposerPackageDownloadError.corruptedCache(archiveURL)
    }

    let digests = try await Self.digests(for: archiveURL)
    guard digests.byteCount <= limits.maximumArchiveBytes,
      digests.sha256 == storedSHA256,
      expectedSHA1 == nil || digests.sha1 == expectedSHA1
    else {
      throw ComposerPackageDownloadError.corruptedCache(archiveURL)
    }

    return ComposerDownloadedPackageArchive(
      packageName: package.name,
      version: package.version,
      fileURL: archiveURL,
      sha256: digests.sha256,
      byteCount: digests.byteCount,
      wasCached: true
    )
  }

  private static func cacheKey(
    for package: ComposerRepositoryPackage,
    distributionURL: URL
  ) -> String {
    let identity = [
      package.name,
      package.version,
      distributionURL.absoluteString,
      package.distReference ?? "",
      package.distChecksum ?? "",
    ].joined(separator: "\u{0}")
    return SHA256.hash(data: Data(identity.utf8)).hexadecimalString
  }

  private static func normalizedSHA1(_ value: String?) throws -> String? {
    guard let value else {
      return nil
    }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else {
      return nil
    }
    guard isHexDigest(normalized, length: 40) else {
      throw ComposerPackageDownloadError.invalidChecksumMetadata(value)
    }
    return normalized
  }

  private static func validateSecure(_ url: URL) throws {
    guard url.scheme?.lowercased() == "https", url.host != nil else {
      throw ComposerPackageDownloadError.insecureURL(url)
    }
  }

  private static func isHexDigest(_ value: String, length: Int) -> Bool {
    value.count == length && value.allSatisfy(\.isHexDigit)
  }

  private nonisolated static func digests(for url: URL) async throws -> Digests {
    try await Task.detached(priority: .utility) {
      let handle = try FileHandle(forReadingFrom: url)
      defer {
        try? handle.close()
      }

      var sha1 = Insecure.SHA1()
      var sha256 = SHA256()
      var byteCount: Int64 = 0
      while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        byteCount += Int64(data.count)
        sha1.update(data: data)
        sha256.update(data: data)
      }
      return Digests(
        sha1: sha1.finalize().hexadecimalString,
        sha256: sha256.finalize().hexadecimalString,
        byteCount: byteCount
      )
    }.value
  }
}

private final class ComposerDownloadLimitDelegate: NSObject, URLSessionDownloadDelegate,
  @unchecked Sendable
{
  private let maximumBytes: Int64
  private let lock = NSLock()
  private var exceededBytes: Int64?

  init(maximumBytes: Int64) {
    self.maximumBytes = maximumBytes
  }

  var exceededByteCount: Int64? {
    lock.withLock { exceededBytes }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesWritten > maximumBytes else {
      return
    }
    lock.withLock {
      exceededBytes = max(exceededBytes ?? 0, totalBytesWritten)
    }
    downloadTask.cancel()
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {}
}

extension Digest {
  fileprivate var hexadecimalString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
