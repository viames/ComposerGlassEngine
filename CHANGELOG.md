# Changelog

All notable changes to ComposerGlass Engine are documented in this file.

The project follows Semantic Versioning. During the `0.x` series, minor
versions may contain source-breaking API improvements.

## Unreleased

### Added

- A versioned Composer `2.10.2` upstream baseline, public Swift metadata,
  machine-readable compatibility manifest, and future-release comparison tool.
- Asynchronous, HTTPS-only ZIP distribution downloads based on `URLSession`.
- Persistent archive caching with SHA-256 validation before reuse.
- Composer SHA-1 verification when repository metadata supplies a checksum.
- Configurable archive-size limits enforced while downloading and before
  caching.
- Typed distribution metadata for archive type, reference, and checksum.
- Native extraction for stored and DEFLATE ZIP entries with CRC-32 validation.
- ZIP preflight protections against path traversal, symbolic links, duplicate
  paths, file/directory collisions, encrypted entries, and expansion bombs.
- Automatic extraction rollback and detection of a single package root.
- Deterministic materialization of complete new vendor trees from resolved
  packages.
- Composer-style `vendor/composer/installed.json` metadata and executable-bit
  preservation.
- Full new-vendor rollback when any package download or extraction fails.

## 0.1.0 — 2026-08-27

### Added

- A dependency-free Swift library product for macOS 14 and later.
- Structure-preserving `composer.json` decoding and encoding.
- Typed root requirement inspection and mutation.
- Numeric Composer version parsing and stability ordering.
- Exact, comparison, caret, tilde, wildcard, hyphen, AND, and OR constraints.
- Structure-preserving `composer.lock` decoding and deterministic encoding.
- Locked-package sorting, required-field validation, and duplicate detection.
- Composer-compatible `content-hash` generation and lock freshness checks.
- An asynchronous, HTTPS-only Composer 2 repository client.
- Regular and minified `p2` metadata, filtering, conditional requests, and
  in-memory fallback.
- Deterministic highest-compatible dependency resolution with transitive
  requirements and cycle-safe backtracking.
- Platform-package validation, stability policies, and structured resolution
  failures.
- Security policy, contribution guide, compatibility matrix, and Italian
  documentation.
