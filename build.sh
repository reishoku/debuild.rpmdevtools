#!/bin/bash
#
# Build rpmdevtools deb package for a target distribution.
#
# Usage: ./build.sh <codename> [codename ...]
#        ./build.sh all
#
# Environment variables (all optional):
#   RPMDEVTOOLS_VERSION  - override version (default: extracted from tarball)
#   SOURCE_DATE_EPOCH    - reproducible timestamp (default: current time)
#   CONTAINER_TOOL       - docker or podman (default: docker)
#   DEBEMAIL             - maintainer email
#   DEBFULLNAME          - maintainer name
#   LANG                 - locale (default: C)
#   TZ                   - timezone (default: Asia/Tokyo)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/debian"
CONTAINER_TOOL="${CONTAINER_TOOL:-docker}"
DEBEMAIL="${DEBEMAIL:-reishoku.gh@pm.me}"
DEBFULLNAME="${DEBFULLNAME:-'KOSHIKAWA Kenichi'}"
LANG="${LANG:-C}"
TZ="${TZ:-Asia/Tokyo}"
export DEBEMAIL DEBFULLNAME LANG TZ

UPSTREAM_URL="https://releases.pagure.org/rpmdevtools"

# Single source of truth for supported codenames and their images
declare -A CODENAME_IMAGE=(
    [bullseye]=debian:bullseye
    [bookworm]=debian:bookworm
    [trixie]=debian:trixie
    [jammy]=ubuntu:jammy
    [noble]=ubuntu:noble
    [questing]=ubuntu:questing
)
CODENAME_ORDER=(bullseye bookworm trixie jammy noble questing)

# Ubuntu codenames that need universe repository
declare -A UBUNTU_CODENAMES=(
    [jammy]=1
    [noble]=1
    [questing]=1
)

# Relative path of debian-template from SCRIPT_DIR (for container mount)
TEMPLATE_REL="${TEMPLATE_DIR#"${SCRIPT_DIR}/"}"

# --- Preflight checks ---

if ! command -v "$CONTAINER_TOOL" > /dev/null 2>&1; then
    echo "Error: ${CONTAINER_TOOL} is not installed or not in PATH" >&2
    exit 1
fi

if [ ! -d "$TEMPLATE_DIR" ]; then
    echo "Error: debian-template directory not found: ${TEMPLATE_DIR}" >&2
    exit 1
fi

# Locate the source tarball (expect exactly one rpmdevtools-*.tar.xz or .tar.gz)
find_tarball() {
    local -a found=()
    for t in "${SCRIPT_DIR}"/rpmdevtools-*.tar.{xz,gz}; do
        [ -f "$t" ] && found+=("$t")
    done
    case ${#found[@]} in
        0) echo "Error: no rpmdevtools-*.tar.{xz,gz} found in ${SCRIPT_DIR}" >&2
           echo "Download from: ${UPSTREAM_URL}/" >&2; return 1 ;;
        1) echo "${found[0]}" ;;
        *) echo "Error: multiple tarballs found; keep exactly one:" >&2
           printf '  %s\n' "${found[@]}" >&2; return 1 ;;
    esac
}

TARBALL=$(find_tarball)
TARBALL_NAME=$(basename "$TARBALL")
SRC_DIR="${TARBALL_NAME%.tar.*}"

# Extract version from tarball name (rpmdevtools-X.Y.tar.xz -> X.Y)
RPMDEVTOOLS_VERSION="${RPMDEVTOOLS_VERSION:-${SRC_DIR#rpmdevtools-}}"

usage() {
    echo "Usage: $0 <codename> [codename ...]" >&2
    echo "       $0 all" >&2
    echo >&2
    echo "Supported codenames:" >&2
    printf '  %s\n' "${CODENAME_ORDER[@]}" >&2
    echo >&2
    echo "Upstream source: ${UPSTREAM_URL}/" >&2
    exit 1
}

if [ $# -eq 0 ]; then
    usage
fi

# Expand "all" to full list
if [ "$1" = "all" ]; then
    set -- "${CODENAME_ORDER[@]}"
fi

# Validate all codenames before starting any build
for codename in "$@"; do
    if [ -z "${CODENAME_IMAGE[$codename]:-}" ]; then
        echo "Error: unknown codename '${codename}'" >&2
        usage
    fi
done

for codename in "$@"; do
    image="${CODENAME_IMAGE[$codename]}"
    out_dir="${SCRIPT_DIR}/${codename}"
    changelog="${out_dir}/changelog"
    is_ubuntu="${UBUNTU_CODENAMES[$codename]:-}"

    mkdir -p "$out_dir"

    # Remove stale .deb from previous builds
    rm -f "${out_dir}"/rpmdevtools_*.deb

    # Generate changelog with dch (from devscripts); clean up via trap
    dch --create --changelog "$changelog" \
        --package rpmdevtools \
        --newversion "${RPMDEVTOOLS_VERSION}-1~${codename}1" \
        --distribution "${codename}" \
        --urgency low \
        "New upstream release ${RPMDEVTOOLS_VERSION}"
    trap 'rm -f "$changelog"' EXIT

    echo "Building rpmdevtools ${RPMDEVTOOLS_VERSION} for ${codename} (${image})..."

    # Pass SOURCE_DATE_EPOCH to container only if set (for reproducible builds)
    epoch_args=()
    [ -n "${SOURCE_DATE_EPOCH:-}" ] && epoch_args=(-e "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}")

    "$CONTAINER_TOOL" run --rm \
        -v "${SCRIPT_DIR}:/src:ro" \
        -v "${out_dir}:/out" \
        -e "TARBALL_NAME=${TARBALL_NAME}" \
        -e "SRC_DIR=${SRC_DIR}" \
        -e "TEMPLATE_REL=${TEMPLATE_REL}" \
        -e "IS_UBUNTU=${is_ubuntu}" \
        "${epoch_args[@]}" \
        "$image" bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Enable universe repository for Ubuntu (python3-rpm, help2man, etc.)
if [ "${IS_UBUNTU:-}" = "1" ]; then
    sed -i "s/^Types: deb$/Types: deb\nComponents: main universe/" \
        /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null \
    || echo "deb http://archive.ubuntu.com/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) universe" \
        >> /etc/apt/sources.list
fi

apt-get update -qq
apt-get install -y -qq devscripts equivs > /dev/null

WORKDIR=$(mktemp -d)
cd "$WORKDIR"

tar xf "/src/${TARBALL_NAME}"
cd "${SRC_DIR}"

cp -a "/src/${TEMPLATE_REL}" debian
cp /out/changelog debian/changelog

mk-build-deps --install \
    --tool "apt-get -y -qq --no-install-recommends" \
    debian/control > /dev/null

debuild -us -uc -b

cp "$WORKDIR"/rpmdevtools_*.deb /out/

rm -rf "$WORKDIR"
'

    rm -f "$changelog"
    trap - EXIT

    echo "=== ${codename}: build complete ==="
    ls -la "${out_dir}"/*.deb
done
