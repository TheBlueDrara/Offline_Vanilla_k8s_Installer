#!/usr/bin/env bash
# Developed by Alex Umansky aka TheBlueDrara
# Purpose: Phase 3 — download the Calico manifest at CALICO_VERSION from
#          GitHub into OUTPUT_DIR/manifests/calico.yaml.
# Reads:   CALICO_VERSION, OUTPUT_DIR (from environment)
set -o errexit
set -o nounset
set -o pipefail

trap 'echo "ERROR: command failed on line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

download_manifest() {
    local dest="${OUTPUT_DIR}/manifests/calico.yaml"

    if [[ -f "${dest}" ]]; then
        echo "==> Calico manifest already present — skipping."
        return 0
    fi

    local url="https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml"

    echo "==> Downloading Calico v${CALICO_VERSION} manifest..."
    curl -fsSL "${url}" -o "${dest}"
    echo "    Saved: ${dest}"
}

main() { download_manifest; }
main "$@"
