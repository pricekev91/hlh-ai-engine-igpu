# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **switch-model.sh extracted from configure heredoc into a standalone repo file** (single source of truth). `configure-hlh-ai-engine-igpu.sh` now installs it (`install -m 0755`) to `/usr/local/bin/switch-model.sh` + `/srv/ai/models/switch-model.sh` instead of generating it; bootstrap (pct/ssh) ships `switch-model.sh` alongside the configure script, and configure fails fast if it is missing.
- **KISS refactor**: removed `ansible/` + `opentofu/` — two bash files only (`deploy-` + `configure-hlh-ai-engine-igpu.sh` with embedded `--bootstrap-inside`), matching `hlh-ai-engine-egpu` pattern. Deploy pushes itself via `pct push`/`scp` with `ROCM_VERSION` forwarded; added post-bootstrap `ai-engine` + `/health` fail-fast check.
- **Repo renamed** `hlh-ai-engine` → `hlh-ai-engine-igpu` — named for the 890M iGPU slot (.12), matching `hlh-ai-engine-egpu` (.11 workhorse) scheme.
- **Hostname** `hlh-ai-engine` → `hlh-ai-engine-igpu`; scripts `deploy-/configure-hlh-ai-engine-igpu.sh`; ansible `hlh_ai_engine_igpu` group + `hlh-ai-engine-igpu.yml` inventory/playbook; opentofu `hlh_ai_engine_igpu` resource. VMID stays `112`, IP stays `192.168.1.12`, 48GB RAM unchanged.

### Added

- **switch-model.sh v1.7.1**: generated ExecStart now includes `--metrics` so llama-server exposes `/metrics` for Prometheus scraping (fixes `hlh-llama.cpp-igpu` dashboard No Data — target was 501). Configured unit also gets `--metrics`.
- switch-model.sh v1.6.1: real readiness check (`/health` probe, crash-loop detection)
- Required-model enforcement: DFlash2 draft GGUF
  `Qwen3.8-27B-DFlash2-Q4_K_M.gguf` is downloaded from
  `z-lab/Qwen3.8-27B-DFlash2-GGUF` if missing (note: no Q2_K variant exists upstream;
  a truncated Q2_K file caused `expected 81, got 58` load failures)
- `dl.sh` resumable HuggingFace downloader written to model dir

### Removed

