#!/bin/bash
#
# Read-only health check for the AUR packages in this superproject.
#
# It compares the local package directories against .gitmodules, .git/modules,
# the AUR, and GitHub; validates every package's git layout, remote sync,
# working tree, PKGBUILD, and .SRCINFO; and compares non-VCS packages against
# upstream with nvchecker (see nvchecker.toml).
#
# It never modifies anything. Remotes are queried with `git ls-remote`; nothing
# is fetched, written, or removed. Exit status is 1 if any problem was found.

set -uo pipefail

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
cd "$SCRIPT_DIR" || exit 1

AUR_USER='kyechou'
GITHUB_USER='kyechou'
NVCHECKER_CONF="${NVCHECKER_CONF:-$SCRIPT_DIR/nvchecker.toml}"
MAX_JOBS=4

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die() {
    echo "[!] ${1-}" >&2
    exit 1
}

# Report a problem. Any call marks the whole run as failed.
report() {
    echo "[-] $*"
    : >"$TMP/failed"
}

if [ "$UID" -eq 0 ]; then
    die 'Please run this script without root privilege'
fi

check_depends() {
    local cmd
    for cmd in git curl jq makepkg vercmp python; do
        type "$cmd" &>/dev/null || die "$cmd not installed"
    done
}

#
# Package lists
#

# Local package directories, one per submodule.
local_pkgs() {
    find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | sort
}

# Submodule paths declared in .gitmodules.
gitmodules_pkgs() {
    git config --file .gitmodules --get-regexp '^submodule\..*\.path$' |
        awk '{print $2}' | sort
}

# Git directories under .git/modules (orphans are left behind by removed submodules).
module_dirs() {
    find .git/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

# Package bases on the AUR maintained or co-maintained by $AUR_USER.
aur_pkgs() {
    local by
    for by in maintainer comaintainers; do
        curl -fsSL "https://aur.archlinux.org/rpc/?v=5&type=search&by=$by&arg=$AUR_USER" |
            jq -r '.results[].PackageBase'
    done | sort -u
}

# Non-archived GitHub repositories named aur-<pkg> under $GITHUB_USER.
github_pkgs() {
    local page=1 names
    while :; do
        names="$(curl -fsSL "https://api.github.com/users/$GITHUB_USER/repos?per_page=100&page=$page" |
            jq -r '.[] | select(.archived | not) | .name | select(startswith("aur-")) | sub("^aur-"; "")')" || return 1
        [ -n "$names" ] || break
        echo "$names"
        page=$((page + 1))
    done | sort
}

# compare_with_local <label> <file>: report names present on only one side.
compare_with_local() {
    local label="$1" file="$2" diff
    diff="$(
        comm -23 "$TMP/local" "$file" | sed 's|^|    only local: |'
        comm -13 "$TMP/local" "$file" | sed "s|^|    only $label: |"
    )"
    if [ -n "$diff" ]; then
        report "package list differs between local and $label:"
        echo "$diff"
    fi
}

check_lists() {
    local_pkgs >"$TMP/local"

    gitmodules_pkgs >"$TMP/gitmodules"
    compare_with_local '.gitmodules' "$TMP/gitmodules"

    module_dirs >"$TMP/modules"
    compare_with_local '.git/modules' "$TMP/modules"

    if aur_pkgs >"$TMP/aur" && [ -s "$TMP/aur" ]; then
        compare_with_local 'AUR' "$TMP/aur"
    else
        report 'could not fetch the AUR package list'
    fi

    if github_pkgs >"$TMP/github" && [ -s "$TMP/github" ]; then
        compare_with_local 'GitHub' "$TMP/github"
    else
        report 'could not fetch the GitHub repository list'
    fi
}

#
# Per-package checks
#

