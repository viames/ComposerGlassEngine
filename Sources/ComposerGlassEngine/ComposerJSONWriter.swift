import Foundation

/// Writes the JSON layout used by Composer's generated project files.
enum ComposerJSONWriter {
  static func data(
    _ value: JSONValue,
    rootOrder: [String]? = nil,
    keyOrders: [String: [String]] = [:]
  ) -> Data {
    Data(
      (write(
        value,
        indent: 0,
        rootOrder: rootOrder,
        keyOrders: keyOrders,
        path: ""
      ) + "\n").utf8
    )
  }

  private static func write(
    _ value: JSONValue,
    indent: Int,
    rootOrder: [String]?,
    keyOrders: [String: [String]],
    path: String
  ) -> String {
    switch value {
    case .null: return "null"
    case .bool(let value): return value ? "true" : "false"
    case .number(let value):
      return String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), value)
    case .string(let value):
      return encodeString(value)
    case .array(let values):
      guard !values.isEmpty else { return "[]" }
      let padding = String(repeating: " ", count: (indent + 1) * 4)
      let closing = String(repeating: " ", count: indent * 4)
      return "[\n" + values.enumerated().map { index, value in
        padding + write(
          value,
          indent: indent + 1,
          rootOrder: rootOrder,
          keyOrders: keyOrders,
          path: childPath(path, String(index))
        )
      }.joined(separator: ",\n") + "\n" + closing + "]"
    case .object(let fields):
      guard !fields.isEmpty else { return "{}" }
      let preferred = keyOrders[path] ?? rootOrder ?? {
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
        let keyJSON = encodeString(key)
        let childOrder = preferredOrder(for: key)
        return padding + keyJSON + ": " + write(
          fields[key]!,
          indent: indent + 1,
          rootOrder: childOrder,
          keyOrders: keyOrders,
          path: childPath(path, key)
        )
      }.joined(separator: ",\n") + "\n" + closing + "}"
    }
  }

  private static func encodeString(_ value: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let encoded = try! encoder.encode(value)
    return String(decoding: encoded, as: UTF8.self)
  }

  private static func childPath(_ parent: String, _ component: String) -> String {
    let escaped = component
      .replacingOccurrences(of: "~", with: "~0")
      .replacingOccurrences(of: "/", with: "~1")
    return parent + "/" + escaped
  }

  private static func preferredOrder(for key: String) -> [String]? {
    switch key {
    case "_readme": return nil
    case "source": return ["type", "url", "reference", "mirrors"]
    case "dist": return ["type", "url", "reference", "shasum", "mirrors"]
    case "require", "require-dev", "conflict", "provide", "replace", "suggest": return []
    case "extra": return ["branch-alias"]
    case "autoload", "autoload-dev": return ["psr-4", "psr-0", "classmap", "files", "exclude-from-classmap"]
    case "support": return ["issues", "source", "docs", "forum", "wiki", "irc", "email", "rss"]
    case "authors": return ["name", "email", "homepage", "role"]
    case "funding": return ["url", "type"]
    case "aliases": return ["package", "version", "alias", "alias_normalized"]
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
    "name", "version", "target-dir", "source", "dist", "require", "conflict",
    "provide", "replace", "require-dev", "suggest", "default-branch", "bin",
    "type", "extra", "autoload", "autoload-dev", "notification-url",
    "include-path", "php-ext", "archive", "scripts", "license", "authors",
    "description", "homepage", "keywords", "repositories", "support", "funding",
    "abandoned", "minimum-stability", "transport-options", "time",
  ]
}
