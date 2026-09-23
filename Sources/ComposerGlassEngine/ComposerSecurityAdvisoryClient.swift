import Foundation

public enum ComposerSecurityAdvisoryError: Error, Equatable, Sendable {
  case invalidEndpoint
  case insecureEndpoint(URL)
  case unexpectedStatus(Int)
  case invalidResponse
}

public struct ComposerSecurityAdvisorySource: Equatable, Codable, Sendable {
  public let name: String
  public let remoteID: String

  private enum CodingKeys: String, CodingKey {
    case name
    case remoteID = "remoteId"
  }

  public init(name: String, remoteID: String) {
    self.name = name
    self.remoteID = remoteID
  }
}

public struct ComposerSecurityAdvisory: Equatable, Sendable {
  public let advisoryID: String
  public let packageName: String
  public let title: String
  public let link: URL?
  public let cve: String?
  public let affectedVersions: String
  public let reportedAt: String?
  public let severity: String?
  public let sources: [ComposerSecurityAdvisorySource]
  public let constraintEvaluationSupported: Bool

  public init(
    advisoryID: String,
    packageName: String,
    title: String,
    link: URL?,
    cve: String?,
    affectedVersions: String,
    reportedAt: String?,
    severity: String?,
    sources: [ComposerSecurityAdvisorySource],
    constraintEvaluationSupported: Bool
  ) {
    self.advisoryID = advisoryID
    self.packageName = packageName
    self.title = title
    self.link = link
    self.cve = cve
    self.affectedVersions = affectedVersions
    self.reportedAt = reportedAt
    self.severity = severity
    self.sources = sources
    self.constraintEvaluationSupported = constraintEvaluationSupported
  }
}

/// HTTPS client for Packagist's documented anonymous security-advisory API.
public actor ComposerSecurityAdvisoryClient {
  private struct Payload: Decodable {
    let advisories: [String: [Advisory]]
  }

  private struct Advisory: Decodable {
    let advisoryId: String
    let packageName: String
    let title: String
    let link: String?
    let cve: String?
    let affectedVersions: String
    let sources: [ComposerSecurityAdvisorySource]?
    let reportedAt: String?
    let severity: String?
  }

  private let endpoint: URL
  private let transport: any ComposerRepositoryTransport

  public init(
    endpoint: URL = URL(string: "https://packagist.org/api/security-advisories/")!,
    transport: any ComposerRepositoryTransport = URLSessionComposerRepositoryTransport()
  ) throws {
    guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
      if endpoint.scheme?.lowercased() != "https" {
        throw ComposerSecurityAdvisoryError.insecureEndpoint(endpoint)
      }
      throw ComposerSecurityAdvisoryError.invalidEndpoint
    }
    self.endpoint = endpoint
    self.transport = transport
  }

  public func audit(lockFile: ComposerLockFile) async throws -> [ComposerSecurityAdvisory] {
    let packages = try lockFile.packages() + lockFile.packages(in: .development)
    let installed = Dictionary(uniqueKeysWithValues: packages.map { ($0.name, $0.version) })
    var advisories: [ComposerSecurityAdvisory] = []
    let names = installed.keys.sorted()
    for start in stride(from: 0, to: names.count, by: 50) {
      try Task.checkCancellation()
      let batch = Array(names[start..<min(start + 50, names.count)])
      let payload = try await load(packageNames: batch)
      for packageName in payload.advisories.keys.sorted() {
        guard let installedVersionText = installed[packageName],
          let installedVersion = try? ComposerVersion(installedVersionText)
        else {
          continue
        }
        for advisory in payload.advisories[packageName] ?? [] {
          let constraint = try? ComposerConstraint.parse(advisory.affectedVersions)
          guard constraint?.matches(installedVersion) != false else {
            continue
          }
          advisories.append(
            ComposerSecurityAdvisory(
              advisoryID: advisory.advisoryId,
              packageName: advisory.packageName,
              title: advisory.title,
              link: advisory.link.flatMap(URL.init(string:)),
              cve: advisory.cve,
              affectedVersions: advisory.affectedVersions,
              reportedAt: advisory.reportedAt,
              severity: advisory.severity,
              sources: advisory.sources ?? [],
              constraintEvaluationSupported: constraint != nil
            )
          )
        }
      }
    }
    return advisories.sorted {
      ($0.packageName, $0.advisoryID) < ($1.packageName, $1.advisoryID)
    }
  }

  public func audit(projectDirectoryURL: URL) async throws -> [ComposerSecurityAdvisory] {
    let lockURL = projectDirectoryURL.appendingPathComponent("composer.lock")
    return try await audit(lockFile: ComposerLockFile.decode(from: Data(contentsOf: lockURL)))
  }

  private func load(packageNames: [String]) async throws -> Payload {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw ComposerSecurityAdvisoryError.invalidEndpoint
    }
    components.queryItems = packageNames.map {
      URLQueryItem(name: "packages[]", value: $0)
    }
    guard let url = components.url else {
      throw ComposerSecurityAdvisoryError.invalidEndpoint
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("ComposerGlassEngine/0.x", forHTTPHeaderField: "User-Agent")
    let response = try await transport.response(for: request)
    guard response.finalURL.scheme?.lowercased() == "https" else {
      throw ComposerSecurityAdvisoryError.insecureEndpoint(response.finalURL)
    }
    guard response.statusCode == 200 else {
      throw ComposerSecurityAdvisoryError.unexpectedStatus(response.statusCode)
    }
    do {
      return try JSONDecoder().decode(Payload.self, from: response.data)
    } catch {
      throw ComposerSecurityAdvisoryError.invalidResponse
    }
  }
}
