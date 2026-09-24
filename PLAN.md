# FIX PLAN — hlh-ai-engine-igpu

## Status: Awaiting Approval

This plan documents every known problem in the `hlh-ai-engine-igpu` repo, the root cause, and the step-by-step fix. Do NOT start fixing until this plan is approved.

---

## 1. SUMMARY

The repo has accumulated multiple layers of drift between code, docs, and what actually runs. The last round of patches (commits `1010f5e`, `2713d18`, `43bca76`) fixed GPU PCI IDs and ROCm 10 repo dist in the **deploy script** and **LXC config** at runtime, but left stale references scattered across source files, docs, and the OpenTofu module. The bootstrap script itself has a hardcoded `ubuntu2404` repo dist that may mismatch the host's actual dist. The version header in the bootstrap is stale. The deploy script has contradictory comments. The OpenTofu module still describes old PCI IDs in comments.

Result: the deploy script *works* at runtime because the LXC config block (lines 252-274 of deploy) uses the correct IDs, but anything that reads the docs, the bootstrap script, or the OpenTofu module will be wrong.

---

## 2. INVENTORY OF ALL ISSUES

### 2.1 Stale GPU PCI IDs in Comments (NOT Runtime-Breaking, But Misleading)

**Where:**
- `ansible/files/configure-ai-engine-inside-lxc.sh` line 6: `Requirements: ... /dev/dri/card1, renderD129, /dev/kfd`
- `deploy-hlh-ai-engine-igpu.sh` line 253: `# Only the 890M iGPU (gfx1150): card1 (226:1) + renderD129 (226:129)`
- `opentofu/main.tf` line 54: `# card1 226:1, renderD129 226:129 + shared kfd (511:0)`
- `90_DONE.md` line 82: `deploy-hlh-ai-engine-igpu.sh ... GPU passthrough (card1+renderD129+kfd)`

**What it should be:** `card0`, `renderD128`, `226:128`, `226:1`

**Why it matters:** Developers reading these comments will copy wrong PCI IDs into new scripts, configs, or troubleshooting. The runtime code (deploy lines 262-274) is correct — it uses `card0`, `renderD128`, `226:128` — but the comments are wrong.

**Fix:** Update all comment references to `card0`/`renderD128`/`226:128` and add a note that earlier configs used `card1`/`renderD129` when K80 was not enumerated as card0.

### 2.2 Bootstrap Script Hardcoded `ubuntu2404` Repo Dist

**Where:**
- `ansible/files/configure-ai-engine-inside-lxc.sh` line 125: `deb ... stable.repo.amd.com/rocm/core/packages/ubuntu2404 stable main`
- `ansible/files/configure-ai-engine-inside-lxc.sh` line 137: `deb ... repo.amd.com/rocm/packages-multi-arch/ubuntu2404 stable main`

**What it should be:** Should detect the LXC's actual distro and use the matching repo dist name (e.g., `ubuntu2404` for Ubuntu 24.04, `debian13` for Debian 13).

**Why it matters:** The LXC is created from `ubuntu-24.04-standard` template (deploy line 23), so `ubuntu2404` is currently correct for the default path. However, if someone changes the LXC image to Debian (e.g., `debian-13-standard`), the ROCm 10.x install will silently fail with a 404 on the repo. This is fragile because the host (trixie) uses `debian13` (see deploy line 43bca76 fix), but the LXC is Ubuntu 24.04. The bootstrap needs to be distro-aware, not hardcoded.

**Fix:** Replace hardcoded `ubuntu2404` with a detection step:
```bash
DIST_ID="$(. /etc/os-release && echo "${ID}${VERSION_ID:0:2}")"
# ID=ubuntu VERSION_ID=24.04 → DIST_ID=ubuntu24
# ID=debian VERSION_ID=13 → DIST_ID=debian13
# Then map: ubuntu24 → ubuntu2404, debian13 → debian13
```

### 2.3 Deploy Script Contradictory Comments

**Where:**
- `deploy-hlh-ai-engine-igpu.sh` line 253: `# Only the 890M iGPU (gfx1150): card1 (226:1) + renderD129 (226:129)`
- `deploy-hlh-ai-engine-igpu.sh` line 260: `# card0 (226:0) + renderD128 (226:128) is the 890M`
- `deploy-hlh-ai-engine-igpu.sh` line 261: `# Earlier configs used card1/renderD129 when K80 was not enumerated as card0`

**The contradiction:** Line 253 says "Only the 890M iGPU ... card1 + renderD129" but the actual cgroup/mount block (lines 262-274) uses `card0` + `renderD128`. The correct IDs are in the block; the summary comment on line 253 is wrong.

**Fix:** Update line 253 to say `card0 (226:1) + renderD128 (226:128)` to match the actual block.

### 2.4 OpenTofu Module GPU Comments Stale

**Where:**
- `opentofu/main.tf` lines 50-55: Comments reference `card1 226:1, renderD129 226:129 + shared kfd (511:0)` and say deploy appends cgroup rules

