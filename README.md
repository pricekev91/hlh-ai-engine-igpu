# hlh-ai-engine-igpu

Infrastructure-as-Code for the HLH shared AI inference engine. Deploys a GPU-accelerated
llama.cpp runtime as a Proxmox LXC container with ROCm + Vulkan dual backend.

## Executive Summary

This repository deploys and configures the **engine** LXC on the HLH Proxmox host. The
engine is a shared AI inference service consumed by all application repos (TrashPanda,
BrickCipher, VoxChimera).

- LXC 112, hostname `hlh-ai-engine-igpu`, IP `192.168.1.12` (gateway `192.168.1.1`)
- ROCm `10.0.0` default (2026-08-26 latest; unpinned — override: `ROCM_VERSION=7.14.1 ./deploy-hlh-ai-engine-igpu.sh`) with AMD RDNA 3.5 890M iGPU (gfx1150, Strix Halo) — deploy always prints version, never pinned
- llama.cpp **dual backend** `HIP+Vulkan` (`GGML_HIP=ON + GGML_VULKAN=ON`, `AMDGPU_TARGETS=gfx1150`, `HSA_OVERRIDE_GFX_VERSION=11.5.0`) — HIP is ROCm; Vulkan is RADV; no inference perf hit vs pure HIP
- llama.cpp backend serving native web UI on port `80` (`/health` + `/v1` OpenAI API)
- Model storage on `RaidZ1-6TB` ZFS pool (`/srv/ai/models` host → `/srv/ai/models` LXC bind mount, same path)

## Repository Boundary

**Owns:**
- LXC lifecycle (create, configure, start) on Proxmox (`112` privileged `nesting,keyctl`, `48G RAM`, `12 cores`, `64G rootfs` on `RaidZ1-6TB`)
- GPU passthrough configuration for ROCm **and** Vulkan (`/dev/dri/card0` `226:1`, `renderD128` `226:128`, `/dev/kfd` `511:0` (ROCm 7) + `234:0` (ROCm 10) — 890M `gfx1150` only; corrected from `card1`/`renderD129` in `1010f5e`)
- Model storage mount wiring (`--mp0 /srv/ai/models,mp=/srv/ai/models` `775`)
- In-container ROCm (`amdrocm${ROCM_MM}-gfx1150`) + Vulkan (`libvulkan-dev`, `glslang-tools` `glslc`) and llama.cpp dual `HIP+Vulkan` installation

**Does not own:**
- Proxmox host configuration (that is `iac-hlh`)
- Application logic or dashboard code (that is `TrashPanda`, `BrickCipher`, etc.)
- AI VM ROCm migration (planned as separate path in `iac-hlh`)

## Quick Start

Deploy the AI engine LXC on the Proxmox host (upgrades host ROCm if needed, then LXC — always prints version, never pinned):

```bash
./deploy-hlh-ai-engine-igpu.sh              # default 10.0.0 (latest 2026-08-26) — prompts to upgrade host 7.14→10.0 if needed
# Override ROCm version (never pinned):
ROCM_VERSION=7.14.1 ./deploy-hlh-ai-engine-igpu.sh   # stay on older stable to match host without upgrade
# Bootstrap also respects: ROCM_VERSION=10.0.0 ./configure-hlh-ai-engine-igpu.sh --bootstrap-inside
# Host must match LXC major (7.x vs 10.x): deploy now checks host $(get_host_rocm_version) and prompts to upgrade host via stable.repo.amd.com
```

Reconfigure an existing LXC via bash (no recreate, no ansible):

```bash
./configure-hlh-ai-engine-igpu.sh
./configure-hlh-ai-engine-igpu.sh --host 192.168.1.12
./configure-hlh-ai-engine-igpu.sh --via-ssh --host 192.168.1.12
```

Switch loaded models (inside LXC after deployment):

```bash
switch-model.sh          # interactive: model, ctx-size 8K-96K, KV q4_0/q6_0/q8_0, spec MTP/ngram/none
# Vulkan large-model tip:
RADV_PERFTEST=nogttspill llama-bench -m /srv/ai/models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf -ngl 48 -dev Vulkan0,ROCm0
```

## Deployment Model

Two bash scripts only (no ansible/opentofu):

1. **Provisioning**: `deploy-hlh-ai-engine-igpu.sh` creates privileged LXC `112`, wires GPU passthrough
   (`card0`+`renderD128`+`kfd` only — `226:1`, `226:128`, `511:0`+`234:0`; RX480 `gfx803` excluded), prints `ROCm ${ROCM_VERSION}` + `HIP+Vulkan gfx1150`,
   and pushes itself-embedded bootstrap via `pct push` (`env ROCM_VERSION=...` forwarded).
2. **Configuration**: `configure-hlh-ai-engine-igpu.sh` - when run on host it pushes itself into the LXC via `pct exec`/`ssh` and re-runs with `--bootstrap-inside`; that flag runs the embedded bootstrap (ROCm + Vulkan + llama.cpp `HIP+Vulkan` `gfx1150`). No separate inside file.

## Repository Layout

```
hlh-ai-engine-igpu/
├── deploy-hlh-ai-engine-igpu.sh    # Provision: LXC creation + GPU passthrough + bootstrap (bash)
├── configure-hlh-ai-engine-igpu.sh # Configuration: host wrapper + embedded bootstrap --bootstrap-inside (bash only)
├── 00_BACKLOG.md
├── 10_ACTIVE.md
├── 90_DONE.md
├── CHANGELOG.md
└── README.md
```

## Runtime Contract

