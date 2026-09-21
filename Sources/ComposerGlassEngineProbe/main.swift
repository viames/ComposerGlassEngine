import ComposerGlassEngine
import Foundation

@main
struct ComposerGlassEngineProbe {
  static func main() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 3 else {
      throw ProbeError.usage
    }

    let command = arguments[0]
    let projectURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let workingURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let includeDevelopmentPackages = !arguments.contains("--no-dev")
    let stateStorage = ComposerNativeStateStorage(
      rootDirectoryURL: workingURL.appendingPathComponent("state", isDirectory: true)
    )

    switch command {
    case "install":
      let installer = try ComposerNativeInstaller(
        cacheDirectoryURL: workingURL.appendingPathComponent("cache", isDirectory: true),
        stateStorage: stateStorage
      )
      let result = try await installer.install(
        projectDirectoryURL: projectURL,
        options: ComposerNativeInstallOptions(
          includeDevelopmentPackages: includeDevelopmentPackages
        )
      )
      print("installed=\(result.installedPackages.count)")
      print("autoloaded=\(result.generatedAutoload.packageCount)")
      print("binaries=\(result.generatedBinaries.count)")
      print("skipped-scripts=\(result.skippedScriptNames.count)")
      print("skipped-plugins=\(result.skippedPluginNames.count)")

    case "dump-autoload":
      let maintenance = ComposerNativeMaintenance(stateStorage: stateStorage)
      let result = try await maintenance.dumpAutoload(
        projectDirectoryURL: projectURL,
        includeDevelopmentAutoload: includeDevelopmentPackages
      )
      print("autoloaded=\(result.autoload.packageCount)")
      print("classmap=\(result.autoload.classmapCount)")
      print("files=\(result.autoload.filesCount)")
      print("binaries=\(result.binaries.count)")

    case "update":
      let repository = try ComposerRepositoryClient(
        repositoryURL: URL(string: "https://repo.packagist.org")!,
        metadataCacheValidityInterval: 300,
        cacheDirectoryURL: workingURL.appendingPathComponent(
          "repository-metadata",
          isDirectory: true
        )
      )
      let manifest = try ComposerManifest.decode(
        from: Data(contentsOf: projectURL.appendingPathComponent("composer.json"))
      )
      var platformPackages = [
        "php": "8.5.2",
        "composer": ComposerUpstreamPlatformVersions.composer,
        "composer-plugin-api": ComposerUpstreamPlatformVersions.pluginAPI,
        "composer-runtime-api": ComposerUpstreamPlatformVersions.runtimeAPI,
      ]
      if case .object(let config)? = manifest["config"],
        case .object(let platform)? = config["platform"]
      {
        for (name, value) in platform {
          if let version = value.stringValue {
            platformPackages[name] = version
          } else if value.boolValue == false {
            platformPackages.removeValue(forKey: name)
          }
        }
      }
      let installer = try ComposerNativeInstaller(
        cacheDirectoryURL: workingURL.appendingPathComponent("cache", isDirectory: true),
        stateStorage: stateStorage
      )
      let manager = ComposerNativeDependencyManager(
        source: repository,
        platform: try ComposerResolutionPlatform(packages: platformPackages),
        installer: installer,
        stateStorage: stateStorage
      )
      let result = try await manager.perform(.updateAll, in: projectURL)
      print("updated=\(try result.lockFile.packages().count + result.lockFile.packages(in: .development).count)")
      print("installed=\(result.installResult?.installedPackages.count ?? 0)")

    default:
      throw ProbeError.unknownCommand(command)
    }
  }
}

private enum ProbeError: LocalizedError {
  case usage
  case unknownCommand(String)

  var errorDescription: String? {
    switch self {
    case .usage:
      return "Usage: composer-glass-engine-probe <install|dump-autoload|update> <project> <working-directory> [--no-dev]"
    case .unknownCommand(let command):
      return "Unknown command: \(command)"
    }
  }
}
