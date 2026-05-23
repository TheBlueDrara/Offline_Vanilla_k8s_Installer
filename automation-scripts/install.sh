#!/usr/bin/env bash
##################### Start Safe Header ########################
# Developed by Alex Umansky aka TheBlueDrara
# Purpose: Install vanilla Kubernetes offline on Ubuntu 24.04. Detects node
#          role at runtime: control_plane initialises the cluster and writes
#          a join command; worker consumes that command and joins.
# Date 13.07.2025
# Version 2.0.0
set -o errexit
set -o nounset
set -o pipefail
#################### End Safe Header ###########################
K8S_VERSION="1.30.14"
POD_NETWORK_CIDR="192.168.0.0/16"
CRI_SOCKET="unix:///run/containerd/containerd.sock"
MANIFESTS_PATH="/etc/kubernetes/manifests"
JOIN_COMMAND_PATH="/tmp/join_command.txt"
ROLE=""
CONTROL_PLANE_IP=""
REAL_USER=""
REAL_HOME=""
NULL=/dev/null
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
PAYLOAD_DIR="${PAYLOAD_DIR:-$SCRIPT_DIR/payload}"
CONFIG_DIR="${CONFIG_DIR:-$SCRIPT_DIR/configs}"
# shellcheck source=/dev/null
. /etc/os-release

