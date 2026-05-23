#!/usr/bin/env bash
##################### Start Safe Header ########################
# Developed by Alex Umansky aka TheBlueDrara
# Purpose Wrap the project to a makeself installer
# Date 04.07.2025
# Version 1.0.0
set -o errexit
set -o nounset
set -o pipefail
#################### End Safe Header ###########################


function main() {
    [[ -d ../payload && -n "$(ls -A ../payload 2>/dev/null)" ]] \
        || { echo "ERROR: payload/ is empty — run prepare-assets.sh first." >&2; exit 1; }

    makeself ../ ../k8s_installer.run "K8s_Offline Installer" bash automation-scripts/install.sh
}

main
