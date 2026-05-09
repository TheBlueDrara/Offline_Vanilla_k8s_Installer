#!/usr/bin/env bash
##################### Start Safe Header ########################
# Developed by Alex Umansky aka TheBlueDrara
# Purpose: Phase 1 — download all .deb packages for tiers 1-5 into
#          OUTPUT_DIR/debs/tier-{1..5}/ using a fresh ubuntu:24.04 container.
set -o errexit
set -o nounset
set -o pipefail
#################### End Safe Header ###########################

NULL=/dev/null

trap 'echo "ERROR: command failed on line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function main(){
    case "${1:-}" in
        -h|--help)
            help
            exit 0
            ;;
    esac

    local tier5_count
    tier5_count=$(find "$OUTPUT_DIR/debs/tier-5" -maxdepth 1 -name '*.deb' 2>$NULL | wc -l)
    if [[ $tier5_count -gt 0 ]]; then
        echo "==> .deb tiers already populated — skipping download."
        return 0
    fi

    echo "==> Downloading .deb packages (ubuntu:24.04 container)
    k8s repo  : pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}
    containerd: download.docker.com/linux/ubuntu"
    download_debs
    echo "==> .deb download complete."
}

# Prints usage information
function help(){
    echo "Usage: bash lib/download-debs.sh

  Reads K8S_VERSION and OUTPUT_DIR from environment.
  Called by prepare-assets.sh — not usually run directly.

Options:
  -h | --help   show this help"
}

# Downloads all .deb tiers using a ubuntu:24.04 container
function download_debs(){
    local k8s_minor
    k8s_minor="${K8S_VERSION%.*}"

    local abs_debs_dir
    abs_debs_dir="$(realpath "$OUTPUT_DIR/debs")"

    docker run --rm -i \
        -e "K8S_MINOR=${k8s_minor}" \
        -e "K8S_VERSION=$K8S_VERSION" \
        -v "${abs_debs_dir}:/debs" \
        -v "$SCRIPT_DIR/docker/inner-download-debs.sh:/tmp/download_debs.sh:ro" \
        ubuntu:24.04 bash /tmp/download_debs.sh
}

main "$@"
