#!/bin/sh
#
# Script name: build-db.sh
# Description: Script for rebuilding the database for basis.
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

echo -e "${GREEN}Building the repo database...${NC}"

## Arch: x86_64
cd x86_64
rm -f basis*

echo -e "${GREEN}Building for architecture 'x86_64'...${NC}"

## repo-add
## -s: signs the packages
## -n: only add new packages not already in database
## -R: remove old package files when updating their entry
repo-add -s -k D4E45188CD819FD6BBA34C2F25E84F84D2110B5E -n -R basis.db.tar.gz *.pkg.tar.zst

# Removing the symlinks because GitLab can't handle them.
rm basis.db
rm basis.files

# Renaming the tar.gz files without the extension.
mv basis.db.tar.gz basis.db
mv basis.files.tar.gz basis.files

echo -e "${GREEN}Packages in the repo have been updated!${NC}"