# expect_remote_url <pkg> <remote> <url>
expect_remote_url() {
    local pkg="$1" remote="$2" expected="$3" actual
    actual="$(git remote get-url "$remote" 2>/dev/null)"
    if [ "$actual" != "$expected" ]; then
        report "$pkg: remote '$remote' should be $expected, found '${actual:-none}'"
        return 1
    fi
}

# All checks for one package. Runs in a subshell; output is buffered by main.
validate_pkg() {
    local pkg="$1"
    cd "$SCRIPT_DIR/$pkg" || return

    #
    # Git layout: two remotes, one branch, in sync, clean tree
    #
    if [ ! -e .git ]; then
        report "$pkg: not a git repo or a submodule"
    else
        local layout_ok=1 remotes branches remote head remote_head

        remotes="$(git remote | sort | tr '\n' ' ')"
        if [ "$remotes" != 'aur origin ' ]; then
            report "$pkg: remotes should be 'aur origin', found '${remotes% }'"
            layout_ok=0
        fi
        expect_remote_url "$pkg" aur "ssh://aur@aur.archlinux.org/$pkg.git" || layout_ok=0
        expect_remote_url "$pkg" origin "git@github.com:$GITHUB_USER/aur-$pkg.git" || layout_ok=0

        branches="$(git branch --format='%(refname:short)' | tr '\n' ' ')"
        if [ "$branches" != 'master ' ]; then
            report "$pkg: local branches should be 'master', found '${branches% }'"
            layout_ok=0
        fi
        if [ "$(git branch --show-current)" != 'master' ]; then
            report "$pkg: not on master"
        fi

        # Compare against the remotes' current heads without fetching.
        if [ "$layout_ok" -eq 1 ]; then
            head="$(git rev-parse master)"
            for remote in aur origin; do
                remote_head="$(git ls-remote --heads "$remote" master 2>/dev/null | cut -f1)"
                if [ -z "$remote_head" ]; then
                    report "$pkg: cannot read master from remote '$remote'"
                elif [ "$remote_head" != "$head" ]; then
                    report "$pkg: $remote/master differs from local master"
                fi
            done
        fi

        git diff-index --quiet --cached HEAD -- || report "$pkg: staged changes not yet committed"
        git diff-files --quiet || report "$pkg: tracked file changes"
        [ -z "$(git ls-files --others --exclude-standard)" ] || report "$pkg: untracked files"
    fi

    #
    # PKGBUILD and .SRCINFO
    #
    if [ ! -f PKGBUILD ]; then
        report "$pkg: no PKGBUILD"
    elif [ ! -f .SRCINFO ]; then
        report "$pkg: no .SRCINFO"
    elif ! diff -B <(makepkg --printsrcinfo 2>/dev/null) .SRCINFO >/dev/null; then
        report "$pkg: .SRCINFO does not match PKGBUILD (run: makepkg --printsrcinfo > .SRCINFO)"
    fi
}

#
# nvchecker.toml
#

# One "name<TAB>source<TAB>locator" line per entry, where locator is the
# repository URL, page URL, or PyPI project the entry queries.
nvchecker_entries() {
    python -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    conf = tomllib.load(f)
for name, entry in conf.items():
    if name == "__config__":
        continue
    source = entry.get("source", "")
    if source == "pypi":
        locator = entry.get("pypi") or name
    else:
        locator = entry.get("url") or entry.get("git") or entry.get(source) or ""
    print(name, source, locator, sep="\t")
' "$NVCHECKER_CONF"
}