function main(){
    while [[ $# -gt 0 ]]; do
        case $1 in
            -r|--role)
                [[ $# -ge 2 ]] || { echo "ERROR: --role requires a value." >&2; exit 1; }
                ROLE="$2"
                shift 2
                ;;
            -m|--master)
                [[ $# -ge 2 ]] || { echo "ERROR: --master requires a value." >&2; exit 1; }
                CONTROL_PLANE_IP="$2"
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
                echo "WARNING: ignoring unrecognized argument: $1" >&2
                shift
                ;;
        esac
    done

    echo "install.sh — role: $ROLE"
    resolve_real_user
    is_root          || { echo "ERROR: Run this script as root (e.g. sudo bash install.sh ...)." >&2; exit 1; }
    is_supported_os  || { echo "ERROR: This installer targets Ubuntu 24.04. Detected OS: $ID" >&2; exit 1; }
    no_docker        || { echo "ERROR: Docker is installed. Remove it before running this installer." >&2; exit 1; }
    is_valid_role    || { echo "ERROR: --role must be 'control_plane' or 'worker'. Got: '${ROLE:-<unset>}'" >&2; exit 1; }
    is_master_set    || { echo "ERROR: --master <IP> is required when --role is control_plane." >&2; exit 1; }
    payload_exists   || { echo "ERROR: Payload directory not found: $PAYLOAD_DIR" >&2; exit 1; }
    config_exists    || { echo "ERROR: Config directory not found: $CONFIG_DIR" >&2; exit 1; }
    check_node || exit 1
}

# Prints usage information
function help(){
    echo "Usage: sudo bash install.sh [OPTIONS]

Options:
  -r | --role     control_plane | worker   (required)
  -m | --master   <IP>                     (required for control_plane)
  --debug                                  enable set -x tracing
  -h | --help                              show this help"
}

# Determines the non-root user who invoked sudo
function resolve_real_user(){
    if [[ -n "${SUDO_USER:-}" ]]; then
        REAL_USER="$SUDO_USER"
    else
        REAL_USER="$(logname 2>$NULL || echo root)"
    fi
    REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
}

function is_root(){         [[ $EUID -eq 0 ]]; }
function is_supported_os(){ [[ "$ID" == "ubuntu" || "$ID" == "debian" ]] || [[ "${ID_LIKE:-}" == *ubuntu* || "${ID_LIKE:-}" == *debian* ]]; }
function no_docker(){       ! command -v docker &>$NULL; }
function is_valid_role(){   [[ "$ROLE" == "control_plane" || "$ROLE" == "worker" ]]; }
function is_master_set(){   [[ "$ROLE" != "control_plane" || -n "$CONTROL_PLANE_IP" ]]; }
function payload_exists(){  [[ -d "$PAYLOAD_DIR" ]]; }
function config_exists(){   [[ -d "$CONFIG_DIR" ]]; }

# Determines the current node state and routes to the appropriate action
function check_node(){
    if ! command -v kubeadm &>$NULL || ! command -v kubelet &>$NULL; then
        install_k8s "$ROLE" || return 1
        return 0
    fi

    local is_control_plane=false
    if [[ -f "$MANIFESTS_PATH/kube-apiserver.yaml" ]]          || \
       [[ -f "$MANIFESTS_PATH/kube-scheduler.yaml" ]]           || \
       [[ -f "$MANIFESTS_PATH/kube-controller-manager.yaml" ]]; then
        is_control_plane=true
    fi

    if [[ "$is_control_plane" == "true" ]]; then
        if systemctl is-active --quiet kubelet; then
            return 0
        else
            echo "ERROR: Control-plane manifests present but kubelet is inactive.
Manual investigation required.
Run: journalctl -u kubelet --no-pager -n 50" >&2
            return 1
        fi
    else
        if systemctl is-active --quiet kubelet; then
            return 0
        else
            recover_worker || return 1
        fi
    fi
}

# Runs the full installation sequence for a fresh node
function install_k8s(){
    local role=$1

    disable_swap          || return 1
    install_os_deps       || return 1
    install_containerd    || return 1
    install_cni           || return 1
    install_cri_tools     || return 1
    install_kube_binaries || return 1
    configure_kernel      || return 1
    configure_iptables    || return 1
    import_images         || return 1

    if [[ "$role" == "control_plane" ]]; then
        init_control_plane    || return 1
        install_calico        || return 1
        install_optional_tools || return 1
    else
        join_worker_node || return 1
    fi
}

# Attempts to restart an inactive kubelet on a previously joined worker
function recover_worker(){
    systemctl start kubelet || return 1

    local retries=10
    while [[ $retries -gt 0 ]]; do
        if systemctl is-active --quiet kubelet; then
            return 0
        fi
        retries=$(( retries - 1 ))
        sleep 2
    done

    echo "ERROR: kubelet did not become active after restart.
Run 'journalctl -u kubelet --no-pager -n 50' for details." >&2
    return 1
}

# Disables swap for the current boot and comments out swap entries in /etc/fstab
function disable_swap(){
    if [[ -z "$(swapon --noheadings --show)" ]]; then
        return 0
    fi

    swapoff -a
    sed -i.bak '/[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab

    if [[ -n "$(swapon --noheadings --show)" ]]; then
        echo "ERROR: Failed to disable swap." >&2
        return 1
    fi
}

# Installs OS-level prerequisites from payload/debs/tier-1
function install_os_deps(){
    if dpkg -s conntrack &>$NULL && dpkg -s socat &>$NULL; then
        return 0
    fi

    require_debs "$PAYLOAD_DIR/debs/tier-1"     || return 1
    dpkg_install_tier "$PAYLOAD_DIR/debs/tier-1" || return 1
}

# Installs containerd from payload/debs/tier-2, writes config, and verifies service
function install_containerd(){
    if command -v containerd &>$NULL && systemctl is-active --quiet containerd; then
        :
    else
        require_debs "$PAYLOAD_DIR/debs/tier-2"     || return 1
        dpkg_install_tier "$PAYLOAD_DIR/debs/tier-2" || return 1
    fi

    mkdir -p /etc/containerd
    cp "$CONFIG_DIR/containerd_conf/config.toml" /etc/containerd/config.toml

    systemctl daemon-reload
    systemctl enable containerd
    systemctl restart containerd

    local retries=10
    while [[ $retries -gt 0 ]]; do
        if systemctl is-active --quiet containerd; then
            return 0
        fi
        retries=$(( retries - 1 ))
        sleep 1
    done

    echo "ERROR: containerd did not start within the expected time." >&2
    journalctl -u containerd --no-pager -n 30 >&2
    return 1
}

# Installs kubernetes-cni from payload/debs/tier-3
function install_cni(){
    if dpkg -s kubernetes-cni &>$NULL; then
        return 0
    fi

    require_debs "$PAYLOAD_DIR/debs/tier-3"     || return 1
    dpkg_install_tier "$PAYLOAD_DIR/debs/tier-3" || return 1
}

# Installs cri-tools (crictl) from payload/debs/tier-4
function install_cri_tools(){
    if command -v crictl &>$NULL; then
        return 0
    fi

    require_debs "$PAYLOAD_DIR/debs/tier-4"     || return 1
    dpkg_install_tier "$PAYLOAD_DIR/debs/tier-4" || return 1
}

# Installs kubelet, kubeadm, and kubectl from payload/debs/tier-5
function install_kube_binaries(){
    local installed_version
    installed_version="$(kubelet --version 2>$NULL | sed 's/Kubernetes v//' || true)"

    if [[ -n "$installed_version" ]]; then
        if [[ "$installed_version" == "$K8S_VERSION" ]]; then
            return 0
        fi
        echo "ERROR: Found kube binaries at v$installed_version, expected v$K8S_VERSION.
Version changes are out of scope for this installer. Manual intervention required." >&2
        return 1
    fi

    require_debs "$PAYLOAD_DIR/debs/tier-5"     || return 1
    dpkg_install_tier "$PAYLOAD_DIR/debs/tier-5" || return 1

    apt-mark hold kubelet kubeadm kubectl
    systemctl daemon-reload
    systemctl enable kubelet
}

# Asserts that a tier directory exists and contains at least one .deb file
function require_debs(){
    local dir=$1
    local count
    count=$(find "$dir" -maxdepth 1 -name '*.deb' 2>$NULL | wc -l)
    if [[ $count -eq 0 ]]; then
        echo "ERROR: No .deb files found in $dir" >&2
        return 1
    fi
}

# Installs all .deb files in a tier directory via a single dpkg -i call
function dpkg_install_tier(){
    local dir=$1
    local -a debs
    mapfile -t debs < <(find "$dir" -maxdepth 1 -name '*.deb' | sort)
    dpkg -i "${debs[@]}"
}

# Loads overlay and br_netfilter kernel modules and applies sysctl settings
function configure_kernel(){
    [[ -d /sys/module/overlay ]]      || modprobe overlay
    [[ -d /sys/module/br_netfilter ]] || modprobe br_netfilter

    printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf

    cp "$CONFIG_DIR/iptables_conf/network.conf" /etc/sysctl.d/99-k8s-cri.conf
    sysctl --system > $NULL
}

# Switches iptables to legacy mode when the iptables-legacy binary is present
function configure_iptables(){
    local legacy="/usr/sbin/iptables-legacy"

    if [[ ! -e "$legacy" ]]; then
        return 0
    fi

    local current
    current="$(readlink -f /etc/alternatives/iptables 2>$NULL || true)"
    if [[ "$current" == "$legacy" ]]; then
        return 0
    fi

    update-alternatives --set iptables "$legacy"
    if [[ -e /usr/sbin/ip6tables-legacy ]]; then
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
    fi
}

# Imports all container images from payload/images into the k8s.io containerd namespace
function import_images(){
    local image_dir="$PAYLOAD_DIR/images"
    local count
    count=$(find "$image_dir" -maxdepth 1 -name '*.tar' 2>$NULL | wc -l)

    if [[ $count -eq 0 ]]; then
        echo "ERROR: No image tarballs found in $image_dir" >&2
        return 1
    fi

    while IFS= read -r tar_file; do
        ctr -n k8s.io images import "$tar_file"
    done < <(find "$image_dir" -maxdepth 1 -name '*.tar' | sort)
}

# Initialises the Kubernetes control plane via kubeadm
function init_control_plane(){
    if [[ -f /etc/kubernetes/admin.conf ]]; then
        if [[ ! -s "$JOIN_COMMAND_PATH" ]]; then
            wait_for_apiserver || return 1
            local join_cmd
            join_cmd="$(kubeadm token create --print-join-command)"
            echo "JOIN_COMMAND=\"$join_cmd\"" > "$JOIN_COMMAND_PATH"
        fi
        return 0
    fi

    kubeadm init \
        --kubernetes-version="v$K8S_VERSION" \
        --control-plane-endpoint="$CONTROL_PLANE_IP" \
        --pod-network-cidr="$POD_NETWORK_CIDR" \
        --cri-socket="$CRI_SOCKET" \
        --v=5

    mkdir -p "$REAL_HOME/.kube"
    cp /etc/kubernetes/admin.conf "$REAL_HOME/.kube/config"
    chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube"

    mkdir -p /root/.kube
    cp /etc/kubernetes/admin.conf /root/.kube/config

    wait_for_apiserver || return 1

    local join_cmd
    join_cmd="$(kubeadm token create --print-join-command)"
    echo "JOIN_COMMAND=\"$join_cmd\"" > "$JOIN_COMMAND_PATH"
}

# Polls the API server /healthz endpoint until it responds or times out
function wait_for_apiserver(){
    local timeout=120
    local start_time=$SECONDS

    until kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /healthz &>$NULL; do
        if [[ $(( SECONDS - start_time )) -ge $timeout ]]; then
            echo "ERROR: API server did not become healthy within ${timeout}s." >&2
            kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /healthz >&2 || true
            return 1
        fi
        sleep 2
    done
}

# Deploys Calico CNI from configs/calico_conf/calico.yaml
function install_calico(){
    if [[ ! -e /usr/lib/cni ]]; then
        ln -s /opt/cni/bin /usr/lib/cni
    fi

    local calico_manifest="$CONFIG_DIR/calico_conf/calico.yaml"
    if [[ ! -f "$calico_manifest" ]]; then
        echo "ERROR: Calico manifest not found: $calico_manifest" >&2
        return 1
    fi

    kubectl --kubeconfig /etc/kubernetes/admin.conf \
        apply --validate=false -f "$calico_manifest"
}

# Installs helm and kustomize from payload/optional_tools if present
function install_optional_tools(){
    local tools_dir="$PAYLOAD_DIR/optional_tools"
    [[ -d "$tools_dir" ]] || return 0

    if ! command -v helm &>$NULL && [[ -f "$tools_dir/helm_bin.tar.gz" ]]; then
        tar -xzf "$tools_dir/helm_bin.tar.gz" -C "$tools_dir/"
        mv "$tools_dir/helm" /usr/local/bin/helm
    fi

    if ! command -v kustomize &>$NULL && [[ -f "$tools_dir/kustomize_bin.tar.gz" ]]; then
        tar -xzf "$tools_dir/kustomize_bin.tar.gz" -C "$tools_dir/"
        mv "$tools_dir/kustomize" /usr/local/bin/kustomize
    fi
}

# Sources the join command from JOIN_COMMAND_PATH and executes it
function join_worker_node(){
    if systemctl is-active --quiet kubelet && \
       [[ ! -f "$MANIFESTS_PATH/kube-apiserver.yaml" ]]; then
        return 0
    fi

    if [[ ! -f "$JOIN_COMMAND_PATH" ]]; then
        echo "ERROR: Join command file not found: $JOIN_COMMAND_PATH" >&2
        return 1
    fi

    # Sourced inside function: file is runtime-generated by init_control_plane
    # and does not exist at script-load time — cannot be moved to global scope.
    # shellcheck source=/dev/null
    . "$JOIN_COMMAND_PATH"

    if [[ -z "${JOIN_COMMAND:-}" ]]; then
        echo "ERROR: JOIN_COMMAND is empty in $JOIN_COMMAND_PATH" >&2
        return 1
    fi

    eval "$JOIN_COMMAND"
}

main "$@"
