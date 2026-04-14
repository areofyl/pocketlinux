#!/bin/sh
# Fetch and extract Alpine x86 packages into the rootfs
# Usage: ./fetch-apks.sh <package-name> [package-name...]

ROOTFS="$(dirname "$0")/fs"
MIRROR="https://dl-cdn.alpinelinux.org/alpine/v3.21"
CACHE="$(dirname "$0")/cache"
mkdir -p "$CACHE"

fetch_and_extract() {
    local pkg="$1"
    local repo="$2"
    local url="$MIRROR/$repo/x86/$pkg"

    if [ ! -f "$CACHE/$pkg" ]; then
        echo "Downloading $pkg..."
        curl -sL -o "$CACHE/$pkg" "$url"
        if [ $? -ne 0 ]; then
            echo "FAILED: $pkg"
            rm -f "$CACHE/$pkg"
            return 1
        fi
    else
        echo "Cached: $pkg"
    fi

    # .apk files are gzipped tars — extract, skipping the .PKGINFO and .SIGN files
    echo "Extracting $pkg..."
    tar xzf "$CACHE/$pkg" -C "$ROOTFS" --exclude='.PKGINFO' --exclude='.SIGN*' --exclude='.pre-*' --exclude='.post-*' --exclude='.trigger' 2>/dev/null
}

# Takes "repo:filename" format
for entry in "$@"; do
    repo="${entry%%:*}"
    pkg="${entry#*:}"
    fetch_and_extract "$pkg" "$repo"
done
