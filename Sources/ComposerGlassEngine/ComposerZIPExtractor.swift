import Compression
import Foundation

public enum ComposerZIPExtractionError: Error, Equatable, Sendable {
  case destinationAlreadyExists(URL)
  case invalidArchive
  case unsupportedMultiDiskArchive
  case unsupportedZIP64Archive
  case unsupportedCompressionMethod(UInt16)
  case encryptedEntry(String)
  case invalidEntryName
  case unsafeEntryPath(String)
  case symbolicLink(String)
  case duplicateEntry(String)
  case entryCollision(String)
  case tooManyEntries(limit: Int, actual: Int)
  case entryTooLarge(path: String, limit: UInt64, actual: UInt64)
  case archiveTooLarge(limit: UInt64, actual: UInt64)
  case invalidCompressedSize(String)
  case decompressionFailed(String)
  case checksumMismatch(path: String, expected: UInt32, actual: UInt32)
}

public struct ComposerZIPExtractionLimits: Equatable, Sendable {
  public let maximumEntries: Int
  public let maximumEntryBytes: UInt64
  public let maximumTotalBytes: UInt64
  public let maximumPathDepth: Int

  public init(
    maximumEntries: Int = 100_000,
    maximumEntryBytes: UInt64 = 512 * 1_024 * 1_024,
    maximumTotalBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024,
    maximumPathDepth: Int = 64
  ) {
    self.maximumEntries = max(1, maximumEntries)
    self.maximumEntryBytes = max(1, maximumEntryBytes)
    self.maximumTotalBytes = max(1, maximumTotalBytes)
    self.maximumPathDepth = max(1, maximumPathDepth)
  }
}

public struct ComposerExtractedZIPArchive: Equatable, Sendable {
  public let destinationURL: URL
  public let contentRootURL: URL
  public let entryCount: Int
  public let uncompressedByteCount: UInt64

  public init(
    destinationURL: URL,
    contentRootURL: URL,
    entryCount: Int,
    uncompressedByteCount: UInt64
  ) {
    self.destinationURL = destinationURL
    self.contentRootURL = contentRootURL
    self.entryCount = entryCount
    self.uncompressedByteCount = uncompressedByteCount
  }
}

/// Extracts the supported Composer ZIP subset without invoking an external
/// executable. Every entry is validated before the destination is created.
public struct ComposerZIPExtractor: Sendable {
  private let limits: ComposerZIPExtractionLimits

  public init(limits: ComposerZIPExtractionLimits = ComposerZIPExtractionLimits()) {
    self.limits = limits
  }

  public func extract(
    archive archiveURL: URL,
    to destinationURL: URL
  ) async throws -> ComposerExtractedZIPArchive {
    let limits = limits
    return try await Task.detached(priority: .utility) {
      try Self.extractSynchronously(
        archive: archiveURL,
        to: destinationURL,
        limits: limits
      )
    }.value
  }

  private struct Entry: Sendable {
    let name: String
    let nameData: Data
    let components: [String]
    let isDirectory: Bool
    let compressionMethod: UInt16
    let crc32: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
    let isExecutable: Bool
  }

  private static func extractSynchronously(
    archive archiveURL: URL,
    to destinationURL: URL,
    limits: ComposerZIPExtractionLimits
  ) throws -> ComposerExtractedZIPArchive {
    let fileManager = FileManager()
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw ComposerZIPExtractionError.destinationAlreadyExists(destinationURL)
    }

