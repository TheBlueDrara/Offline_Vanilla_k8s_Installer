#!/usr/bin/env bash
# Developed by Alex Umansky aka TheBlueDrara
# Purpose: Phase 1 — download all .deb packages for tiers 1-5 into
#          OUTPUT_DIR/debs/tier-{1..5}/ using a fresh ubuntu:24.04 container.
# Reads:   K8S_VERSION, OUTPUT_DIR (from environment)
set -o errexit
set -o nounset
set -o pipefail

trap 'echo "ERROR: command failed on line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

download_debs() {
    local k8s_minor
    k8s_minor="${K8S_VERSION%.*}"

    local tier5_count
    tier5_count=$(find "${OUTPUT_DIR}/debs/tier-5" -maxdepth 1 -name '*.deb' 2>/dev/null | wc -l)
    if [[ "${tier5_count}" -gt 0 ]]; then
        echo "==> .deb tiers already populated — skipping download."
        return 0
    fi

    local abs_debs_dir
    abs_debs_dir="$(realpath "${OUTPUT_DIR}/debs")"

    echo "==> Downloading .deb packages (ubuntu:24.04 container)
    k8s repo  : pkgs.k8s.io/core:/stable:/v${k8s_minor}
    containerd: download.docker.com/linux/ubuntu"

    docker run --rm -i \
        -e "K8S_MINOR=${k8s_minor}" \
        -e "K8S_VERSION=${K8S_VERSION}" \
        -v "${abs_debs_dir}:/debs" \
        -v "${SCRIPT_DIR}/docker/inner-download-debs.sh:/tmp/download_debs.sh:ro" \
        ubuntu:24.04 bash /tmp/download_debs.sh

    echo "==> .deb download complete."
}

download_debs
