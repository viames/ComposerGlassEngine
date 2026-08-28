#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly ENGINE_DIRECTORY="$(cd "${SCRIPT_DIRECTORY}/.." && pwd -P)"
readonly MANIFEST="${ENGINE_DIRECTORY}/COMPOSER-UPSTREAM.json"

usage() {
    printf 'Usage: %s /path/to/composer-checkout TARGET_REF\n' "$0" >&2
}

if [[ $# -ne 2 ]]; then
    usage
    exit 64
fi

readonly COMPOSER_CHECKOUT="$1"
readonly TARGET_REF="$2"

if ! /usr/bin/git -C "$COMPOSER_CHECKOUT" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'error: the supplied path is not a Composer Git checkout: %s\n' \
        "$COMPOSER_CHECKOUT" >&2
    exit 66
fi

readonly BASELINE_VERSION="$(/usr/bin/plutil -extract composer.version raw "$MANIFEST")"
readonly BASELINE_COMMIT="$(/usr/bin/plutil -extract composer.commit raw "$MANIFEST")"

if ! /usr/bin/git -C "$COMPOSER_CHECKOUT" cat-file -e "${BASELINE_COMMIT}^{commit}" 2>/dev/null; then
    printf 'error: baseline commit %s is missing; fetch Composer tags first.\n' \
        "$BASELINE_COMMIT" >&2
    exit 69
fi

readonly TARGET_COMMIT="$(
    /usr/bin/git -C "$COMPOSER_CHECKOUT" rev-parse --verify "${TARGET_REF}^{commit}"
)"

printf 'ComposerGlass baseline: Composer %s (%s)\n' \
    "$BASELINE_VERSION" "$BASELINE_COMMIT"
printf 'Comparison target: %s (%s)\n' "$TARGET_REF" "$TARGET_COMMIT"

print_changes() {
    local title="$1"
    shift
    printf '\n%s\n' "$title"
    /usr/bin/git -C "$COMPOSER_CHECKOUT" diff --name-status \
        "${BASELINE_COMMIT}..${TARGET_COMMIT}" -- "$@"
}

print_changes 'Dependency solver and package semantics' \
    src/Composer/DependencyResolver \
    src/Composer/Package \
    src/Composer/Semver

print_changes 'Repositories and downloads' \
    src/Composer/Repository \
    src/Composer/Downloader \
    src/Composer/Util/Http

print_changes 'Installation, lock files, and autoloading' \
    src/Composer/Installer \
    src/Composer/Autoload \
    src/Composer/Package/Locker.php

print_changes 'Commands, schemas, security, and release notes' \
    src/Composer/Command \
    res/composer-schema.json \
    res/composer-lock-schema.json \
    CHANGELOG.md \
    SECURITY.md

printf '\nOverall upstream diff statistics\n'
/usr/bin/git -C "$COMPOSER_CHECKOUT" diff --stat \
    "${BASELINE_COMMIT}..${TARGET_COMMIT}"
