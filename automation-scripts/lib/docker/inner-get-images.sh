#!/usr/bin/env bash
# Developed by Alex Umansky aka TheBlueDrara
# Purpose: Run inside ubuntu:24.04 container — installs kubeadm and prints
#          the full image list for the target k8s version to stdout.
# Invoked by: lib/pull-images.sh via docker run bind-mount.
set -o errexit
set -o nounset
set -o pipefail

export DEBIAN_FRONTEND=noninteractive

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
