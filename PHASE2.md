# Phase 2 Plan — Makeself Installer Packaging & Deployment

**Status:** Planned — not yet started  
**Branch:** create from `main` when starting  
**Prerequisite:** Phase 1A merged to main ✅

---

## Overview

Phase 2 collapses the deploy artifact into a single self-extracting `.run` file produced by makeself.
Today Ansible ships three things to each node (`payload/`, `configs/`, `install.sh`) over four copy
tasks then runs the installer. Phase 2 ships one file and runs it — making the installer
redistributable outside Ansible (USB, scp, HTTP) and reducing the Ansible layer to its bare minimum.

---

## Goals

- Produce a single `k8s-installer-<k8s>-<calico>.run` artifact containing payload + configs + installer
- Argument passthrough works end-to-end: `sudo ./k8s-installer.run -- --role control_plane --master <ip>` reaches `install.sh` unchanged
- Ansible reduced to: copy one file → execute → fetch join command (control plane) / copy join command → execute (worker)
- One documented runbook: `prepare-assets.sh` → `makeself.sh` → `ansible-playbook`
- Fresh 2-node Vagrant cluster from zero with no manual steps beyond those three commands

---

## Out of Scope for Phase 2

- Jenkins / GitHub Actions CI to build the `.run` automatically
- Multi-version support (K8S_VERSION / CALICO_VERSION stay pinned)
- Signing / checksums for the `.run` file
- Containerised build (running makeself inside Docker)
- Uninstall / reset path inside the `.run`
- Replacing Ansible entirely with `.run`-over-ssh
- Any behaviour changes to `automation-scripts/install.sh`
- HA control plane (multiple control-plane nodes)

---

## Open Questions — Resolve Before Starting Implementation

**Q1 — Version sourcing for the `.run` filename.**
Should `makeself.sh` read `K8S_VERSION`/`CALICO_VERSION` by grepping `install.sh` and
`prepare-assets.sh` (single source of truth, no flags), or accept `--k8s-version`/`--calico-version`
CLI flags (explicit but duplicates state)?
_Recommendation: grep-from-source for consistency with Phase 1A pinning._

**Q2 — Compression inside the `.run`.**
Makeself defaults to gzip. Image tarballs compress poorly (already binary). Options:
- `gzip` — default, simple
- `zstd` — smaller/faster, needs `--complevel` flag
- `none` — skip outer compression since payload is already dense `.tar` files

**Q3 — Extraction location on target VM.**
Makeself default is `/tmp/selfgz<pid>/` which is tmpfs-backed and can be too small for
a 2–3 GB payload. Options:
- Keep default `/tmp/` (risky for large payloads)
- `--target /var/tmp/k8s-installer --keep` (predictable, survives debugging) ← recommendation

**Q4 — Ansible `creates:` guard.**
Should the `command:` task that runs the `.run` include `creates: /etc/kubernetes/admin.conf`
(control plane) / `creates: /var/lib/kubelet/config.yaml` (worker) so re-runs skip extraction?
Pro: faster re-runs. Con: hides the idempotent path.
_Recommendation: no guard — `install.sh` already self-skips, keep it simple._

**Q5 — `dist/` artifact distribution.**
Keep `dist/*.run` git-ignored and local-only (built per developer), or publish the `.run` to
GitHub Releases as a release asset (extends the Phase 1A pattern)?

**Q6 — `startup.sh` location.**
Live alongside `install.sh` in `automation-scripts/` (keeps it next to what it wraps), or
in `build-script/` (signals it is packaging-only)?
_Mild recommendation: `automation-scripts/`._

---

## Deliverables

### D1 — Rewritten `build-script/makeself.sh`

Builds a staged tree, runs makeself against it, outputs the `.run` plus a `latest` symlink.

**Files changed:** `build-script/makeself.sh`, `.gitignore`

**Inputs:** populated `payload/`, `configs/`, present `automation-scripts/install.sh` and
`automation-scripts/startup.sh`, `makeself` on PATH.

**Outputs:** `dist/k8s-installer-<k8s>-<calico>.run` + `dist/k8s-installer-latest.run` symlink.

**Staging tree layout (inside `build-script/.stage/`):**
```
.stage/
  install.sh        ← symlinked or copied from automation-scripts/
  startup.sh        ← symlinked or copied from automation-scripts/
  payload/          ← copied from repo root payload/
  configs/          ← copied from repo root configs/
```
This preserves the `SCRIPT_DIR`-relative `PAYLOAD_DIR`/`CONFIG_DIR` resolution in `install.sh`
(lines 23–26) — no env-var injection needed.

**Tasks:**
- T1.1 — Rewrite `makeself.sh`: build staging tree, run makeself, update `latest` symlink, trap-cleanup staging on exit
- T1.2 — Add preflights: `payload/` non-empty, `configs/` non-empty, `install.sh` executable, `makeself` on PATH, `startup.sh` present — exit 1 with clear message on failure
- T1.3 — Add `dist/` and `build-script/.stage/` to `.gitignore`
- T1.4 — ShellCheck the rewritten script

**Acceptance criteria:**
- `bash build-script/makeself.sh` exits 0 and produces `dist/k8s-installer-<k8s>-<calico>.run`
- `dist/k8s-installer-latest.run --info` shows makeself archive metadata
- Running with empty `payload/` exits non-zero with a clear error message

---

