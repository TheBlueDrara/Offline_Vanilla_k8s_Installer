# Overview

Here you will find ideas on modification and project upgrades in the feature.

## Ideas

instead of splitting the binaries and commiting them to the repositroy

create deb packages and the docker images upload to the GitHub Assets that can be up to 2GB

the user clones the project, spins up the CI env, it creates a new Make Self installer version by pulling with curl the needed assets from the project ( a must requirement is internet connection) than the CD env that is also span up, deploys the new installer on the new Vagrant VMs, so it will create the Vanilla k8s cluster.


## CI

The CI should include linting of the bash script, and spell check.
in the end it will create a new Make Self installer.

The idea is to make the make self installer moduler so the user can use different versions of k8s. so he can make custom k8s robust installer that can handle different versions for upgrading the workers 

the Make self logic should handle version control by the version jumps k8s must have

## CD 

Should run the new installer that was made from the CI, and deploy it on the Dev Env VMs to try to upgrade a version or implement a new feature

## General

Make everything in a conatiner, make the user clone the project, and when he runs the starter script, it will pull custom made docker images by me that will have everything needed to pull the assetss, package the makeself package and output into an output in the root directory, than another image will run an ansible server that will deploy the makeself installer




###
Read docs/PROJECT_CONTEXT.md first, then explore the repo to understand 
the current state — especially:
- automation-scripts/install.sh (the makeself startup script with role 
  detection)
- build-script/ (current makeself build logic)
- binaries/ (current asset layout being replaced)
- ansible/ playbooks (existing CD logic)
- ci/Jenkinsfile if present

After reading, summarize back in 5 bullets:
1. What install.sh does today and how role detection works
2. The current asset layout and how install.sh consumes it
3. What Ansible currently does to deploy and orchestrate
4. Hardcoded values you spotted (user names, IPs, versions, paths)
5. Bugs or code smells you noticed

Don't propose changes or write code yet. I want to confirm you 
understand the current state.

---

CONTEXT FOR THE WORK AHEAD:

We previously drafted a full Phase 1 plan that covered the new installer 
PLUS Jenkins CI pipelines PLUS GitHub Releases asset publishing all at 
once. That scope is too big for a single step. I'm breaking it into 
sub-phases.

PHASE 1A (what we're doing now):
Get a working new installer in my hands, hand-tested on Vagrant VMs via 
Ansible. No Jenkins, no GitHub Releases yet.

Deliverables for Phase 1A:

1. prepare-assets.sh
   - Runs on a machine with internet (my laptop or a build VM)
   - Downloads full .deb transitive closure for k8s components, 
     containerd, CNI, cri-tools, and OS deps (conntrack, socat, 
     ebtables, iptables, etc.)
   - Output organized into tiered directories:
       payload/debs/tier-1/  (OS deps)
       payload/debs/tier-2/  (containerd.io + deps)
       payload/debs/tier-3/  (kubernetes-cni)
       payload/debs/tier-4/  (cri-tools)
       payload/debs/tier-5/  (kubelet, kubeadm, kubectl)
   - Pulls each container image and saves as individual .tar (no splits):
       payload/images/kube-apiserver.tar
       payload/images/etcd.tar
       payload/images/coredns.tar
       payload/images/pause.tar
       payload/images/kube-proxy.tar
       payload/images/kube-controller-manager.tar
       payload/images/kube-scheduler.tar
       payload/images/calico-node.tar
       payload/images/calico-cni.tar
       payload/images/calico-kube-controllers.tar
   - Inputs: K8S_VERSION and CALICO_VERSION (env vars or CLI args)
   - NO gh CLI, NO GitHub Release upload, NO version tags. Local output 
     only.

2. Rewritten install.sh
   - SAME role-detection logic as today. Control plane creates cluster 
     and saves join command; worker reads join command and joins; 
     re-running on a node with k8s already installed is an idempotent 
     no-op (NOT a version-bump upgrade — that's out of scope).
   - SAME CLI interface (--role, --master). Ansible playbook stays 
     untouched.
   - WHAT CHANGES: how dependencies get onto the node.
       OLD: extract binaries from the makeself archive, cat split image 
            parts back together, manually install
       NEW: dpkg -i tier-1/*.deb through tier-5/*.deb in explicit order, 
            then apt-mark hold; ctr -n k8s.io images import for every 
            .tar in payload/images/ (note the k8s.io namespace — kubelet 
            won't see images in the default namespace)
   - Idempotent: each step detects already-done state and skips. 
     Detection patterns: dpkg -l for packages, ctr -n k8s.io images ls 
     for images, systemctl is-active for services, kubeadm/kubectl 
     state checks for cluster membership.
   - Bugs to fix in the same pass:
       a. Shebang on line 1, before set -x
       b. OS check: Ubuntu-aware, not $ID == "debian"
       c. Arg parser needs *) shift ;; catch-all to prevent infinite loop
       d. ROLE validated against allowed values; unrecognized exits 1 
          with clear message
       e. install_iptables else-branch logic (spurious error on happy 
          path)
       f. REAL_USER from SUDO_USER or CLI param, not hardcoded "vagrant"
       g. --kubernetes-version, --pod-network-cidr, --cri-socket sourced 
          from variables at top of script
   - Wrap set -x behind a --debug flag, not always-on.

3. Deployment via Ansible (no makeself for now)
   - Skip makeself entirely in Phase 1A — faster iteration.
   - Ansible scp's the payload/ directory + install.sh to each Vagrant 
     VM, then runs install.sh directly with sudo.
   - Existing playbook structure stays: control_plane role runs first, 
     fetches the join command back to the Ansible host, worker role 
     copies the join command and runs install.sh on workers.
   - Adjust tasks as needed for the new payload layout, but don't 
     restructure the playbook.

OUT OF SCOPE for Phase 1A (do NOT build any of this yet):
- Jenkinsfile or Jenkinsfile-assets
- gh CLI usage
- GitHub Releases upload
- publish-release.sh
- A full build-installer.sh that fetches from GH Releases
- Multi-version support
- Any modularity refactor beyond what's needed for Phase 1A

WORKFLOW I'M EXPECTING:

Step 1: You read the repo and summarize current state (above).
Step 2: I confirm or correct your understanding.
Step 3: You produce a Phase 1A scripting plan: list of files to create or 
        modify, what each does, in what order they'll be invoked, plus a 
        manual test plan ("given a fresh Vagrant VM, here are the commands 
        I run to validate end-to-end").
Step 4: I review the plan and approve or push back.
Step 5: You write install.sh first (highest-risk piece, independently 
        testable with a manually-assembled payload/ directory).
Step 6: I test install.sh on Vagrant VMs by hand, report bugs, iterate.
Step 7: Once install.sh is solid, you write prepare-assets.sh.
Step 8: Update Ansible tasks for the new payload layout.
Step 9: Full end-to-end test: fresh Vagrant VMs, run prepare-assets.sh, 
        run ansible-playbook, end up with a working cluster.

Start with Step 1. Read and summarize. No code yet.