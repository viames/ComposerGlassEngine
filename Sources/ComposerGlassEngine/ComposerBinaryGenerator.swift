import Foundation

public enum ComposerBinaryGenerationError: Error, Equatable, Sendable {
  case vendorDirectoryMissing(URL)
  case invalidPackageManifest(URL)
  case invalidBinaryMetadata(package: String)
  case unsafeBinaryPath(package: String, path: String)
  case binaryMissing(package: String, path: String)
  case symbolicLink(URL)
  case duplicateBinary(String)
}

public struct ComposerGeneratedBinary: Equatable, Sendable {
  public let packageName: String
  public let sourceRelativePath: String
  public let proxyURL: URL

  public init(packageName: String, sourceRelativePath: String, proxyURL: URL) {
    self.packageName = packageName
    self.sourceRelativePath = sourceRelativePath
    self.proxyURL = proxyURL
  }
}

/// Generates deterministic POSIX proxies for dependency binaries. The
/// generator validates metadata and writes files but never executes them.
public struct ComposerBinaryGenerator {
  private struct PlannedBinary {
    let packageName: String
    let relativePath: String
    let proxyName: String
  }

  private let fileManager: FileManager

  public init() {
    self.fileManager = FileManager()
  }

  public func generate(
    in vendorDirectoryURL: URL
  ) throws -> [ComposerGeneratedBinary] {
    let vendorURL = vendorDirectoryURL.standardizedFileURL
    try validateDirectory(vendorURL, missing: .vendorDirectoryMissing(vendorURL))
    let planned = try plannedBinaries(in: vendorURL)
    var names = Set<String>()
    for binary in planned {
      guard names.insert(binary.proxyName).inserted else {
        throw ComposerBinaryGenerationError.duplicateBinary(binary.proxyName)
      }
    }
    guard !planned.isEmpty else {
      return []
    }

    let binaryDirectoryURL = vendorURL.appendingPathComponent("bin", isDirectory: true)
    if fileManager.fileExists(atPath: binaryDirectoryURL.path) {
      try rejectSymbolicLink(binaryDirectoryURL)
    }
    try fileManager.createDirectory(
      at: binaryDirectoryURL,
      withIntermediateDirectories: true
    )
    var generated: [ComposerGeneratedBinary] = []
    generated.reserveCapacity(planned.count)
    do {
      for binary in planned {
        let proxyURL = binaryDirectoryURL.appendingPathComponent(binary.proxyName)
        let target = "../\(binary.packageName)/\(binary.relativePath)"
        let sourceURL = vendorURL.appendingPathComponent(
          "\(binary.packageName)/\(binary.relativePath)"
        )
        try Data(
          Self.proxySource(
            target: target,
            sourceURL: sourceURL,
            isPHPUnit: binary.packageName == "phpunit/phpunit"
              && binary.relativePath == "phpunit"
          ).utf8
        ).write(
          to: proxyURL,
          options: .atomic
        )
        try fileManager.setAttributes(
          [.posixPermissions: NSNumber(value: 0o755)],
          ofItemAtPath: proxyURL.path
        )
        generated.append(
          ComposerGeneratedBinary(
            packageName: binary.packageName,
            sourceRelativePath: binary.relativePath,
            proxyURL: proxyURL
          )
        )
      }
    } catch {
      for binary in generated {
        try? fileManager.removeItem(at: binary.proxyURL)
      }
      throw error
    }
    return generated
  }

