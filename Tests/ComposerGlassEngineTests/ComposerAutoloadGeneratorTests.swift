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
    let composerMetadataURL = vendorURL.appendingPathComponent("composer")
    try FileManager.default.createDirectory(
      at: composerMetadataURL,
      withIntermediateDirectories: true
    )
    try Data(
      #"{"packages":[{"name":"acme/library","version":"1.2.3","version_normalized":"1.2.3.0","type":"library","source":{"reference":"abc123"},"install-path":"../acme/library","dev_requirement":false,"provide":{"acme/virtual":"^1.0"}}],"dev":false,"dev-package-names":[]}"#
        .utf8
    ).write(to: composerMetadataURL.appendingPathComponent("installed.json"))
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
      "name": .string("acme/project"),
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
    #expect(result.classmapCount == 3)
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
    #expect(classmap.contains("'Composer\\\\InstalledVersions'"))
    #expect(classmap.contains("'/../composer/InstalledVersions.php'"))
    #expect(!classmap.contains("FakeComment"))
    let real = try String(
      contentsOf: vendorURL.appendingPathComponent("composer/autoload_real.php"),
      encoding: .utf8
    )
    #expect(real.contains("ComposerGlassAutoloaderInit"))
    #expect(real.contains("$loader->register(true)"))
    let installedVersionsURL = vendorURL.appendingPathComponent(
      "composer/InstalledVersions.php"
    )
    let installedPHPURL = vendorURL.appendingPathComponent("composer/installed.php")
    #expect(FileManager.default.fileExists(atPath: installedVersionsURL.path))
    #expect(FileManager.default.fileExists(atPath: installedPHPURL.path))
    let installedPHP = try String(contentsOf: installedPHPURL, encoding: .utf8)
    #expect(installedPHP.contains("'name' => 'acme/project'"))
    #expect(installedPHP.contains("'acme/project' => array("))
    #expect(installedPHP.contains("'acme/library' => array("))
    #expect(installedPHP.contains("'version' => '1.2.3.0'"))
    #expect(installedPHP.contains("'acme/virtual' => array("))
    #expect(installedPHP.contains("'provided' => array(0 => '^1.0')"))

    if let phpURL = phpExecutableURL() {
      let output = Pipe()
      let process = Process()
      process.executableURL = phpURL
      process.arguments = [
        "-r",
        #"require $argv[1]; echo \Composer\InstalledVersions::getPrettyVersion('acme/library');"#,
        result.autoloadURL.path,
      ]
      process.standardOutput = output
      process.standardError = output
      try process.run()
      process.waitUntilExit()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      let text = String(decoding: data, as: UTF8.self)
      #expect(process.terminationStatus == 0, Comment(rawValue: text))
      #expect(text == "1.2.3")
    }
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

  @Test("Overlapping classmap paths include the same declaration once")
  func deduplicatesOverlappingClassmapPaths() throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let vendorURL = workspace.appendingPathComponent("vendor")
    let packageURL = vendorURL.appendingPathComponent("acme/library")
    let includeURL = packageURL.appendingPathComponent("include")
    try FileManager.default.createDirectory(at: includeURL, withIntermediateDirectories: true)
    try Data(
      #"{"name":"acme/library","autoload":{"classmap":["include","include/Types.php"]}}"#.utf8
    ).write(to: packageURL.appendingPathComponent("composer.json"))
    try Data("<?php class IncludedType {}".utf8)
      .write(to: includeURL.appendingPathComponent("Types.php"))

    let result = try ComposerAutoloadGenerator().generate(
      rootManifest: ComposerManifest(fields: [:]),
      projectDirectoryURL: workspace,
      vendorDirectoryURL: vendorURL
    )

    #expect(result.classmapCount == 2)
    let classmap = try String(
      contentsOf: vendorURL.appendingPathComponent("composer/autoload_classmap.php"),
      encoding: .utf8
    )
    #expect(classmap.components(separatedBy: "'IncludedType'").count == 2)
  }

  private func phpExecutableURL() -> URL? {
    let paths = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
    return paths.lazy.map { path in
      URL(fileURLWithPath: String(path)).appendingPathComponent("php")
    }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }
}
