#!/usr/bin/env bash
##################### Start Safe Header ########################
# Developed by Alex Umansky aka TheBlueDrara
# Purpose: Pull Calico images, save them to upload/, and pack the
#          two release bundles (images + debs) ready for gh release create.
# Start Date 23.05.2026
# Version 1.0.0
set -o errexit
set -o nounset
set -o pipefail
#################### End Safe Header ###########################

K8S_VERSION="1.30.14"
CALICO_VERSION="3.28.5"
UPLOAD_DIR="./upload"
NULL=/dev/null

# Validates that a version string matches X.Y.Z format
function validate_version() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
}

# Verify docker is on PATH; exit 1 with a clear message if not
function check_prerequisites() {
    if ! command -v docker >"$NULL" 2>&1; then
        printf 'ERROR: docker not found on PATH. Install Docker and retry.\n' >&2
        exit 1
    fi
    printf 'docker found: %s\n' "$(command -v docker)"
}

# Pull the three Calico images from docker.io
function pull_calico_images() {
    local -a names=(cni node kube-controllers)
    local name image
    for name in "${names[@]}"; do
        image="docker.io/calico/${name}:v${CALICO_VERSION}"
        printf '==> Pulling %s...\n' "$image"
        if ! docker pull "$image"; then
            printf 'ERROR: docker pull failed for %s.\n' "$image" >&2
            exit 1
        fi
        printf '    done.\n'
    done
}

# Save each Calico image to a .tar file; remove stale calico tarballs first
function save_calico_images() {
    local images_dir="${UPLOAD_DIR}/images/v${K8S_VERSION}"

    if [[ ! -d "$images_dir" ]]; then
        printf 'ERROR: images directory not found: %s\n' "$images_dir" >&2
        exit 1
    fi

    # Remove calico tarballs that belong to a different Calico version
    local f
    for f in "${images_dir}"/calico-*.tar; do
        # The glob expands to the literal pattern when there are no matches
        [[ -e "$f" ]] || continue
        # Keep files that already match the target version
        if [[ "$f" != *"v${CALICO_VERSION}.tar" ]]; then
            printf '==> Removing stale tarball: %s\n' "$f"
            rm -f "$f"
        fi
    done

    local -a names=(cni node kube-controllers)
    local name image out_file
    for name in "${names[@]}"; do
        image="docker.io/calico/${name}:v${CALICO_VERSION}"
        out_file="${images_dir}/calico-${name}-v${CALICO_VERSION}.tar"
        printf '==> Saving %s -> %s\n' "$image" "$out_file"
        if ! docker save "$image" -o "$out_file"; then
            printf 'ERROR: docker save failed for %s.\n' "$image" >&2
            exit 1
        fi
        printf '    done.\n'
    done
}

# Build upload/images-k8s-vX.Y.Z-calico-vA.B.C.tar.zst
# Internal structure: payload/images/<file>.tar  (strips the v<K8S_VERSION>/ prefix)
function build_images_bundle() {
    local bundle_path="${UPLOAD_DIR}/images-k8s-v${K8S_VERSION}-calico-v${CALICO_VERSION}.tar.zst"
    local images_dir="${UPLOAD_DIR}/images"

    printf '==> Building images bundle: %s\n' "$bundle_path"
    tar -I 'zstd -19' -cf "$bundle_path" \
        -C "$images_dir" \
        --transform "s|^v${K8S_VERSION}/|payload/images/|" \
        "v${K8S_VERSION}/"

    local size
    size="$(du -sh "$bundle_path" | cut -f1)"
    printf '    done. Size: %s\n' "$size"
}

