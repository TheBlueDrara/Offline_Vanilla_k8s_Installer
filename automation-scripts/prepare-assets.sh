#!/usr/bin/env bash
##################### Start Safe Header ########################
# Developed by Alex Umansky aka TheBlueDrara
# Purpose: Download pre-built payload bundles from GitHub Releases into a local
#          payload/ directory ready for Ansible deployment.
# Start Date 13.07.2025
# Modification Date 22.5.2026
# Version 3.0.0
set -o errexit
set -o nounset
set -o pipefail
#################### End Safe Header ###########################
K8S_VERSION="1.30.14"
CALICO_VERSION="3.28.5"
OUTPUT_DIR="./payload"
GITHUB_REPO="TheBlueDrara/Offline_Vanilla_k8s_Installer"
NULL=/dev/null
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Validates that a version string matches X.Y.Z format
function validate_version(){
    local value="$1"
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
}

# Silent prerequisite check — return 0 on success, 1 on failure
function check_curl_installed(){ command -v curl &>"$NULL"; }
function check_zstd_installed(){ command -v zstd &>"$NULL"; }

# Creates all required output subdirectories
function setup_output_dirs(){
    local -a dirs=(
        "$OUTPUT_DIR/debs/tier-1"
        "$OUTPUT_DIR/debs/tier-2"
        "$OUTPUT_DIR/debs/tier-3"
        "$OUTPUT_DIR/debs/tier-4"
        "$OUTPUT_DIR/debs/tier-5"
        "$OUTPUT_DIR/images"
    )
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
    done
}

# Downloads a tar.zst from the release URL to a tempfile, then extracts it into dest_dir
function download_asset(){
    local url="$1" dest_dir="$2" strip="$3"
    local tmp
    tmp="$(mktemp /tmp/asset-XXXXXX.tar.zst)"
    if ! curl -fSL --progress-bar "$url" -o "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! tar --zstd -xf "$tmp" -C "$dest_dir" --strip-components="$strip"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

# Prints usage information
function help(){
    printf 'Usage: bash prepare-assets.sh [OPTIONS]\n\nOptions:\n  --k8s-version    <X.Y.Z>   k8s version      (default: 1.30.14)\n  --calico-version <X.Y.Z>   Calico version   (default: 3.28.5)\n  --output-dir     <PATH>    output directory  (default: ./payload)\n  --debug                    enable set -x tracing\n  -h | --help                show this help\n\nDownloads 2 pre-built tar.zst bundles (debs, images) from a GitHub\nRelease and extracts them into payload/. Requires curl and zstd.\n'
}

function main(){
    while [[ $# -gt 0 ]]; do
        case $1 in
            --k8s-version)
                if [[ $# -lt 2 ]]; then
                    printf 'ERROR: --k8s-version requires a value.\n' >&2
                    exit 1
                fi
                K8S_VERSION="$2"
                shift 2
                ;;
            --calico-version)
                if [[ $# -lt 2 ]]; then
                    printf 'ERROR: --calico-version requires a value.\n' >&2
                    exit 1
                fi
                CALICO_VERSION="$2"
                shift 2
                ;;
            --output-dir)
                if [[ $# -lt 2 ]]; then
                    printf 'ERROR: --output-dir requires a value.\n' >&2
                    exit 1
                fi
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
                printf 'ERROR: unrecognized argument: %s\n' "$1" >&2
                exit 1
                ;;
        esac
    done

    for version in "$K8S_VERSION" "$CALICO_VERSION"; do
        if ! validate_version "$version"; then
            printf 'ERROR: invalid version format, expected X.Y.Z.\n' >&2
            exit 1
        fi
    done

    printf 'prepare-assets.sh\n  k8s version    : %s\n  Calico version : %s\n  Output dir     : %s\n\n' \
        "$K8S_VERSION" "$CALICO_VERSION" "$OUTPUT_DIR"

    if ! check_curl_installed; then
        printf 'ERROR: curl not found on PATH.\n' >&2
        exit 1
    fi

    if ! check_zstd_installed; then
        printf 'ERROR: zstd not found on PATH. Install zstd and retry.\n' >&2
        exit 1
    fi

    if ! setup_output_dirs; then
        printf 'ERROR: failed to create output directories.\n' >&2
        exit 1
    fi
    printf 'Output directory: %s\n' "$(realpath "$OUTPUT_DIR")"

    local release_base="https://github.com/${GITHUB_REPO}/releases/download/k8s-${K8S_VERSION}-calico-${CALICO_VERSION}"

    local -a filenames=(
        "debs-k8s-v${K8S_VERSION}-calico-v${CALICO_VERSION}.tar.zst"
        "images-k8s-v${K8S_VERSION}-calico-v${CALICO_VERSION}.tar.zst"
    )
    local -a destinations=(
        "$OUTPUT_DIR/debs"
        "$OUTPUT_DIR/images"
    )

    local i
    for i in 0 1; do
        local filename="${filenames[$i]}"
        local dest="${destinations[$i]}"
        printf 'Downloading %s...\n' "$filename"
        if ! download_asset "${release_base}/${filename}" "$dest" 2; then
            printf 'ERROR: failed to download %s.\n' "$filename" >&2
            exit 1
        fi
        printf '    done.\n'
    done

    local tier img_count tier_counts=""
    for tier in 1 2 3 4 5; do
        local count
        count=$(find "$OUTPUT_DIR/debs/tier-${tier}" -maxdepth 1 -name '*.deb' | wc -l)
        tier_counts="${tier_counts}      tier-${tier}: ${count} .deb(s)
"
    done
    img_count=$(find "$OUTPUT_DIR/images" -maxdepth 1 -name '*.tar' | wc -l)

    printf '\n==> payload/ is ready.\n    Tier counts:\n%s      images  : %s .tar(s)\n\n    Next: ansible-playbook cd/playbooks/main.yaml\n' \
        "$tier_counts" "$img_count"
}

main "$@"
