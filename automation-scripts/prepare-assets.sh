#!/usr/bin/env bash
###################################### START SAFE HEADER #########################################
# Developed by Alex Umansky aka TheBlueDrara
# Purpose: Download all .deb packages and container images needed by install.sh
#          into a local payload/ directory ready for Ansible deployment.
#
# Prerequisites: Docker (running, current user has access), curl.
#               No root required. Runs on any OS with Docker.
#
# Usage: bash automation-scripts/prepare-assets.sh [--output-dir PATH]
#
# Versions are pinned to the known-working set for this project.
# Override via CLI flags only if you know what you are doing.
set -o errexit
set -o nounset
set -o pipefail
#################################### END SAFE HEADER #############################################

K8S_VERSION="1.30.14"
CALICO_VERSION="3.27.2"
OUTPUT_DIR="./payload"

trap 'echo "ERROR: command failed on line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --k8s-version)
                [[ $# -ge 2 ]] || { echo "ERROR: --k8s-version requires a value." >&2; exit 1; }
                K8S_VERSION="$2"; shift 2 ;;
            --calico-version)
                [[ $# -ge 2 ]] || { echo "ERROR: --calico-version requires a value." >&2; exit 1; }
                CALICO_VERSION="$2"; shift 2 ;;
            --output-dir)
                [[ $# -ge 2 ]] || { echo "ERROR: --output-dir requires a value." >&2; exit 1; }
                OUTPUT_DIR="$2"; shift 2 ;;
            *)
                echo "WARNING: ignoring unrecognized argument: $1" >&2; shift ;;
        esac
    done

    echo "prepare-assets.sh
  k8s version    : ${K8S_VERSION}
  Calico version : ${CALICO_VERSION}
  Output dir     : ${OUTPUT_DIR}
"

    validate_prerequisites
    setup_output_dirs

    export K8S_VERSION CALICO_VERSION OUTPUT_DIR

    bash "${SCRIPT_DIR}/lib/download-debs.sh"
    bash "${SCRIPT_DIR}/lib/pull-images.sh"
    bash "${SCRIPT_DIR}/lib/download-manifest.sh"

    local tier img_count tier_counts=""
    for tier in 1 2 3 4 5; do
        local count
        count=$(find "${OUTPUT_DIR}/debs/tier-${tier}" -maxdepth 1 -name '*.deb' | wc -l)
        tier_counts="${tier_counts}      tier-${tier}: ${count} .deb(s)
"
    done
    img_count=$(find "${OUTPUT_DIR}/images" -maxdepth 1 -name '*.tar' | wc -l)

    echo "
==> payload/ is ready.
    Tier counts:
${tier_counts}      images : ${img_count} .tar(s)

    Next: ansible-playbook cd/playbooks/main.yaml"
}

validate_prerequisites() {
    if ! command -v docker &>/dev/null; then
        echo "ERROR: docker not found on PATH." >&2
        exit 1
    fi

    if ! docker info &>/dev/null; then
        echo "ERROR: Docker daemon is not running, or current user lacks access.
       Add your user to the 'docker' group or run with sudo." >&2
        exit 1
    fi

    if ! command -v curl &>/dev/null; then
        echo "ERROR: curl not found on PATH." >&2
        exit 1
    fi
}

setup_output_dirs() {
    local -a dirs=(
        "${OUTPUT_DIR}/debs/tier-1"
        "${OUTPUT_DIR}/debs/tier-2"
        "${OUTPUT_DIR}/debs/tier-3"
        "${OUTPUT_DIR}/debs/tier-4"
        "${OUTPUT_DIR}/debs/tier-5"
        "${OUTPUT_DIR}/images"
        "${OUTPUT_DIR}/manifests"
    )
    for dir in "${dirs[@]}"; do
        mkdir -p "${dir}"
    done
    echo "Output directory: $(realpath "${OUTPUT_DIR}")"
}

main "$@"
