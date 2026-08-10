#!/usr/bin/env bash
#
# build-db.sh — rebuild and sign the VasakOS pacman database.
#
# GitHub: https://github.com/Vasak-OS/repository-script
# Forked from: https://www.gitlab.com/Tomoghno/ts-arch-repo
# Author: Tomoghno Sen
# Edit: Joaquin (Pato) Decima
#
# Every package sitting in x86_64/ is signed and added to a database rebuilt
# from scratch, so the database always describes exactly what is in the
# directory — a package deleted from disk disappears from the database too.
#
# pacman resolves `Server/$repo.db`, but repo-add writes `$repo.db.tar.gz` and a
# symlink. GitLab and most static hosts do not serve symlinks, so the tarballs
# are renamed to the plain names at the end, signatures included.
#
# Usage:
#   ./build-db.sh [options]
#
# Options:
#   -k, --key KEYID    GPG key to sign with (default: the one below,
#                      overridable with $VASAKOS_GPG_KEY).
#       --no-sign      Build the database without signing anything.
#   -h, --help         Show this help.

set -euo pipefail

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[01;33m'
CYAN=$'\033[0;36m'
LBLUE=$'\033[01;34m'
DIM=$'\033[2m'
NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; GREEN=""; YELLOW=""; CYAN=""; LBLUE=""; DIM=""; NC=""; }

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="x86_64"
REPO_NAME="vasakos"
GPG_KEY="${VASAKOS_GPG_KEY:-307E04B769840811099F4077ED5D59DA704DEBE2}"
SIGN=1

REPO_DB="${REPO_NAME}.db.tar.gz"
REPO_FILES="${REPO_NAME}.files.tar.gz"
REPO_DB_FINAL="${REPO_NAME}.db"
REPO_FILES_FINAL="${REPO_NAME}.files"

# The help text is the header comment itself, so the two cannot drift apart.
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -k|--key) GPG_KEY="${2:?--key needs a key id}"; shift 2 ;;
    --no-sign) SIGN=0; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

command -v repo-add >/dev/null || { echo "repo-add not found (install pacman-contrib/base-devel)." >&2; exit 1; }

if [[ $SIGN -eq 1 ]]; then
  if ! gpg --list-secret-keys "$GPG_KEY" >/dev/null 2>&1; then
    echo "${RED}Secret key $GPG_KEY is not in this keyring.${NC}" >&2
    echo "Import it, pass --key, set \$VASAKOS_GPG_KEY, or run with --no-sign." >&2
    exit 1
  fi
fi

cd "$SCRIPT_DIR/$ARCH"

shopt -s nullglob
PACKAGES=(*.pkg.tar.zst *.pkg.tar.xz)
shopt -u nullglob

if [[ ${#PACKAGES[@]} -eq 0 ]]; then
  echo "${RED}No packages in $SCRIPT_DIR/$ARCH — nothing to publish.${NC}" >&2
  echo "Build them first: ../PKGBUILDS/build-all.sh" >&2
  exit 1
fi

echo "${GREEN}Building the repo database for '${ARCH}'…${NC}"

# The database is rebuilt from zero on every run: that is what makes a deleted
# package actually disappear instead of lingering as a dangling entry.
rm -f "${REPO_NAME}."*

ADD_ARGS=(-n -R)
[[ $SIGN -eq 1 ]] && ADD_ARGS=(-s -k "$GPG_KEY" "${ADD_ARGS[@]}")

SUMMARY=()
for package in "${PACKAGES[@]}"; do
  echo "${CYAN}Adding ${package}…${NC}"
  repo-add "${ADD_ARGS[@]}" "$REPO_DB" "$package"

  base="${package%.pkg.tar.*}"
  arch_field="${base##*-}"
  rest="${base%-*}"                    # name-pkgver-pkgrel
  pkgrel="${rest##*-}"
  rest="${rest%-*}"                    # name-pkgver
  pkgver="${rest##*-}"
  name="${rest%-*}"
  size="$(du -h "$package" | cut -f1)"
  SUMMARY+=("$(printf '%-32s %-18s %-8s %s' "$name" "${pkgver}-${pkgrel}" "$arch_field" "$size")")
done

# repo-add leaves symlinks (vasakos.db -> vasakos.db.tar.gz); replace them with
# the real files under the names pacman asks for.
for pair in "$REPO_DB:$REPO_DB_FINAL" "$REPO_FILES:$REPO_FILES_FINAL"; do
  src="${pair%%:*}"
  dst="${pair##*:}"
  rm -f "$dst"
  [[ -f "$src" ]] && mv -f "$src" "$dst"
  # The detached signature has to follow the rename, otherwise pacman looks for
  # vasakos.db.sig and finds only vasakos.db.tar.gz.sig.
  rm -f "$dst.sig"
  [[ -f "$src.sig" ]] && mv -f "$src.sig" "$dst.sig"
done

# repo-add keeps a .old copy of every database it replaces. Useful while it is
# working, noise once it is done — and it would otherwise be uploaded.
rm -f ./*.old

echo
echo "${LBLUE}═══════════════════════════════════════════════════════════════════${NC}"
echo "${LBLUE}Repository summary — ${REPO_NAME} (${ARCH})${NC}"
echo "${LBLUE}═══════════════════════════════════════════════════════════════════${NC}"
printf '%-32s %-18s %-8s %s\n' "PACKAGE" "VERSION" "ARCH" "SIZE"
echo "${LBLUE}───────────────────────────────────────────────────────────────────${NC}"
printf '%s\n' "${SUMMARY[@]}"
echo "${LBLUE}───────────────────────────────────────────────────────────────────${NC}"
echo "${YELLOW}Total: ${#PACKAGES[@]} package(s), $(du -sh . | cut -f1) on disk${NC}"
if [[ $SIGN -eq 1 ]]; then
  echo "${GREEN}Signed with ${GPG_KEY}${NC}"
else
  echo "${YELLOW}Unsigned build (--no-sign)${NC}"
fi
echo "${LBLUE}═══════════════════════════════════════════════════════════════════${NC}"
echo
echo "${DIM}Upload x86_64/ to https://repo.vasak.net.ar/repo/x86_64/${REPO_NAME}/ — see README.md.${NC}"
