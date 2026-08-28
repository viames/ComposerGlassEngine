import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer ZIP extractor")
struct ComposerZIPExtractorTests {
  @Test("Stored files are extracted under a detected package root")
  func extractsStoredFiles() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let archiveURL = workspace.appendingPathComponent("package.zip")
    let destinationURL = workspace.appendingPathComponent("extracted")
    let composerJSON = Data(#"{"name":"vendor/package"}"#.utf8)
    let source = Data("<?php\n".utf8)
    try makeZIP([
      ZIPTestEntry(name: "package/composer.json", data: composerJSON),
      ZIPTestEntry(name: "package/src/File.php", data: source),
    ]).write(to: archiveURL)

    let result = try await ComposerZIPExtractor().extract(
      archive: archiveURL,
      to: destinationURL
    )

    #expect(result.contentRootURL == destinationURL.appendingPathComponent("package"))
    #expect(result.entryCount == 2)
    #expect(result.uncompressedByteCount == UInt64(composerJSON.count + source.count))
    #expect(
      try Data(contentsOf: result.contentRootURL.appendingPathComponent("composer.json"))
        == composerJSON
    )
    #expect(
      try Data(contentsOf: result.contentRootURL.appendingPathComponent("src/File.php"))
        == source
    )
  }

  @Test("Raw DEFLATE entries are decoded and checked with CRC-32")
  func extractsDeflatedFile() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let archiveURL = workspace.appendingPathComponent("deflated.zip")
    let destinationURL = workspace.appendingPathComponent("deflated")
    let original = Data("hello".utf8)
    let compressed = Data([0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00])
    try makeZIP([
      ZIPTestEntry(
        name: "package/readme.txt",
        data: original,
        compressionMethod: 8,
        compressedData: compressed
      )
    ]).write(to: archiveURL)

    let result = try await ComposerZIPExtractor().extract(
      archive: archiveURL,
      to: destinationURL
    )

    #expect(
      try Data(contentsOf: result.contentRootURL.appendingPathComponent("readme.txt"))
        == original
    )
  }

  @Test(arguments: ["../escape.php", "/absolute.php", "package\\escape.php"])
  func rejectsUnsafePaths(_ path: String) async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let archiveURL = workspace.appendingPathComponent("unsafe.zip")
    let destinationURL = workspace.appendingPathComponent("unsafe")
    try makeZIP([ZIPTestEntry(name: path, data: Data("unsafe".utf8))]).write(to: archiveURL)

    let error = await extractionError(
      from: ComposerZIPExtractor(),
      archiveURL: archiveURL,
      destinationURL: destinationURL
    )

    #expect(error == .unsafeEntryPath(path))
    #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    #expect(
      !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("escape.php").path))
  }

  @Test("Symbolic links are rejected before the destination is created")
  func rejectsSymbolicLinks() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let archiveURL = workspace.appendingPathComponent("symlink.zip")
    let destinationURL = workspace.appendingPathComponent("symlink")
    let path = "package/link"
    try makeZIP([
      ZIPTestEntry(name: path, data: Data("../outside".utf8), unixMode: 0o120777)
    ]).write(to: archiveURL)

    let error = await extractionError(
      from: ComposerZIPExtractor(),
      archiveURL: archiveURL,
      destinationURL: destinationURL
    )

    #expect(error == .symbolicLink(path))
    #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
  }

  @Test("Case-insensitive duplicate paths are rejected")
  func rejectsDuplicatePaths() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let archiveURL = workspace.appendingPathComponent("duplicate.zip")
    let destinationURL = workspace.appendingPathComponent("duplicate")
    try makeZIP([
      ZIPTestEntry(name: "package/File.php", data: Data("one".utf8)),
      ZIPTestEntry(name: "package/file.php", data: Data("two".utf8)),
    ]).write(to: archiveURL)

    let error = await extractionError(
      from: ComposerZIPExtractor(),
      archiveURL: archiveURL,
      destinationURL: destinationURL
    )

    #expect(error == .duplicateEntry("package/file.php"))
  }

  @Test("A regular file cannot also be a parent directory")
  func rejectsFileDirectoryCollisions() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let archiveURL = workspace.appendingPathComponent("collision.zip")
    let destinationURL = workspace.appendingPathComponent("collision")
    try makeZIP([
      ZIPTestEntry(name: "package/vendor", data: Data("file".utf8)),
      ZIPTestEntry(name: "package/vendor/library.php", data: Data("child".utf8)),
    ]).write(to: archiveURL)

    let error = await extractionError(
      from: ComposerZIPExtractor(),
      archiveURL: archiveURL,
      destinationURL: destinationURL
    )

    #expect(error == .entryCollision("package/vendor/library.php"))
  }

  @Test("CRC failure removes the incomplete extraction directory")
  func rollsBackAfterChecksumFailure() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let archiveURL = workspace.appendingPathComponent("checksum.zip")
    let destinationURL = workspace.appendingPathComponent("checksum")
    try makeZIP([
      ZIPTestEntry(
        name: "package/file.txt",
        data: Data("content".utf8),
        checksumOverride: 0
      )
    ]).write(to: archiveURL)

    let error = await extractionError(
      from: ComposerZIPExtractor(),
      archiveURL: archiveURL,
      destinationURL: destinationURL
    )

    guard case .checksumMismatch(let path, let expected, _) = error else {
      Issue.record("Expected a CRC-32 mismatch")
      return
    }
    #expect(path == "package/file.txt")
    #expect(expected == 0)
    #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
  }

  @Test("DEFLATE output cannot exceed the size declared during preflight")
  func stopsUnexpectedDeflateExpansion() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let archiveURL = workspace.appendingPathComponent("expansion.zip")
    let destinationURL = workspace.appendingPathComponent("expansion")
    try makeZIP([
      ZIPTestEntry(
        name: "package/file.txt",
        data: Data("hello".utf8),
        compressionMethod: 8,
        compressedData: Data([0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00]),
        uncompressedSizeOverride: 1
      )
    ]).write(to: archiveURL)

    let error = await extractionError(
      from: ComposerZIPExtractor(),
      archiveURL: archiveURL,
      destinationURL: destinationURL
    )

    #expect(error == .invalidCompressedSize("package/file.txt"))
    #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
  }

  @Test("Entry and total expansion limits are enforced during preflight")
  func enforcesExpansionLimits() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let archiveURL = workspace.appendingPathComponent("large.zip")
    try makeZIP([
      ZIPTestEntry(name: "package/one", data: Data(repeating: 1, count: 6)),
      ZIPTestEntry(name: "package/two", data: Data(repeating: 2, count: 6)),
    ]).write(to: archiveURL)

    let entryLimited = ComposerZIPExtractor(
      limits: ComposerZIPExtractionLimits(
        maximumEntries: 10,
        maximumEntryBytes: 5,
        maximumTotalBytes: 100
      )
    )
    #expect(
      await extractionError(
        from: entryLimited,
        archiveURL: archiveURL,
        destinationURL: workspace.appendingPathComponent("entry-limited")
      ) == .entryTooLarge(path: "package/one", limit: 5, actual: 6)
    )

    let totalLimited = ComposerZIPExtractor(
      limits: ComposerZIPExtractionLimits(
        maximumEntries: 10,
        maximumEntryBytes: 10,
        maximumTotalBytes: 10
      )
    )
    #expect(
      await extractionError(
        from: totalLimited,
        archiveURL: archiveURL,
        destinationURL: workspace.appendingPathComponent("total-limited")
      ) == .archiveTooLarge(limit: 10, actual: 12)
    )
  }

  @Test("Encrypted and unsupported compression entries are rejected")
  func rejectsUnsupportedEntries() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }

    let encryptedURL = workspace.appendingPathComponent("encrypted.zip")
    try makeZIP([
      ZIPTestEntry(name: "package/secret", data: Data(), flags: 0x0001)
    ]).write(to: encryptedURL)
    #expect(
      await extractionError(
        from: ComposerZIPExtractor(),
        archiveURL: encryptedURL,
        destinationURL: workspace.appendingPathComponent("encrypted")
      ) == .encryptedEntry("package/secret")
    )

    let unsupportedURL = workspace.appendingPathComponent("unsupported.zip")
    try makeZIP([
      ZIPTestEntry(name: "package/file", data: Data(), compressionMethod: 12)
    ]).write(to: unsupportedURL)
    #expect(
      await extractionError(
        from: ComposerZIPExtractor(),
        archiveURL: unsupportedURL,
        destinationURL: workspace.appendingPathComponent("unsupported")
      ) == .unsupportedCompressionMethod(12)
    )
  }

  @Test("An existing destination is never modified")
  func preservesExistingDestination() async throws {
    let workspace = try zipTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let archiveURL = workspace.appendingPathComponent("package.zip")
    let destinationURL = workspace.appendingPathComponent("existing")
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    let marker = destinationURL.appendingPathComponent("marker")
    try Data("keep".utf8).write(to: marker)
    try makeZIP([ZIPTestEntry(name: "file", data: Data("new".utf8))]).write(to: archiveURL)

    let error = await extractionError(
      from: ComposerZIPExtractor(),
      archiveURL: archiveURL,
      destinationURL: destinationURL
    )

    #expect(error == .destinationAlreadyExists(destinationURL))
    #expect(try Data(contentsOf: marker) == Data("keep".utf8))
  }
}

