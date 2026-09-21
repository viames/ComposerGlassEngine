import Foundation

/// Writes the JSON layout used by Composer's generated project files.
enum ComposerJSONWriter {
  static func data(_ value: JSONValue, rootOrder: [String]? = nil) -> Data {
    Data((write(value, indent: 0, rootOrder: rootOrder) + "\n").utf8)
  }

  private static func write(_ value: JSONValue, indent: Int, rootOrder: [String]?) -> String {
    switch value {
    case .null: return "null"
    case .bool(let value): return value ? "true" : "false"
    case .number(let value):
      return String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), value)
    case .string(let value):
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.withoutEscapingSlashes]
      let encoded = try! encoder.encode(value)
      return String(decoding: encoded, as: UTF8.self)
    case .array(let values):
      guard !values.isEmpty else { return "[]" }
      let padding = String(repeating: " ", count: (indent + 1) * 4)
      let closing = String(repeating: " ", count: indent * 4)
      return "[\n" + values.map {
        padding + write($0, indent: indent + 1, rootOrder: nil)
      }.joined(separator: ",\n") + "\n" + closing + "]"
    case .object(let fields):
      guard !fields.isEmpty else { return "{}" }
      let preferred = rootOrder ?? {
        if fields["name"] != nil && fields["version"] != nil { return packageOrder }
        if fields["name"] != nil && fields["homepage"] != nil {
          return ["name", "homepage", "email", "role"]
        }
        return []
      }()
      let keys = preferred.filter { fields[$0] != nil }
        + fields.keys.filter { !preferred.contains($0) }.sorted()
      let padding = String(repeating: " ", count: (indent + 1) * 4)
      let closing = String(repeating: " ", count: indent * 4)
      return "{\n" + keys.map { key in
        let keyJSON = String(decoding: try! JSONEncoder().encode(key), as: UTF8.self)
        let childOrder = preferredOrder(for: key)
        return padding + keyJSON + ": " + write(fields[key]!, indent: indent + 1, rootOrder: childOrder)
      }.joined(separator: ",\n") + "\n" + closing + "}"
    }
  }

  private static func preferredOrder(for key: String) -> [String]? {
    switch key {
    case "_readme": return nil
    case "source": return ["type", "url", "reference"]
    case "dist": return ["type", "url", "reference", "shasum"]
    case "require", "require-dev", "conflict", "provide", "replace", "suggest": return []
    case "extra": return ["branch-alias"]
    case "autoload", "autoload-dev": return ["psr-0", "psr-4", "classmap", "files", "exclude-from-classmap"]
    case "support": return ["issues", "source", "docs", "wiki", "irc", "rss", "chat"]
    case "authors": return ["name", "homepage", "email", "role"]
    case "branch-alias": return nil
    default: return nil
    }
  }

  static let lockRootOrder = [
    "_readme", "content-hash", "packages", "packages-dev", "aliases",
    "minimum-stability", "stability-flags", "prefer-stable", "prefer-lowest",
    "platform", "platform-dev", "platform-overrides", "plugin-api-version",
  ]

  static let packageOrder = [
    "name", "version", "version_normalized", "source", "dist", "require",
    "conflict", "provide", "replace", "require-dev", "suggest", "type",
    "extra", "autoload", "autoload-dev", "notification-url", "license",
    "authors", "description", "homepage", "keywords", "support", "funding",
    "time", "default-branch", "bin", "include-path", "archive", "abandoned",
    "transport-options",
  ]
}
