# Compatibility

ComposerGlass Engine uses semantic versioning for its own API. Until version
`1.0.0`, source compatibility may change between minor releases.

The current behavioral reference is Composer `2.10.3`, tag `2.10.3`, commit
`f0de0bf90226853b841672f086d8b58b02332504`. The reference is versioned in
`COMPOSER-UPSTREAM.json` and exposed by `ComposerUpstreamReference.current`.
See `COMPOSER-UPSTREAM.md` for the required comparison workflow.

## Normative `composer.lock` serialization contract

Within the supported feature set, an unchanged resolved dependency state must
produce no `composer.lock` Git diff when switching between ComposerGlass Engine
and the official baseline release. The complete serialized bytes are part of
the compatibility surface; decoded JSON equality alone is not sufficient.

The contract covers:

- whitespace, indentation, and the final newline;
- escaping of keys and values, including slashes and Unicode;
- root, package, and nested object field order;
- array order; and
- exact attribute inclusion or omission.

A format-only diff is a regression. Serialization changes require focused
fixtures and a realistic official lockfile fixture that compare complete
generated `Data` byte for byte. When the baseline changes, review Composer's
lockfile dumper and JSON writer before regenerating those fixtures.

## Implemented

| Area | Status |
| --- | --- |
| `composer.json` JSON preservation | Implemented |
| Root requirement access and mutation | Implemented |
| `composer.lock` byte-for-byte official serialization parity | Implemented |
| Locked package inspection and deterministic ordering | Implemented |
| Required lock field and duplicate validation | Implemented |
| Composer-compatible `content-hash` | Implemented |
| Manifest/lock freshness checks | Implemented |
| Numeric Composer versions | Implemented |
| Stability ordering | Implemented |
| Exact and comparison constraints | Implemented |
| Caret and tilde constraints | Implemented |
| Wildcard and hyphen constraints | Implemented |
| AND and OR constraint groups | Implemented |
| Composer 2 `packages.json` and `metadata-url` | Implemented |
| Composer 2 `p2` package metadata | Implemented |
| `composer/2.0` metadata expansion | Implemented |
| `available-packages` and wildcard filtering | Implemented |
| `Last-Modified` revalidation and in-memory fallback | Implemented |
| Concurrent loading and persistent repository metadata cache | Implemented |
| HTTPS-only native repository transport | Implemented |
| Numeric root and transitive `require` resolution | Implemented |
| Deterministic highest-compatible backtracking | Implemented |
| Branch aliases and development branch resolution | Implemented |
| `conflict`, `replace`, `provide`, and provided virtual packages | Implemented |
| Platform-package requirement validation | Implemented |
| `minimum-stability`, root stability flags, and `prefer-stable` | Implemented |
| Structured dependency-resolution problems | Implemented |
| HTTPS-only ZIP distribution download | Implemented |
| Composer SHA-1 and local SHA-256 archive verification | Implemented |
| Persistent verified package archive cache | Implemented |
| Configurable in-flight archive-size limit | Implemented |
| Stored and DEFLATE ZIP extraction | Implemented |
| CRC-32 validation and automatic extraction rollback | Implemented |
| ZIP path, symlink, collision, and expansion protection | Implemented |
| Deterministic new-vendor tree materialization | Implemented |
| `vendor/composer/installed.json` generation | Implemented |
| Failed new-vendor cleanup | Implemented |
| Transactional `vendor` activation, recovery, and rollback | Implemented |
| PSR-0, PSR-4, files, and classmap autoloading | Implemented |
| `vendor/bin` proxy generation | Implemented |
| Deterministic lock generation | Implemented |
| Native install from `composer.lock` | Implemented |
| Native update, selected update, `require`, and `remove` | Implemented |
| Project mutation backup, recovery, and rollback | Implemented |
| External transaction state and legacy project-state migration | Implemented |
| Native validate, show, and outdated inspection | Implemented |
| Packagist security advisory audit | Implemented |
| Native dump-autoload maintenance | Implemented |

## Planned

| Area | Status |
| --- | --- |
| Composer 1 provider/include repository protocol | Planned |
| Full Composer SAT solver equivalence | Planned |

## Intentionally unsupported in the App Store profile

- Composer plugins
- Composer scripts and arbitrary project commands
- Executing downloaded PHP code
- `source` installations that require Git or another VCS executable
- `path` and `artifact` repositories
- Composer self-update

The compatibility target is Composer's documented file formats and observable
results for the supported feature set. Passing the package's tests does not yet
imply drop-in compatibility with Composer.
