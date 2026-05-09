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

trap 'echo "ERROR: command failed on line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="${PAYLOAD_DIR:-$SCRIPT_DIR/payload}"
CONFIG_DIR="${CONFIG_DIR:-$SCRIPT_DIR/configs}"

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
            *)
                echo "WARNING: ignoring unrecognized argument: $1" >&2
                shift
                ;;
        esac
    done

    resolve_real_user
    validate_environment
    check_node
}

# Determines the non-root user who invoked sudo
function resolve_real_user(){
    if [[ -n "${SUDO_USER:-}" ]]; then
        REAL_USER="${SUDO_USER}"
    else
        REAL_USER="$(logname 2>$NULL || echo root)"
    fi
    REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
}

# Checks all preconditions before any installation work begins
function validate_environment(){
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Run this script as root (e.g. sudo bash install.sh ...)." >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    . /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]] && \
       [[ "${ID_LIKE:-}" != *ubuntu* && "${ID_LIKE:-}" != *debian* ]]; then
        echo "ERROR: This installer targets Ubuntu 24.04. Detected OS: $ID" >&2
        exit 1
    fi

    if command -v docker &>$NULL; then
        echo "ERROR: Docker is installed. Remove it before running this installer." >&2
        exit 1
    fi

    if [[ "$ROLE" != "control_plane" && "$ROLE" != "worker" ]]; then
        echo "ERROR: --role must be 'control_plane' or 'worker'. Got: '${ROLE:-<unset>}'" >&2
        exit 1
    fi

    if [[ "$ROLE" == "control_plane" && -z "$CONTROL_PLANE_IP" ]]; then
        echo "ERROR: --master <IP> is required when --role is control_plane." >&2
        exit 1
    fi

    if [[ ! -d "$PAYLOAD_DIR" ]]; then
        echo "ERROR: Payload directory not found: $PAYLOAD_DIR" >&2
        exit 1
    fi

    if [[ ! -d "$CONFIG_DIR" ]]; then
        echo "ERROR: Config directory not found: $CONFIG_DIR" >&2
        exit 1
    fi
}

# Determines the current node state and routes to the appropriate action
function check_node(){
    if ! command -v kubeadm &>$NULL || ! command -v kubelet &>$NULL; then
        echo "k8s not installed — starting fresh installation (role: $ROLE)..."
        install_k8s "$ROLE"
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
            echo "Control plane is already running — re-run is a no-op."
            exit 0
        else
            echo "ERROR: Control-plane manifests present but kubelet is inactive." >&2
            echo "Manual investigation required." >&2
            echo "Run: journalctl -u kubelet --no-pager -n 50" >&2
            exit 1
        fi
    else
        if systemctl is-active --quiet kubelet; then
            echo "Worker already joined and running — re-run is a no-op."
            exit 0
        else
            recover_worker
        fi
    fi
}

# Runs the full installation sequence for a fresh node
function install_k8s(){
    local role=$1

    disable_swap
    install_os_deps
    install_containerd
    install_cni
    install_cri_tools
    install_kube_binaries
    configure_kernel
    configure_iptables
    import_images

    if [[ "$role" == "control_plane" ]]; then
        init_control_plane
        install_calico
        install_optional_tools
    else
        join_worker_node
    fi
}

# Attempts to restart an inactive kubelet on a previously joined worker
function recover_worker(){
    echo "Worker kubelet is inactive — attempting restart..."
    systemctl start kubelet

    local retries=10
    while [[ $retries -gt 0 ]]; do
        if systemctl is-active --quiet kubelet; then
            echo "kubelet restarted successfully."
            return 0
        fi
        retries=$(( retries - 1 ))
        sleep 2
    done

    echo "ERROR: kubelet did not become active after restart." >&2
    echo "Run 'journalctl -u kubelet --no-pager -n 50' for details." >&2
    exit 1
}

# Disables swap for the current boot and comments out swap entries in /etc/fstab
function disable_swap(){
    if [[ -z "$(swapon --noheadings --show)" ]]; then
        echo "Swap already disabled."
        return 0
    fi

    echo "Disabling swap..."
    swapoff -a
    sed -i.bak '/[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab

    if [[ -n "$(swapon --noheadings --show)" ]]; then
        echo "ERROR: Failed to disable swap." >&2
        exit 1
    fi
}

