#!/bin/bash

set -o nounset

SCRIPT_DIR="$(dirname $(realpath ${BASH_SOURCE[0]}))"
cd "$SCRIPT_DIR"

if [ $UID -eq 0 ]; then
    echo '[!] Please run this script without root privilege' >&2
    exit 1
fi

# check dependency
script_depends=(git curl jq aur-out-of-date)
for cmd in ${script_depends[@]}; do
    if ! type $cmd &>/dev/null; then
        echo "[!] $cmd not installed" >&2
        exit 1
    fi
done

local_pkgs=()
aur_pkgs=()
gh_pkgs=()

collect_pkgs() {
    AUR_URL='https://aur.archlinux.org/rpc/?v=5&type=search&by=maintainer&arg=kyechou'
    GH_URL='https://api.github.com/users/kyechou/repos'

    local_pkgs+=($(ls -d */ | sed 's,/,,g' | sort -u))
    aur_pkgs+=($(curl -L "$AUR_URL" 2>/dev/null \
                | jq '.results[].PackageBase' \
                | sed -e 's/^"//' -e 's/"$//' \
                | sort -u))
    pageNo=1
    while :; do
        new_pkgs=($(curl -L "$GH_URL?page=$pageNo" 2>/dev/null \
                    | jq '.[].name' \
                    | grep 'aur-' \
                    | sed -e 's/^"aur-//' -e 's/"$//' \
                    | sort -u))
        if [ "${#new_pkgs[@]}" -eq 0 ]; then
            break
        fi
        gh_pkgs+=("${new_pkgs[@]}")
        pageNo=$((pageNo + 1))
    done
}

checkPkg() {
    package="$1"

    pushd "$package" >/dev/null

    #
    # Git sanity check
    #
    # check if it is a git repo or a submodule
    if [ ! -e ".git" ]; then
        echo "[-] $package is not a git repo or a submodule"
    else
        pkg_err=0

        # check if there are exactly two remotes, "origin" and "aur"
        if [ "$(git remote)" != 'aur'$'\n''origin' ]; then
            echo "[-] $package remote error: $(git remote)"
            pkg_err=1
        fi

        # check if there is exactly one local branch, "master"
        if [ "$(git branch | sed 's,\* ,,')" != 'master' ]; then
            echo "[-] $package branch error: $(git branch | sed 's,\* ,,')"
            pkg_err=1
        fi

        if [ $pkg_err -eq 0 ]; then # if there is no remote or branch error
            # check if the local and remote branches point to the same commit
            if [ "$(git rev-parse master)" != "$(git rev-parse aur/master)" ]; then
                echo "[-] $package: aur/master is not equal to master"
            fi
            if [ "$(git rev-parse master)" != "$(git rev-parse origin/master)" ]; then
                echo "[-] $package: origin/master is not equal to master"
            fi

            # check if there are uncommitted changes

            # check if there are untracked files
        fi
    fi

    #
    # PKGBUILD check
    #
    if [ ! -f "PKGBUILD" ]; then
        echo "[-] $package does not have PKGBUILD"
    else
        # check if sources are up to date
        GITHUB_ATOM=1 aur-out-of-date -pkg $package \
            | sed '/\[UP-TO-DATE\]/d' \
            | sed '/\[UNKNOWN\] .* No \(GitHub \)\?release found/d' \
            | sed '/\[UNKNOWN\] .* upstream version is/d'
    fi

    #
    # .SRCINFO check
    #
    if [ ! -f ".SRCINFO" ]; then
        echo "[-] $package does not have .SRCINFO"
    elif [ -f "PKGBUILD" ]; then
        # check if .SRCINFO matches PKGBUILD
        if ! diff <(makepkg --printsrcinfo) .SRCINFO -B &>/dev/null; then
            echo "[-] $package: .SRCINFO does not match PKGBUILD"
        fi
    fi

    popd >/dev/null
}

main() {
    # collect package lists from the local FS, AUR, and GitHub
    collect_pkgs

    # check local and AUR packages consistency
    pkgdiff=$(diff <(printf "%s\n" "${local_pkgs[@]}") <(printf "%s\n" "${aur_pkgs[@]}"))
    if [ -n "${pkgdiff[*]}" ]; then
        echo "[-] local and AUR package list mismatch: ${#local_pkgs[@]} vs ${#aur_pkgs[@]}"
        echo "${pkgdiff}" | sed -e 's/^/    /'
        exit 1
    fi

    # check local and GitHub packages consistency
    pkgdiff=$(diff <(printf "%s\n" "${local_pkgs[@]}") <(printf "%s\n" "${gh_pkgs[@]}"))
    if [ -n "${pkgdiff[*]}" ]; then
        echo "[-] local and GitHub package list mismatch: ${#local_pkgs[@]} vs ${#gh_pkgs[@]}"
        echo "${pkgdiff}" | sed -e 's/^/    /'
        exit 1
    fi

    for package in ${local_pkgs[@]}; do
        checkPkg "$package" &
    done
    wait
}


main

# vim: set ts=4 sw=4 et:
