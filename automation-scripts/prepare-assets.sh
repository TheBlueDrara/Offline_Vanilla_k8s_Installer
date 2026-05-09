#!/usr/bin/env bash
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

# ── Pinned versions ────────────────────────────────────────────────────────
K8S_VERSION="1.30.14"
CALICO_VERSION="3.27.2"
OUTPUT_DIR="./payload"

trap 'echo "ERROR: command failed on line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# ══════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════

# Converts a full image reference to a short filename (no tag, no registry).
# Calico images are prefixed with "calico-" to disambiguate from k8s images.
# Examples:
#   registry.k8s.io/kube-apiserver:v1.30.14  →  kube-apiserver
#   registry.k8s.io/coredns/coredns:v1.11.3  →  coredns
#   docker.io/calico/node:v3.27.2            →  calico-node
function image_to_filename() {
    local image="$1"
    local name

    name="${image##*/}"   # strip registry + path prefix  →  node:v3.27.2
    name="${name%%:*}"    # strip tag                     →  node

    if [[ "${image}" == *"/calico/"* ]]; then
        name="calico-${name}"
    fi

    printf '%s' "${name}"
}

# ══════════════════════════════════════════════════════════════════════════
# VALIDATION
# ══════════════════════════════════════════════════════════════════════════

# Checks that Docker and curl are available before any work begins.
# Pre:  none.
# Post: exits 1 if any prerequisite is missing; returns 0 otherwise.
function validate_prerequisites() {
    if ! command -v docker &>/dev/null; then
        echo "ERROR: docker not found on PATH." >&2
        exit 1
    fi

    if ! docker info &>/dev/null; then
        echo "ERROR: Docker daemon is not running, or current user lacks access." >&2
        echo "       Add your user to the 'docker' group or run with sudo." >&2
        exit 1
    fi

    if ! command -v curl &>/dev/null; then
        echo "ERROR: curl not found on PATH." >&2
        exit 1
    fi
}

# ══════════════════════════════════════════════════════════════════════════
# DIRECTORY SETUP
# ══════════════════════════════════════════════════════════════════════════

