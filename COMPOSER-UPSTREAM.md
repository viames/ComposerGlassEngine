# Composer upstream baseline

[Documentazione italiana](COMPOSER-UPSTREAM.it.md)

ComposerGlass Engine `0.1.0` uses Composer `2.10.2` as its behavioral
compatibility baseline:

- release date: `2026-07-01`;
- signed upstream tag: `2.10.2`;
- immutable source commit: `8d4439f572a97670a9edc039eb3b093cc976b4bc`;
- upstream repository: <https://github.com/composer/composer>.

The same data is available to automation in `COMPOSER-UPSTREAM.json` and to
Swift clients through `ComposerUpstreamReference.current`. Tests require the
two representations to remain identical.

This baseline identifies the Composer source and behavior reviewed while
building the supported native feature set. It does not claim that the Swift
implementation contains Composer source code or that every Composer feature
is supported. The exact supported and intentionally unsupported areas remain
listed in `COMPATIBILITY.md` and in the machine-readable manifest.

## Comparing a future Composer release

Clone or update an official Composer checkout, then run:

```sh
./script/compare_composer_upstream.sh /path/to/composer 2.11.0
```

The report groups changed files into solver and package semantics, repository
and download behavior, installation and autoloading, and command, schema, and
security changes. It also prints the complete upstream diff statistics.

For every baseline update:

1. Verify the official signed release tag and record the peeled commit SHA.
2. Review the grouped source diff and the complete upstream changelog.
3. Treat security changes as mandatory review items, including changes outside
   the currently implemented subset.
4. Add deterministic compatibility fixtures for relevant observable behavior.
5. Compare correctness and performance with the same public or reproducible
   fixtures before and after the engine change.
6. Update `ComposerUpstreamReference.current`, `COMPOSER-UPSTREAM.json`, this
   document, `COMPATIBILITY.md`, and `CHANGELOG.md` in the same pull request.
7. Run `swift test` and the ComposerGlass application test suite.

Keeping the old baseline in Git history makes each engine release directly
comparable with the exact Composer revision it targeted.
