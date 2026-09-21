import Foundation

/// Extracts object-key order from valid JSON without changing the decoded value.
/// Composer preserves the order of nested metadata such as `autoload` and
/// `support` when it writes `installed.json`, while Swift dictionaries do not.
struct JSONKeyOrderParser {
  private var bytes: [UInt8]
  private var index = 0
  private(set) var orders: [String: [String]] = [:]

  static func parse(_ data: Data) -> [String: [String]] {
    var parser = JSONKeyOrderParser(bytes: Array(data))
    try? parser.parseValue(path: "")
    return parser.orders
  }

  private mutating func parseValue(path: String) throws {
    skipWhitespace()
    guard index < bytes.count else { throw ParseError.unexpectedEnd }
    switch bytes[index] {
    case 0x7B:
      try parseObject(path: path)
    case 0x5B:
      try parseArray(path: path)
    case 0x22:
      _ = try parseString()
    default:
      parseScalar()
    }
  }

  private mutating func parseObject(path: String) throws {
    index += 1
    skipWhitespace()
    var keys: [String] = []
    if consume(0x7D) {
      orders[path] = keys
      return
    }
    while true {
      skipWhitespace()
      let key = try parseString()
      keys.append(key)
      skipWhitespace()
      guard consume(0x3A) else { throw ParseError.invalidJSON }
      try parseValue(path: childPath(path, key))
      skipWhitespace()
      if consume(0x7D) { break }
      guard consume(0x2C) else { throw ParseError.invalidJSON }
    }
    orders[path] = keys
  }

  private mutating func parseArray(path: String) throws {
    index += 1
    skipWhitespace()
    if consume(0x5D) { return }
    var item = 0
    while true {
      try parseValue(path: childPath(path, String(item)))
      item += 1
      skipWhitespace()
      if consume(0x5D) { break }
      guard consume(0x2C) else { throw ParseError.invalidJSON }
    }
  }

  private mutating func parseString() throws -> String {
    guard consume(0x22) else { throw ParseError.invalidJSON }
    let start = index - 1
    var escaped = false
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      if escaped {
        escaped = false
      } else if byte == 0x5C {
        escaped = true
      } else if byte == 0x22 {
        let data = Data(bytes[start..<index])
        return try JSONDecoder().decode(String.self, from: data)
      }
    }
    throw ParseError.unexpectedEnd
  }

  private mutating func parseScalar() {
    while index < bytes.count {
      switch bytes[index] {
      case 0x2C, 0x5D, 0x7D, 0x20, 0x09, 0x0A, 0x0D:
        return
      default:
        index += 1
      }
    }
  }

  private mutating func skipWhitespace() {
    while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
      index += 1
    }
  }

  private mutating func consume(_ byte: UInt8) -> Bool {
    guard index < bytes.count, bytes[index] == byte else { return false }
    index += 1
    return true
  }

  private func childPath(_ parent: String, _ component: String) -> String {
    let escaped = component
      .replacingOccurrences(of: "~", with: "~0")
      .replacingOccurrences(of: "/", with: "~1")
    return parent + "/" + escaped
  }

  private enum ParseError: Error {
    case invalidJSON
    case unexpectedEnd
  }
}
