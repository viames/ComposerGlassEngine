# Changelog

All notable changes to ComposerGlass Engine are documented in this file.

The project follows Semantic Versioning. During the `0.x` series, minor
versions may contain source-breaking API improvements.

## 0.4.0 — 2026-08-27

### Added

- A deterministic, highest-compatible dependency resolver for numeric package
  versions.
- Root and transitive `require` processing with cycle-safe backtracking.
- PHP, extension, library, and Composer platform-package validation.
- `minimum-stability`, root stability flags, and `prefer-stable` policies.
- Structured resolution failures containing contributing constraints and
  available repository versions.
- A package-source protocol and typed repository-package initializer for custom
  repositories and deterministic tests.

## 0.3.0 — 2026-08-27

### Added

- An asynchronous, HTTPS-only Composer 2 repository client based on
  `URLSession` and Swift concurrency.
- `packages.json`, `metadata-url`, regular `p2`, and development metadata
  loading.
- Expansion of `composer/2.0` minified package metadata.
- `available-packages` and wildcard pattern filtering.
- Conditional `Last-Modified` requests, in-memory metadata fallback, and
  negative caching for missing packages.
- Structure-preserving typed access to package versions and download URLs.

## 0.2.0 — 2026-08-27

### Added

- Structure-preserving `composer.lock` decoding and deterministic encoding.
- Typed access to runtime and development package entries.
- Locked-package sorting, required-field validation, and duplicate detection.
- Composer-compatible `content-hash` generation, including platform overrides.
- Freshness checks between `composer.json` and `composer.lock`.

## 0.1.0 — 2026-08-27

### Added

- A dependency-free Swift library product for macOS 14 and later.
- Structure-preserving `composer.json` decoding and encoding.
- Typed root requirement inspection and mutation.
- Numeric Composer version parsing and stability ordering.
- Exact, comparison, caret, tilde, wildcard, hyphen, AND, and OR constraints.
- Security policy, contribution guide, compatibility matrix, and Italian
  documentation.
