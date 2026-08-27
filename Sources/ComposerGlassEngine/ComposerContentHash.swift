import CryptoKit
import Foundation

public enum ComposerContentHashError: Error, Equatable, Sendable {
  case invalidJSON(offset: Int)
  case rootIsNotObject
}

/// Computes the same dependency-relevant hash written by Composer in
/// `composer.lock`.
public enum ComposerContentHash {
  private static let relevantKeys = Set([
    "name",
    "version",
    "require",
    "require-dev",
    "conflict",
    "replace",
    "provide",
    "minimum-stability",
    "prefer-stable",
    "repositories",
    "extra",
  ])

  public static func compute(from composerJSON: Data) throws -> String {
    var parser = OrderedJSONParser(data: composerJSON)
    let value = try parser.parse()
    guard case .object(let rootFields) = value else {
      throw ComposerContentHashError.rootIsNotObject
    }

    var relevantFields = rootFields.filter { relevantKeys.contains($0.key) }
    if let config = rootFields.last(where: { $0.key == "config" })?.value,
      case .object(let configFields) = config,
      let platform = configFields.last(where: { $0.key == "platform" })?.value
    {
      relevantFields.append(
        OrderedJSONMember(
          key: "config",
          value: .object([OrderedJSONMember(key: "platform", value: platform)])
        )
      )
    }

    relevantFields.sort { $0.key < $1.key }
    let encoded = OrderedJSONValue.object(relevantFields).composerEncoded()
    let digest = Insecure.MD5.hash(data: Data(encoded.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

private struct OrderedJSONMember: Equatable, Sendable {
  let key: String
  let value: OrderedJSONValue
}

private indirect enum OrderedJSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case number(String)
  case string(String)
  case array([OrderedJSONValue])
  case object([OrderedJSONMember])

  func composerEncoded() -> String {
    switch self {
    case .null:
      return "null"
    case .bool(let value):
      return value ? "true" : "false"
    case .number(let value):
      return Self.normalizedNumber(value)
    case .string(let value):
      return Self.encodedString(value)
    case .array(let values):
      return "[" + values.map { $0.composerEncoded() }.joined(separator: ",") + "]"
    case .object(let members):
      return "{"
        + members.map {
          Self.encodedString($0.key) + ":" + $0.value.composerEncoded()
        }.joined(separator: ",") + "}"
    }
  }

  private static func normalizedNumber(_ value: String) -> String {
    guard
      let data = "[\(value)]".data(using: .utf8),
      let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
      let number = array.first,
      let encoded = try? JSONSerialization.data(withJSONObject: [number]),
      let result = String(data: encoded, encoding: .utf8)
    else {
      return value
    }
    return String(result.dropFirst().dropLast())
  }

  private static func encodedString(_ value: String) -> String {
    var result = "\""
    for codeUnit in value.utf16 {
      switch codeUnit {
      case 0x08:
        result += "\\b"
      case 0x09:
        result += "\\t"
      case 0x0A:
        result += "\\n"
      case 0x0C:
        result += "\\f"
      case 0x0D:
        result += "\\r"
      case 0x22:
        result += "\\\""
      case 0x2F:
        result += "\\/"
      case 0x5C:
        result += "\\\\"
      case 0x20...0x7E:
        result.unicodeScalars.append(UnicodeScalar(codeUnit)!)
      default:
        result += String(format: "\\u%04x", codeUnit)
      }
    }
    result += "\""
    return result
  }
}

private struct OrderedJSONParser {
  private let bytes: [UInt8]
  private var index = 0

  init(data: Data) {
    bytes = Array(data)
  }

  mutating func parse() throws -> OrderedJSONValue {
    skipWhitespace()
    let value = try parseValue()
    skipWhitespace()
    guard index == bytes.count else {
      throw error()
    }
    return value
  }

  private mutating func parseValue() throws -> OrderedJSONValue {
    guard let byte = current else {
      throw error()
    }
    switch byte {
    case 0x7B:
      return try parseObject()
    case 0x5B:
      return try parseArray()
    case 0x22:
      return .string(try parseString())
    case 0x74:
      try consume("true")
      return .bool(true)
    case 0x66:
      try consume("false")
      return .bool(false)
    case 0x6E:
      try consume("null")
      return .null
    case 0x2D, 0x30...0x39:
      return .number(try parseNumber())
    default:
      throw error()
    }
  }

  private mutating func parseObject() throws -> OrderedJSONValue {
    index += 1
    skipWhitespace()
    var members: [OrderedJSONMember] = []
    if consumeIfPresent(0x7D) {
      return .object(members)
    }

    while true {
      guard current == 0x22 else {
        throw error()
      }
      let key = try parseString()
      skipWhitespace()
      guard consumeIfPresent(0x3A) else {
        throw error()
      }
      skipWhitespace()
      members.append(OrderedJSONMember(key: key, value: try parseValue()))
      skipWhitespace()
      if consumeIfPresent(0x7D) {
        return .object(members)
      }
      guard consumeIfPresent(0x2C) else {
        throw error()
      }
      skipWhitespace()
    }
  }

  private mutating func parseArray() throws -> OrderedJSONValue {
    index += 1
    skipWhitespace()
    var values: [OrderedJSONValue] = []
    if consumeIfPresent(0x5D) {
      return .array(values)
    }

    while true {
      values.append(try parseValue())
      skipWhitespace()
      if consumeIfPresent(0x5D) {
        return .array(values)
      }
      guard consumeIfPresent(0x2C) else {
        throw error()
      }
      skipWhitespace()
    }
  }

  private mutating func parseString() throws -> String {
    let start = index
    index += 1
    var escaped = false

    while let byte = current {
      index += 1
      if escaped {
        escaped = false
      } else if byte == 0x5C {
        escaped = true
      } else if byte == 0x22 {
        let data = Data(bytes[start..<index])
        guard let value = try? JSONDecoder().decode(String.self, from: data) else {
          throw error()
        }
        return value
      } else if byte < 0x20 {
        throw error()
      }
    }
    throw error()
  }

  private mutating func parseNumber() throws -> String {
    let start = index
    while let byte = current,
      byte == 0x2D || byte == 0x2B || byte == 0x2E || byte == 0x45 || byte == 0x65
        || (0x30...0x39).contains(byte)
    {
      index += 1
    }
    let value = String(decoding: bytes[start..<index], as: UTF8.self)
    guard
      let data = "[\(value)]".data(using: .utf8),
      (try? JSONSerialization.jsonObject(with: data)) != nil
    else {
      throw error()
    }
    return value
  }

  private mutating func consume(_ literal: StaticString) throws {
    let literalBytes = Array(String(describing: literal).utf8)
    guard bytes[index...].starts(with: literalBytes) else {
      throw error()
    }
    index += literalBytes.count
  }

  private mutating func skipWhitespace() {
    while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
      index += 1
    }
  }

  private mutating func consumeIfPresent(_ byte: UInt8) -> Bool {
    guard current == byte else {
      return false
    }
    index += 1
    return true
  }

  private var current: UInt8? {
    index < bytes.count ? bytes[index] : nil
  }

  private func error() -> ComposerContentHashError {
    .invalidJSON(offset: index)
  }
}