| Item | Value |
|------|-------|
| API endpoint | `http://192.168.1.12:80` |
| OpenAI-compatible base | `http://192.168.1.12:80/v1/` |
| Model storage | `/srv/ai/models` (host mount) |
| GPU device | `/dev/dri` + `/dev/kfd` bind-mount |
| Default model | Qwen3.6-35B-A3B-MTP-Q4_K_M.gguf (96K ctx, KV q4_0, MTP draft n-max 5) |

## GPU Backend Notes

**Dual HIP+Vulkan — single chip `gfx1150` (890M Strix Halo), no perf hit.** HIP *is* ROCm (`GGML_HIP` = ROCm path); Vulkan is Mesa RADV. Earlier single-ROCm builds disabled Vulkan for missing `SPIRV-Headers` — now resolved (`libvulkan-dev`, `glslang-tools` `glslc`, `spirv-tools`).

- ROCm `10.0.0` default (unpinned, latest 2026-08-26; never pinned). `7.14.x` + `10.0.x` both support `gfx1150` natively via `rocBLAS`; deploy always prints version. Package names track `major.minor`: `amdrocm10.0-gfx1150` for `10.0.0`, `amdrocm7.14-gfx1150` for `7.14.1` (`ROCM_MM=$(cut -d. -f1,2)` in bootstrap). GPU PCI IDs: `card0` (was `card1`), `renderD128` (was `renderD129`), kfd `511:0` (ROCm 7) + `234:0` (ROCm 10).
- `HSA_OVERRIDE_GFX_VERSION=11.5.0` set in `ai-engine.service` via embedded bootstrap in `configure-hlh-ai-engine-igpu.sh` — rocBLAS native `gfx1150`.
- `AMDGPU_TARGETS=gfx1150` at build time (chip-locked repo; not multi-target).
- `GGML_HIP=ON + GGML_VULKAN=ON` — same binaries, runtime pick `-dev ROCm0|Vulkan0`. Pure HIP vs dual has **no inference perf delta** (HIP uses `rocBLAS`, Vulkan uses `RADV ACO`; disjoint codegen, idle backend not dispatched). Binary `+~12-18M`, build `+4-6m` only.
- Vulkan sees full UMA `48G VRAM + 40G GTT = 88G` vs HIP `48G` only. For `≤30B Q4` (e.g. `Qwen3-Coder-30B` `~21G`) HIP `pp` faster (`~332` vs `267` `7B pp512` on `890M`); for `35B+ Q8` or large `96K` `q8_0` `~24G` KV, Vulkan `RADV_PERFTEST=nogttspill` wins (`~370` vs `150 pp` on `96G` box) — dual lets `switch-model.sh` stay HIP default with Vulkan fallback.

## llama.cpp Tuning Reference

Default llama-server flags (from systemd unit):

| Flag | Default | Description |
|------|---------|-------------|
| `--model` | mounted GGUF path | Model file |
| `--host` | `0.0.0.0` | Listen on all interfaces |
| `--port` | `80` | Native web UI + API port |
| `--ctx-size` | `98304` (96K) | Context window (switch via `switch-model.sh`) |
| `-ngl` | `48` | GPU offload layers |
| `--batch-size` | `128` | Batch size for inference |
| `--parallel` | `1` | Request parallelism |
| `--cache-type-k` | `q4_0` | KV key cache quantization |
| `--cache-type-v` | `q4_0` | KV value cache quantization |
| `--spec-type` | `draft-mtp` | MTP speculative decoding (auto-detected for MTP models) |
| `--spec-draft-n-max` | `5` | MTP draft tokens (MoE auto) |

Context size options (via `switch-model.sh`):

| Option | ctx-size | Description |
|--------|----------|-------------|
| 1 | 98304 (96K) | Maximum long-context |
| 2 | 73728 (72K) | Extended long-context |
| 3 | 65536 (64K) | Full long-context |
| 4 | 32768 (32K) | Half, saves ~50% KV VRAM |
| 5 | 16384 (16K) | Quarter, minimal KV usage |
| 6 | 8192 (8K) | Minimal, maximum VRAM headroom |

KV cache VRAM estimates:

| Context | q4_0 | q6_0 | q8_0 |
|---------|------|------|------|
| 96K | ~12 GB | ~18 GB | ~24 GB |
| 72K | ~9 GB | ~14 GB | ~18 GB |
| 64K | ~8 GB | ~12 GB | ~18 GB |
| 32K | ~4 GB | ~6 GB | ~9 GB |
| 16K | ~2 GB | ~3 GB | ~5 GB |
| 8K | ~1 GB | ~2 GB | ~3 GB |

## Health Checks & Service Lifecycle

| Check | Command |
|-------|---------|
| Service status | `systemctl status ai-engine` |
| Live health | `curl -s http://localhost:80/health` |
| Model info | `curl -s http://localhost:80/v1/models` |
| GPU HIP | `rocm-smi && hipconfig --version` |
| GPU Vulkan | `vulkaninfo --summary` && `RADV_PERFTEST=nogttspill llama-bench -dev Vulkan0` |
| Both backends | `nm /opt/llama.cpp/build/bin/llama-server \| grep -i -E 'hip|vulkan'` |
| Logs | `journalctl -u ai-engine -f` |
| Deployed version | `grep ROCM_VERSION /root/ai-engine-bootstrap/configure-ai-engine-inside-lxc.sh` ; `ROCM_VERSION=... ./deploy-hlh-ai-engine-igpu.sh` prints header |

`switch-model.sh` probes `http://127.0.0.1:80/health` for up to 90s after restart (real readiness, not `systemctl is-active` crash-loop green). Deploy prints `ROCm version : ${ROCM_VERSION} | Backend: HIP+Vulkan dual, gfx1150` on `[6/6]`.

## Governance

This repo is a submodule of `iac-hlh`. Deployments consume pinned commits for
deterministic results. See the HLH Agile Design Handbook for the full architecture
and dependency map.
