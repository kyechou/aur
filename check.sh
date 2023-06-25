#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
cd "$SCRIPT_DIR" || exit

die() {
    echo -e "[!] ${1-}" >&2
    exit 1
}

if [ $UID -eq 0 ]; then
    die "Please run this script without root privilege"
fi

check_depends() {
    local script_depends=(git curl jq aur-out-of-date)

    for cmd in "${script_depends[@]}"; do
        if ! type "$cmd" &>/dev/null; then
            die "$cmd not installed"
        fi
    done
}

collect_pkgs() {
    local aur_maintainer_url='https://aur.archlinux.org/rpc/?v=5&type=search&by=maintainer&arg=kyechou'
    local aur_comaintainer_url='https://aur.archlinux.org/rpc/?v=5&type=search&by=comaintainers&arg=kyechou'
    local github_url='https://api.github.com/users/kyechou/repos'

    mapfile -t local_pkgs < <(
        find . -maxdepth 1 -type d |
            sed -e 's,./,,' -e '/^\..*/d' |
            sort -u
    )

    mapfile -t aur_pkgs < <(
        curl -L "$aur_maintainer_url" 2>/dev/null |
            jq '.results[].PackageBase' |
            sed -e 's/"//g' |
            sort -u
    )

    mapfile -t -O "${#aur_pkgs[@]}" aur_pkgs < <(
        curl -L "$aur_comaintainer_url" 2>/dev/null |
            jq '.results[].PackageBase' |
            sed -e 's/"//g' |
            sort -u
    )

    mapfile -t aur_pkgs < <(printf '%s\n' "${aur_pkgs[@]}" | sort -u)

    local num_gh_pkgs=0
    local page_number=1
    while :; do
        mapfile -t -O "$num_gh_pkgs" gh_pkgs < <(
            curl -L "$github_url?page=$page_number" 2>/dev/null |
                jq '.[].name' |
                grep 'aur-' |
                sed -e 's/"//g' -e 's/^aur-//' |
                sort -u
        )
        if [ "${#gh_pkgs[@]}" -eq "$num_gh_pkgs" ]; then
            break
        fi
        num_gh_pkgs="${#gh_pkgs[@]}"
        page_number=$((page_number + 1))
    done

    export local_pkgs
    export aur_pkgs
    export gh_pkgs
}

validate_pkg() {
    local pkg="$1"

    pushd "$pkg" >/dev/null || exit

    #
    # Git sanity check
    #
    # check if it is a git repo or a submodule
    if [ ! -e ".git" ]; then
        echo "[-] $pkg: not a git repo or a submodule"
    else
        local pkg_err=0

        # check if there are exactly two remotes: "origin" and "aur"
        if [ "$(git remote)" != 'aur'$'\n''origin' ]; then
            echo "[-] $pkg: remote error: $(git remote)"
            pkg_err=1
        fi

        # check if there is exactly one local branch called "master"
        if [ "$(git branch | sed 's,[\* ] ,,')" != 'master' ]; then
            echo "[-] $pkg: local branch error: $(git branch | sed 's,[\* ] ,,')"
            pkg_err=1
        fi

        # check if there are two remote branches: "aur/master" and "origin/master"
        if [ "$(git branch -l -r '*/master' | sed -e 's/  //')" != 'aur/master'$'\n''origin/master' ]; then
            echo "[-] $pkg: remote branch error: $(git branch -l -r '*/master' | sed -e 's/  //')"
        fi

        if [ $pkg_err -eq 0 ]; then # if there is no remote or branch error
            # check if the local and remote branches point to the same commit
            if [ "$(git rev-parse master)" != "$(git rev-parse aur/master)" ]; then
                echo "[-] $pkg: aur/master is not equal to master"
            fi
            if [ "$(git rev-parse master)" != "$(git rev-parse origin/master)" ]; then
                echo "[-] $pkg: origin/master is not equal to master"
            fi

            # check if there are staged but uncommitted changes
            if ! git diff-index --quiet --cached HEAD --; then
                echo "[-] $pkg: staged changes not yet committed"
            fi

            # check if there are non-staged changes to the tracked files
            if ! git diff-files --quiet; then
                echo "[-] $pkg: tracked file changes"
            fi

            # check if there are untracked and unignored files
            if [ -n "$(git ls-files --others)" ]; then
                echo "[-] $pkg: untracked files"
            fi
        fi
    fi

    #
    # PKGBUILD check
    #
    if [ ! -f "PKGBUILD" ]; then
        echo "[-] $pkg: does not have PKGBUILD"
    else
        # check if sources are up to date
        GITHUB_ATOM=1 aur-out-of-date -pkg "$pkg" |
            sed -e '/\[UP-TO-DATE\]/d' \
                -e '/\[UNKNOWN\] .* No \(\S\+ \)\?release found/d' \
                -e '/\[UNKNOWN\] .* Failed to obtain \(\S\+ \)\?release/d' \
                -e '/\[UNKNOWN\] .* upstream version is/d'
    fi

    #
    # .SRCINFO check
    #
    if [ ! -f ".SRCINFO" ]; then
        echo "[-] $pkg: does not have .SRCINFO"
    elif [ -f "PKGBUILD" ]; then
        # check if .SRCINFO matches PKGBUILD
        if ! diff <(makepkg --printsrcinfo) .SRCINFO -B &>/dev/null; then
            echo "[-] $pkg: .SRCINFO does not match PKGBUILD"
        fi
    fi

    popd >/dev/null || exit
}

main() {
    check_depends
    collect_pkgs # collect packages from the local FS, AUR, and GitHub

    # check local and AUR packages consistency
    pkgdiff=$(diff <(printf "%s\n" "${local_pkgs[@]}") <(printf "%s\n" "${aur_pkgs[@]}"))
    if [ -n "${pkgdiff[*]}" ]; then
        echo "[-] local and AUR package list mismatch: ${#local_pkgs[@]} vs ${#aur_pkgs[@]}"
        echo "${pkgdiff}" | awk -F $'\n' '{print "    " $1}'
        exit 1
    fi

    # check local and GitHub packages consistency
    pkgdiff=$(diff <(printf "%s\n" "${local_pkgs[@]}") <(printf "%s\n" "${gh_pkgs[@]}"))
    if [ -n "${pkgdiff[*]}" ]; then
        echo "[-] local and GitHub package list mismatch: ${#local_pkgs[@]} vs ${#gh_pkgs[@]}"
        echo "${pkgdiff}" | awk -F $'\n' '{print "    " $1}'
        exit 1
    fi

    for pkg in "${local_pkgs[@]}"; do
        validate_pkg "$pkg" &
    done
    wait
}

main

# vim: set ts=4 sw=4 et:
