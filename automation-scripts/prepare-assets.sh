#!/usr/bin/env bash
##################### Start Safe Header ########################
# Developed by Alex Umansky aka TheBlueDrara
# Purpose: Download all .deb packages and container images needed by install.sh
#          into a local payload/ directory ready for Ansible deployment.
# Date 13.07.2025
# Version 2.0.0
set -o errexit
set -o nounset
set -o pipefail
#################### End Safe Header ###########################

K8S_VERSION="1.30.14"
CALICO_VERSION="3.27.2"
OUTPUT_DIR="./payload"

NULL=/dev/null



SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function main(){
    while [[ $# -gt 0 ]]; do
        case $1 in
            --k8s-version)
                [[ $# -ge 2 ]] || { echo "ERROR: --k8s-version requires a value." >&2; exit 1; }
                K8S_VERSION="$2"
                shift 2
                ;;
            --calico-version)
                [[ $# -ge 2 ]] || { echo "ERROR: --calico-version requires a value." >&2; exit 1; }
                CALICO_VERSION="$2"
                shift 2
                ;;
            --output-dir)
                [[ $# -ge 2 ]] || { echo "ERROR: --output-dir requires a value." >&2; exit 1; }
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --debug)
                set -x
                shift
                ;;
            -h|--help)
                help
                exit 0
                ;;
            *)
                echo "WARNING: ignoring unrecognized argument: $1" >&2
                shift
                ;;
        esac
    done

    echo "prepare-assets.sh
  k8s version    : $K8S_VERSION
  Calico version : $CALICO_VERSION
  Output dir     : $OUTPUT_DIR
"

    validate_prerequisites
    setup_output_dirs
    echo "Output directory: $(realpath "$OUTPUT_DIR")"

    export K8S_VERSION CALICO_VERSION OUTPUT_DIR

    bash "$SCRIPT_DIR/lib/download-debs.sh"
    bash "$SCRIPT_DIR/lib/pull-images.sh"
    bash "$SCRIPT_DIR/lib/download-manifest.sh"

    local tier img_count tier_counts=""
    for tier in 1 2 3 4 5; do
        local count
        count=$(find "$OUTPUT_DIR/debs/tier-${tier}" -maxdepth 1 -name '*.deb' | wc -l)
        tier_counts="${tier_counts}      tier-${tier}: ${count} .deb(s)
"
    done
    img_count=$(find "$OUTPUT_DIR/images" -maxdepth 1 -name '*.tar' | wc -l)

    echo "
==> payload/ is ready.
    Tier counts:
${tier_counts}      images : $img_count .tar(s)

    Next: ansible-playbook cd/playbooks/main.yaml"
}

# Prints usage information
function help(){
    echo "Usage: bash prepare-assets.sh [OPTIONS]

Options:
  --k8s-version    <X.Y.Z>   k8s version      (default: 1.30.14)
  --calico-version <X.Y.Z>   Calico version   (default: 3.27.2)
  --output-dir     <PATH>    output directory  (default: ./payload)
  --debug                    enable set -x tracing
  -h | --help                show this help"
}

# Validates that docker and curl are available
function validate_prerequisites(){
    if ! command -v docker &>$NULL; then
        echo "ERROR: docker not found on PATH." >&2
        exit 1
    fi

    if ! docker info &>$NULL; then
        echo "ERROR: Docker daemon is not running, or current user lacks access.
       Add your user to the 'docker' group or run with sudo." >&2
        exit 1
    fi

    if ! command -v curl &>$NULL; then
        echo "ERROR: curl not found on PATH." >&2
        exit 1
    fi
}

# Creates all required output subdirectories
function setup_output_dirs(){
    local -a dirs=(
        "$OUTPUT_DIR/debs/tier-1"
        "$OUTPUT_DIR/debs/tier-2"
        "$OUTPUT_DIR/debs/tier-3"
        "$OUTPUT_DIR/debs/tier-4"
        "$OUTPUT_DIR/debs/tier-5"
        "$OUTPUT_DIR/images"
        "$OUTPUT_DIR/manifests"
    )
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
    done
}

main "$@"