# Creates the payload/ directory tree expected by install.sh.
# Pre:  OUTPUT_DIR is set.
# Post: payload/{debs/tier-{1..5},images,manifests} all exist.
function setup_output_dirs() {
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

# ══════════════════════════════════════════════════════════════════════════
# DEB DOWNLOADS
# ══════════════════════════════════════════════════════════════════════════

# Downloads all .deb packages for tiers 1–5 using a fresh ubuntu:24.04
# Docker container. Running inside Docker guarantees the same base package
# state as a freshly provisioned target VM, so the dependency closure is
# resolved correctly regardless of what is installed on the build machine.
# Pre:  Docker available; OUTPUT_DIR/debs/tier-{1..5}/ exist;
#       K8S_VERSION is set.
# Post: each tier directory contains the .deb files for that component plus
#       any transitive dependencies not already present on a base Ubuntu 24.04
#       install. Some cross-tier dep overlap is expected and harmless.
function download_debs() {
    local k8s_minor
    k8s_minor="${K8S_VERSION%.*}"

    # Skip if tier-5 is already populated (last tier = entire run completed).
    local tier5_count
    tier5_count=$(find "${OUTPUT_DIR}/debs/tier-5" -maxdepth 1 -name '*.deb' 2>/dev/null | wc -l)
    if [[ "${tier5_count}" -gt 0 ]]; then
        echo "==> .deb tiers already populated — skipping download."
        return 0
    fi

    local abs_debs_dir
    abs_debs_dir="$(realpath "${OUTPUT_DIR}/debs")"

    echo "==> Downloading .deb packages via ubuntu:24.04 container..."
    echo "    k8s repo  : pkgs.k8s.io/core:/stable:/v${k8s_minor}"
    echo "    containerd: download.docker.com/linux/ubuntu"

    local inner_script
    inner_script="$(mktemp)"
    trap 'rm -f "${inner_script}"' RETURN ERR
    cat > "${inner_script}" << 'INNER'
#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl gpg
apt-get clean

mkdir -p /etc/apt/keyrings

curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/k8s.gpg
printf 'deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/v%s/deb/ /\n' \
    "${K8S_MINOR}" > /etc/apt/sources.list.d/k8s.list

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -qq

# Downloads packages (and their uncached deps) into the apt cache, then
# moves all resulting .deb files to the tier directory.
download_tier() {
    local tier="$1"
    shift
    echo "--- tier-${tier}: $*"
    apt-get install -y --download-only --no-install-recommends "$@"
    find /var/cache/apt/archives/ -maxdepth 1 -name '*.deb' \
        -exec mv {} "/debs/tier-${tier}/" \;
}

# apt-get download fetches a package regardless of installed state.
# We use it for perl-base because it is a transitive dep of ebtables/perl
# that is already at a newer version in this Docker image than in the
# target Vagrant box — apt-get install --download-only would skip it.
cd /debs/tier-1 && apt-get download perl-base && cd /

download_tier 1 conntrack socat ebtables iptables
download_tier 2 containerd.io
download_tier 3 kubernetes-cni
download_tier 4 cri-tools
download_tier 5 \
    "kubelet=${K8S_VERSION}-*" \
    "kubeadm=${K8S_VERSION}-*" \
    "kubectl=${K8S_VERSION}-*"

echo "--- All tiers downloaded."
INNER

    docker run --rm -i \
        -e "K8S_MINOR=${k8s_minor}" \
        -e "K8S_VERSION=${K8S_VERSION}" \
        -v "${abs_debs_dir}:/debs" \
        -v "${inner_script}:/tmp/download_debs.sh:ro" \
        ubuntu:24.04 bash /tmp/download_debs.sh

    echo "    .deb download complete."
}

# ══════════════════════════════════════════════════════════════════════════
# IMAGE DOWNLOADS
# ══════════════════════════════════════════════════════════════════════════

# Queries kubeadm inside a Docker container for the exact image refs required
# by the target k8s version. Prints one fully-qualified image ref per line.
# This is the authoritative source for etcd and CoreDNS version pins —
# no hardcoding required.
# Pre:  Docker available; K8S_VERSION set.
# Post: image list written to stdout.
function get_k8s_image_list() {
    local k8s_minor
    k8s_minor="${K8S_VERSION%.*}"

    local inner_script
    inner_script="$(mktemp)"
    trap 'rm -f "${inner_script}"' RETURN ERR
    cat > "${inner_script}" << 'INNER'
#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
# All setup commands redirect stdout+stderr to /dev/null so only the final
# `kubeadm config images list` output reaches the caller's stdout.
apt-get update -qq >/dev/null 2>&1
apt-get install -y --no-install-recommends ca-certificates curl gpg >/dev/null 2>&1
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/k8s.gpg 2>/dev/null
printf 'deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/v%s/deb/ /\n' \
    "${K8S_MINOR}" > /etc/apt/sources.list.d/k8s.list
apt-get update -qq >/dev/null 2>&1
apt-get install -y --no-install-recommends "kubeadm=${K8S_VERSION}-*" >/dev/null 2>&1
kubeadm config images list --kubernetes-version="v${K8S_VERSION}"
INNER

    docker run --rm -i \
        -e "K8S_MINOR=${k8s_minor}" \
        -e "K8S_VERSION=${K8S_VERSION}" \
        -v "${inner_script}:/tmp/get_images.sh:ro" \
        ubuntu:24.04 bash /tmp/get_images.sh
}

# Pulls and saves all container images (k8s control-plane + Calico) to
# payload/images/ as individual .tar files.
# Uses --platform linux/amd64 on every pull to ensure the correct
# architecture regardless of the build machine (e.g. Apple Silicon).
# Pre:  Docker available; OUTPUT_DIR/images/ exists.
# Post: one <name>.tar per image in payload/images/. Existing tars are skipped.
function pull_and_save_images() {
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

    echo "    Images saved."
}

# ══════════════════════════════════════════════════════════════════════════
# CALICO MANIFEST
# ══════════════════════════════════════════════════════════════════════════

# Downloads the official Calico manifest at the exact CALICO_VERSION from
# the projectcalico GitHub release. Image refs in the manifest match the
# tars saved by pull_and_save_images because both use the same version tag.
# Pre:  curl available; OUTPUT_DIR/manifests/ exists.
# Post: payload/manifests/calico.yaml exists at the correct version.
function download_calico_manifest() {
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

# ══════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ══════════════════════════════════════════════════════════════════════════

function main() {
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

    echo "prepare-assets.sh"
    echo "  k8s version    : ${K8S_VERSION}"
    echo "  Calico version : ${CALICO_VERSION}"
    echo "  Output dir     : ${OUTPUT_DIR}"
    echo ""

    validate_prerequisites
    setup_output_dirs
    download_debs
    pull_and_save_images
    download_calico_manifest

    echo ""
    echo "==> payload/ is ready."
    echo "    Tier counts:"
    local tier
    for tier in 1 2 3 4 5; do
        local count
        count=$(find "${OUTPUT_DIR}/debs/tier-${tier}" -maxdepth 1 -name '*.deb' | wc -l)
        echo "      tier-${tier}: ${count} .deb(s)"
    done
    local img_count
    img_count=$(find "${OUTPUT_DIR}/images" -maxdepth 1 -name '*.tar' | wc -l)
    echo "      images : ${img_count} .tar(s)"
    echo ""
    echo "    Next: ansible-playbook cd/playbooks/main.yaml"
}

main "$@"
