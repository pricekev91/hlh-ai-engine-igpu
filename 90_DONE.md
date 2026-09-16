# DONE

This is what is already implemented and verified in this repository.

## LXC Deployment

- Direct Proxmox LXC creation via `deploy-hlh-ai-engine.sh` (no OpenTofu required for initial setup) — **LXC 112** (`.12` parity with `192.168.1.12`, Proxmox requires `>=100`)
- Privileged LXC `112` with hostname `hlh-ai-engine`
- 48 GiB RAM (`49152`), 12 cores, 64 GiB rootfs on `RaidZ1-6TB` pool, `onboot 1`
- Static IP assignment: `192.168.1.12/24` gw `192.168.1.1` `vmbr0`
- Nesting and keyctl features enabled (`nesting=1,keyctl=1`)
- Prompt-before-redeploy guard prevents accidental LXC recreation
- Deploy script prints header: `ROCm version : ${ROCM_VERSION} | Backend: HIP+Vulkan dual, gfx1150` and forwards `ROCM_VERSION` into LXC via `env`

## GPU Passthrough

- AMD iGPU `/dev/dri` bind-mount for ROCm **and Vulkan** device access (`/dev/dri/card0` `226:1`, `renderD128` `226:128` — 890M `gfx1150` only; corrected from `card1`/`renderD129` in `1010f5e`)
- AMD iGPU `/dev/kfd` bind-mount for HIP/ROCm compute (`511:0` ROCm 7, `234:0` ROCm 10 — `2713d18`, both allowed for forward compat)
- cgroup2 device allow rules: `c 226:1 rwm`, `c 226:128 rwm`, `c 511:0 rwm`, `c 234:0 rwm` (RX480 `gfx803` intentionally excluded; corrected from `renderD129`/`226:129` in `1010f5e`, added `234:0` for ROCm 10 in `2713d18`)
- GPU detected as gfx1150 (Radeon 890M, RDNA 3.5 Strix Halo, `gfx1150`)
- `HSA_OVERRIDE_GFX_VERSION=11.5.0` set in systemd unit
- Single-chip repo: `AMDGPU_TARGETS=gfx1150` only

## ROCm / Runtime

- ROCm **unpinned, never pinned**: `ROCM_VERSION` env default `10.0.0` (2026-08-26 latest), `7.14.1` still supported via `ROCM_VERSION=7.14.1 ./deploy-hlh-ai-engine.sh` — deploy always prints version, forwarded into LXC. GPU PCI: `card0` (was `card1`), `renderD128` (was `renderD129`), `kfd` `511:0` (ROCm 7) + `234:0` (ROCm 10, `2713d18`)
- ROCm package names track `major.minor`: `amdrocm${ROCM_MM}-gfx1150` + `amdrocm-core-dev${ROCM_MM}-gfx1150` (`ROCM_MM=$(cut -d. -f1,2)`)
- ROCm repo keyrings and APT pinning configured (`repo.radeon.com` Pin-Priority `1001`, `rocminfo` removed)
- Vulkan deps restored: `libvulkan-dev`, `glslang-tools` (`glslc`), `spirv-tools`, `vulkan-tools` (for `GGML_VULKAN=ON`, RADV `GFX1150`)
- llama.cpp built from HEAD **dual `HIP+Vulkan`** (`GGML_HIP=ON + GGML_VULKAN=ON`, `AMDGPU_TARGETS=gfx1150`, `HIPCXX=$(hipconfig -l)/clang`); no inference perf hit vs pure HIP (disjoint `rocBLAS` vs `RADV ACO`, `+~12-18M` binary, `+4-6m` build)
- Vulkan sees full UMA `88G` (`48G VRAM + 40G GTT`) vs HIP `48G` only — dual lets small models use HIP `pp` speed, large `35B+ Q8` use `RADV_PERFTEST=nogttspill` Vulkan
- llama-server native web UI on port 80 (no nginx) `http://192.168.1.12:80` `/health` + `/v1/models`
- Model download skipped when `/srv/ai/models` mount already contains GGUF files; `DEFAULT_MODEL_URL` fixed to `bartowski/Qwen3-Coder-30B-A3B-Instruct-GGUF`
- MTP (Mixture of Parameter Transfer) auto-detect in switch-model.sh

## Model Management