- switch-model.sh v1.7.0: DFlash2 spec option removed (Strix Point iGPU is
  bandwidth-starved so block-verify speculation can't win; draft also not
  loadable on unpinned master since PR #27342 remains open upstream). Spec
  menu is now MTP / ngram / none (standard) only.

### Changed

- llama.cpp build unpinned: tracks latest upstream master again (deterministic
  pin removed at user request; pin recipe kept as comments in the configure
  script). NOTE: DFlash2 PR #27342 is still open upstream, so DFlash2 draft
  support is lost on the next deploy unless the pin is restored
- Upgrade ROCm from 7.2.3 to 7.14.0 (native gfx1150 rocBLAS support)
- Switch llama-server from port 8080 (nginx) to port 80 (native web UI)
- Update default model to Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf

### Fixed

- Fix ROCm 7.14 repo URLs for Ubuntu 24.04
- Install ROCm dev package required for HIP CMake builds

### Known limitations

- Qwen3.8-27B decodes at ~4.3 tok/s regardless of speculation method (MTP/DFlash2/none)
  because its Gated Delta Net attention fused kernels are not supported on HIP
  (`fused Gated Delta Net not supported, set to disabled`); Qwen3.6-27B+MTP remains
  the fastest config on this iGPU (~7.6-7.8 tok/s)
- DFlash2 draft GGUF (`Qwen3.8-27B-DFlash2-Q4_K_M.gguf`) no longer loads: PR #27342
  is unmerged upstream and the llama.cpp build is unpinned. The file is kept on
  storage for future use (e.g. MI50/60 with a pinned fork)

## [0.9.4] - 2026-09-11

### Changed

- Bump ROCm default **never pinned** to `10.0.0` (2026-08-26 latest; was `7.14.1` `2026-09-02` patch) — deploy always prints version, `ROCM_VERSION=7.14.1` still supported via env override
- Both `deploy-hlh-ai-engine-igpu.sh:34` and `ansible/files/configure-ai-engine-inside-lxc.sh:72` now default `ROCM_VERSION=10.0.0`; comments say never pinned
- `README`/`90_DONE` `7.14.1` → `10.0.0` default, `10_ACTIVE` `7.14.1`→`10.0.0`, `opentofu` description `7.14.1`→`10.0.0`, bootstrap `v0.9.3→v0.9.4`

## [0.9.3] - 2026-09-11

### Added

- Dual HIP+Vulkan build: `llama.cpp` now `GGML_HIP=ON + GGML_VULKAN=ON` (`gfx1150`-only, `AMDGPU_TARGETS=gfx1150`, `HSA_OVERRIDE_GFX_VERSION=11.5.0`)
  HIP is ROCm, Vulkan is Mesa RADV; same binaries, runtime pick `-dev ROCm0|Vulkan0`, no inference perf hit vs pure HIP
- Vulkan build deps restored: `libvulkan-dev`, `glslang-tools` (`glslc`), `spirv-tools`, `vulkan-tools` (fixes `README` `SPIRV-Headers` gap)
- Deploy header prints `ROCm version : ${ROCM_VERSION} | Backend: HIP+Vulkan dual, gfx1150` and forwards `ROCM_VERSION` into LXC via `pct exec env`

### Changed

- **ROCm unpinned**: `ROCM_VERSION` env default `7.14.1` (2026-09-02 latest `7.14` patch; was pinned `7.14.0`), supports `10.0.0` major
  Packages track `major.minor`: `amdrocm${MM}-gfx1150` + `amdrocm-core-dev${MM}-gfx1150` (`ROCM_MM=$(cut -d. -f1,2)`)
  Both `deploy-hlh-ai-engine-igpu.sh:32` and `ansible/files/configure-ai-engine-inside-lxc.sh:64` respect `ROCM_VERSION=10.0.0 ./deploy-hlh-ai-engine-igpu.sh`
- `DEFAULT_MODEL_URL` fixed: `bartowski/Qwen3-Coder-30B-A3B-Instruct-GGUF` (was `Qwen2.5-Coder-32B` path containing `Qwen3-Coder-30B` file)
- Docs current: `README` `LXC 101→112`, `vmid 101→112`, `GPU Backend Notes` dual `HIP+Vulkan` `88G` UMA vs `48G` HIP, `Health Checks` `vulkaninfo`/`HIP+Vulkan nm`, `90_DONE` `LXC 112` `amdrocm${MM}` `v0.9.3`
- Bootstrap version `0.9.2 → 0.9.3`, `description` `ROCm+Vulkan dual` `gfx1150-only chip`

### Fixed

- `deploy-hlh-ai-engine-igpu.sh:141` `http://<container-ip>:8080` → `http://<container-ip>:80` (native web UI, was stale after `80` migration)
- Bootstrap Vulkan verification: `glslc` check, `vulkaninfo --summary` after device passthrough, `nm ... | grep hip|vulkan` dual symbol check (was HIP-only)

## [0.3.1] - 2026-06

### Fixed

- Flatten repository layout to repo root (d187300)

## [0.3.0] - 2026-05

### Changed

- Prefer Q4_K_M ai-engine model on bootstrap (46bc607)

### Fixed

- Revert ai-engine GPU layer selection change (03777d7)

## [0.2.1] - 2026-05

### Added

- Partial GPU offload control for large ai-engine models (5b6b91c)

### Fixed

- Fix switch-model awk quoting for port 80 rewrite (60cd89e)

## [0.2.0] - 2026-04

### Changed

- Move ai-engine webui to port 80 and remove turboquant option (5c53144)
- Rename ai-engine LXC hostname to hlh-ai-engine-igpu (9db702b)
- Rename ai-engine provision script to deploy (56b615f)

### Added

- switch-model.sh v1.3.0 with MTP auto-detect (f4da34f)
- Working llama.cpp ROCm 7.2.3 deployment on gfx1150 (890M) (547768a)

### Fixed

- Pin LXC 101 to static 192.168.1.12 (fd72026)
- Skip default model download when mount already has gguf (f1ff9df)
- Mount /srv/ai/models host path into LXC (f2c49ca)

## [0.1.0] - 2026-04

### Added

- Initial AI engine LXC deployment scaffolding
- ROCm 7.2.3 installation via amdgpu-install
- Ansible playbook for in-container configuration
- OpenTofu module for Proxmox LXC provisioning
- deploy-hlh-ai-engine-igpu.sh: LXC creation, GPU passthrough, bootstrap
- Configure-hlh-ai-engine-igpu.sh: in-container configuration

### Fixed

- ZFS rootfs creation syntax for Proxmox 9.x (multiple fixes across 20+ commits)