# Installs OS-level prerequisites from payload/debs/tier-1
function install_os_deps(){
    if dpkg -s conntrack &>$NULL && dpkg -s socat &>$NULL; then
        echo "OS dependencies already installed."
        return 0
    fi

    echo "Installing OS dependencies (tier-1)..."
    require_debs "$PAYLOAD_DIR/debs/tier-1"
    dpkg_install_tier "$PAYLOAD_DIR/debs/tier-1"
}

# Installs containerd from payload/debs/tier-2, writes config, and verifies service
function install_containerd(){
    if command -v containerd &>$NULL && systemctl is-active --quiet containerd; then
        echo "containerd already installed and active; refreshing config."
    else
        echo "Installing containerd (tier-2)..."
        require_debs "$PAYLOAD_DIR/debs/tier-2"
        dpkg_install_tier "$PAYLOAD_DIR/debs/tier-2"
    fi

    mkdir -p /etc/containerd
    cp "$CONFIG_DIR/containerd_conf/config.toml" /etc/containerd/config.toml

    systemctl daemon-reload
    systemctl enable containerd
    systemctl restart containerd

    local retries=10
    while [[ $retries -gt 0 ]]; do
        if systemctl is-active --quiet containerd; then
            echo "containerd is active."
            return 0
        fi
        retries=$(( retries - 1 ))
        sleep 1
    done

    echo "ERROR: containerd did not start within the expected time." >&2
    journalctl -u containerd --no-pager -n 30 >&2
    exit 1
}

# Installs kubernetes-cni from payload/debs/tier-3
function install_cni(){
    if dpkg -s kubernetes-cni &>$NULL; then
        echo "kubernetes-cni already installed."
        return 0
    fi

    echo "Installing kubernetes-cni (tier-3)..."
    require_debs "$PAYLOAD_DIR/debs/tier-3"
    dpkg_install_tier "$PAYLOAD_DIR/debs/tier-3"
}

# Installs cri-tools (crictl) from payload/debs/tier-4
function install_cri_tools(){
    if command -v crictl &>$NULL; then
        echo "cri-tools already installed."
        return 0
    fi

    echo "Installing cri-tools (tier-4)..."
    require_debs "$PAYLOAD_DIR/debs/tier-4"
    dpkg_install_tier "$PAYLOAD_DIR/debs/tier-4"
}

# Installs kubelet, kubeadm, and kubectl from payload/debs/tier-5
function install_kube_binaries(){
    local installed_version
    installed_version="$(kubelet --version 2>$NULL | sed 's/Kubernetes v//' || true)"

    if [[ -n "$installed_version" ]]; then
        if [[ "$installed_version" == "$K8S_VERSION" ]]; then
            echo "kube binaries already at v$K8S_VERSION."
            return 0
        fi
        echo "ERROR: Found kube binaries at v$installed_version, expected v$K8S_VERSION." >&2
        echo "Version changes are out of scope for this installer. Manual intervention required." >&2
        exit 1
    fi

    echo "Installing kube binaries (tier-5)..."
    require_debs "$PAYLOAD_DIR/debs/tier-5"
    dpkg_install_tier "$PAYLOAD_DIR/debs/tier-5"

    apt-mark hold kubelet kubeadm kubectl
    systemctl daemon-reload
    systemctl enable kubelet
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
        echo "WARNING: iptables-legacy not found — leaving iptables backend unchanged."
        return 0
    fi

    local current
    current="$(readlink -f /etc/alternatives/iptables 2>$NULL || true)"
    if [[ "$current" == "$legacy" ]]; then
        echo "iptables already in legacy mode."
        return 0
    fi

    echo "Switching iptables to legacy mode..."
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
        exit 1
    fi

    echo "Importing $count container image(s) into k8s.io namespace..."
    while IFS= read -r tar_file; do
        echo "  -> $(basename "$tar_file")"
        ctr -n k8s.io images import "$tar_file"
    done < <(find "$image_dir" -maxdepth 1 -name '*.tar' | sort)
}

