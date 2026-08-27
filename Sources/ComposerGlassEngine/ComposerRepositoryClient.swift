import Foundation

public struct ComposerHTTPResponse: Sendable {
  public let data: Data
  public let statusCode: Int
  public let headers: [String: String]
  public let finalURL: URL

  public init(
    data: Data,
    statusCode: Int,
    headers: [String: String] = [:],
    finalURL: URL
  ) {
    self.data = data
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

public protocol ComposerRepositoryTransport: Sendable {
  func response(for request: URLRequest) async throws -> ComposerHTTPResponse
}

public struct URLSessionComposerRepositoryTransport: ComposerRepositoryTransport {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func response(for request: URLRequest) async throws -> ComposerHTTPResponse {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse, let finalURL = response.url else {
      throw ComposerRepositoryError.invalidResponse
    }
    let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
      guard let name = item.key as? String else {
        return
      }
      result[name] = String(describing: item.value)
    }
    return ComposerHTTPResponse(
      data: data,
      statusCode: response.statusCode,
      headers: headers,
      finalURL: finalURL
    )
  }
}

public actor ComposerRepositoryClient {
  private struct CachedDocument: Sendable {
    let data: Data
    let lastModified: String?
  }

  private let repositoryURL: URL
  private let packagesJSONURL: URL
  private let transport: any ComposerRepositoryTransport
  private var index: ComposerRepositoryIndex?
  private var packageCache: [String: CachedDocument] = [:]
  private var missingPackageFiles = Set<String>()

  public init(
    repositoryURL: URL,
    transport: any ComposerRepositoryTransport = URLSessionComposerRepositoryTransport()
  ) throws {
    guard repositoryURL.scheme?.lowercased() == "https", repositoryURL.host != nil else {
      if repositoryURL.scheme?.lowercased() != "https" {
        throw ComposerRepositoryError.insecureURL(repositoryURL)
      }
      throw ComposerRepositoryError.invalidRepositoryURL
    }
    self.repositoryURL = repositoryURL
    self.packagesJSONURL = Self.makePackagesJSONURL(from: repositoryURL)
    self.transport = transport
  }

  public func loadIndex(forceRefresh: Bool = false) async throws -> ComposerRepositoryIndex {
    if !forceRefresh, let index {
      return index
    }
    let response = try await fetch(packagesJSONURL, cached: nil)
    guard response.statusCode == 200 else {
      throw ComposerRepositoryError.unexpectedStatus(response.statusCode)
    }
    let decoded = try ComposerRepositoryIndex.decode(from: response.data)
    index = decoded
    return decoded
  }

  public func packages(
    named packageName: String,
    includeDevelopmentVersions: Bool = false
  ) async throws -> [ComposerRepositoryPackage] {
    let name = packageName.lowercased()
    guard ComposerPackageName.isValid(name), name == packageName else {
      throw ComposerRepositoryError.invalidPackages
    }

    let index = try await loadIndex()
    if let inline = try index.inlinePackages(named: name) {
      return inline
    }
    guard index.mayContain(package: name) else {
      return []
    }
    guard let template = index.metadataURLTemplate else {
      throw ComposerRepositoryError.missingMetadataURL
    }

    var packages = try await fetchPackages(
      fileName: name,
      expectedName: name,
      template: template
    )
    if includeDevelopmentVersions {
      packages += try await fetchPackages(
        fileName: name + "~dev",
        expectedName: name,
        template: template
      )
    }
    return packages
  }

  private func fetchPackages(
    fileName: String,
    expectedName: String,
    template: String
  ) async throws -> [ComposerRepositoryPackage] {
    let url = try metadataURL(template: template, packageFileName: fileName)
    let cacheKey = fileName
    if missingPackageFiles.contains(cacheKey) {
      return []
    }
    let cached = packageCache[cacheKey]
    let response: ComposerHTTPResponse
    do {
      response = try await fetch(url, cached: cached)
    } catch {
      if let cached {
        return try decodePackages(cached.data, expectedName: expectedName)
      }
      throw error
    }

    switch response.statusCode {
    case 200:
      missingPackageFiles.remove(cacheKey)
      let document = CachedDocument(
        data: response.data,
        lastModified: response.header(named: "last-modified")
      )
      packageCache[cacheKey] = document
      return try decodePackages(document.data, expectedName: expectedName)
    case 304:
      guard let cached else {
        throw ComposerRepositoryError.invalidResponse
      }
      return try decodePackages(cached.data, expectedName: expectedName)
    case 404:
      missingPackageFiles.insert(cacheKey)
      return []
    default:
      throw ComposerRepositoryError.unexpectedStatus(response.statusCode)
    }
  }

  private func decodePackages(
    _ data: Data,
    expectedName: String
  ) throws -> [ComposerRepositoryPackage] {
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    guard case .object(let root) = value,
      case .object(let packageMap)? = root["packages"],
      let rawVersions = packageMap[expectedName]
    else {
      throw ComposerRepositoryError.invalidPackages
    }

    let versions: JSONValue
    if root["minified"] == .string("composer/2.0") {
      guard case .array(let values) = rawVersions else {
        throw ComposerRepositoryError.invalidPackages
      }
      versions = .array(try ComposerMetadataMinifier.expand(values))
    } else {
      versions = rawVersions
    }
    return try ComposerRepositoryPackage.decodeCollection(
      versions,
      expectedName: expectedName
    )
  }

  private func fetch(
    _ url: URL,
    cached: CachedDocument?
  ) async throws -> ComposerHTTPResponse {
    try Self.validateSecure(url)
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let lastModified = cached?.lastModified {
      request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
    }
    let response = try await transport.response(for: request)
    try Self.validateSecure(response.finalURL)
    return response
  }

  private func metadataURL(
    template: String,
    packageFileName: String
  ) throws -> URL {
    guard template.contains("%package%") else {
      throw ComposerRepositoryError.invalidMetadataURL(template)
    }
    let path = template.replacingOccurrences(of: "%package%", with: packageFileName)
    let base = repositoryURL.metadataBaseURL()
    guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
      throw ComposerRepositoryError.invalidMetadataURL(template)
    }
    try Self.validateSecure(url)
    return url
  }

  private static func makePackagesJSONURL(from repositoryURL: URL) -> URL {
    if repositoryURL.pathExtension.lowercased() == "json" {
      return repositoryURL
    }
    return repositoryURL.appendingPathComponent("packages.json")
  }

  private static func validateSecure(_ url: URL) throws {
    guard url.scheme?.lowercased() == "https", url.host != nil else {
      throw ComposerRepositoryError.insecureURL(url)
    }
  }
}

extension URL {
  fileprivate func metadataBaseURL() -> URL {
    let base = pathExtension.lowercased() == "json" ? deletingLastPathComponent() : self
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
      return base
    }
    if !components.path.hasSuffix("/") {
      components.path += "/"
    }
    return components.url ?? base
  }
}
