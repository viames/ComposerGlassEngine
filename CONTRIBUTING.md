# Contributing

Thank you for helping improve ComposerGlass Engine.

Before opening a pull request:

1. Add focused tests for behavior changes.
2. Run `swift test` from the package root.
3. Document compatibility differences from Composer.
4. Avoid adding runtime dependencies or process execution.
5. Do not include private manifests, credentials, or package source code.
6. When changing the Composer baseline, follow `COMPOSER-UPSTREAM.md` and
   update the Swift reference and JSON manifest together.

Contributions are submitted under the repository's MIT License. Compatibility
claims need a reproducible fixture or a link to public Composer documentation.
