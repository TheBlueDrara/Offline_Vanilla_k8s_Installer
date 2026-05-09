#!/usr/bin/env bash
##################### Start Safe Header ########################
# Developed by Alex Umansky aka TheBlueDrara
# Purpose: Run inside ubuntu:24.04 container — adds apt repos and downloads
#          all .deb packages for tiers 1-5 into /debs/tier-{1..5}/.
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

    setup_repos
    cd /debs/tier-1 && apt-get download perl-base && cd /
    download_tier 1 conntrack socat ebtables iptables
    download_tier 2 containerd.io
    download_tier 3 kubernetes-cni
    download_tier 4 cri-tools
    download_tier 5 \
        "kubelet=$K8S_VERSION-*" \
        "kubeadm=$K8S_VERSION-*" \
        "kubectl=$K8S_VERSION-*"
    echo "--- All tiers downloaded."
}

# Prints usage information
function help(){
    echo "Usage: bash inner-download-debs.sh

  Runs inside ubuntu:24.04 container. Invoked by download-debs.sh.
  Expects K8S_MINOR and K8S_VERSION in environment.

Options:
  --debug       enable set -x tracing
  -h | --help   show this help"
}

# Configures apt repositories for k8s and Docker inside the container
function setup_repos(){
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends ca-certificates curl gpg
    apt-get clean

    mkdir -p /etc/apt/keyrings

    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
        | gpg --dearmor -o /etc/apt/keyrings/k8s.gpg

    printf 'deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/v%s/deb/ /\n' \
        "$K8S_MINOR" > /etc/apt/sources.list.d/k8s.list

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
}

# Downloads packages for a single tier into /debs/tier-N
function download_tier(){
    local tier=$1
    shift
    echo "--- tier-${tier}: $*"
    apt-get install -y --download-only --no-install-recommends "$@"
    find /var/cache/apt/archives/ -maxdepth 1 -name '*.deb' \
        -exec mv {} "/debs/tier-${tier}/" \;
}

main "$@"
