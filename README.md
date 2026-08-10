# repository-script

Build scripts and staging directory for **`vasakos`**, the official pacman
repository of [VasakOS](https://os.vasak.net.ar/).

This repository is the last stop before a package reaches users: PKGBUILDs are
built in the [`PKGBUILDS`](https://github.com/Vasak-OS/PKGBUILDS) repo, the
resulting `.pkg.tar.zst` files land in [`x86_64/`](x86_64), and `build-db.sh`
turns that directory into a signed pacman database. Uploading the result to
`repo.vasak.net.ar` is still a manual step, on purpose.

---

## For users — adding the repository

You do not need this repository to *use* VasakOS' packages, only to publish
them. To consume them, add the repository to `/etc/pacman.conf`:

```conf
[vasakos]
Include = /etc/pacman.d/vasakos-mirrorlist
```

and install the two helper packages that provide the mirrorlist and the signing
key. On a VasakOS installation both are already present; on plain Arch, install
them from the repository once, bootstrapping with an explicit `Server` line:

```conf
[vasakos]
SigLevel = Optional TrustAll
Server = https://repo.vasak.net.ar/repo/$arch/$repo
```

```bash
sudo pacman -Sy vasakos-keyring vasakos-mirrorlist
```

Then replace the bootstrap block with the `Include` form above and drop the
`SigLevel` override, so signatures are actually enforced:

```bash
sudo pacman-key --populate vasakos
sudo pacman -Syu
```

The packages are signed with:

```
Joaquin (Pato) Decima (VasakOS Repository Key) <jdecima@vasak.net.ar>
307E04B769840811099F4077ED5D59DA704DEBE2
```

---

## Layout

```
repository-script/
├── build-db.sh      # signs every package in x86_64/ and rebuilds the database
├── update-repo.sh   # build out-of-date packages + rebuild the database
└── x86_64/          # staging area: the repository itself (git-ignored)
```

`x86_64/` is deliberately **not** tracked by git — see [.gitignore](.gitignore).
Packages are large binaries and the directory is a build artefact; it is
reconstructed from the PKGBUILDS repo whenever it is needed.

The scripts assume the workspace layout used across VasakOS development, with
both repositories checked out side by side:

```
VasakOS/
├── PKGBUILDS/            # the PKGBUILDs and build-all.sh
├── archiso/              # the ISO profile, which consumes [vasakos]
└── repository-script/    # this repo
```

`build-all.sh` defaults to publishing into `../repository-script/x86_64`, so no
paths have to be passed by hand. Override it with `--repo DIR` or by exporting
`VASAKOS_REPO_DIR`.

---

## Releasing packages

### The short version

```bash
./update-repo.sh
```

That is the whole release, minus the upload. It runs the two steps below in
order and prints exactly which packages were added and which older versions
were deleted.

### What it actually does

**1. Build only what changed.** `update-repo.sh` calls
`../PKGBUILDS/build-all.sh --repo ./x86_64`. For every PKGBUILD, `build-all.sh`
asks makepkg which files that PKGBUILD would produce (`makepkg --packagelist`,
which resolves `pkgname`/`pkgver`/`pkgrel`/`arch` and split packages). If those
files are already in `x86_64/`, the package is up to date and is not rebuilt.
Anything else is built, copied in, and the version it replaces — plus its
detached signature — is deleted, so the directory always holds exactly one
version of each package.

Bumping a `pkgver` or `pkgrel` in PKGBUILDS is therefore the only thing needed
to queue a package for the next release.

**2. Rebuild and sign the database.** `build-db.sh` then wipes `vasakos.db*`
and re-adds every package on disk. Building from zero on each run is what makes
a *deleted* package actually disappear from the database instead of lingering as
a dangling entry.

pacman resolves `Server/$repo.db`, but `repo-add` writes `$repo.db.tar.gz` plus
a symlink, and most static hosts do not serve symlinks. The script renames the
tarballs — signatures included — to the plain `vasakos.db` / `vasakos.files`
names at the end.

**3. Upload.** Still manual:

```bash
rsync -avz --delete x86_64/ <host>:/srv/repo/repo/x86_64/vasakos/
```

The target path is what `vasakos-mirrorlist` points at
(`Server = https://repo.vasak.net.ar/repo/$arch/$repo`). Use `--delete` so
packages removed locally also disappear from the mirror; the database on the
server would otherwise reference files that are still being served.

**4. Rebuild the ISO** if the release should ship in one. `archiso/pacman.conf`
pulls from `[vasakos]`, so the ISO picks up whatever was just uploaded:

```bash
sudo mkarchiso -v -w /tmp/archiso-work -o ~/isos ../archiso
```

To test an ISO *before* uploading, point the profile's `pacman.conf` at the
local staging directory instead:

```conf
[vasakos]
SigLevel = Optional TrustAll
Server = file:///home/<user>/VasakOS/repository-script/x86_64
```

---

## Common tasks

| Goal | Command |
| --- | --- |
| Full release (build + database) | `./update-repo.sh` |
| See what would change, touch nothing | `./update-repo.sh --dry-run` |
| Force one package to rebuild | `./update-repo.sh vasak-desktop-git` |
| Rebuild everything from scratch | `./update-repo.sh --all` |
| Only refresh the database | `./update-repo.sh --db-only` |
| Publish packages, sign later | `./update-repo.sh --build-only` |
| Fill the directory from earlier builds | `../PKGBUILDS/build-all.sh --adopt` |
| Database without a signing key | `./update-repo.sh --no-sign` |

### Forcing a rebuild

A `-git` PKGBUILD carries a static `pkgver`, so a new upstream commit does not
change the file name and the up-to-date check will consider it published. When
upstream moved but the version did not, name the directory explicitly:

```bash
./update-repo.sh vasak-desktop-git
```

For PKGBUILDs that *do* carry a `pkgver()` function, `--refresh-vcs` fetches the
sources first so the computed version reflects upstream `HEAD` before the check
runs.

---

## `build-db.sh`

```
./build-db.sh [-k KEYID] [--no-sign]
```

| Option | Effect |
| --- | --- |
| `-k, --key KEYID` | Sign with a different key (or set `$VASAKOS_GPG_KEY`). |
| `--no-sign` | Build an unsigned database — local testing only. |

It refuses to start if the secret key is not in the keyring, rather than
producing an unsigned repository by surprise, and it refuses to run against an
empty `x86_64/`.

## `update-repo.sh`

```
./update-repo.sh [options] [package-dir ...]
```

| Option | Effect |
| --- | --- |
| `-a, --all` | Rebuild every package, published or not. |
| `-n, --dry-run` | Report what would change; touch nothing. |
| `--db-only` | Skip the build, just rebuild the database. |
| `--build-only` | Build and publish, leave the database alone. |
| `--no-sign` | Unsigned database. |
| `--no-check` | Skip the `check-all.sh` pre-flight. |
| `--refresh-vcs` | Resolve `pkgver()` from upstream before comparing. |

Unrecognised arguments are passed through to `build-all.sh`, so every flag it
accepts works here too.

---

## Adding a new package to the repository

1. Add the PKGBUILD to the [PKGBUILDS](https://github.com/Vasak-OS/PKGBUILDS)
   repo, in a directory named after it.
2. Push the upstream sources — the PKGBUILDs fetch with `git+https`, so makepkg
   builds the *pushed* branch, not your working copy.
3. Run `./update-repo.sh` here. The new package has no counterpart in `x86_64/`,
   so it is picked up automatically.
4. Upload.

If the package should also be on the ISO, add its `pkgname` to
`archiso/packages.x86_64`.

---

## Troubleshooting

**`Secret key … is not in this keyring`** — the signing key is not available.
Import it, pass `--key`, or use `--no-sign` for a local test build.

**`No packages in …/x86_64`** — nothing has been built yet. Run
`../PKGBUILDS/build-all.sh --adopt` to pick up packages built in earlier
sessions, or `./update-repo.sh` to build them.

**pacman reports a signature error after an upload** — the database references
signatures that were not uploaded, or `--delete` removed packages the database
still lists. Re-run `./build-db.sh` and upload the whole directory again.

**A package did not rebuild even though upstream changed** — expected for `-git`
PKGBUILDs with a static `pkgver`. Name the directory explicitly to force it.

---

## Credits

Forked from [ts-arch-repo](https://www.gitlab.com/Tomoghno/ts-arch-repo) by
Tomoghno Sen, adapted for VasakOS by Joaquin (Pato) Decima.

## License

[GPL-3.0](LICENSE)