- switch-model.sh v1.7.0 with MTP auto-detect, ctx-size 96K support, spec menu `MTP/ngram/none` (`/health` readiness probe `90s`)
- Model storage: host `/srv/ai/models` bind-mounted to LXC `/srv/ai/models` (same path, `775`, `RaidZ1-6TB` dataset)
- Default model pinned to `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf` (`bartowski/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/...`, fixed from `Qwen2.5` path)
- Preferred models list: Qwen3-Coder-30B, Qwen3.6-35B-A3B, Qwen3-Coder-Next (plus any existing `*.gguf` fallback)
- MTP models detected by filename (case-insensitive 'MTP' match); MoE auto `n-max 5` vs dense `3`
- Atomic ExecStart rewrite via awk (no sed fragility) — preserves `HSA_OVERRIDE_GFX_VERSION`, `ROCM_PATH`, dual backend
- Startup wait loop (`90s` `/health`) + web UI URL confirmation after model switch; also synced to `/srv/ai/models/switch-model.sh`
- `dl.sh` resumable `curl -C -` HuggingFace downloader in model dir

## Networking

- llama-server native web UI + API on port 80 inside LXC
- OpenAI-compatible API at port 80/v1/

## Ansible Configuration

- Ansible inventory: `ansible/inventories/hlh-ai-engine.yml` (`192.168.1.12` `ansible_user: root`)
- Playbook: `ansible/playbooks/hlh-ai-engine.yml` (`ansible.builtin.script` → `configure-ai-engine-inside-lxc.sh`)
- Bootstrap script: `ansible/files/configure-ai-engine-inside-lxc.sh` **(v0.9.4)** dual `HIP+Vulkan`, unpinned `ROCM_VERSION` `10.0.0` default, never pinned
- SSH key-based auth: `~/.ssh/id_ed25519`
- Reconfiguration via `configure-hlh-ai-engine.sh` with `--host` and `--offline` flags

## Speculative Decoding (MTP / standard)

- llama.cpp builds latest upstream master (pin removed 0.9.1; DFlash2 PR #27342
  still open upstream, so the DFlash2 draft requires re-pinning via
  `LLAMA_CPP_PIN` in the configure script — recipe kept in step 2 comments)
- `switch-model.sh` v1.7.0: MTP / ngram / none (standard) only; DFlash2 option
  removed (bandwidth-starved iGPU can't benefit). Readiness check probes
  `/health` (crash-loop detection)
- DFlash2 draft GGUF (`Qwen3.8-27B-DFlash2-Q4_K_M.gguf`) kept on storage for
  future use (e.g. MI50/60 with a pinned fork)
- Known limitation: Qwen3.8-27B caps at ~4.3 tok/s on this iGPU (Gated Delta Net
  fused kernels unsupported on HIP); Qwen3.6-27B+MTP is the fast config (~7.6-7.8)

## OpenTofu Provisioning

- Proxmox provider: `telmate/proxmox >= 2.7.2` (BACKLOG: migrate to `bpg/proxmox`)
- LXC resource `proxmox_lxc hlh_ai_engine` `vmid 112` `192.168.1.12/24`, `48G`/`12c`/`64G` on `RaidZ1-6TB`, `mp0 /srv/ai/models`
- Variables for API URL, token auth, network, and storage (`opentofu/variables.tf`)
- GPU passthrough (cgroup allow + mount entries) **appended by `deploy-hlh-ai-engine.sh` post-create** (not native provider passthrough — avoids exposing `gfx803`)

## Configuration Scripts

- `deploy-hlh-ai-engine.sh` - Full LXC `112` creation, GPU passthrough (`card0`+`renderD128`+`kfd`), bootstrap with `ROCM_VERSION` header + `HIP+Vulkan` `gfx1150` description
- `configure-hlh-ai-engine.sh` - Ansible-based reconfiguration with `--host` and `--offline` flags (`hlh_offline` → `HLH_OFFLINE`)

## Service Lifecycle

- Systemd auto-restart on failure (`Restart=on-failure`, `RestartSec=10`) `ai-engine.service` `WorkingDirectory=/opt/llama.cpp/build/bin` `Environment=HSA_OVERRIDE_GFX_VERSION=11.5.0`
- `switch-model.sh` probes `/health` up to `90s` (`NRestarts` + `ActiveState` crash-loop detect)
- Bootstrap verification: `rocm-smi`, `hipconfig`, `vulkaninfo --summary`, `nm ... | grep -i hip|vulkan`, `llama-server --version`, `systemctl status ai-engine` — prints `[Bootstrap complete - v0.9.4]` `ROCm ${ROCM_VERSION}` `HIP+Vulkan` (never pinned)
