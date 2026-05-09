#!/usr/bin/env bash
# Developed by Alex Umansky aka TheBlueDrara
# Purpose: Phase 2 — pull all k8s control-plane and Calico images and save
#          them as individual .tar files in OUTPUT_DIR/images/.
# Reads:   K8S_VERSION, CALICO_VERSION, OUTPUT_DIR (from environment)
set -o errexit
set -o nounset
set -o pipefail

trap 'echo "ERROR: command failed on line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

image_to_filename() {
    local image="$1"
    local name

    name="${image##*/}"
    name="${name%%:*}"

    if [[ "${image}" == *"/calico/"* ]]; then
        name="calico-${name}"
    fi

    printf '%s' "${name}"
}

get_k8s_image_list() {
    local k8s_minor
    k8s_minor="${K8S_VERSION%.*}"

    docker run --rm -i \
        -e "K8S_MINOR=${k8s_minor}" \
        -e "K8S_VERSION=${K8S_VERSION}" \
        -v "${SCRIPT_DIR}/docker/inner-get-images.sh:/tmp/get_images.sh:ro" \
        ubuntu:24.04 bash /tmp/get_images.sh
}

pull_and_save_images() {
    echo "==> Querying kubeadm for k8s image list..."

    local -a k8s_images
    mapfile -t k8s_images < <(get_k8s_image_list)

    if [[ ${#k8s_images[@]} -eq 0 ]]; then
        echo "ERROR: get_k8s_image_list returned no images. Check Docker/network." >&2
        exit 1
    fi

    echo "    ${#k8s_images[@]} k8s images listed."

    local -a calico_images=(
        "docker.io/calico/node:v${CALICO_VERSION}"
        "docker.io/calico/cni:v${CALICO_VERSION}"
        "docker.io/calico/kube-controllers:v${CALICO_VERSION}"
    )

    local -a all_images=( "${k8s_images[@]}" "${calico_images[@]}" )

    echo "==> Pulling and saving ${#all_images[@]} images..."

    local image filename tar_path
    for image in "${all_images[@]}"; do
        filename="$(image_to_filename "${image}")"
        tar_path="${OUTPUT_DIR}/images/${filename}.tar"

        if [[ -f "${tar_path}" ]]; then
            echo "    SKIP  ${filename}.tar (already exists)"
            continue
        fi

        echo "    PULL  ${image}"
        docker pull --platform linux/amd64 --quiet "${image}"

        echo "    SAVE  ${filename}.tar"
        docker save "${image}" -o "${tar_path}"
    done

    echo "==> Images saved."
}

pull_and_save_images
