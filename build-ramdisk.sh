#!/usr/bin/env bash

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${DEST_DIR:-$SOURCE_DIR}"
RAMDISK="${RAMDISK:-/dev/shm}"
BUILD_ROOT="${BUILD_ROOT:-$RAMDISK/linux-t2-imac-build-${USER:-user}-$$}"
MAKEFLAGS="${MAKEFLAGS:--j$(nproc)}"
MIN_RAM_GB="${MIN_RAM_GB:-24}"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

cleanup() {
	if [[ "${KEEP_RAM_BUILD:-0}" != 1 && -n "${BUILD_ROOT:-}" && -d "$BUILD_ROOT" ]]; then
		rm -rf -- "$BUILD_ROOT"
	fi
}

need_cmd awk
need_cmd df
need_cmd find
need_cmd makepkg
need_cmd nproc
need_cmd rsync

[[ -d "$RAMDISK" ]] || die "RAMDISK does not exist: $RAMDISK"
[[ -f "$SOURCE_DIR/PKGBUILD" ]] || die "PKGBUILD not found in $SOURCE_DIR"

available_kb="$(df -Pk "$RAMDISK" | awk 'NR == 2 { print $4 }')"
required_kb=$((MIN_RAM_GB * 1024 * 1024))

if (( available_kb < required_kb )); then
	die "$RAMDISK has less than ${MIN_RAM_GB}GiB free; set RAMDISK=/path/to/tmpfs or lower MIN_RAM_GB"
fi

mkdir -p "$BUILD_ROOT" "$DEST_DIR"
trap cleanup EXIT

printf 'Staging source tree in RAM: %s\n' "$BUILD_ROOT"
rsync -a --delete \
	--exclude '/.git/' \
	--exclude '/src/' \
	--exclude '/pkg/' \
	--exclude '/*.pkg.tar' \
	--exclude '/*.pkg.tar.*' \
	--exclude '/*.log' \
	"$SOURCE_DIR/" "$BUILD_ROOT/"

printf 'Building in RAM with MAKEFLAGS=%s\n' "$MAKEFLAGS"
(
	cd "$BUILD_ROOT"
	export MAKEFLAGS
	makepkg -Cf --noconfirm
)

printf 'Copying built packages to: %s\n' "$DEST_DIR"
find "$BUILD_ROOT" -maxdepth 1 -type f \
	\( -name '*.pkg.tar' -o -name '*.pkg.tar.*' \) \
	-exec cp -f -t "$DEST_DIR" {} +

printf 'Done. Packages now in %s:\n' "$DEST_DIR"
find "$DEST_DIR" -maxdepth 1 -type f \
	\( -name '*.pkg.tar' -o -name '*.pkg.tar.*' \) \
	-printf '%f\n' | sort
