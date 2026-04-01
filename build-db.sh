#!/bin/sh
#
# Script name: build-db.sh
# Description: Script for rebuilding the database for vasakos.
# GitHub: https://github.com/Vasak-OS/repository-script 
# Forked Of: https://www.gitlab.com/Tomoghno/ts-arch-repo
# Author: Tomoghno Sen
# Edit: Joaquin (Pato) Decima

# Colors
BLACK='\033[0;30m'
RED='\033[0;31m'
GREEN='\033[0;32m'
BROWN='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
LGRAY='\033[0;37m'
DGRAY='\033[1;30m'
LRED='\033[1;31m'
LGREEN='\033[1;32m'
YELLOW='\033[01;33m'
LBLUE='\033[01;34m'
LPURPLE='\033[01;35m'
LCYAN='\033[01;36m'
WHITE='\033[01;37m'
NC='\033[0m' # No Color

# Configuration Variables
ARCH="x86_64"
REPO_NAME="vasakos"
GPG_KEY="307E04B769840811099F4077ED5D59DA704DEBE2"
REPO_DB="${REPO_NAME}.db.tar.gz"
REPO_FILES="${REPO_NAME}.files.tar.gz"
REPO_DB_FINAL="${REPO_NAME}.db"
REPO_FILES_FINAL="${REPO_NAME}.files"

# Summary tracking
PACKAGE_COUNT=0
PACKAGE_SUMMARY=""

echo -e "${GREEN}Building the repo database...${NC}"

## Arch: architecture selected
cd "$ARCH"
rm -f "${REPO_NAME}."*

echo -e "${GREEN}Building for architecture '${ARCH}'...${NC}"

## repo-add
## -s: signs the packages
## -n: only add new packages not already in database
## -R: remove old package files when updating their entry
for package in ./*.pkg.tar.zst; do
    if [ -f "$package" ]; then
        echo -e "${CYAN}Adding $package...${NC}"
        repo-add -s -k "$GPG_KEY" -n -R "$REPO_DB" "$package"
        
        # Extract package name and version for summary
        PACKAGE_BASENAME=$(basename "$package" .pkg.tar.zst)
        # Remove architecture and release number to get name-version
        PACKAGE_INFO=$(echo "$PACKAGE_BASENAME" | sed 's/-[^-]*-[^-]*$//')
        
        PACKAGE_COUNT=$((PACKAGE_COUNT + 1))
        PACKAGE_SUMMARY="${PACKAGE_SUMMARY}${PACKAGE_INFO}\n"
    fi
done

# Removing the symlinks because GitLab can't handle them.
rm "$REPO_DB_FINAL"
rm "$REPO_FILES_FINAL"

# Renaming the tar.gz files without the extension.
mv "$REPO_DB" "$REPO_DB_FINAL"
mv "$REPO_FILES" "$REPO_FILES_FINAL"

echo -e "${GREEN}Packages in the repo have been updated!${NC}"

# Display summary table
echo ""
echo -e "${LBLUE}═══════════════════════════════════════${NC}"
echo -e "${LBLUE}Repository Summary${NC}"
echo -e "${LBLUE}═══════════════════════════════════════${NC}"
echo -e "${YELLOW}Total packages added: ${PACKAGE_COUNT}${NC}"
echo ""
echo -e "${CYAN}Package List:${NC}"
echo -e "${LBLUE}───────────────────────────────────────${NC}"
echo -e "$PACKAGE_SUMMARY" | nl -w2 -s'. '
echo -e "${LBLUE}═══════════════════════════════════════${NC}"
echo ""

