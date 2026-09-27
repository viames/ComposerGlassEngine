# ComposerGlass Engine

[Documentazione italiana](README.it.md)

[![CI](https://github.com/viames/ComposerGlassEngine/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/viames/ComposerGlassEngine/actions/workflows/ci.yml?query=branch%3Amain)
[![Latest release](https://img.shields.io/github/v/release/viames/ComposerGlassEngine)](https://github.com/viames/ComposerGlassEngine/releases/latest)
[![License](https://img.shields.io/github/license/viames/ComposerGlassEngine)](LICENSE)

ComposerGlass Engine is an independent, unofficial Composer-compatible
dependency engine written in Swift. It is not affiliated with or endorsed by
the Composer project.

The current `0.2.x` behavioral baseline is Composer `2.10.3`, tag `2.10.3`, commit
`f0de0bf90226853b841672f086d8b58b02332504`. See
[COMPOSER-UPSTREAM.md](COMPOSER-UPSTREAM.md) for the machine-readable reference
and the future-release comparison workflow.

The package is being built for native developer tools that need to inspect,
resolve, and install PHP dependencies without launching PHP, Composer, a shell,
or another executable. The initial `0.x` releases intentionally implement a
safe subset of Composer and never execute downloaded package code.

## Documentation

| Topic | Canonical document |
| --- | --- |
| API overview and examples | This README |
| Supported features and intentional exclusions | [COMPATIBILITY.md](COMPATIBILITY.md) |
| Composer reference version and upgrade workflow | [COMPOSER-UPSTREAM.md](COMPOSER-UPSTREAM.md) |
| Contribution requirements | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Security boundaries and private reporting | [SECURITY.md](SECURITY.md) |
| Release history | [CHANGELOG.md](CHANGELOG.md) |

## Supported surface

- **Project files:** structure-preserving `composer.json` and `composer.lock`,
  Composer-compatible `content-hash`, byte-identical lockfile serialization,
  validation, and duplicate detection.
- **Resolution:** Composer 2 repository metadata, numeric and development
  versions, common constraint operators, stability policies, transitive
  backtracking, aliases, conflicts, replacements, providers, and platform
  packages.
- **Transport and extraction:** HTTPS-only metadata and distribution access,
  conditional caching, SHA-1/SHA-256 verification, bounded ZIP downloads, and
  native stored/DEFLATE extraction with path, collision, CRC-32, and expansion
  protection.
- **Generated output:** deterministic vendor trees, installed-package metadata,
  PSR-0, PSR-4, classmap and files autoloading, plus `vendor/bin` proxies.
- **Operations and recovery:** native install, update, selected update,
  `require`, `remove`, `validate`, `show`, `outdated`, `audit`, and
  `dump-autoload`, with external transaction state, backups, crash recovery,
  and rollback.

The package has no runtime dependencies and is suitable for static linking.
Review [COMPATIBILITY.md](COMPATIBILITY.md) before modifying a project.

## Lockfile byte compatibility

For the same resolved dependency state, every supported operation must produce
the exact bytes written by the official baseline Composer release. Semantic
JSON equality is insufficient because whitespace, escaping, ordering, or field
presence alone can create noisy Git changes. The complete normative contract
and test requirements live in [COMPATIBILITY.md](COMPATIBILITY.md); baseline
updates follow [COMPOSER-UPSTREAM.md](COMPOSER-UPSTREAM.md).

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
so an interrupted operation can be recovered or rolled back. Transaction
state, staging directories, and backups are stored outside managed projects in
ComposerGlass's Application Support directory. Existing
`.composerglass-engine` directories are migrated automatically, including
journal paths required for recovery and rollback.

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
