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
# It also writes a `$repo.json` next to the database listing what is published.
# pacman ignores it; the website reads it at build time so os.vasak.net.ar/state/
# shows the version that is really in the repository instead of one somebody
# remembered to edit by hand.
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

# A JSON index of what is published, written next to the database. pacman does
# not need it — the website does: os.vasak.net.ar/state/ reads it at build time
# so the version of every component comes from what is actually in the
# repository instead of from a number somebody remembered to edit by hand.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'
}

# .PKGINFO holds what makepkg recorded at build time, which beats parsing the
# file name: a pkgname can contain dashes and the description cannot be guessed.
pkginfo_field() {
  bsdtar -xOqf "$1" .PKGINFO 2>/dev/null | sed -n "s/^$2 = //p" | head -1
}

SUMMARY=()
JSON_ENTRIES=()
for package in "${PACKAGES[@]}"; do
  echo "${CYAN}Adding ${package}…${NC}"

  # Sign the package itself, before adding it.
  #
  # `repo-add -s` signs the *database*, and only that. pacman's default is
  # `SigLevel = Required DatabaseOptional`: the signatures it insists on are the
  # packages', so a repository with a signed database and unsigned packages
  # fails to install with «invalid or corrupted package». That was the state
  # this script produced until it was actually tried.
  #
  # Before repo-add and not after, because repo-add copies the signature into
  # the database entry when it finds one. Signed afterwards, pacman would have
  # to fetch every .sig separately — and older pacman would not look at all.
  if [[ $SIGN -eq 1 ]]; then
    rm -f "$package.sig"
    if ! gpg --detach-sign --no-armor --local-user "$GPG_KEY" "$package"; then
      echo "${RED}No se pudo firmar $package${NC}" >&2
      exit 1
    fi
  fi

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

  info_name="$(pkginfo_field "$package" pkgname)"
  JSON_ENTRIES+=("$(printf '    {"name":"%s","version":"%s","arch":"%s","desc":"%s","url":"%s","builddate":%s,"csize":%s,"filename":"%s"}' \
    "$(json_escape "${info_name:-$name}")" \
    "$(json_escape "${pkgver}-${pkgrel}")" \
    "$(json_escape "$arch_field")" \
    "$(json_escape "$(pkginfo_field "$package" pkgdesc)")" \
    "$(json_escape "$(pkginfo_field "$package" url)")" \
    "$(pkginfo_field "$package" builddate | grep -E '^[0-9]+$' || echo 0)" \
    "$(stat -c %s "$package")" \
    "$(json_escape "$package")")")
done

{
  printf '{\n  "repo": "%s",\n  "arch": "%s",\n  "generated": "%s",\n  "count": %d,\n  "packages": [\n' \
    "$REPO_NAME" "$ARCH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${#PACKAGES[@]}"
  printf '%s' "${JSON_ENTRIES[0]}"
  for entry in "${JSON_ENTRIES[@]:1}"; do printf ',\n%s' "$entry"; done
  printf '\n  ]\n}\n'
} > "${REPO_NAME}.json"

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

# repo-add keeps a .old copy of every database it replaces, and signs that too.
# Useful while it is working, noise once it is done — and both would otherwise be
# uploaded.
rm -f ./*.old ./*.old.sig

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
echo "${DIM}Índice para la web: ${REPO_NAME}.json (${#PACKAGES[@]} paquetes)${NC}"
echo "${DIM}Upload x86_64/ to https://repo.vasak.net.ar/repo/x86_64/${REPO_NAME}/ — see README.md.${NC}"