# Initialises the Kubernetes control plane via kubeadm
function init_control_plane(){
    if [[ -f /etc/kubernetes/admin.conf ]]; then
        if [[ ! -s "$JOIN_COMMAND_PATH" ]]; then
            echo "Control plane already initialised but join command is missing — regenerating..."
            wait_for_apiserver
            local join_cmd
            join_cmd="$(kubeadm token create --print-join-command)"
            echo "JOIN_COMMAND=\"$join_cmd\"" > "$JOIN_COMMAND_PATH"
            echo "Join command written to $JOIN_COMMAND_PATH"
        else
            echo "Control plane already initialised and join command exists."
        fi
        return 0
    fi

    echo "Initialising control plane..."
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

    wait_for_apiserver

    local join_cmd
    join_cmd="$(kubeadm token create --print-join-command)"
    echo "JOIN_COMMAND=\"$join_cmd\"" > "$JOIN_COMMAND_PATH"
    echo "Join command written to $JOIN_COMMAND_PATH"
}

# Deploys Calico CNI from payload/manifests/calico.yaml
function install_calico(){
    if [[ ! -e /usr/lib/cni ]]; then
        ln -s /opt/cni/bin /usr/lib/cni
    fi

    local calico_manifest="$PAYLOAD_DIR/manifests/calico.yaml"
    if [[ ! -f "$calico_manifest" ]]; then
        echo "ERROR: Calico manifest not found: $calico_manifest" >&2
        exit 1
    fi

    echo "Deploying Calico (kubectl apply is idempotent)..."
    kubectl --kubeconfig /etc/kubernetes/admin.conf \
        apply --validate=false -f "$calico_manifest"
}

# Installs helm and kustomize from payload/optional_tools if present
function install_optional_tools(){
    local tools_dir="$PAYLOAD_DIR/optional_tools"
    [[ -d "$tools_dir" ]] || return 0

    if ! command -v helm &>$NULL && [[ -f "$tools_dir/helm_bin.tar.gz" ]]; then
        echo "Installing helm..."
        tar -xzf "$tools_dir/helm_bin.tar.gz" -C "$tools_dir/"
        mv "$tools_dir/helm" /usr/local/bin/helm
    fi

    if ! command -v kustomize &>$NULL && [[ -f "$tools_dir/kustomize_bin.tar.gz" ]]; then
        echo "Installing kustomize..."
        tar -xzf "$tools_dir/kustomize_bin.tar.gz" -C "$tools_dir/"
        mv "$tools_dir/kustomize" /usr/local/bin/kustomize
    fi
}

# Sources the join command from JOIN_COMMAND_PATH and executes it
function join_worker_node(){
    if systemctl is-active --quiet kubelet && \
       [[ ! -f "$MANIFESTS_PATH/kube-apiserver.yaml" ]]; then
        echo "Worker already joined and kubelet is active."
        return 0
    fi

    if [[ ! -f "$JOIN_COMMAND_PATH" ]]; then
        echo "ERROR: Join command file not found: $JOIN_COMMAND_PATH" >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    . "$JOIN_COMMAND_PATH"

    if [[ -z "${JOIN_COMMAND:-}" ]]; then
        echo "ERROR: JOIN_COMMAND is empty in $JOIN_COMMAND_PATH" >&2
        exit 1
    fi

    echo "Joining cluster..."
    # eval is required: JOIN_COMMAND is a multi-word kubeadm command string
    eval "$JOIN_COMMAND"
}

# Asserts that a tier directory exists and contains at least one .deb file
function require_debs(){
    local dir=$1
    local count
    count=$(find "$dir" -maxdepth 1 -name '*.deb' 2>$NULL | wc -l)
    if [[ $count -eq 0 ]]; then
        echo "ERROR: No .deb files found in $dir" >&2
        exit 1
    fi
}

# Installs all .deb files in a tier directory via a single dpkg -i call
function dpkg_install_tier(){
    local dir=$1
    local -a debs
    mapfile -t debs < <(find "$dir" -maxdepth 1 -name '*.deb' | sort)
    dpkg -i "${debs[@]}"
}

# Polls the API server /healthz endpoint until it responds or times out
function wait_for_apiserver(){
    local timeout=120
    local start_time=$SECONDS

    echo "Waiting for API server to become healthy..."
    until kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /healthz &>$NULL; do
        if [[ $(( SECONDS - start_time )) -ge $timeout ]]; then
            echo "ERROR: API server did not become healthy within ${timeout}s." >&2
            kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /healthz >&2 || true
            exit 1
        fi
        sleep 2
    done
    echo "API server is healthy ($(( SECONDS - start_time ))s elapsed)."
}

main "$@"