# Every non-VCS package must have an entry. Every entry must name a local
# non-VCS package and query the same upstream that its PKGBUILD uses.
check_nvchecker_conf() {
    local conf
    conf="$(basename "$NVCHECKER_CONF")"
    if [ ! -f "$NVCHECKER_CONF" ]; then
        report "$conf not found"
        return
    fi
    nvchecker_entries >"$TMP/nvchecker.entries" || die "cannot parse $conf"

    local pkg
    while IFS= read -r pkg; do
        [[ "$pkg" == *-git ]] && continue
        cut -f1 "$TMP/nvchecker.entries" | grep -qxF -- "$pkg" ||
            report "$conf: no entry for $pkg"
    done <"$TMP/local"

    local name source locator token
    while IFS=$'\t' read -r name source locator; do
        if [ ! -f "$name/PKGBUILD" ]; then
            report "$conf: entry '$name' has no local package"
            continue
        fi
        if [[ "$name" == *-git ]]; then
            report "$conf: entry '$name' is a VCS package and should not be listed"
            continue
        fi
        [ -f "$name/.SRCINFO" ] || continue # already reported by validate_pkg

        if [ "$source" = pypi ]; then
            grep '^	source = ' "$name/.SRCINFO" | grep -qiF -- "/$locator/" ||
                report "$conf: entry '$name' queries PyPI project '$locator', which is not in its sources"
        else
            # host/owner/repo must appear in the expanded url or sources; deeper
            # path components (feeds, .git suffixes) are allowed to differ.
            token="${locator#*://}"
            token="${token%%\?*}"
            token="${token%/}"
            token="${token%.git}"
            until grep -qF -- "$token" "$name/.SRCINFO"; do
                token="${token%/*}"
                if [[ "$token" != */*/* ]]; then
                    report "$conf: entry '$name' points at $locator, which matches neither its url nor its sources"
                    break
                fi
            done
        fi
    done <"$TMP/nvchecker.entries"
}

#
# Upstream versions
#

# Compare each nvchecker.toml entry against the local pkgver.
check_upstream() {
    if ! type nvchecker &>/dev/null; then
        report 'nvchecker not installed; upstream versions not checked'
        return
    fi
    [ -f "$NVCHECKER_CONF" ] || return # already reported by check_nvchecker_conf

    nvchecker --file "$NVCHECKER_CONF" --logger json 2>/dev/null >"$TMP/nvchecker.json"

    # Problems nvchecker hit while querying upstream.
    jq -r 'select(.level == "error" or .level == "warning") |
           "\(.name // "nvchecker"): \(.event)"' "$TMP/nvchecker.json" |
        while IFS= read -r line; do
            report "upstream: $line"
        done

    local pkg upstream local_ver
    while IFS=$'\t' read -r pkg upstream; do
        [ -f "$pkg/PKGBUILD" ] || continue # already reported by check_nvchecker_conf
        local_ver="$(cd "$pkg" && makepkg --printsrcinfo 2>/dev/null |
            awk '/^\tpkgver = /{print $3; exit}')"
        case "$(vercmp "$local_ver" "$upstream")" in
            -1) report "$pkg: out of date: $local_ver -> $upstream" ;;
            1) report "$pkg: local $local_ver is newer than upstream $upstream (check $(basename "$NVCHECKER_CONF"))" ;;
        esac
    done < <(jq -r 'select(.logger_name == "nvchecker.core" and .version != null) |
                    "\(.name)\t\(.version)"' "$TMP/nvchecker.json")
}

main() {
    check_depends

    echo '==> Checking package lists'
    check_lists

    echo "==> Checking $(basename "$NVCHECKER_CONF")"
    check_nvchecker_conf

    echo '==> Checking packages'
    # Each package opens SSH connections to the AUR and GitHub; too many at
    # once get dropped by the servers, so cap the parallelism.
    local pkg
    while IFS= read -r pkg; do
        if [ "$(jobs -rp | wc -l)" -ge "$MAX_JOBS" ]; then
            wait -n
        fi
        validate_pkg "$pkg" >"$TMP/$pkg.out" 2>&1 &
    done <"$TMP/local"
    wait
    cat "$TMP"/*.out

    echo '==> Checking upstream versions'
    check_upstream

    if [ -e "$TMP/failed" ]; then
        echo '==> Problems found'
        exit 1
    fi
    echo '==> All checks passed'
}

main "$@"

# vim: set ts=4 sw=4 et:
