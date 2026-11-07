# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A superproject that tracks every AUR package maintained by `kyechou`. Each top-level
directory is a **git submodule** holding one package (`PKGBUILD`, `.SRCINFO`, and any
patches / `.install` / service files). There is no shared build system; each package is
built independently with `makepkg`.

Every submodule is a separate git repo with exactly this shape (enforced by `check.sh`):

- Two remotes: `origin` = `git@github.com:kyechou/aur-<pkg>.git`, `aur` = `ssh://aur@aur.archlinux.org/<pkg>.git`
- One local branch, `master`, which must match both `aur/master` and `origin/master`
- No staged, unstaged, or untracked files

The GitHub repo name is always `aur-<pkg>`; the directory and AUR package base are `<pkg>`.

## Commands

All work happens inside a package directory unless noted.

```bash
# Regenerate .SRCINFO after any PKGBUILD change (check.sh diffs these, ignoring blank lines)
makepkg --printsrcinfo > .SRCINFO

# Test-build a package (installs missing deps, forces rebuild)
makepkg -sf

# Refresh checksums after changing source= entries
updpkgsums
```

Repository-wide health check, run from the root:

```bash
./check.sh
```

`check.sh` is strictly read-only and never fetches, writes, or removes anything. It needs
`git`, `curl`, `jq`, `makepkg`, `vercmp`, and `nvchecker`. It compares the local directory
list against `.gitmodules`, `.git/modules`, the AUR maintainer/co-maintainer list, and the
`aur-*` GitHub repos; checks each package's remote URLs and branch layout, sync with both
remotes via `git ls-remote`, dirty trees, and `.SRCINFO` drift; validates `nvchecker.toml`
itself (one entry per non-`-git` package, none for VCS or removed packages, each pointing
at the same upstream as the package's `.SRCINFO` url or sources); then compares every
non-`-git` package's `pkgver` against upstream. Exit status is 1 if anything was reported.

## Workflow for updating a package

1. Edit `PKGBUILD` in `<pkg>/`, bump `pkgver`/`pkgrel`, run `updpkgsums` if sources changed.
2. `makepkg --printsrcinfo > .SRCINFO`, then test with `makepkg -sf`.
3. Commit in the submodule (messages are short, e.g. `Update to 0.23`, `Bump to 0.22.1`).
4. Push to both remotes: `git push origin master && git push aur master`.
5. In the superproject root, commit the submodule pointer bump. Convention is
   `Update <pkg>`, `Add <pkg>`, `Remove <pkg>`, or `Fix <pkg> ...`.

## Adding / removing a package

- **Add**: create the `aur-<pkg>` repo on GitHub, then from the root
  `git submodule add git@github.com:kyechou/aur-<pkg>.git <pkg>`, and inside it
  `git remote add aur ssh://aur@aur.archlinux.org/<pkg>.git`. A non-`-git` package also
  needs an entry in `nvchecker.toml`, or `check.sh` will flag it.
- **Remove**: `git submodule deinit -f <pkg> && git rm -f <pkg>`, then
  `rm -rf .git/modules/<pkg>`, which git leaves behind. `check.sh` reports stale
  `.gitmodules` entries and orphaned `.git/modules` directories.

## PKGBUILD conventions

- 4-space indentation; files end with a vim modeline (`# vim: set sw=4 ts=4 et:`).
- Maintainer header: `# Maintainer: Kuan-Yen Chou <kuanyenchou at gmail dot com>`; keep
  existing `# Contributor:` lines when adopting a package.
- `-git` packages use the standard `pkgver()` helper (`git describe --long --tags` with the
  `r<count>.g<hash>` fallback) and `sha256sums=('SKIP')` for the VCS source.
- Local patches live next to the `PKGBUILD`, are listed in `source=`, have real checksums,
  and are applied in `prepare()`.
- Python packages build with `python -m build --wheel --no-isolation` and install with
  `python -m installer`; `python-setuptools`/`python-build`/`python-installer`/`python-wheel`
  go in `makedepends`.
- Some packages carry a `.gitignore` for `src/`, `pkg/`, `*.tar*`, and the cloned VCS dir;
  add one when a build would otherwise leave untracked files (which `check.sh` flags).