  private func plannedBinaries(in vendorURL: URL) throws -> [PlannedBinary] {
    var planned: [PlannedBinary] = []
    for vendorDirectory in try directoryChildren(of: vendorURL)
    where vendorDirectory.lastPathComponent != "composer"
      && vendorDirectory.lastPathComponent != "bin"
    {
      for packageDirectory in try directoryChildren(of: vendorDirectory) {
        let manifestURL = packageDirectory.appendingPathComponent("composer.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
          continue
        }
        let manifest: ComposerManifest
        do {
          manifest = try ComposerManifest.decode(from: Data(contentsOf: manifestURL))
        } catch {
          throw ComposerBinaryGenerationError.invalidPackageManifest(manifestURL)
        }
        let expectedName =
          "\(vendorDirectory.lastPathComponent)/\(packageDirectory.lastPathComponent)"
        guard manifest.name == expectedName else {
          throw ComposerBinaryGenerationError.invalidPackageManifest(manifestURL)
        }
        guard let bin = manifest["bin"] else {
          continue
        }
        let paths = try binaryPaths(bin, package: expectedName)
        for path in paths {
          let relativePath = try validatedRelativePath(path, package: expectedName)
          let sourceURL = packageDirectory.appendingPathComponent(relativePath)
          guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw ComposerBinaryGenerationError.binaryMissing(
              package: expectedName,
              path: path
            )
          }
          let values = try sourceURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
          ])
          if values.isSymbolicLink == true {
            throw ComposerBinaryGenerationError.symbolicLink(sourceURL)
          }
          guard values.isRegularFile == true else {
            throw ComposerBinaryGenerationError.binaryMissing(
              package: expectedName,
              path: path
            )
          }
          let proxyName = sourceURL.lastPathComponent
          guard !proxyName.isEmpty, proxyName != ".", proxyName != ".." else {
            throw ComposerBinaryGenerationError.unsafeBinaryPath(
              package: expectedName,
              path: path
            )
          }
          planned.append(
            PlannedBinary(
              packageName: expectedName,
              relativePath: relativePath,
              proxyName: proxyName
            )
          )
        }
      }
    }
    return planned.sorted {
      ($0.proxyName, $0.packageName, $0.relativePath)
        < ($1.proxyName, $1.packageName, $1.relativePath)
    }
  }

  private func binaryPaths(_ value: JSONValue, package: String) throws -> [String] {
    if let path = value.stringValue {
      return [path]
    }
    guard case .array(let values) = value else {
      throw ComposerBinaryGenerationError.invalidBinaryMetadata(package: package)
    }
    let paths = values.compactMap(\.stringValue)
    guard paths.count == values.count else {
      throw ComposerBinaryGenerationError.invalidBinaryMetadata(package: package)
    }
    return paths
  }

  private func validatedRelativePath(_ path: String, package: String) throws -> String {
    let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
    guard
      !path.hasPrefix("/"), !path.contains("\\"), !normalized.isEmpty,
      !components.contains(".."), !components.contains("."), !components.contains("")
    else {
      throw ComposerBinaryGenerationError.unsafeBinaryPath(package: package, path: path)
    }
    return normalized
  }

  private func directoryChildren(of directoryURL: URL) throws -> [URL] {
    try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).filter { url in
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        throw ComposerBinaryGenerationError.symbolicLink(url)
      }
      return values.isDirectory == true
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func validateDirectory(
    _ url: URL,
    missing error: ComposerBinaryGenerationError
  ) throws {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw error
    }
    try rejectSymbolicLink(url)
  }

  private func rejectSymbolicLink(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    if values.isSymbolicLink == true {
      throw ComposerBinaryGenerationError.symbolicLink(url)
    }
  }

  private static func proxySource(
    target: String,
    sourceURL: URL,
    isPHPUnit: Bool
  ) -> String {
    let prefix = (try? FileHandle(forReadingFrom: sourceURL)).flatMap { handle -> Data? in
      defer { try? handle.close() }
      return try? handle.read(upToCount: 500)
    }.map { String(decoding: $0, as: UTF8.self) } ?? ""
    let phpPattern = #"^(#!.*\r?\n)?[\r\n\t ]*<\?php"#
    guard let expression = try? NSRegularExpression(pattern: phpPattern),
      let match = expression.firstMatch(
        in: prefix,
        range: NSRange(prefix.startIndex..<prefix.endIndex, in: prefix)
      )
    else {
      return shellProxySource(target: target)
    }

    let shebang: String
    let usesStreamWrapper: Bool
    if match.range(at: 1).location != NSNotFound,
      let range = Range(match.range(at: 1), in: prefix)
    {
      shebang = prefix[range].trimmingCharacters(in: .whitespacesAndNewlines)
      usesStreamWrapper = true
    } else {
      shebang = "#!/usr/bin/env php"
      usesStreamWrapper = false
    }
    let targetExpression = "__DIR__ . '/..'.\(phpQuote("/" + String(target.dropFirst(3))))"
    let streamHint = usesStreamWrapper
      ? " using a stream wrapper to prevent the shebang from being output on PHP<8\n *"
      : ""
    let phpunitGlobal = isPHPUnit
      ? "$GLOBALS['__PHPUNIT_ISOLATION_EXCLUDE_LIST'] = $GLOBALS['__PHPUNIT_ISOLATION_BLACKLIST'] = array(realpath(\(targetExpression)));\n"
      : ""
    let wrapper = usesStreamWrapper
      ? streamWrapperSource(targetExpression: targetExpression, isPHPUnit: isPHPUnit)
      : ""
    return """
      \(shebang)
      <?php

      /**
       * Proxy PHP file generated by Composer
       *
       * This file includes the referenced bin path (\(target))
       *\(streamHint)
       * @generated
       */

      namespace Composer;

      $GLOBALS['_composer_bin_dir'] = __DIR__;
      $GLOBALS['_composer_autoload_path'] = __DIR__ . '/..'.'/autoload.php';
      \(phpunitGlobal)\(wrapper)return include \(targetExpression);
      """ + "\n"
  }

  private static func streamWrapperSource(
    targetExpression: String,
    isPHPUnit: Bool
  ) -> String {
    let openedPath = isPHPUnit
      ? "$opened_path = 'phpvfscomposer://'.$this->realpath;"
      : "$opened_path = $this->realpath;"
    let phpunitReadHack = isPHPUnit
      ? "\n                $data = str_replace('__DIR__', var_export(dirname($this->realpath), true), $data);\n                $data = str_replace('__FILE__', var_export($this->realpath, true), $data);"
      : ""
    return """

      if (PHP_VERSION_ID < 80000) {
          if (!class_exists('Composer\\BinProxyWrapper')) {
              /**
               * @internal
               */
              final class BinProxyWrapper
              {
                  private $handle;
                  private $position;
                  private $realpath;

                  public function stream_open($path, $mode, $options, &$opened_path)
                  {
                      // get rid of phpvfscomposer:// prefix for __FILE__ & __DIR__ resolution
                      $opened_path = substr($path, 17);
                      $this->realpath = realpath($opened_path) ?: $opened_path;
                      \(openedPath)
                      $this->handle = fopen($this->realpath, $mode);
                      $this->position = 0;

                      return (bool) $this->handle;
                  }

                  public function stream_read($count)
                  {
                      $data = fread($this->handle, $count);

                      if ($this->position === 0) {
                          $data = preg_replace('{^#!.*\\r?\\n}', '', $data);
                      }\(phpunitReadHack)

                      $this->position += strlen($data);

                      return $data;
                  }

                  public function stream_cast($castAs)
                  {
                      return $this->handle;
                  }

                  public function stream_close()
                  {
                      fclose($this->handle);
                  }

                  public function stream_lock($operation)
                  {
                      return $operation ? flock($this->handle, $operation) : true;
                  }

                  public function stream_seek($offset, $whence)
                  {
                      if (0 === fseek($this->handle, $offset, $whence)) {
                          $this->position = ftell($this->handle);
                          return true;
                      }

                      return false;
                  }

                  public function stream_tell()
                  {
                      return $this->position;
                  }

                  public function stream_eof()
                  {
                      return feof($this->handle);
                  }

                  public function stream_stat()
                  {
                      return array();
                  }

                  public function stream_set_option($option, $arg1, $arg2)
                  {
                      return true;
                  }

                  public function url_stat($path, $flags)
                  {
                      $path = substr($path, 17);
                      if (file_exists($path)) {
                          return stat($path);
                      }

                      return false;
                  }
              }
          }

          if (
              (function_exists('stream_get_wrappers') && in_array('phpvfscomposer', stream_get_wrappers(), true))
              || (function_exists('stream_wrapper_register') && stream_wrapper_register('phpvfscomposer', 'Composer\\BinProxyWrapper'))
          ) {
              return include("phpvfscomposer://" . \(targetExpression));
          }
      }

      """ + "\n"
  }

  private static func shellProxySource(target: String) -> String {
    let directory = (target as NSString).deletingLastPathComponent
    let file = (target as NSString).lastPathComponent
    return """
      #!/usr/bin/env sh

      # Support bash to support `source` with fallback on $0 if this does not run with bash
      # https://stackoverflow.com/a/35006505/6512
      selfArg="$BASH_SOURCE"
      if [ -z "$selfArg" ]; then
          selfArg="$0"
      fi

      self=$(realpath "$selfArg" 2> /dev/null)
      if [ -z "$self" ]; then
          self="$selfArg"
      fi

      dir=$(cd "${self%[/\\]*}" > /dev/null; cd \(directory) && pwd)

      if [ -d /proc/cygdrive ]; then
          case $(which php) in
              $(readlink -n /proc/cygdrive)/*)
                  # We are in Cygwin using Windows php, so the path must be translated
                  dir=$(cygpath -m "$dir");
                  ;;
          esac
      fi

      export COMPOSER_RUNTIME_BIN_DIR="$(cd "${self%[/\\]*}" > /dev/null; pwd)"

      # If bash is sourcing this file, we have to source the target as well
      bashSource="$BASH_SOURCE"
      if [ -n "$bashSource" ]; then
          if [ "$bashSource" != "$0" ]; then
              source "${dir}/\(file)" "$@"
              return
          fi
      fi

      exec "${dir}/\(file)" "$@"
      """ + "\n"
  }

  private static func phpQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))'"
  }
}
