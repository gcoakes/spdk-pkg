#!/bin/sh -e
rootdir="$(readlink -f "$(dirname "$0")")"
cd "$rootdir"

export DEBIAN_FRONTEND="noninteractive"

sed -i 's/^# deb-src/deb-src/' /etc/apt/sources.list
apt update
apt install -y build-essential git

build_dir="$(mktemp -d)"

if [ -z "$FIO_SRC" ]; then
    cd "$build_dir"
    apt source fio
    apt build-dep -y fio
    FIO_SRC="$(find "$build_dir" -maxdepth 1 -name 'fio-*' | head -n1)"
fi
cd "$FIO_SRC"
./configure
make

if [ -z "$SPDK_SRC" ]; then
    SPDK_REPO="${SPDK_REPO-https://github.com/spdk/spdk.git}"
    if [ -z "$SPDK_REF" ]; then
        SPDK_REF="$(
            git ls-remote --tags --exit-code --refs "$SPDK_REPO" \
            | sed 's|.*refs/tags/\(.*\)$|\1|' \
            | tail -n1 \
        )"
        # Shallowly clone since we know tag will be head.
        git clone \
            --branch "$SPDK_REF" \
            --depth 1 \
            --recurse-submodules \
            --shallow-submodules \
            "$SPDK_REPO" \
            "$build_dir/spdk"
    else
        # Deeply clone so we preserve tags and describe gives correct info.
        git clone --branch "$SPDK_REF" --recurse-submodules "$SPDK_REPO" "$build_dir/spdk"
    fi
    SPDK_SRC="$build_dir/spdk"
fi
cd "$SPDK_SRC"
./scripts/pkgdep.sh --fuse
./configure --with-fio="$FIO_SRC" --with-nvme-cuse
make
version="$(git describe --long | sed 's/^v//')"
cd "$rootdir"

pkg_dir="spdk_$version"
cp -r deb "$pkg_dir"
sed -i "s/@VERSION@/$version/" "$pkg_dir/DEBIAN/control"

mkdir -p "$pkg_dir/usr/lib64" "$pkg_dir/usr/src"
cp -r "$SPDK_SRC/build/bin" "$SPDK_SRC/build/lib" "$SPDK_SRC/build/include" "$pkg_dir/usr"
git -C "$SPDK_SRC" archive --format tar.gz --prefix spdk/ HEAD | tar xzv -C "$pkg_dir/usr/src"
# shellcheck disable=SC2016
find "$SPDK_SRC/build/fio" -type f -executable -print0 \
| xargs -0 -I% sh -c 'cp % "$pkg_dir/usr/lib64/fio-$(basename %).so"'
dpkg-deb --build --root-owner-group "$pkg_dir"