**Fix:** Update comments to reference `card0`, `renderD128`, `226:128`, `234:0` for ROCm 10 forward compat.

### 2.5 90_DONE.md Stale Deploy Script Reference

**Where:**
- `90_DONE.md` line 82: `deploy-hlh-ai-engine-igpu.sh - Full LXC 112 creation, GPU passthrough (card1+renderD129+kfd)`

**Fix:** Change to `card0+renderD128+kfd`.

### 2.6 Bootstrap Version Header Stale

**Where:**
- `ansible/files/configure-ai-engine-inside-lxc.sh` line 3: `# Version: 0.9.4`
- `ansible/files/configure-ai-engine-inside-lxc.sh` line 823: `echo "[Bootstrap complete - v0.9.4]"`

**Issue:** If we're making changes in this fix round, the version should be bumped (e.g., `0.9.5`). If not, leave as-is. This should be explicitly decided during approval.

### 2.7 ROCm Package Name Inconsistency Between Deploy and Bootstrap

**Deploy script (host-side):** Uses `amdrocm${ROCM_MM_HOST}-gfx1150` + `amdrocm-core${ROCM_MM_HOST}-gfx1150` (line 178)
**Bootstrap script (LXC-side):** Uses `amdrocm${ROCM_MM}-gfx1150` + `amdrocm-core-dev${ROCM_MM}-gfx1150` (line 156-157)

Note the deploy uses `amdrocm-core` while bootstrap uses `amdrocm-core-dev`. These are different packages. The deploy host-side might fail because `amdrocm-core` (not `-dev`) may not exist or may be wrong.

**Fix:** Verify which package names actually exist on the host ROCm 10 repo and align both paths. The `-dev` suffix is the development package; the runtime package may be just `amdrocm10.0`. Need to test both.

### 2.8 ROCm Repo Dist Mismatch: Host vs LXC

**Host-side (deploy):** Line 87-97 maps host dist to repo dist: `trixie → debian13`, `24.04 → ubuntu2404`. This is correct (see commit `43bca76`).

**LXC-side (bootstrap):** Hardcoded to `ubuntu2404` regardless of what LXC image was used. This works for the default Ubuntu 24.04 LXC but would break if LXC image changes.

**Fix:** See 2.2 above — make bootstrap distro-aware.

---

## 3. ROOT CAUSE ANALYSIS

The fundamental problem is a **separation of concerns failure**:

1. **GPU PCI IDs were corrected in the deploy script** (the runtime-critical file) but the correction was never propagated to comments, docs, and the OpenTofu module. The deploy script worked because the actual cgroup/mount config block (lines 262-274) was updated in commit `1010f5e`, but the summary comment on line 253 was not.

2. **ROCm repo dist was fixed for the host** (deploy script) in commit `43bca76` but the bootstrap script's hardcoded `ubuntu2404` was not made distro-aware.

3. **Version numbers drifted**: The bootstrap says `v0.9.4` but multiple fixes have landed since the last documented version bump.

4. **Package names diverged** between the host-side deploy (amdrocm-core) and LXC-side bootstrap (amdrocm-core-dev), creating ambiguity about which packages are correct.

---

## 4. FIX PLAN

### Phase 1: Comment & Documentation Cleanup (Safe, No Runtime Impact)

**Step 1.1: Fix all stale GPU PCI ID references in comments**

Files to touch (6 locations):
- `deploy-hlh-ai-engine-igpu.sh` line 253: Change summary comment from `card1/renderD129` to `card0/renderD128`
- `ansible/files/configure-ai-engine-inside-lxc.sh` line 6: Change Requirements comment from `card1, renderD129` to `card0, renderD128`
- `opentofu/main.tf` lines 50-55: Update GPU comments from `card1/renderD129/511:0` to `card0/renderD128/511:0+234:0`
- `90_DONE.md` line 82: Change deploy description from `card1+renderD129` to `card0+renderD128`

**Step 1.2: Add GPU PCI ID history note to deploy script**

After line 261, add a clarifying note:
```
# NOTE: On hosts where K80 is card0 (old), 890M was card1/renderD129.
# On current hosts (trixie, 7.0.14-11-pve), 890M is card0/renderD128.
# This script uses card0/renderD128 for the 890M. If your host has
# 890M at a different index, verify with: lspci | grep -i vga
```

### Phase 2: Bootstrap Script Fixes (Runtime-Impacting)

**Step 2.1: Make ROCm repo dist detection dynamic**

Replace hardcoded `ubuntu2404` in `configure-ai-engine-inside-lxc.sh` lines 125 and 137 with distro detection:
```bash
# Detect LXC distro for ROCm repo dist name mapping
if [ -f /etc/os-release ]; then
  . /etc/os-release
  case "$ID" in
    ubuntu)  ROCM_REPO_DIST="ubuntu2404" ;;
    debian)  ROCM_REPO_DIST="debian13" ;;
    *)       echo "WARNING: Unknown distro $ID, defaulting to ubuntu2404" && ROCM_REPO_DIST="ubuntu2404" ;;
  esac
else
  echo "ERROR: /etc/os-release not found — cannot determine ROCm repo dist"
  exit 1
fi
```