### D2 — New `automation-scripts/startup.sh`

Thin wrapper that makeself calls as its startup script. Sanity-checks the extraction, then
forwards all args to `bash ./install.sh`.

**Why a wrapper instead of pointing makeself at `install.sh` directly:**
1. Validates the extracted tree before running (surfaces corrupted `.run` builds cleanly)
2. Lets us add pre-install side effects later without touching `install.sh`
3. Keeps `install.sh` runnable standalone outside the `.run` for development

**Tasks:**
- T2.1 — Create `automation-scripts/startup.sh`: safe header, sanity checks (`install.sh` present and executable, `payload/` exists, `configs/` exists), forward `"$@"` to `bash ./install.sh`
- T2.2 — ShellCheck

**Acceptance criteria:**
- `sudo ./k8s-installer-latest.run -- --role control_plane --master <ip>` runs `install.sh` with those exact args
- `sudo ./k8s-installer-latest.run -- --help` shows `install.sh`'s help text
- `sudo ./k8s-installer-latest.run -- --debug` propagates `set -x` output
- `sudo ./k8s-installer-latest.run -- --role worker` works end-to-end on a worker VM

---

### D3 — Ansible role simplification

Replace the four-copy + shell-exec pattern with assert → copy-one-file → exec → fetch/copy join command.

**Files changed:**
- `cd/roles/control_plane/tasks/main.yaml`
- `cd/roles/worker/tasks/main.yaml`

**`cd/playbooks/main.yaml` — no changes.**

**New control_plane task flow (≤ 4 tasks):**
1. `stat` + `assert` that `dist/k8s-installer-latest.run` exists on the Ansible controller
2. `copy` it to `/tmp/k8s-installer.run` on the node, mode `0755`
3. `command: /tmp/k8s-installer.run -- --role control_plane --master {{ ansible_host }}`
4. `fetch` `/tmp/join_command.txt` back to the Ansible controller

**New worker task flow (≤ 4 tasks):**
1. `stat` + `assert` that `dist/k8s-installer-latest.run` exists on the Ansible controller
2. `copy` it to `/tmp/k8s-installer.run` on the node, mode `0755`
3. `copy` `/tmp/join_command.txt` from controller to worker
4. `command: /tmp/k8s-installer.run -- --role worker`

**Tasks:**
- T3.1 — Rewrite `cd/roles/control_plane/tasks/main.yaml`
- T3.2 — Rewrite `cd/roles/worker/tasks/main.yaml`
- T3.3 — Delete unused payload/configs/install.sh copy tasks from both roles
- T3.4 — Update inline comment headers in both role files

**Acceptance criteria:**
- `ansible-playbook cd/playbooks/main.yaml` from a clean Vagrant `up` produces a Ready cluster
- Re-running the playbook on a converged cluster exits 0 with no errors (idempotence)
- Both role files are ≤ 4 tasks each

---

### D4 — Runbook in README

New `## Build & Deploy` section documenting the three-step workflow with exact commands
and standalone `.run` usage (without Ansible).

**Tasks:**
- T4.1 — Add `## Build & Deploy` section to `README.md` with the three commands + expected output
- T4.2 — Add `makeself` to the prerequisites list in `README.md`
- T4.3 — Document standalone `.run` usage (scp + run without Ansible)
- T4.4 — Add one-line pointer in `FLOW.md` to the new README section

**Acceptance criteria:**
- A reader following the README from scratch reaches a Ready cluster without consulting any other doc
- The section states what each command produces and where it lives on disk

---

### D5 — Manual test pass on Vagrant

**6 test scenarios:**

| # | Scenario | Expected result |
|---|---|---|
| 1 | Cold path: `vagrant destroy -f && vagrant up` → all three commands | Both nodes Ready, all pods running |
| 2 | Re-run idempotence: run `ansible-playbook` a second time | Exits 0, cluster undisturbed |
| 3 | Standalone `.run`: scp file manually, invoke with right args | Cluster comes up without Ansible |
| 4 | Wrong role flag: `--role nonsense` | Exits non-zero with install.sh's role-validation message |
| 5 | Missing payload at build time: `rm -rf payload && makeself.sh` | Fails fast with clear preflight error |
| 6 | Worker run before join command exists | Fails with existing JOIN_COMMAND error path |

---

## Workflow After Phase 2

```
[internet machine]
1. bash automation-scripts/prepare-assets.sh
   → populates payload/ from GitHub Release k8s-1.30.14-calico-3.28.5

2. bash build-script/makeself.sh
   → produces dist/k8s-installer-latest.run  (~2-3 GB self-extracting archive)

[deploy]
3. cd cd && ansible-playbook playbooks/main.yaml
   → copies dist/k8s-installer-latest.run to each VM
   → runs it with --role control_plane / --role worker
   → cluster is up
```

## What Stays the Same from Phase 1A

- `automation-scripts/install.sh` — unchanged
- `automation-scripts/prepare-assets.sh` — unchanged
- `payload/` and `configs/` directory layouts — unchanged
- `cd/inventory/hosts.ini` and `cd/ansible.cfg` — unchanged
- `cd/playbooks/main.yaml` — unchanged
- Control-plane → join-command → worker handoff pattern — unchanged
- `K8S_VERSION=1.30.14` and `CALICO_VERSION=3.28.5` pinning — unchanged
- Ubuntu 24.04 / Vagrant libvirt target — unchanged
