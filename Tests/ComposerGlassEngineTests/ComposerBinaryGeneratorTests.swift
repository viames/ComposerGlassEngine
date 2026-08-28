import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer binary generator")
struct ComposerBinaryGeneratorTests {
  @Test("Dependency binaries receive deterministic executable proxies")
  func generatesBinaryProxies() throws {
    let vendorURL = try binaryVendor()
    defer { try? FileManager.default.removeItem(at: vendorURL.deletingLastPathComponent()) }
    let packageURL = vendorURL.appendingPathComponent("acme/tool")
    try FileManager.default.createDirectory(
      at: packageURL.appendingPathComponent("bin"),
      withIntermediateDirectories: true
    )
    try Data(#"{"name":"acme/tool","bin":["bin/acme","bin/acme-helper"]}"#.utf8)
      .write(to: packageURL.appendingPathComponent("composer.json"))
    try Data("#!/usr/bin/env php\n<?php".utf8)
      .write(to: packageURL.appendingPathComponent("bin/acme"))
    try Data("#!/usr/bin/env php\n<?php".utf8)
      .write(to: packageURL.appendingPathComponent("bin/acme-helper"))

    let generated = try ComposerBinaryGenerator().generate(in: vendorURL)

    #expect(generated.map { $0.proxyURL.lastPathComponent } == ["acme", "acme-helper"])
    let proxy = try String(
      contentsOf: vendorURL.appendingPathComponent("bin/acme"),
      encoding: .utf8
    )
    #expect(proxy.contains("../acme/tool/bin/acme"))
    #expect(proxy.contains("exec \"$composer_glass_bin_dir\""))
    let attributes = try FileManager.default.attributesOfItem(
      atPath: vendorURL.appendingPathComponent("bin/acme").path
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
  }

  @Test("Duplicate binary names are rejected before writing proxies")
  func rejectsDuplicateBinaryNames() throws {
    let vendorURL = try binaryVendor()
    defer { try? FileManager.default.removeItem(at: vendorURL.deletingLastPathComponent()) }
    for package in ["first/tool", "second/tool"] {
      let packageURL = vendorURL.appendingPathComponent(package)
      try FileManager.default.createDirectory(
        at: packageURL.appendingPathComponent("bin"),
        withIntermediateDirectories: true
      )
      try Data("{\"name\":\"\(package)\",\"bin\":\"bin/tool\"}".utf8)
        .write(to: packageURL.appendingPathComponent("composer.json"))
      try Data("tool".utf8).write(to: packageURL.appendingPathComponent("bin/tool"))
    }

    #expect(throws: ComposerBinaryGenerationError.duplicateBinary("tool")) {
      try ComposerBinaryGenerator().generate(in: vendorURL)
    }
    #expect(!FileManager.default.fileExists(atPath: vendorURL.appendingPathComponent("bin").path))
  }

  @Test("Binary paths cannot escape their package")
  func rejectsUnsafeBinaryPaths() throws {
    let vendorURL = try binaryVendor()
    defer { try? FileManager.default.removeItem(at: vendorURL.deletingLastPathComponent()) }
    let packageURL = vendorURL.appendingPathComponent("acme/tool")
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try Data(#"{"name":"acme/tool","bin":"../outside"}"#.utf8)
      .write(to: packageURL.appendingPathComponent("composer.json"))

    #expect(
      throws: ComposerBinaryGenerationError.unsafeBinaryPath(
        package: "acme/tool",
        path: "../outside"
      )
    ) {
      try ComposerBinaryGenerator().generate(in: vendorURL)
    }
  }
}

private func binaryVendor() throws -> URL {
  let workspace = try zipTemporaryDirectory()
  let vendorURL = workspace.appendingPathComponent("vendor")
  try FileManager.default.createDirectory(at: vendorURL, withIntermediateDirectories: true)
  return vendorURL
}
