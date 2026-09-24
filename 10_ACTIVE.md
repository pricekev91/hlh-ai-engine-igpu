# TODO

Active items in progress. These are the current focus areas.

## Active

- [ ] Validate GPU PCI IDs for passthrough on updated Proxmox kernels (`226:1`, `226:128`, `511:0` + `234:0` for `gfx1150` — now HIP+Vulkan)
- [ ] Run ai-vm ROCm migration plan on staging environment
- [ ] Confirm final DNS hostnames for AI endpoint (`192.168.1.12:80`)

## This Week

- [ ] Validate ROCm 10.x compatibility on latest Proxmox kernel after `2713d18` kfd `234:0` addition
- [ ] Verify cgroup rules (`226:1`, `226:128`, `511:0`, `234:0`) survive LXC redeploy with `deploy-hlh-ai-engine-igpu.sh`

## Done (2026-09-11 — v0.9.4 + v0.9.3)

- [x] GPU PCI IDs corrected: `card0`/`renderD128`/`226:128` (was `card1`/`renderD129`/`226:129`, `1010f5e`), kfd `234:0` added alongside `511:0` for ROCm 10 forward compat (`2713d18`), both cgroup rules in deploy
- [x] Validate GPU PCI IDs for passthrough on updated Proxmox kernels (`226:1`, `226:128`, `511:0` + `234:0` for `gfx1150` — now HIP+Vulkan)
- [x] Unpinned `ROCM_VERSION` never pinned — default now `10.0.0` (was `7.14.1`), `7.14.1` still via `ROCM_VERSION=7.14.1` override, `ROCM_MM` mapping (v0.9.4)
- [x] Fix `DEFAULT_MODEL_URL` `Qwen2.5→Qwen3-Coder-30B` + docs `LXC 101→112` `8080→80` drift
- [x] Deploy script always calls out version (`[0/6]` header + `[6/6]` footer) and forwards `ROCM_VERSION` into LXC — never pinned
