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
    if ! type $cmd >/dev/null 2>&1; then
        echo "[!] $cmd not installed" >&2
        exit 1
    fi
done

packages=$(ls -d */ | sed 's,/$,,' | sort)
aur_pkgs=$(curl -L 'https://aur.archlinux.org/rpc/?v=5&type=search&by=maintainer&arg=kyechou' 2>/dev/null | jq '.results[].Name' | sed -e 's/^"//' -e 's/"$//' | sort)
gh_pkgs=$(curl -L 'https://api.github.com/users/kyechou/repos' 2>/dev/null | jq '.[].name' | grep 'aur-' | sed -e 's/^"aur-//' -e 's/"$//' | sort)

countArgs() {
    echo $#
}

# check local and AUR packages consistency
pkgdiff=$(diff <(printf "%s\n" "${packages[@]}") <(printf "%s\n" "${aur_pkgs[@]}"))
if [ -n "${pkgdiff[*]}" ]; then
    echo "[-] local and AUR package list mismatch: $(countArgs ${packages[@]}) vs $(countArgs ${aur_pkgs[@]})"
    echo "${pkgdiff}" | sed -e 's/^/    /'
fi

# check local and GitHub packages consistency
pkgdiff=$(diff <(printf "%s\n" "${packages[@]}") <(printf "%s\n" "${gh_pkgs[@]}"))
if [ -n "${pkgdiff[*]}" ]; then
    echo "[-] local and GitHub package list mismatch: $(countArgs ${packages[@]}) vs $(countArgs ${gh_pkgs[@]})"
    echo "${pkgdiff}" | sed -e 's/^/    /'
fi

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
    if [ $# -eq 0 ]; then
        for package in ${packages[@]}; do
            checkPkg "$package" &
        done
    else
        for package in $@; do
            checkPkg "$package" &
        done
    fi
    wait
}

main $@

# vim: set ts=4 sw=4 et:
