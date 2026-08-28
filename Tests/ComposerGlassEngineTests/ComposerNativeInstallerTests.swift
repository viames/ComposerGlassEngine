import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer native installer")
struct ComposerNativeInstallerTests {
  @Test("Installs a fresh lock file without executing package code")
  func installsProjectFromLockFile() async throws {
    let project = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: project) }
    let manifestData = Data(
      #"{"name":"root/project","require":{"acme/library":"1.0.0"},"scripts":{"post-install-cmd":"Acme\\Setup::run"},"autoload":{"psr-4":{"Root\\":"src/"}}}"#
        .utf8
    )
    try manifestData.write(to: project.appendingPathComponent("composer.json"))
    let package = try nativeLockedPackage()
    let lockFile = try ComposerLockFile(
      contentHash: try ComposerContentHash.compute(from: manifestData),
      packages: [package]
    )
    try lockFile.encoded().write(to: project.appendingPathComponent("composer.lock"))
    let oldVendor = project.appendingPathComponent("vendor")
    try FileManager.default.createDirectory(at: oldVendor, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: oldVendor.appendingPathComponent("old.txt"))
    let archive = makeZIP([
      ZIPTestEntry(
        name: "package/composer.json",
        data: Data(
          #"{"name":"acme/library","autoload":{"psr-4":{"Acme\\":"src/"}},"bin":"bin/acme"}"#.utf8
        )
      ),
      ZIPTestEntry(
        name: "package/src/Library.php",
        data: Data("<?php namespace Acme; class Library {}".utf8)
      ),
      ZIPTestEntry(
        name: "package/bin/acme",
        data: Data("#!/usr/bin/env php\n<?php".utf8),
        unixMode: 0o100755
      ),
    ])
    let transport = NativeInstallerTransport(payload: archive)
    let installer = ComposerNativeInstaller(
      downloader: try ComposerPackageDownloader(
        cacheDirectory: project.appendingPathComponent("cache"),
        transport: transport
      )
    )
    let events = NativeInstallerEvents()

    let result = try await installer.install(projectDirectoryURL: project) { event in
      await events.append(event)
    }

    #expect(result.installedPackages.map(\.packageName) == ["acme/library"])
    #expect(result.generatedAutoload.packageCount == 1)
    #expect(result.generatedBinaries.map { $0.proxyURL.lastPathComponent } == ["acme"])
    #expect(result.skippedScriptNames == ["post-install-cmd"])
    #expect(
      FileManager.default.fileExists(
        atPath: project.appendingPathComponent("vendor/autoload.php").path
      )
    )
    #expect(
      FileManager.default.fileExists(
        atPath: project.appendingPathComponent("vendor/bin/acme").path
      )
    )
    #expect(
      !FileManager.default.fileExists(atPath: oldVendor.appendingPathComponent("old.txt").path))
    #expect(await transport.requestCount == 1)
    let capturedEvents = await events.values
    #expect(capturedEvents.first == .recovering)
    #expect(capturedEvents.contains(.generatingAutoload))
    #expect(capturedEvents.contains(.activatingVendor))

    try await installer.rollback(result)
    #expect(
      try Data(contentsOf: oldVendor.appendingPathComponent("old.txt")) == Data("old".utf8)
    )
  }

  @Test("Stale lock files fail before changing vendor")
  func rejectsStaleLockFile() async throws {
    let project = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: project) }
    try Data(#"{"name":"root/project"}"#.utf8)
      .write(to: project.appendingPathComponent("composer.json"))
    let lockFile = try ComposerLockFile(contentHash: String(repeating: "0", count: 32))
    try lockFile.encoded().write(to: project.appendingPathComponent("composer.lock"))
    let vendorURL = project.appendingPathComponent("vendor")
    try FileManager.default.createDirectory(at: vendorURL, withIntermediateDirectories: true)
    try Data("untouched".utf8).write(to: vendorURL.appendingPathComponent("state.txt"))
    let transport = NativeInstallerTransport(payload: Data())
    let installer = ComposerNativeInstaller(
      downloader: try ComposerPackageDownloader(
        cacheDirectory: project.appendingPathComponent("cache"),
        transport: transport
      )
    )

    await #expect(throws: ComposerNativeInstallError.staleLockFile) {
      try await installer.install(projectDirectoryURL: project)
    }

    #expect(
      try Data(contentsOf: vendorURL.appendingPathComponent("state.txt"))
        == Data("untouched".utf8)
    )
    #expect(await transport.requestCount == 0)
  }

  @Test("Composer plugins are installed but never executed by the App Store profile")
  func installsComposerPluginsWithoutExecutingThem() async throws {
    let project = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: project) }
    let manifestData = Data(#"{"name":"root/project"}"#.utf8)
    try manifestData.write(to: project.appendingPathComponent("composer.json"))
    let plugin = try ComposerLockedPackage(
      name: "acme/plugin",
      version: "1.0.0",
      fields: [
        "type": .string("composer-plugin"),
        "dist": .object([
          "type": .string("zip"),
          "url": .string("https://dist.example.test/acme-plugin.zip"),
          "reference": .string("plugin123"),
        ]),
      ]
    )
    let lockFile = try ComposerLockFile(
      contentHash: try ComposerContentHash.compute(from: manifestData),
      packages: [plugin]
    )
    try lockFile.encoded().write(to: project.appendingPathComponent("composer.lock"))
    let archive = makeZIP([
      ZIPTestEntry(
        name: "plugin/composer.json",
        data: Data(#"{"name":"acme/plugin","type":"composer-plugin"}"#.utf8)
      )
    ])
    let installer = ComposerNativeInstaller(
      downloader: try ComposerPackageDownloader(
        cacheDirectory: project.appendingPathComponent("cache"),
        transport: NativeInstallerTransport(payload: archive)
      )
    )

    let result = try await installer.install(projectDirectoryURL: project)

    #expect(result.installedPackages.map(\.packageName) == ["acme/plugin"])
    #expect(result.skippedPluginNames == ["acme/plugin"])
    #expect(
      FileManager.default.fileExists(
        atPath: project.appendingPathComponent("vendor/acme/plugin/composer.json").path
      )
    )
  }
}

private actor NativeInstallerTransport: ComposerPackageArchiveTransport {
  private let payload: Data
  private(set) var requestCount = 0

  init(payload: Data) {
    self.payload = payload
  }

  func download(
    for request: URLRequest,
    maximumBytes: Int64
  ) async throws -> ComposerPackageArchiveHTTPResponse {
    requestCount += 1
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComposerNativeInstaller-\(UUID().uuidString).zip")
    try payload.write(to: temporaryURL)
    return ComposerPackageArchiveHTTPResponse(
      temporaryFileURL: temporaryURL,
      statusCode: 200,
      headers: ["Content-Length": String(payload.count)],
      finalURL: try #require(request.url)
    )
  }
}

private actor NativeInstallerEvents {
  private(set) var values: [ComposerNativeInstallEvent] = []

  func append(_ event: ComposerNativeInstallEvent) {
    values.append(event)
  }
}

private func nativeLockedPackage() throws -> ComposerLockedPackage {
  try ComposerLockedPackage(
    name: "acme/library",
    version: "1.0.0",
    fields: [
      "dist": .object([
        "type": .string("zip"),
        "url": .string("https://dist.example.test/acme-library.zip"),
        "reference": .string("abc123"),
      ])
    ]
  )
}
