# Compatibility

ComposerGlass Engine uses semantic versioning for its own API. Until version
`1.0.0`, source compatibility may change between minor releases.

## Implemented

| Area | Status |
| --- | --- |
| `composer.json` JSON preservation | Implemented |
| Root requirement access and mutation | Implemented |
| `composer.lock` JSON preservation | Implemented |
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
| HTTPS-only native repository transport | Implemented |
| Numeric root and transitive `require` resolution | Implemented |
| Deterministic highest-compatible backtracking | Implemented |
| Platform-package requirement validation | Implemented |
| `minimum-stability`, root stability flags, and `prefer-stable` | Implemented |
| Structured dependency-resolution problems | Implemented |

## Planned

| Area | Status |
| --- | --- |
| Persistent repository metadata cache | Planned |
| Composer 1 provider/include repository protocol | Planned |
| Branch aliases and development branch resolution | Planned |
| `conflict`, `replace`, `provide`, and provided virtual packages | Planned |
| Full Composer SAT solver equivalence | Planned |
| Package download and cache | Planned |
| ZIP extraction | Planned |
| Transactional installation | Planned |
| PSR-0, PSR-4, files, and classmap autoloading | Planned |
| `vendor/bin` proxy generation | Planned |
| Security advisory audit | Planned |

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
