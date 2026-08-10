#!/usr/bin/env bash
#
# update-repo.sh — one command to take the workspace from "I bumped a pkgver"
# to "the repository directory is ready to upload".
#
# It chains the two halves of the release:
#
#   1. PKGBUILDS/build-all.sh --repo <this>/x86_64
#      builds only the packages whose version is not already published here,
#      copies them in, and deletes the versions they replace.
#   2. build-db.sh
#      rebuilds and signs vasakos.db / vasakos.files from whatever is now on
#      disk.
#
# The upload itself is still manual on purpose — see README.md.
#
# Usage:
#   ./update-repo.sh [options] [package-dir ...]
#
# Options:
#   -a, --all           Rebuild every package, published or not.
#   -n, --dry-run       Show what would be built and removed; change nothing.
#       --db-only       Skip the build; just rebuild the database.
#       --build-only    Build and publish, but don't touch the database.
#       --no-sign       Build the database without signing it.
#       --no-check      Skip the check-all.sh pre-flight.
#       --refresh-vcs   Refresh pkgver() versions from upstream first.
#   -h, --help          Show this help.
#
# Anything else is passed through to build-all.sh, so naming a package
# directory forces that one to be rebuilt:
#
#   ./update-repo.sh vasak-desktop-git

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ALL="$WORKSPACE/PKGBUILDS/build-all.sh"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; LBLUE=$'\033[01;34m'; DIM=$'\033[2m'; NC=$'\033[0m'
[[ -t 1 ]] || { GREEN=""; RED=""; LBLUE=""; DIM=""; NC=""; }

# The help text is the header comment itself, so the two cannot drift apart.
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; exit "${1:-0}"; }

DO_BUILD=1
DO_DB=1
DRY_RUN=0
DB_ARGS=()
BUILD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-only) DO_BUILD=0; shift ;;
    --build-only) DO_DB=0; shift ;;
    --no-sign) DB_ARGS+=(--no-sign); shift ;;
    -n|--dry-run) DRY_RUN=1; BUILD_ARGS+=(--dry-run); DO_DB=0; shift ;;
    -h|--help) usage 0 ;;
    *) BUILD_ARGS+=("$1"); shift ;;
  esac
done

if [[ $DO_BUILD -eq 1 ]]; then
  [[ -x "$BUILD_ALL" ]] || {
    echo "${RED}build-all.sh not found at $BUILD_ALL${NC}" >&2
    echo "This script expects the PKGBUILDS repo to be checked out next to this one." >&2
    exit 1
  }
  echo "${LBLUE}══ 1/2 · Building out-of-date packages ═══════════════════════════${NC}"
  "$BUILD_ALL" --repo "$SCRIPT_DIR/x86_64" "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}"
  echo
fi

if [[ $DO_DB -eq 1 ]]; then
  echo "${LBLUE}══ 2/2 · Rebuilding the database ═════════════════════════════════${NC}"
  "$SCRIPT_DIR/build-db.sh" "${DB_ARGS[@]+"${DB_ARGS[@]}"}"
fi

if [[ $DRY_RUN -eq 0 && $DO_DB -eq 1 ]]; then
  echo
  echo "${GREEN}Repository ready.${NC} Upload x86_64/ and then rebuild the ISO:"
  echo "${DIM}  rsync -avz --delete $SCRIPT_DIR/x86_64/ <host>:/srv/repo/repo/x86_64/vasakos/${NC}"
  echo "${DIM}  sudo mkarchiso -v -w /tmp/archiso-work -o ~/isos $WORKSPACE/archiso${NC}"
fi
