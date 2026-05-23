#!/usr/bin/env bash
##################### Start Safe Header ########################
# Developed by Alex Umansky aka TheBlueDrara
# Purpose: Phase 2 — pull all k8s control-plane and Calico images and save
#          them as individual .tar files in OUTPUT_DIR/images/.
# Date 13.07.2025
# Version 1.0.0
set -o errexit
set -o nounset
set -o pipefail
#################### End Safe Header ###########################

# shellcheck disable=SC2034
NULL=/dev/null



SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

    echo "==> Querying kubeadm for k8s image list..."

    local -a k8s_images
    get_k8s_image_list > /tmp/k8s_images_list.txt || { echo "ERROR: Failed to retrieve k8s image list." >&2; exit 1; }
    mapfile -t k8s_images < /tmp/k8s_images_list.txt
    rm -f /tmp/k8s_images_list.txt

    if [[ ${#k8s_images[@]} -eq 0 ]]; then
        echo "ERROR: get_k8s_image_list returned no images. Check Docker/network." >&2
        exit 1
    fi

    echo "    ${#k8s_images[@]} k8s images listed."

    local -a calico_images=(
        "docker.io/calico/node:v$CALICO_VERSION"
        "docker.io/calico/cni:v$CALICO_VERSION"
        "docker.io/calico/kube-controllers:v$CALICO_VERSION"
    )

    local -a all_images=( "${k8s_images[@]}" "${calico_images[@]}" )

    echo "==> Pulling and saving ${#all_images[@]} images..."

    local image filename tar_path
    for image in "${all_images[@]}"; do
        filename="$(image_to_filename "$image")"
        tar_path="$OUTPUT_DIR/images/${filename}.tar"

        if [[ -f "$tar_path" ]]; then
            echo "    SKIP  ${filename}.tar (already exists)"
            continue
        fi

        echo "    PULL  $image"
        docker pull --platform linux/amd64 --quiet "$image"

        echo "    SAVE  ${filename}.tar"
        docker save "$image" -o "$tar_path"
    done

    echo "==> Images saved."
}

# Prints usage information
function help(){
    echo "Usage: bash lib/pull-images.sh

  Reads K8S_VERSION, CALICO_VERSION, and OUTPUT_DIR from environment.
  Called by prepare-assets.sh — not usually run directly.

Options:
  --debug       enable set -x tracing
  -h | --help   show this help"
}

# Returns the k8s image list by running kubeadm inside a container
function get_k8s_image_list(){
    local k8s_minor
    k8s_minor="${K8S_VERSION%.*}"

    docker run --rm -i \
        -e "K8S_MINOR=${k8s_minor}" \
        -e "K8S_VERSION=$K8S_VERSION" \
        -v "$SCRIPT_DIR/docker/inner-get-images.sh:/tmp/get_images.sh:ro" \
        ubuntu:24.04 bash /tmp/get_images.sh
}

# Converts an image reference to a safe filename (tag included, colon replaced with dash)
function image_to_filename(){
    local image=$1
    local base tag name

    base="${image##*/}"        # strip registry + path prefix, e.g. "kube-apiserver:v1.30.14"
    name="${base%%:*}"         # component name before the colon
    tag="${base#*:}"           # everything after the colon

    if [[ "$image" == *"/calico/"* ]]; then
        name="calico-${name}"
    fi

    printf '%s' "${name}-${tag}"
}

main "$@"
