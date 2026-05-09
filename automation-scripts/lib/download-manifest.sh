#!/usr/bin/env bash
##################### Start Safe Header ########################
# Developed by Alex Umansky aka TheBlueDrara
# Purpose: Phase 3 — download the Calico manifest at CALICO_VERSION from
#          GitHub into OUTPUT_DIR/manifests/calico.yaml.
set -o errexit
set -o nounset
set -o pipefail
#################### End Safe Header ###########################

# shellcheck disable=SC2034
NULL=/dev/null



function main(){
    case "${1:-}" in
        --debug)
            set -x
            shift
            ;;
        -h|--help)
            help
            exit 0
            ;;
    esac

    local dest="$OUTPUT_DIR/manifests/calico.yaml"

    if [[ -f "$dest" ]]; then
        echo "==> Calico manifest already present — skipping."
        return 0
    fi

    echo "==> Downloading Calico v$CALICO_VERSION manifest..."
    download_manifest "$dest"
    echo "    Saved: $dest"
}

# Prints usage information
function help(){
    echo "Usage: bash lib/download-manifest.sh

  Reads CALICO_VERSION and OUTPUT_DIR from environment.
  Called by prepare-assets.sh — not usually run directly.

Options:
  --debug       enable set -x tracing
  -h | --help   show this help"
}

# Downloads the Calico manifest from GitHub
function download_manifest(){
    local dest=$1
    local url="https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml"

    curl -fsSL "$url" -o "$dest"
}

main "$@"
