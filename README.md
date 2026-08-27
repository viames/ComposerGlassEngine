# ComposerGlass Engine

[Documentazione italiana](README.it.md)

ComposerGlass Engine is an independent, unofficial Composer-compatible
dependency engine written in Swift. It is not affiliated with or endorsed by
the Composer project.

The package is being built for native developer tools that need to inspect,
resolve, and install PHP dependencies without launching PHP, Composer, a shell,
or another executable. The initial `0.x` releases intentionally implement a
safe subset of Composer and never execute downloaded package code.

## Current capabilities

- Structure-preserving decoding and encoding of `composer.json`, including
  unknown fields.
- Typed, structure-preserving `composer.lock` decoding and deterministic
  encoding.
- Composer-compatible `content-hash` generation and lock freshness checks.
- Deterministic locked-package ordering and duplicate validation.
- Typed access to root requirements and common manifest metadata.
- Composer-style numeric version parsing and stability comparison.
- Exact, comparison, caret, tilde, wildcard, hyphen, AND, and OR constraints.
- Asynchronous Composer 2 repository discovery and package metadata loading.
- Expansion of `composer/2.0` minified metadata, conditional HTTP caching, and
  development-version endpoints.
- HTTPS-only repository and redirect validation in the App Store-safe client.
- Deterministic highest-compatible dependency resolution with transitive
  requirements and backtracking.
- PHP, extension, library, and Composer platform-package validation.
- `minimum-stability`, root stability flags, and `prefer-stable` selection.
- Structured resolution problems with contributing constraints and available
  repository versions.
- A dependency-free Swift Package suitable for static linking.

See [COMPATIBILITY.md](COMPATIBILITY.md) before using the package for project
modifications.

## Requirements

- Swift 6.0 or later
- macOS 14 or later

## Usage

```swift
import ComposerGlassEngine

let manifest = try ComposerManifest.decode(from: manifestData)
let constraint = try ComposerConstraint.parse("^3.0 || ^4.0")
let version = try ComposerVersion("3.2.1")

if constraint.matches(version) {
    // The version satisfies the declared requirement.
}

let lockFile = try ComposerLockFile.decode(from: lockData)
let isFresh = try lockFile.isFresh(for: manifestData)
let runtimePackages = try lockFile.packages()

if let repositoryURL = URL(string: "https://repo.packagist.org") {
    let repository = try ComposerRepositoryClient(repositoryURL: repositoryURL)
    let versions = try await repository.packages(named: "psr/log")

    let platform = try ComposerResolutionPlatform(packages: [
        "php": "8.4.1",
        "ext-json": "8.4.1"
    ])
    let resolver = ComposerDependencyResolver(
        source: repository,
        platform: platform
    )
    let result = try await resolver.resolve(
        requirements: ["psr/log": "^3.0"]
    )
}
```

The `0.4` resolver supports numeric package versions, root and transitive
`require` constraints, platform packages, stability selection, cycles, and
deterministic backtracking. Branch aliases, `conflict`, the `replace` and
`provide` mechanisms—including provided virtual packages—and full Composer SAT
equivalence remain outside this release; unsupported versions are never
silently installed.

## Development

```sh
swift build
swift test
```

## Security

Please read [SECURITY.md](SECURITY.md). Do not report vulnerabilities in a
public issue before the maintainers have had an opportunity to assess them.

## License and attribution

ComposerGlass Engine is available under the MIT License. Composer itself is
also MIT-licensed. This project studies Composer's public formats and behavior
to provide compatibility; it remains an independent implementation. See
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for attribution.