Then replace both hardcoded `ubuntu2404` references with `${ROCM_REPO_DIST}`.

**Step 2.2: Bump bootstrap version**

Change line 3 from `Version: 0.9.4` to `Version: 0.9.5` (or whatever version makes sense).
Change line 823 from `[Bootstrap complete - v0.9.4]` to `[Bootstrap complete - v0.9.5]`.
Add a changelog entry in the header comments.

### Phase 3: Package Name Alignment (Testing Required)

**Step 3.1: Verify ROCm package names**

Run this on the host to check actual package names:
```bash
# On host with ROCm 10 installed:
apt-cache search "^amdrocm10" | head -20
# Check if amdrocm-core or amdrocm-core-dev exists
apt-cache show amdrocm-core 2>/dev/null || echo "amdrocm-core NOT FOUND"
apt-cache show amdrocm-core-dev 2>/dev/null || echo "amdrocm-core-dev NOT FOUND"
```

**Step 3.2: Align deploy and bootstrap**

Once we know the correct package names, update both:
- `deploy-hlh-ai-engine-igpu.sh` line 178 (host-side install)
- `ansible/files/configure-ai-engine-inside-lxc.sh` lines 156-157 (LXC-side install)

Both should use the same package naming convention. If `amdrocm10.0` (no suffix) is the correct runtime package, use that in both places.

### Phase 4: Verification & Testing

**Step 4.1: Dry-run the deploy script**

```bash
ROCM_VERSION=10.0.0 ./deploy-hlh-ai-engine-igpu.sh --help  # Just verify syntax
```

**Step 4.2: Verify cgroup rules in deploy output**

After running deploy, check `/etc/pve/lxc/112.conf`:
```bash
grep -E "cgroup2|mount.entry" /etc/pve/lxc/112.conf
# Should show:
# lxc.cgroup2.devices.allow: c 226:1 rwm
# lxc.cgroup2.devices.allow: c 226:128 rwm
# lxc.cgroup2.devices.allow: c 511:0 rwm
# lxc.cgroup2.devices.allow: c 234:0 rwm
# lxc.mount.entry: /dev/dri/card0 ...
# lxc.mount.entry: /dev/dri/renderD128 ...
```

**Step 4.3: Verify ROCm repo in LXC**

After LXC creation, check:
```bash
cat /etc/apt/sources.list.d/rocm.list
# Should show ubuntu2404 (or debian13) dynamically
cat /etc/apt/preferences.d/rocm-pin
```

**Step 4.4: Verify llama.cpp build**

```bash
# Inside LXC:
cd /opt/llama.cpp/build
grep -i 'ggml_hip\|ggml_vulkan' CMakeCache.txt
nm bin/llama-server | grep -i -E 'hip|vulkan' | head -5
```

---

## 5. WHAT IS CURRENTLY CORRECT (NOT BROKEN)

These items are working and do NOT need changes:
- Deploy script LXC config block (lines 257-275): Uses correct `card0`, `renderD128`, `226:128`, `511:0`, `234:0`
- ROCm 10.0.0 default version (deploy line 34, bootstrap line 73)
- Dual HIP+Vulkan build flags (both scripts)
- Model storage mount (mp0)
- OpenTofu module structure (vmid, network, storage)
- switch-model.sh v1.7.0
- deploy-hlh-ai-engine-igpu.sh version printing (header + footer)
- ROCm 10.x repo detection on host (deploy lines 142-163)
- Host repo dist detection (deploy lines 87-97)

---

## 6. RISK ASSESSMENT

| Step | Risk | Mitigation |
|------|------|------------|
| 1.1-1.2 | None (comments only) | N/A |
| 2.1 | Low — ROCm repo dist detection | Fallback to ubuntu2404; tested on Ubuntu 24.04 LXC |
| 2.2 | None (version bump only) | N/A |
| 3.1-3.2 | Medium — package name mismatch could break ROCm install | Verify on host first; keep fallback logic |
| 4.x | None — verification steps only | N/A |

---

## 7. APPROVAL CHECKLIST

- [ ] Plan reviewed and approved
- [ ] Phase 1 comments fixed (1.1-1.2)
- [ ] Phase 2 bootstrap dist detection implemented (2.1)
- [ ] Phase 2 version bumped (2.2)
- [ ] Phase 3 package names verified and aligned (3.1-3.2)
- [ ] Phase 4 verification steps passed
- [ ] All changes committed and pushed
- [ ] README/ACTIVE/DONE updated to reflect fixes

---

## 8. TIMELINE

- Phase 1: ~10 min (comment edits only)
- Phase 2: ~20 min (edit + review)
- Phase 3: ~30 min (requires host access for apt-cache verify)
- Phase 4: ~15 min (verification)
- Total estimated: ~75 min from approval to deploy-ready

---

**Last updated:** 2026-09-15
**Author:** hlh-ai-engine-igpu session
**Pending:** Awaiting user approval to begin Phase 1
