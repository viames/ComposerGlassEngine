# Security policy

## Supported versions

Only the most recent release receives security fixes while the project is in
the `0.x` development series.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature for this
repository. Include a minimal reproducer, the affected version, and the
expected security boundary.

Do not include credentials, private package metadata, or proprietary source
code in a report.

## Security boundaries

ComposerGlass Engine treats manifests, repository metadata, archives, and
package contents as untrusted input. The library must not:

- execute package code, Composer plugins, or Composer scripts;
- invoke PHP, Composer, a shell, Git, or another executable;
- write outside an explicitly supplied workspace;
- follow archive paths or symbolic links outside their destination;
- emit credentials in errors or logs.

The default repository client accepts HTTPS URLs only and verifies the final
response URL after redirects. Custom transports must preserve the same
security boundary.

The native package downloader enforces a configurable transfer limit and
verifies cached archives before reuse. The ZIP extractor validates every entry
before creating its destination, rejects symbolic links and unsafe paths,
checks CRC-32 values, bounds expansion, and removes incomplete output after a
failure.

The package materializer only writes to a destination that does not already
exist. A failed materialization removes that new tree in full and never alters
an active project vendor directory.
