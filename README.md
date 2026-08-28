# ComposerGlass Engine

[Documentazione italiana](README.it.md)

ComposerGlass Engine is an independent, unofficial Composer-compatible
dependency engine written in Swift. It is not affiliated with or endorsed by
the Composer project.

The current behavioral baseline is Composer `2.10.2`, tag `2.10.2`, commit
`8d4439f572a97670a9edc039eb3b093cc976b4bc`. See
[COMPOSER-UPSTREAM.md](COMPOSER-UPSTREAM.md) for the machine-readable reference
and the future-release comparison workflow.

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
- Branch aliases, development versions, `conflict`, `replace`, `provide`, and
  virtual-package provider discovery.
- PHP, extension, library, and Composer platform-package validation.
- `minimum-stability`, root stability flags, and `prefer-stable` selection.
- Structured resolution problems with contributing constraints and available
  repository versions.
- Asynchronous HTTPS-only ZIP downloads with in-flight size enforcement.
- Persistent package archive caching with SHA-256 validation and optional
  Composer SHA-1 verification.
- Native stored/DEFLATE ZIP extraction with CRC-32 validation, path containment,
  expansion limits, and rollback on failure.
- Deterministic materialization of new vendor trees with installed-package
  metadata and all-or-nothing cleanup on failure.
- PSR-0, PSR-4, classmap, and files autoload generation, plus deterministic
  `vendor/bin` proxy generation.
- Transactional active-vendor replacement with journaled recovery and rollback.
- Deterministic lock generation and native update, selected update, `require`,
  and `remove` workflows with project-file backups.
- Native `install`, `validate`, `show`, `outdated`, `audit`, and
  `dump-autoload` services.
- A dependency-free Swift Package suitable for static linking.

See [COMPATIBILITY.md](COMPATIBILITY.md) before using the package for project
modifications.

## Requirements

- Swift 6.0 or later
- macOS 14 or later

## Usage

```swift
import Foundation
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

    if !result.packages.isEmpty,
       let caches = FileManager.default.urls(
           for: .cachesDirectory,
           in: .userDomainMask
       ).first {
        let downloader = try ComposerPackageDownloader(
            cacheDirectory: caches.appendingPathComponent("ComposerGlassEngine")
        )
        let materializer = ComposerPackageMaterializer(downloader: downloader)
        let materialized = try await materializer.materialize(
            result,
            at: caches.appendingPathComponent(
                "ComposerGlassEngine-Vendor-\(UUID().uuidString)"
            )
        )
    }
}
```

The resolver supports numeric and development package versions, root and
transitive `require` constraints, platform packages, stability selection,
cycles, deterministic backtracking, branch aliases, conflicts, replacements,
and virtual providers. Full Composer SAT equivalence remains outside this
release; unsupported constraints are never silently accepted.

The downloader and extractor currently accept ZIP distributions containing
stored or DEFLATE entries. Cached content is verified before reuse; extraction
rejects unsafe paths, symbolic links, encrypted entries, duplicates, collisions,
and configured expansion limits. Package code is never executed.

The high-level native services install into a staging directory, generate
autoload metadata and binary proxies, then activate `vendor` transactionally.
Mutating dependency operations also journal `composer.json` and `composer.lock`
so an interrupted operation can be recovered or rolled back.

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
