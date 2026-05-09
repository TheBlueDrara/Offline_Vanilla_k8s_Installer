#!/usr/bin/env bash
##################### Start Safe Header ########################
# Developed by Alex Umansky aka TheBlueDrara
# Purpose: Run inside ubuntu:24.04 container — installs kubeadm and prints
#          the full image list for the target k8s version to stdout.
set -o errexit
set -o nounset
set -o pipefail
#################### End Safe Header ###########################

trap 'echo "ERROR: command failed on line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

function main(){
    setup_repos
    apt-get install -y --no-install-recommends "kubeadm=${K8S_VERSION}-*" >/dev/null 2>&1
    kubeadm config images list --kubernetes-version="v$K8S_VERSION"
}

# Configures the k8s apt repository inside the container
function setup_repos(){
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq >/dev/null 2>&1
    apt-get install -y --no-install-recommends ca-certificates curl gpg >/dev/null 2>&1

    mkdir -p /etc/apt/keyrings

    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
        | gpg --dearmor -o /etc/apt/keyrings/k8s.gpg 2>/dev/null

    printf 'deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/v%s/deb/ /\n' \
        "$K8S_MINOR" > /etc/apt/sources.list.d/k8s.list

    apt-get update -qq >/dev/null 2>&1
}

main "$@"
