import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer autoload generator")
struct ComposerAutoloadGeneratorTests {
  @Test("Generates deterministic PSR, files, and classmap metadata")
  func generatesAutoloadFiles() throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let vendorURL = workspace.appendingPathComponent("vendor")
    let packageURL = vendorURL.appendingPathComponent("acme/library")
    try FileManager.default.createDirectory(
      at: packageURL.appendingPathComponent("src"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: packageURL.appendingPathComponent("legacy"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: packageURL.appendingPathComponent("classmap"),
      withIntermediateDirectories: true
    )
    try Data(
      #"{"name":"acme/library","autoload":{"psr-4":{"Acme\\Library\\":"src/"},"psr-0":{"Legacy_":"legacy/"},"files":["functions.php"],"classmap":["classmap/"]}}"#
        .utf8
    ).write(to: packageURL.appendingPathComponent("composer.json"))
    try Data("<?php function acme_helper() {}".utf8)
      .write(to: packageURL.appendingPathComponent("functions.php"))
    try Data(
      """
      <?php
      namespace Acme\\Mapped;
      // class FakeComment {}
      final class RealClass {}
      interface RealContract {}
      """.utf8
    ).write(to: packageURL.appendingPathComponent("classmap/Types.php"))
    let rootManifest = ComposerManifest(fields: [
      "autoload": .object([
        "psr-4": .object(["Root\\": .string("app/")])
      ]),
      "autoload-dev": .object([
        "psr-4": .object(["RootTests\\": .string("tests/")])
      ]),
    ])

    let result = try ComposerAutoloadGenerator().generate(
      rootManifest: rootManifest,
      projectDirectoryURL: workspace,
      vendorDirectoryURL: vendorURL
    )

    #expect(result.packageCount == 1)
    #expect(result.classmapCount == 2)
    #expect(result.filesCount == 1)
    #expect(FileManager.default.fileExists(atPath: result.autoloadURL.path))
    let psr4 = try String(
      contentsOf: vendorURL.appendingPathComponent("composer/autoload_psr4.php"),
      encoding: .utf8
    )
    #expect(psr4.contains("'Acme\\\\Library\\\\'"))
    #expect(psr4.contains("'/../acme/library/src'"))
    #expect(psr4.contains("'Root\\\\'"))
    #expect(psr4.contains("'RootTests\\\\'"))
    let classmap = try String(
      contentsOf: vendorURL.appendingPathComponent("composer/autoload_classmap.php"),
      encoding: .utf8
    )
    #expect(classmap.contains("'Acme\\\\Mapped\\\\RealClass'"))
    #expect(classmap.contains("'Acme\\\\Mapped\\\\RealContract'"))
    #expect(!classmap.contains("FakeComment"))
    let real = try String(
      contentsOf: vendorURL.appendingPathComponent("composer/autoload_real.php"),
      encoding: .utf8
    )
    #expect(real.contains("ComposerGlassAutoloaderInit"))
    #expect(real.contains("$loader->register(true)"))
  }

  @Test("Development autoload can be excluded")
  func excludesDevelopmentAutoload() throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let vendorURL = workspace.appendingPathComponent("vendor")
    try FileManager.default.createDirectory(at: vendorURL, withIntermediateDirectories: true)
    let rootManifest = ComposerManifest(fields: [
      "autoload-dev": .object([
        "psr-4": .object(["RootTests\\": .string("tests/")])
      ])
    ])

    _ = try ComposerAutoloadGenerator().generate(
      rootManifest: rootManifest,
      projectDirectoryURL: workspace,
      vendorDirectoryURL: vendorURL,
      includeDevelopmentAutoload: false
    )

    let psr4 = try String(
      contentsOf: vendorURL.appendingPathComponent("composer/autoload_psr4.php"),
      encoding: .utf8
    )
    #expect(!psr4.contains("RootTests"))
  }

  @Test("Autoload paths cannot escape their package")
  func rejectsUnsafePaths() throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let vendorURL = workspace.appendingPathComponent("vendor")
    try FileManager.default.createDirectory(at: vendorURL, withIntermediateDirectories: true)
    let rootManifest = ComposerManifest(fields: [
      "autoload": .object([
        "psr-4": .object(["Unsafe\\": .string("../outside")])
      ])
    ])

    #expect(
      throws: ComposerAutoloadGenerationError.unsafePath(
        package: "__root__",
        path: "../outside"
      )
    ) {
      try ComposerAutoloadGenerator().generate(
        rootManifest: rootManifest,
        projectDirectoryURL: workspace,
        vendorDirectoryURL: vendorURL
      )
    }
  }

  @Test("Duplicate classmap declarations are rejected")
  func rejectsDuplicateClasses() throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let vendorURL = workspace.appendingPathComponent("vendor")
    try FileManager.default.createDirectory(at: vendorURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: workspace.appendingPathComponent("classes"),
      withIntermediateDirectories: true
    )
    try Data("<?php class DuplicateType {}".utf8)
      .write(to: workspace.appendingPathComponent("classes/One.php"))
    try Data("<?php class DuplicateType {}".utf8)
      .write(to: workspace.appendingPathComponent("classes/Two.php"))
    let rootManifest = ComposerManifest(fields: [
      "autoload": .object([
        "classmap": .array([.string("classes")])
      ])
    ])

    #expect(throws: ComposerAutoloadGenerationError.duplicateClass("DuplicateType")) {
      try ComposerAutoloadGenerator().generate(
        rootManifest: rootManifest,
        projectDirectoryURL: workspace,
        vendorDirectoryURL: vendorURL
      )
    }
  }
}