struct ZIPTestEntry {
  let name: String
  let data: Data
  let compressionMethod: UInt16
  let compressedData: Data
  let flags: UInt16
  let unixMode: UInt16
  let checksum: UInt32
  let uncompressedSize: UInt32

  init(
    name: String,
    data: Data,
    compressionMethod: UInt16 = 0,
    compressedData: Data? = nil,
    flags: UInt16 = 0,
    unixMode: UInt16 = 0o100644,
    checksumOverride: UInt32? = nil,
    uncompressedSizeOverride: UInt32? = nil
  ) {
    self.name = name
    self.data = data
    self.compressionMethod = compressionMethod
    self.compressedData = compressedData ?? data
    self.flags = flags
    self.unixMode = unixMode
    self.checksum = checksumOverride ?? zipCRC32(data)
    self.uncompressedSize = uncompressedSizeOverride ?? UInt32(data.count)
  }
}

func makeZIP(_ entries: [ZIPTestEntry]) -> Data {
  struct CentralRecord {
    let entry: ZIPTestEntry
    let localOffset: UInt32
  }

  var archive = Data()
  var centralRecords: [CentralRecord] = []
  for entry in entries {
    let localOffset = UInt32(archive.count)
    let nameData = Data(entry.name.utf8)
    archive.appendLittleEndian(UInt32(0x0403_4B50))
    archive.appendLittleEndian(UInt16(20))
    archive.appendLittleEndian(entry.flags)
    archive.appendLittleEndian(entry.compressionMethod)
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(entry.checksum)
    archive.appendLittleEndian(UInt32(entry.compressedData.count))
    archive.appendLittleEndian(entry.uncompressedSize)
    archive.appendLittleEndian(UInt16(nameData.count))
    archive.appendLittleEndian(UInt16(0))
    archive.append(nameData)
    archive.append(entry.compressedData)
    centralRecords.append(CentralRecord(entry: entry, localOffset: localOffset))
  }

  let centralOffset = UInt32(archive.count)
  for record in centralRecords {
    let entry = record.entry
    let nameData = Data(entry.name.utf8)
    archive.appendLittleEndian(UInt32(0x0201_4B50))
    archive.appendLittleEndian(UInt16((3 << 8) | 20))
    archive.appendLittleEndian(UInt16(20))
    archive.appendLittleEndian(entry.flags)
    archive.appendLittleEndian(entry.compressionMethod)
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(entry.checksum)
    archive.appendLittleEndian(UInt32(entry.compressedData.count))
    archive.appendLittleEndian(entry.uncompressedSize)
    archive.appendLittleEndian(UInt16(nameData.count))
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(UInt32(entry.unixMode) << 16)
    archive.appendLittleEndian(record.localOffset)
    archive.append(nameData)
  }
  let centralSize = UInt32(archive.count) - centralOffset

  archive.appendLittleEndian(UInt32(0x0605_4B50))
  archive.appendLittleEndian(UInt16(0))
  archive.appendLittleEndian(UInt16(0))
  archive.appendLittleEndian(UInt16(entries.count))
  archive.appendLittleEndian(UInt16(entries.count))
  archive.appendLittleEndian(centralSize)
  archive.appendLittleEndian(centralOffset)
  archive.appendLittleEndian(UInt16(0))
  return archive
}

func zipCRC32(_ data: Data) -> UInt32 {
  var value: UInt32 = 0xFFFF_FFFF
  for byte in data {
    var current = (value ^ UInt32(byte)) & 0xFF
    for _ in 0..<8 {
      current = current & 1 == 1 ? 0xEDB8_8320 ^ (current >> 1) : current >> 1
    }
    value = current ^ (value >> 8)
  }
  return value ^ 0xFFFF_FFFF
}

func zipTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("ComposerZIPExtractorTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func extractionError(
  from extractor: ComposerZIPExtractor,
  archiveURL: URL,
  destinationURL: URL
) async -> ComposerZIPExtractionError? {
  do {
    _ = try await extractor.extract(archive: archiveURL, to: destinationURL)
    Issue.record("Expected ZIP extraction to fail")
    return nil
  } catch let error as ComposerZIPExtractionError {
    return error
  } catch {
    Issue.record("Unexpected error: \(error)")
    return nil
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}