# Build upload/debs-k8s-vX.Y.Z-calico-vA.B.C.tar.zst
# Internal structure: payload/debs/tier-N/<file>.deb
function build_debs_bundle() {
    local bundle_path="${UPLOAD_DIR}/debs-k8s-v${K8S_VERSION}-calico-v${CALICO_VERSION}.tar.zst"
    local debs_dir="${UPLOAD_DIR}/debs"
    local debs_version_dir="${debs_dir}/v${K8S_VERSION}"

    if [[ ! -d "$debs_version_dir" ]]; then
        printf 'ERROR: debs directory not found: %s\n' "$debs_version_dir" >&2
        exit 1
    fi

    printf '==> Building debs bundle: %s\n' "$bundle_path"
    tar -I 'zstd -19' -cf "$bundle_path" \
        -C "$debs_dir" \
        --transform "s|^v${K8S_VERSION}/|payload/debs/|" \
        "v${K8S_VERSION}/"

    local size
    size="$(du -sh "$bundle_path" | cut -f1)"
    printf '    done. Size: %s\n' "$size"
}

# Print usage information
function help() {
    printf 'Usage: bash build-release-bundle.sh [OPTIONS]\n\nOptions:\n  --k8s-version    <X.Y.Z>   k8s version      (default: 1.30.14)\n  --calico-version <X.Y.Z>   Calico version   (default: 3.28.5)\n  --upload-dir     <PATH>    upload directory  (default: ./upload)\n  --debug                    enable set -x tracing\n  -h | --help                show this help\n\nPulls the 3 Calico images, saves them, and builds two release bundles:\n  images-k8s-v<K8S>-calico-v<CALICO>.tar.zst\n  debs-k8s-v<K8S>-calico-v<CALICO>.tar.zst\nRequires docker and zstd on PATH.\n'
}

function main() {
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
            --upload-dir)
                if [[ $# -lt 2 ]]; then
                    printf 'ERROR: --upload-dir requires a value.\n' >&2
                    exit 1
                fi
                UPLOAD_DIR="$2"
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
            printf 'ERROR: invalid version format "%s", expected X.Y.Z.\n' "$version" >&2
            exit 1
        fi
    done

    printf 'build-release-bundle.sh\n  k8s version    : %s\n  Calico version : %s\n  Upload dir     : %s\n\n' \
        "$K8S_VERSION" "$CALICO_VERSION" "$UPLOAD_DIR"

    check_prerequisites
    pull_calico_images
    save_calico_images
    build_images_bundle
    build_debs_bundle

    local img_bundle="${UPLOAD_DIR}/images-k8s-v${K8S_VERSION}-calico-v${CALICO_VERSION}.tar.zst"
    local deb_bundle="${UPLOAD_DIR}/debs-k8s-v${K8S_VERSION}-calico-v${CALICO_VERSION}.tar.zst"
    local img_size deb_size
    img_size="$(du -sh "$img_bundle" | cut -f1)"
    deb_size="$(du -sh "$deb_bundle" | cut -f1)"

    printf '\n==> Bundles ready in upload/:\n    images-k8s-v%s-calico-v%s.tar.zst  (%s)\n    debs-k8s-v%s-calico-v%s.tar.zst    (%s)\n' \
        "$K8S_VERSION" "$CALICO_VERSION" "$img_size" \
        "$K8S_VERSION" "$CALICO_VERSION" "$deb_size"

    printf '\n==> To publish to GitHub Releases, run:\n    gh release create k8s-%s-calico-%s \\\n        --repo TheBlueDrara/Offline_Vanilla_k8s_Installer \\\n        --title "k8s %s + Calico %s" \\\n        --notes "Offline installer bundles for k8s v%s with Calico v%s" \\\n        upload/images-k8s-v%s-calico-v%s.tar.zst \\\n        upload/debs-k8s-v%s-calico-v%s.tar.zst\n' \
        "$K8S_VERSION" "$CALICO_VERSION" \
        "$K8S_VERSION" "$CALICO_VERSION" \
        "$K8S_VERSION" "$CALICO_VERSION" \
        "$K8S_VERSION" "$CALICO_VERSION" \
        "$K8S_VERSION" "$CALICO_VERSION"
}

main "$@"