    let data = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
    let entries = try parseEntries(from: data, limits: limits)
    try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: false)
    var extractionSucceeded = false
    defer {
      if !extractionSucceeded {
        try? fileManager.removeItem(at: destinationURL)
      }
    }

    for entry in entries {
      let targetURL = entry.components.reduce(destinationURL) {
        $0.appendingPathComponent($1, isDirectory: entry.isDirectory)
      }
      if entry.isDirectory {
        try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
        continue
      }

      try fileManager.createDirectory(
        at: targetURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      guard fileManager.createFile(atPath: targetURL.path, contents: nil) else {
        throw ComposerZIPExtractionError.entryCollision(entry.name)
      }
      do {
        try extract(entry, from: data, to: targetURL)
        try fileManager.setAttributes(
          [.posixPermissions: entry.isExecutable ? 0o755 : 0o644],
          ofItemAtPath: targetURL.path
        )
      } catch {
        try? fileManager.removeItem(at: targetURL)
        throw error
      }
    }

    let topLevelComponents = Set(entries.compactMap { $0.components.first })
    let contentRootURL: URL
    if topLevelComponents.count == 1, let component = topLevelComponents.first {
      let candidate = destinationURL.appendingPathComponent(component, isDirectory: true)
      var isDirectory: ObjCBool = false
      contentRootURL =
        fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
          && isDirectory.boolValue
        ? candidate
        : destinationURL
    } else {
      contentRootURL = destinationURL
    }

    extractionSucceeded = true
    return ComposerExtractedZIPArchive(
      destinationURL: destinationURL,
      contentRootURL: contentRootURL,
      entryCount: entries.count,
      uncompressedByteCount: entries.reduce(0) { $0 + $1.uncompressedSize }
    )
  }

  private static func parseEntries(
    from data: Data,
    limits: ComposerZIPExtractionLimits
  ) throws -> [Entry] {
    let endOffset = try endOfCentralDirectoryOffset(in: data)
    let diskNumber = try data.uint16(at: endOffset + 4)
    let centralDirectoryDisk = try data.uint16(at: endOffset + 6)
    let entriesOnDisk = try data.uint16(at: endOffset + 8)
    let entryCount = try data.uint16(at: endOffset + 10)
    let centralDirectorySize = try data.uint32(at: endOffset + 12)
    let centralDirectoryOffset = try data.uint32(at: endOffset + 16)
    let commentLength = try data.uint16(at: endOffset + 20)

    guard diskNumber == 0, centralDirectoryDisk == 0, entriesOnDisk == entryCount else {
      throw ComposerZIPExtractionError.unsupportedMultiDiskArchive
    }
    guard entryCount != UInt16.max, centralDirectorySize != UInt32.max,
      centralDirectoryOffset != UInt32.max
    else {
      throw ComposerZIPExtractionError.unsupportedZIP64Archive
    }
    guard Int(entryCount) <= limits.maximumEntries else {
      throw ComposerZIPExtractionError.tooManyEntries(
        limit: limits.maximumEntries,
        actual: Int(entryCount)
      )
    }
    guard endOffset + 22 + Int(commentLength) == data.count else {
      throw ComposerZIPExtractionError.invalidArchive
    }

    let centralStart = Int(centralDirectoryOffset)
    let centralEnd = centralStart + Int(centralDirectorySize)
    guard centralStart >= 0, centralEnd >= centralStart, centralEnd <= endOffset else {
      throw ComposerZIPExtractionError.invalidArchive
    }

    var entries: [Entry] = []
    entries.reserveCapacity(Int(entryCount))
    var cursor = centralStart
    var totalUncompressed: UInt64 = 0
    for _ in 0..<entryCount {
      guard try data.uint32(at: cursor) == 0x0201_4B50 else {
        throw ComposerZIPExtractionError.invalidArchive
      }
      let versionMadeBy = try data.uint16(at: cursor + 4)
      let flags = try data.uint16(at: cursor + 8)
      let method = try data.uint16(at: cursor + 10)
      let crc32 = try data.uint32(at: cursor + 16)
      let compressedSize32 = try data.uint32(at: cursor + 20)
      let uncompressedSize32 = try data.uint32(at: cursor + 24)
      let nameLength = Int(try data.uint16(at: cursor + 28))
      let extraLength = Int(try data.uint16(at: cursor + 30))
      let entryCommentLength = Int(try data.uint16(at: cursor + 32))
      let entryDisk = try data.uint16(at: cursor + 34)
      let externalAttributes = try data.uint32(at: cursor + 38)
      let localHeaderOffset32 = try data.uint32(at: cursor + 42)
      let variableLength = nameLength + extraLength + entryCommentLength
      guard nameLength > 0, cursor + 46 + variableLength <= centralEnd else {
        throw ComposerZIPExtractionError.invalidArchive
      }
      guard entryDisk == 0 else {
        throw ComposerZIPExtractionError.unsupportedMultiDiskArchive
      }
      guard compressedSize32 != UInt32.max, uncompressedSize32 != UInt32.max,
        localHeaderOffset32 != UInt32.max
      else {
        throw ComposerZIPExtractionError.unsupportedZIP64Archive
      }

      let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
      guard let name = String(data: nameData, encoding: .utf8), !name.contains("\0") else {
        throw ComposerZIPExtractionError.invalidEntryName
      }
      guard flags & 0x0001 == 0 else {
        throw ComposerZIPExtractionError.encryptedEntry(name)
      }
      guard method == 0 || method == 8 else {
        throw ComposerZIPExtractionError.unsupportedCompressionMethod(method)
      }

      let creatorSystem = versionMadeBy >> 8
      let unixMode = creatorSystem == 3 ? UInt16(externalAttributes >> 16) : 0
      let fileType = unixMode & 0xF000
      guard fileType != 0xA000 else {
        throw ComposerZIPExtractionError.symbolicLink(name)
      }
      guard fileType == 0 || fileType == 0x4000 || fileType == 0x8000 else {
        throw ComposerZIPExtractionError.unsafeEntryPath(name)
      }

      let isDirectory = name.hasSuffix("/") || fileType == 0x4000
      let components = try pathComponents(for: name, isDirectory: isDirectory, limits: limits)
      let uncompressedSize = UInt64(uncompressedSize32)
      if isDirectory,
        crc32 != 0 || compressedSize32 != 0 || uncompressedSize32 != 0
      {
        throw ComposerZIPExtractionError.invalidCompressedSize(name)
      }
      guard uncompressedSize <= limits.maximumEntryBytes else {
        throw ComposerZIPExtractionError.entryTooLarge(
          path: name,
          limit: limits.maximumEntryBytes,
          actual: uncompressedSize
        )
      }
      let (nextTotal, overflow) = totalUncompressed.addingReportingOverflow(uncompressedSize)
      guard !overflow, nextTotal <= limits.maximumTotalBytes else {
        throw ComposerZIPExtractionError.archiveTooLarge(
          limit: limits.maximumTotalBytes,
          actual: overflow ? UInt64.max : nextTotal
        )
      }
      totalUncompressed = nextTotal

      entries.append(
        Entry(
          name: name,
          nameData: nameData,
          components: components,
          isDirectory: isDirectory,
          compressionMethod: method,
          crc32: crc32,
          compressedSize: UInt64(compressedSize32),
          uncompressedSize: uncompressedSize,
          localHeaderOffset: UInt64(localHeaderOffset32),
          isExecutable: unixMode & 0o111 != 0
        )
      )
      cursor += 46 + variableLength
    }
    guard cursor == centralEnd else {
      throw ComposerZIPExtractionError.invalidArchive
    }
    try validateEntryRelationships(entries)
    return entries
  }

  private static func pathComponents(
    for name: String,
    isDirectory: Bool,
    limits: ComposerZIPExtractionLimits
  ) throws -> [String] {
    guard !name.hasPrefix("/"), !name.hasPrefix("\\"), !name.contains("\\"),
      name.utf8.count <= 4_096
    else {
      throw ComposerZIPExtractionError.unsafeEntryPath(name)
    }
    var rawComponents = name.split(separator: "/", omittingEmptySubsequences: false).map(
      String.init)
    if isDirectory, rawComponents.last == "" {
      rawComponents.removeLast()
    }
    guard !rawComponents.isEmpty, rawComponents.count <= limits.maximumPathDepth,
      rawComponents.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
      }),
      !(rawComponents.first?.range(of: #"^[A-Za-z]:$"#, options: .regularExpression) != nil)
    else {
      throw ComposerZIPExtractionError.unsafeEntryPath(name)
    }
    return rawComponents
  }

  private static func validateEntryRelationships(_ entries: [Entry]) throws {
    var entryTypes: [String: Bool] = [:]
    for entry in entries {
      let canonical = canonicalPath(entry.components)
      guard entryTypes[canonical] == nil else {
        throw ComposerZIPExtractionError.duplicateEntry(entry.name)
      }
      entryTypes[canonical] = entry.isDirectory
    }

    for entry in entries {
      guard entry.components.count > 1 else {
        continue
      }
      for length in 1..<entry.components.count {
        let prefix = canonicalPath(Array(entry.components.prefix(length)))
        if entryTypes[prefix] == false {
          throw ComposerZIPExtractionError.entryCollision(entry.name)
        }
      }
    }
  }

  private static func canonicalPath(_ components: [String]) -> String {
    components.map {
      $0.precomposedStringWithCanonicalMapping.lowercased()
    }.joined(separator: "/")
  }

  private static func endOfCentralDirectoryOffset(in data: Data) throws -> Int {
    guard data.count >= 22 else {
      throw ComposerZIPExtractionError.invalidArchive
    }
    let lowerBound = max(0, data.count - 22 - Int(UInt16.max))
    for offset in stride(from: data.count - 22, through: lowerBound, by: -1) {
      if (try? data.uint32(at: offset)) == 0x0605_4B50 {
        return offset
      }
    }
    throw ComposerZIPExtractionError.invalidArchive
  }

  private static func extract(
    _ entry: Entry,
    from archiveData: Data,
    to targetURL: URL
  ) throws {
    let localOffset = Int(entry.localHeaderOffset)
    guard try archiveData.uint32(at: localOffset) == 0x0403_4B50 else {
      throw ComposerZIPExtractionError.invalidArchive
    }
    let localFlags = try archiveData.uint16(at: localOffset + 6)
    let localMethod = try archiveData.uint16(at: localOffset + 8)
    let localNameLength = Int(try archiveData.uint16(at: localOffset + 26))
    let localExtraLength = Int(try archiveData.uint16(at: localOffset + 28))
    let nameStart = localOffset + 30
    let dataStart = nameStart + localNameLength + localExtraLength
    let dataEnd = dataStart + Int(entry.compressedSize)
    guard localFlags & 0x0001 == 0, localMethod == entry.compressionMethod,
      nameStart >= 0, dataStart >= nameStart, dataEnd >= dataStart,
      dataEnd <= archiveData.count,
      archiveData.subdata(in: nameStart..<(nameStart + localNameLength)) == entry.nameData
    else {
      throw ComposerZIPExtractionError.invalidArchive
    }

    let compressedData = archiveData[dataStart..<dataEnd]
    let result: (crc32: UInt32, byteCount: UInt64)
    switch entry.compressionMethod {
    case 0:
      guard entry.compressedSize == entry.uncompressedSize else {
        throw ComposerZIPExtractionError.invalidCompressedSize(entry.name)
      }
      result = try writeStored(compressedData, to: targetURL)
    case 8:
      result = try inflate(
        compressedData,
        to: targetURL,
        path: entry.name,
        maximumOutputBytes: entry.uncompressedSize
      )
    default:
      throw ComposerZIPExtractionError.unsupportedCompressionMethod(entry.compressionMethod)
    }
    guard result.byteCount == entry.uncompressedSize else {
      throw ComposerZIPExtractionError.invalidCompressedSize(entry.name)
    }
    guard result.crc32 == entry.crc32 else {
      throw ComposerZIPExtractionError.checksumMismatch(
        path: entry.name,
        expected: entry.crc32,
        actual: result.crc32
      )
    }
  }

  private static func writeStored(
    _ data: Data.SubSequence,
    to targetURL: URL
  ) throws -> (crc32: UInt32, byteCount: UInt64) {
    let handle = try FileHandle(forWritingTo: targetURL)
    defer { try? handle.close() }
    var checksum = CRC32()
    var offset = data.startIndex
    while offset < data.endIndex {
      let end = min(offset + 1_048_576, data.endIndex)
      let chunk = Data(data[offset..<end])
      try handle.write(contentsOf: chunk)
      checksum.update(chunk)
      offset = end
    }
    return (checksum.finalized, UInt64(data.count))
  }

  private static func inflate(
    _ data: Data.SubSequence,
    to targetURL: URL,
    path: String,
    maximumOutputBytes: UInt64
  ) throws -> (crc32: UInt32, byteCount: UInt64) {
    let handle = try FileHandle(forWritingTo: targetURL)
    defer { try? handle.close() }
    let initialDestination = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    let initialSource = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    defer {
      initialDestination.deallocate()
      initialSource.deallocate()
    }
    var stream = compression_stream(
      dst_ptr: initialDestination,
      dst_size: 0,
      src_ptr: UnsafePointer(initialSource),
      src_size: 0,
      state: nil
    )
    guard
      compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        != COMPRESSION_STATUS_ERROR
    else {
      throw ComposerZIPExtractionError.decompressionFailed(path)
    }
    defer { compression_stream_destroy(&stream) }

    let destinationCapacity = 64 * 1_024
    let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationCapacity)
    defer { destination.deallocate() }
    var checksum = CRC32()
    var byteCount: UInt64 = 0

    let status = try data.withUnsafeBytes { sourceBuffer -> compression_status in
      stream.src_ptr =
        sourceBuffer.bindMemory(to: UInt8.self).baseAddress
        ?? UnsafePointer(initialSource)
      stream.src_size = sourceBuffer.count
      while true {
        stream.dst_ptr = destination
        stream.dst_size = destinationCapacity
        let status = compression_stream_process(
          &stream,
          Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
        )
        let produced = destinationCapacity - stream.dst_size
        if produced > 0 {
          let (nextByteCount, overflow) = byteCount.addingReportingOverflow(UInt64(produced))
          guard !overflow, nextByteCount <= maximumOutputBytes else {
            throw ComposerZIPExtractionError.invalidCompressedSize(path)
          }
          let chunk = Data(bytes: destination, count: produced)
          try handle.write(contentsOf: chunk)
          checksum.update(chunk)
          byteCount = nextByteCount
        }
        switch status {
        case COMPRESSION_STATUS_END:
          return status
        case COMPRESSION_STATUS_ERROR:
          return status
        default:
          if produced == 0, stream.src_size == 0 {
            return COMPRESSION_STATUS_ERROR
          }
        }
      }
    }
    guard status == COMPRESSION_STATUS_END else {
      throw ComposerZIPExtractionError.decompressionFailed(path)
    }
    return (checksum.finalized, byteCount)
  }
}

private struct CRC32 {
  private static let table: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 {
      crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
    }
    return crc
  }

  private var value: UInt32 = 0xFFFF_FFFF

  mutating func update(_ data: Data) {
    for byte in data {
      let index = Int((value ^ UInt32(byte)) & 0xFF)
      value = Self.table[index] ^ (value >> 8)
    }
  }

  var finalized: UInt32 {
    value ^ 0xFFFF_FFFF
  }
}

extension Data {
  fileprivate func uint16(at offset: Int) throws -> UInt16 {
    guard offset >= 0, offset + 2 <= count else {
      throw ComposerZIPExtractionError.invalidArchive
    }
    return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
  }

  fileprivate func uint32(at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= count else {
      throw ComposerZIPExtractionError.invalidArchive
    }
    return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8
      | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
  }
}
