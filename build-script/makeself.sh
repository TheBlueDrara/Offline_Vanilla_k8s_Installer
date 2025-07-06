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

makeself ../ ../k8s_installer.run "K8s_Offline Installer" bash automation-scripts/install.sh
}

main
