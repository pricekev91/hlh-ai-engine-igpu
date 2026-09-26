#!/usr/bin/env bash
set -euo pipefail

# configure-hlh-ai-engine-igpu.sh - 2nd script (configuration) for hlh-ai-engine-igpu
# Pure bash, no ansible/opentofu. One for provision (deploy), one for configuration.
# Usage:
#   ./configure-hlh-ai-engine-igpu.sh [--host <ip>] [--via-ssh]          # host-side: pushes and runs bootstrap inside LXC
#   ./configure-hlh-ai-engine-igpu.sh --bootstrap-inside                 # inside LXC: runs the actual bootstrap (called via pct exec)
#   ROCM_VERSION=7.14.1 ./configure-hlh-ai-engine-igpu.sh                # override ROCm (forwarded into LXC)
# When invoked via pct exec or ssh, the bootstrap logic runs inside the target LXC.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LXC_ID=112
DEFAULT_HOST="192.168.1.12"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
HOST_OVERRIDE=""
VIA_SSH=false
BOOTSTRAP_INSIDE=false

usage() {
    cat <<'EOF'
Usage:
  ./configure-hlh-ai-engine-igpu.sh [--host <ip>] [--via-ssh]
  ./configure-hlh-ai-engine-igpu.sh --bootstrap-inside   (run inside LXC)

Options:
  --host <ip>          Override target host (default 192.168.1.12 or LXC 112 via pct if local)
  --via-ssh            Force ssh even if pct is available
  --bootstrap-inside   Run bootstrap logic inside LXC (invoked via pct exec, not manually)
  -h, --help           Show this help.

Two scripts only: deploy (provision) + configure (this file). This file *is* the bootstrap when --bootstrap-inside is used.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            [[ $# -ge 2 ]] || { echo "ERROR: --host requires a value" >&2; exit 1; }
            HOST_OVERRIDE="$2"; shift ;;
        --via-ssh) VIA_SSH=true ;;
        --bootstrap-inside) BOOTSTRAP_INSIDE=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

if $BOOTSTRAP_INSIDE; then
    # --- BEGIN BOOTSTRAP LOGIC (formerly ansible/files/configure-ai-engine-inside-lxc.sh) ---
# configure-ai-engine-inside-lxc.sh
# Version: 0.9.6
# Description: Bootstrap llama.cpp AI engine on LXC with ROCm+Vulkan dual backend
# Target GPU: AMD Radeon 890M (gfx1150/Strix Halo) on Proxmox 9.x privileged LXC — gfx1150-only chip
# Requirements: Run as root inside privileged LXC with GPU passthrough (/dev/dri/card0, renderD128, /dev/kfd) and /srv/ai/models bind mount
# Changelog:
#   0.9.8 - Renamed switch-model.sh -> igpu-switch-model.sh (v1.7.2) for box parity with
#           egpu-switch-model.sh (.11). Deployed as /usr/local/bin/igpu-switch-model.sh +
#           /srv/ai/models/igpu-switch-model.sh.
#   0.9.7 - switch-model.sh v1.7.1: extracted from heredoc into a standalone repo file
#           (single source of truth — configure now installs it instead of generating it).
#           Generated ExecStart includes --metrics so llama-server exposes /metrics for
#           Prometheus scraping. Bootstrap now ships switch-model.sh alongside this script.
#   0.9.6 - Fix 0.9.5 regression: amdrocm-core-dev10.0-gfx1150 DOES exist (dev metapackage ships hip-lang-config.cmake); install it after runtime
#   0.9.5 - Distro-agnostic ROCm repo detection; fix package name: amdrocm-core-dev does not exist on ROCm 10.x (use amdrocm-core); explicit failure message for -dev mismatch
#   0.9.4 - Bump ROCm default to 10.0.0 (latest 2026-08-26) — deploy never pinned; still override via ROCM_VERSION=7.14.1
#   0.9.3 - Dual backend: llama.cpp built with GGML_HIP=ON + GGML_VULKAN=ON (gfx1150)
#           Unpinned ROCm: ROCM_VERSION env override (default 7.14.1, latest 7.14 patch; now 10.0.0)
#           Vulkan deps restored: libvulkan-dev, glslang-tools (glslc), spirv-tools, vulkan-tools
#           DEFAULT_MODEL_URL fixed: bartowski/Qwen3-Coder-30B-A3B-Instruct-GGUF (was Qwen2.5 path)
#           Deploy script now prints ROCm version + backend and forwards ROCM_VERSION into LXC
#   0.9.2 - switch-model.sh v1.7.0: DFlash2 option removed (bandwidth-starved
#           iGPU can't benefit; draft not loadable on unpinned master). Spec
#           menu is now MTP / ngram / none (standard) only.
#   0.9.1 - Unpinned llama.cpp: build latest upstream master again (per user
#           request). DFlash2 PR #27342 is still OPEN upstream, so DFlash2
#           draft support disappears on next deploy unless LLAMA_CPP_PIN is
#           set to the PR commit again. Pin recipe left in step 2 comments.
#   0.9.0 - Pin llama.cpp to DFlash2 commit 5ecbe1a (PR #27342, 2026-08-18) instead of
#           floating master: deterministic builds, DFlash2 draft-model support
#           switch-model.sh bumped to v1.6.1: adds DFlash2 speculative decoding option,
#           auto-pairs same-family DFlash draft GGUF, and a real readiness check that
#           probes /health instead of trusting `systemctl is-active` during crash loops
#           Ensures DFlash2 draft GGUF (Qwen3.8-27B-DFlash2-Q4_K_M.gguf) is present,
#           downloads from z-lab/Qwen3.8-27B-DFlash2-GGUF if missing
#           Writes dl.sh (resumable curl downloader) to model dir
#   0.8.3 - switch-model.sh v1.4.2: added 72K (73728) and 96K (98304) ctx-size options
#            VRAM budget table updated with 72K and 96K KV cache estimates
#   0.8.2 - Fixed triple-nested rewrite_execstart bug in switch-model.sh (was never callable)
#            Updated default model to Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf
#            Updated PREFERRED_MODELS list to include Qwen3-Coder model
#            switch-model.sh now copied to /srv/ai/models/ to keep both copies in sync
#            Added startup wait loop + web UI URL confirmation after model switch
#            switch-model.sh bumped to v1.4.1
#   0.8.1 - Reuse existing .gguf on mounted /srv/ai/models during bootstrap
#            Download default model only when model directory is empty
#   0.8.0 - switch-model.sh v1.3.0: full ctx-size + KV cache + MTP auto-detect
#            MTP models detected by filename (case-insensitive 'MTP' match)
#            ExecStart rewritten atomically via awk on every switch (no sed fragility)
#   0.7.0 - Upgraded to ROCm 7.14.0 for native gfx1150 (Strix Halo) rocBLAS support
#            Fixed -ngl flag, removed --flash-attn, added render/video group for root
#            Fixed KFD cgroup device major (511, not 238) documented in create script
#   0.6.2 - Disabled Vulkan (missing SPIRV-Headers); ROCm only
#   0.6.0 - Added glslc, pre-build checks, fixed LD_LIBRARY_PATH unbound variable
#   0.5.0 - Fixed HIP compiler: use HIPCXX env var pointing to clang, not hipcc wrapper
#   0.4.0 - Added rocm-hip-runtime-dev, Vulkan support, hipcc verification
#   0.3.0 - Added CMake ROCm path flags
#   0.2.0 - Fixed ROCm repo setup and package names
#   0.1.0 - Initial version

set -euo pipefail

# --- CONFIGURABLE ---
MODEL_DIR="/srv/ai/models"
DEFAULT_MODEL_FILE="Qwen3.6-35B-A3B-MTP-Q4_K_M.gguf"
DEFAULT_MODEL_URL=""
LLAMA_CPP_REPO="https://github.com/ggerganov/llama.cpp.git"
LLAMA_CPP_DIR="/opt/llama.cpp"
# NOTE: builds latest master. DFlash2 (PR #27342) and TurboQuant are NOT in
# upstream master yet; to use them, set LLAMA_CPP_PIN to a commit containing
# the needed PR(s) and uncomment the pinned fetch/checkout in step 2.
# LLAMA_CPP_PIN="5ecbe1ac17ec0484c5b44af0bd580cdc9c428ed4"  # DFlash2 PR #27342 (open, unmerged)
SERVICE_NAME="ai-engine"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"
SWITCH_SCRIPT="/usr/local/bin/igpu-switch-model.sh"
GFX_VERSION="11.5.0"   # gfx1150 native — rocBLAS 7.14.x / 10.0.x supports it
ROCM_PATH="/opt/rocm"
# Unpinned: tracks latest stable (default 10.0.0 2026-08-26). Override via env:
#   ROCM_VERSION=7.14.1 bash configure-ai-engine-inside-lxc.sh  (pin to older stable)
#   ROCM_VERSION=10.0.0 ./deploy-hlh-ai-engine.sh  (forwarded via pct exec env) — never pinned; deploy always prints version
ROCM_VERSION="${ROCM_VERSION:-10.0.0}"
DFLASH2_DRAFT_FILE="Qwen3.8-27B-DFlash2-Q4_K_M.gguf"
DFLASH2_DRAFT_URL="https://huggingface.co/z-lab/Qwen3.8-27B-DFlash2-GGUF/resolve/main/Qwen3.8-27B-DFlash2-Q4_K_M.gguf?download=true"

# --- DISTRO DETECTION (for ROCm repo dist name, used in ROCm repo setup) ---
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

# --- 1. BASE DEPENDENCIES ---
echo "[1/7] Installing base dependencies (ROCm ${ROCM_VERSION}, backend HIP+Vulkan, gfx1150)..."
apt-get update
apt-get install -y --no-install-recommends \
  build-essential git cmake pkg-config \
  python3 python3-pip curl wget unzip \
  libopenblas-dev libssl-dev ca-certificates gnupg \
  openssh-server

# Vulkan build deps (restored for dual HIP+Vulkan; provides glslc + SPIR-V headers + RADV driver)
# glslc is from package 'glslc' (shaderc) on noble, NOT glslang-tools — FindVulkan needs glslc specifically.
# SPIRV-Headers is needed for ggml/src/ggml-vulkan/CMakeLists.txt:14 (SPIRV-HeadersConfig.cmake).
# mesa-vulkan-drivers provides RADV for gfx1150; without it vulkaninfo fails 'Found no drivers!' and llama.cpp Vulkan backend is unusable.
echo "[1/7] Installing Vulkan build dependencies (for GGML_VULKAN=ON, RADV GFX1150)..."
apt-get install -y --no-install-recommends \
  libvulkan-dev glslang-tools spirv-tools spirv-headers vulkan-tools glslc mesa-vulkan-drivers 2>&1 || {
  echo "WARNING: Vulkan deps install had issues (trying fallback packages)"
  apt-get install -y --no-install-recommends glslc spirv-headers mesa-vulkan-drivers 2>&1 || true
}
# Verify glslc + SPIRV-Headers now exist for FindVulkan (ggml/src/ggml-vulkan/CMakeLists.txt:9,14)
if ! command -v glslc >/dev/null 2>&1; then
  echo "ERROR: glslc still not found after Vulkan deps install (FindVulkan will fail with 'Could NOT find Vulkan (missing: glslc)')" >&2
  echo "Attempting to locate any glslc package..." >&2
  apt-cache search glslc 2>&1 | head -20 >&2 || true
  # Do not exit yet — cmake will surface clear error, but warn here for faster diagnosis
else
  echo "glslc: $(command -v glslc) $(glslc --version 2>&1 | head -1)"
fi
if ! dpkg -l | grep -qi spirv-headers; then
  echo "WARNING: spirv-headers package not installed — CMake will fail at ggml-vulkan:14 (SPIRV-HeadersConfig.cmake missing)" >&2
  apt-cache search spirv-headers 2>&1 | head -20 >&2 || true
else
  echo "spirv-headers: $(dpkg -l | grep spirv-headers | awk '{print $2, $3}')"
  # Verify CMake config exists
  find /usr -name "SPIRV-HeadersConfig.cmake" -o -name "spirv-headers-config.cmake" 2>/dev/null | head -5 || echo "NOTE: SPIRV-HeadersConfig.cmake not found in /usr (will still try cmake)"
fi

# --- 1b. ADD ROCM ${ROCM_VERSION} REPO (unpinned, tracks latest 7.14.x / 10.x) ---
echo "[1/7] Adding ROCm ${ROCM_VERSION} repository (override: ROCM_VERSION=x.y.z)..."
mkdir -p /etc/apt/keyrings
# ROCm 10.x uses the new stable repo (https://stable.repo.amd.com/rocm/core/packages); 7.x uses the legacy multi-arch repo.
# Keep both repo URLs available and pick by major version — 10.x was released 2026-08-26 and moved to stable.repo.amd.com.
ROCM_MAJOR="$(echo "${ROCM_VERSION}" | cut -d. -f1)"
if [ "${ROCM_MAJOR}" -ge 10 ] 2>/dev/null; then
  echo "[1/7] ROCm ${ROCM_VERSION} >=10 — using stable.repo.amd.com (was repo.amd.com/packages-multi-arch for 7.x)"
  wget -qO - https://stable.repo.amd.com/rocm/gpg/packages.gpg | \
    gpg --dearmor | tee /etc/apt/keyrings/amdrocm.gpg > /dev/null
  tee /etc/apt/sources.list.d/rocm.list << EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://stable.repo.amd.com/rocm/core/packages/${ROCM_REPO_DIST} stable main
EOF
  # Stable repo origin is stable.repo.amd.com (pin that instead of repo.radeon.com for 10.x)
  tee /etc/apt/preferences.d/rocm-pin << 'PIN'
Package: *
Pin: origin stable.repo.amd.com
Pin-Priority: 1001
PIN
else
  wget -qO - https://repo.amd.com/rocm/packages-multi-arch/gpg/rocm.gpg | \
    gpg --dearmor | tee /etc/apt/keyrings/amdrocm.gpg > /dev/null
  tee /etc/apt/sources.list.d/rocm.list << EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://repo.amd.com/rocm/packages-multi-arch/${ROCM_REPO_DIST} stable main
EOF
  tee /etc/apt/preferences.d/rocm-pin << 'PIN'
Package: *
Pin: origin repo.radeon.com
Pin-Priority: 1001
PIN
fi

echo 'APT::Key::GPGCommand "/usr/bin/gpg";' > /etc/apt/apt.conf.d/99gpg-override

# Remove Ubuntu's conflicting rocminfo
apt-get remove -y rocminfo 2>/dev/null || true

apt-get update
# ROCm package names encode major.minor (e.g. amdrocm7.14-gfx1150 for 7.14.1, amdrocm10.0 for 10.0.0).
# For 10.x the per-GPU package may be named amdrocm10.0-gfx1150 or may be a generic amdrocm10.0; try per-GPU first, fall back to generic.
ROCM_MM="$(echo "${ROCM_VERSION}" | cut -d. -f1,2)"
# NOTE: ROCm 10.x splits runtime (amdrocm-core) from dev (amdrocm-core-dev).
# hip-lang-config.cmake (needed for llama.cpp HIP builds) ships in the DEV metapackage:
# amdrocm-core-dev10.0-gfx1150 (verified via apt-cache on live 112). 0.9.5 wrongly dropped -dev.
echo "[1/7] Installing ROCm ${ROCM_VERSION} packages: amdrocm${ROCM_MM}-gfx1150 + amdrocm-core${ROCM_MM}-gfx1150 ..."
if ! apt-get install -y --no-install-recommends \
  "amdrocm${ROCM_MM}-gfx1150" \
  "amdrocm-core${ROCM_MM}-gfx1150"; then
  echo "WARNING: per-GPU package amdrocm${ROCM_MM}-gfx1150 not found (common for 10.x); trying generic amdrocm${ROCM_MM} + amdrocm-core${ROCM_MM} ..."
  apt-get install -y --no-install-recommends \
    "amdrocm${ROCM_MM}" \
    "amdrocm-core${ROCM_MM}" || {
      echo "ERROR: Neither per-GPU nor generic ROCm ${ROCM_VERSION} packages found." >&2
      echo "Available amdrocm packages:" >&2
      apt-cache search "^amdrocm${ROCM_MM}" 2>&1 | head -100 >&2 || true
      apt-cache search "^amdrocm" 2>&1 | head -100 >&2 || true
      exit 1
    }
  echo "Installed generic amdrocm${ROCM_MM} (no per-GPU suffix) — verify gfx1150 is in this bundle via 'rocm-smi' + 'rocminfo | grep gfx'"
fi

echo "[1/7] Installing ROCm dev metapackage for HIP CMake (hip-lang-config.cmake): amdrocm-core-dev${ROCM_MM}-gfx1150 ..."
if ! apt-get install -y --no-install-recommends "amdrocm-core-dev${ROCM_MM}-gfx1150"; then
  echo "WARNING: per-GPU dev amdrocm-core-dev${ROCM_MM}-gfx1150 not found; trying generic amdrocm-core-dev${ROCM_MM} ..."
  apt-get install -y --no-install-recommends "amdrocm-core-dev${ROCM_MM}" || {
    echo "ERROR: ROCm dev package not found — HIP builds will fail without hip-lang-config.cmake." >&2
    apt-cache search "^amdrocm-core-dev${ROCM_MM}" 2>&1 | head -30 >&2 || true
    exit 1
  }
fi

# llama.cpp HIP builds require the HIP CMake package (hip-lang-config.cmake),
# which is provided by ROCm developer components.
if [ ! -f /opt/rocm/lib/cmake/hip-lang/hip-lang-config.cmake ] && \
   [ ! -f /opt/rocm/lib64/cmake/hip-lang/hip-lang-config.cmake ] && \
   [ ! -f /opt/rocm/lib/x86_64-unknown-linux-gnu/cmake/hip-lang/hip-lang-config.cmake ]; then
  echo "ERROR: HIP CMake package not found after ROCm install (hip-lang-config.cmake)." >&2
  exit 1
fi

# Add root to render and video groups for GPU access
usermod -aG render root
usermod -aG video root

# Allow root SSH login with password for lab access.
# The root password is set manually after deploy.
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-root-login.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
EOF
systemctl enable ssh
systemctl restart ssh || systemctl restart sshd

# Install amdgpu-top via the upstream .deb release (works in LXC; snapd/AppArmor
# do not function reliably in unprivileged/container environments).
echo "[1/7] Installing amdgpu-top (.deb release, no snapd required)..."
AMDGPU_TOP_VERSION="0.11.5"
AMDGPU_TOP_DEB="amdgpu-top_${AMDGPU_TOP_VERSION}-1_amd64.deb"
AMDGPU_TOP_URL="https://github.com/Umio-Yasuno/amdgpu_top/releases/download/v${AMDGPU_TOP_VERSION}/${AMDGPU_TOP_DEB}"
AMDGPU_TOP_TMP="/tmp/${AMDGPU_TOP_DEB}"

if command -v amdgpu_top >/dev/null 2>&1; then
  echo "amdgpu_top already installed: $(command -v amdgpu_top)"
else
  if wget -qO "$AMDGPU_TOP_TMP" "$AMDGPU_TOP_URL"; then
    apt-get install -y "$AMDGPU_TOP_TMP" || {
      echo "WARNING: amdgpu-top .deb install failed; continuing without it"
    }
    rm -f "$AMDGPU_TOP_TMP"
  else
    echo "WARNING: Failed to download amdgpu-top .deb; continuing without it"
  fi
fi

# --- ROCm Environment Setup ---
echo "[1/7] Setting up ROCm environment..."
tee /etc/profile.d/rocm.env << EOF
export PATH=\$PATH:${ROCM_PATH}/bin:${ROCM_PATH}/llvm/bin
export LD_LIBRARY_PATH=${ROCM_PATH}/lib:\${LD_LIBRARY_PATH:-}
export ROCM_PATH=${ROCM_PATH}
export HIP_PATH=${ROCM_PATH}
EOF

set +u
source /etc/profile.d/rocm.env
set -u

# --- Pre-Build Checks ---
echo "[1/7] Verifying HIP tools (ROCm ${ROCM_VERSION})..."
HIPCXX_PATH="$(hipconfig -l)/clang"
HIP_PATH_VAL="$(hipconfig -R)"
echo "HIP clang path: ${HIPCXX_PATH}"
echo "HIP root path:  ${HIP_PATH_VAL}"
[ -f "${HIPCXX_PATH}" ] || { echo "ERROR: HIP clang not found at ${HIPCXX_PATH}"; exit 1; }

echo "[1/7] Verifying Vulkan tools (for dual backend)..."
if command -v glslc >/dev/null 2>&1; then
  echo "glslc: $(glslc --version 2>&1 | head -1)"
else
  echo "WARNING: glslc not found — Vulkan build will fail; ensure glslang-tools installed"
fi
vulkaninfo --summary 2>&1 | head -20 || echo "NOTE: vulkaninfo not yet useful (driver inside LXC needs /dev/dri passthrough; will be available after deploy)"

# --- 2. BUILD LLAMA.CPP (ROCm+Vulkan dual, latest master, gfx1150-only chip) ---
echo "[2/7] Cloning and building llama.cpp (ROCm ${ROCM_VERSION} + Vulkan gfx1150, latest master, dual HIP+Vulkan)..."
if [ ! -d "$LLAMA_CPP_DIR" ]; then
  git clone --depth=1 "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
fi

# Move back onto master before pulling (the checkout may be on a detached
# HEAD from a previous pinned build, where plain `git pull` would fail).
git -C "$LLAMA_CPP_DIR" checkout -f master 2>/dev/null || true
git -C "$LLAMA_CPP_DIR" pull --ff-only

# To pin a specific commit/PR (e.g. DFlash2 PR #27342, TurboQuant), uncomment:
# git -C "$LLAMA_CPP_DIR" fetch --depth=1 origin "$LLAMA_CPP_PIN"
# git -C "$LLAMA_CPP_DIR" checkout -f "$LLAMA_CPP_PIN"

cd "$LLAMA_CPP_DIR"

HIPCXX="${HIPCXX_PATH}" HIP_PATH="${HIP_PATH_VAL}" \
cmake -S . -B build \
  -DGGML_HIP=ON \
  -DGGML_VULKAN=ON \
  -DAMDGPU_TARGETS=gfx1150 \
  -DCMAKE_BUILD_TYPE=Release

echo "[2/7] Checking HIP+Vulkan CMake configuration..."
if [ ! -f build/CMakeCache.txt ] || ! grep -qi 'GGML_HIP=TRUE' build/CMakeCache.txt 2>/dev/null; then
  echo "WARNING: HIP may not be enabled in cmake cache; re-running cmake with explicit HIP paths"
  HIPCXX="${HIPCXX_PATH}" HIP_PATH="${HIP_PATH_VAL}" \
  cmake -S . -B build \
    -DGGML_HIP=ON \
    -DGGML_VULKAN=ON \
    -DAMDGPU_TARGETS=gfx1150 \
    -DCMAKE_BUILD_TYPE=Release
fi
if ! grep -qi 'GGML_VULKAN=TRUE' build/CMakeCache.txt 2>/dev/null; then
  echo "WARNING: Vulkan may not be enabled in cmake cache; ensure libvulkan-dev + glslang-tools installed"
fi

echo "[2/7] Building... (this can take 10-25 minutes with 12 cores, dual HIP+Vulkan)"
cmake --build build --config Release -j$(nproc)

# Verify the binary has HIP + Vulkan support (HIP is ROCm; Vulkan is RADV on gfx1150, gfx1150-only chip)
echo "[2/7] Verifying dual backend symbols..."
if nm build/bin/llama-server 2>/dev/null | grep -qi hip; then
  echo "OK: HIP/ROCm symbols found in llama-server binary"
else
  echo "WARNING: No HIP symbols found in llama-server binary; HIP support may not be enabled"
fi
if nm build/bin/llama-server 2>/dev/null | grep -qi vulkan; then
  echo "OK: Vulkan symbols found in llama-server binary"
else
  echo "WARNING: No Vulkan symbols found; Vulkan support may not be enabled"
fi
# vulkaninfo check inside LXC (needs /dev/dri passthrough; may be empty at build time)
vulkaninfo --summary 2>&1 | head -30 || true

# --- 3. MODEL STORAGE & DOWNLOAD ---
echo "[3/7] Setting up model directory..."
mkdir -p "$MODEL_DIR"
cd "$MODEL_DIR"

ACTIVE_MODEL_FILE=""

if [ -f "${MODEL_DIR}/${DEFAULT_MODEL_FILE}" ]; then
  ACTIVE_MODEL_FILE="$DEFAULT_MODEL_FILE"
  echo "Default model already present: $ACTIVE_MODEL_FILE"
else
  PREFERRED_MODELS=(
    "Qwen3.6-35B-A3B-MTP-Q4_K_M.gguf"
    "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
    "Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
    "Qwen_Qwen3-Coder-Next-Q4_K_M.gguf"
  )
  for MODEL_CANDIDATE in "${PREFERRED_MODELS[@]}"; do
    if [ -f "${MODEL_DIR}/${MODEL_CANDIDATE}" ]; then
      ACTIVE_MODEL_FILE="$MODEL_CANDIDATE"
      echo "Using preferred existing model from mounted storage: $ACTIVE_MODEL_FILE"
      break
    fi
  done

  if [ -z "${ACTIVE_MODEL_FILE}" ]; then
    mapfile -t EXISTING_MODELS < <(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' -printf '%f\n' | sort)
    if [ "${#EXISTING_MODELS[@]}" -gt 0 ]; then
      ACTIVE_MODEL_FILE="${EXISTING_MODELS[0]}"
      echo "Using existing model from mounted storage: $ACTIVE_MODEL_FILE"
    else
      ACTIVE_MODEL_FILE="$DEFAULT_MODEL_FILE"
      if [ -z "$DEFAULT_MODEL_URL" ]; then
        echo "ERROR: No .gguf on shared mount $MODEL_DIR and no DEFAULT_MODEL_URL — populate host /srv/ai/models with $DEFAULT_MODEL_FILE first" >&2
        exit 1
      fi
      echo "No existing models found; downloading default model: $ACTIVE_MODEL_FILE"
      wget -O "${MODEL_DIR}/${ACTIVE_MODEL_FILE}" "$DEFAULT_MODEL_URL"
    fi
  fi
fi

# --- 3b. ENSURE REQUIRED MODELS (DFlash2 draft) ---
for ENTRY in "${DFLASH2_DRAFT_FILE}|${DFLASH2_DRAFT_URL}"; do
  FILE="${ENTRY%%|*}"
  URL="${ENTRY#*|}"
  if [ -f "${MODEL_DIR}/${FILE}" ]; then
    echo "Required model present: ${FILE}"
  else
    echo "Downloading required model: ${FILE}"
    wget -c -O "${MODEL_DIR}/${FILE}" "$URL"
  fi
done

# --- 4. SYSTEMD SERVICE ---
# Default: Qwen3.6-35B-A3B-MTP-Q4_K_M (~21GB) + 96K ctx KV q4_0 (~12GB) = ~33GB fits 48GB UMA.
# MTP enabled (MoE auto n-max 5), -ngl 48 / batch 128 / parallel 1 kept (known good on 890M).
echo "[4/7] Creating systemd service for llama-server..."
cat > "$SYSTEMD_SERVICE" << UNIT
[Unit]
Description=llama.cpp AI Engine (llama-server) - native web UI on port 80
After=network.target

[Service]
Type=simple
WorkingDirectory=${LLAMA_CPP_DIR}/build/bin
Environment=HSA_OVERRIDE_GFX_VERSION=${GFX_VERSION}
Environment=PATH=${ROCM_PATH}/bin:${ROCM_PATH}/llvm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LD_LIBRARY_PATH=${ROCM_PATH}/lib:${ROCM_PATH}/lib64
Environment=ROCM_PATH=${ROCM_PATH}
Environment=HIP_PATH=${ROCM_PATH}
ExecStart=${LLAMA_CPP_DIR}/build/bin/llama-server \
  --model ${MODEL_DIR}/${ACTIVE_MODEL_FILE} \
  --host 0.0.0.0 --port 80 \
  --ctx-size 98304 \
  -ngl 48 \
  --batch-size 128 \
  --parallel 1 \
  --cache-type-k q4_0 \
  --cache-type-v q4_0 \
  --spec-type draft-mtp \
  --spec-draft-n-max 5 \
  --metrics
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
UNIT

# --- 5. MODEL SWITCH SCRIPT (standalone repo file — single source of truth) ---
echo "[5/7] Installing interactive model switcher: $SWITCH_SCRIPT..."
SWITCH_SRC="${SCRIPT_DIR}/igpu-switch-model.sh"
if [[ ! -f "$SWITCH_SRC" ]]; then
    echo "ERROR: ${SWITCH_SRC} not found — igpu-switch-model.sh must live next to this configure script in the repo" >&2
    exit 1
fi
install -m 0755 "$SWITCH_SRC" "$SWITCH_SCRIPT"

# Keep /srv/ai/models/igpu-switch-model.sh in sync (both locations exist on this host)
install -m 0755 "$SWITCH_SRC" "${MODEL_DIR}/igpu-switch-model.sh"

# --- 5b. MODEL DOWNLOAD HELPER (dl.sh) ---
echo "[5b/7] Creating model download helper: ${MODEL_DIR}/dl.sh..."
cat > "${MODEL_DIR}/dl.sh" << 'EOS'
#!/usr/bin/env bash
# dl.sh - HuggingFace model downloader with resume support
# Usage: dl.sh <huggingface-resolve-url>
URL="$1"
if [ -z "$URL" ]; then
    echo "Usage: $0 <huggingface-download-url>"
    exit 1
fi
OUT="$(basename "${URL%%\?*}")"
echo "=== HuggingFace Downloader ==="
echo "URL : $URL"
echo "OUT : $OUT"
echo
for attempt in {1..5}; do
    echo "[Attempt $attempt] Starting/resuming download..."
    curl -L -C - --fail --show-error --retry 3 --progress-bar -o "$OUT" "$URL" && {
        echo "[✓] Download completed: $OUT"
        exit 0
    }
    echo "[!] Attempt $attempt failed; retrying in 5s..."
    sleep 5
done
echo "[✗] Download failed after 5 attempts: $URL"
exit 1
EOS
chmod +x "${MODEL_DIR}/dl.sh"

# --- 6. ENABLE & START SERVICE ---
echo "[6/7] Enabling and starting $SERVICE_NAME..."
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

# --- 7. VERIFICATION ---
echo "[7/7] Verifying setup..."
echo ""
echo "[rocm-smi output]"
rocm-smi || echo "rocm-smi not found or failed"
echo ""
echo "[llama-server version]"
${LLAMA_CPP_DIR}/build/bin/llama-server --version || true
echo ""
# Verify HIP/ROCm + Vulkan support in the binary
echo "Checking HIP+Vulkan build support (HIP is ROCm; Vulkan is RADV, gfx1150-only)..."
if nm "${LLAMA_CPP_DIR}/build/bin/llama-server" 2>/dev/null | grep -qi hip; then
  echo "OK: HIP/ROCm symbols found in llama-server binary"
else
  echo "WARNING: No HIP symbols found in llama-server binary; HIP support may not be enabled"
fi
if nm "${LLAMA_CPP_DIR}/build/bin/llama-server" 2>/dev/null | grep -qi vulkan; then
  echo "OK: Vulkan symbols found in llama-server binary"
else
  echo "WARNING: No Vulkan symbols found; Vulkan support may not be enabled"
fi
# Verify ROCm environment variables are set for the running process
echo "Checking ROCm environment (ROCm ${ROCM_VERSION})..."
if [ -n "${HSA_OVERRIDE_GFX_VERSION:-}" ]; then
  echo "OK: HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE_GFX_VERSION} is set"
else
  echo "WARNING: HSA_OVERRIDE_GFX_VERSION not set"
fi
if [ -n "${LD_LIBRARY_PATH:-}" ]; then
  echo "OK: LD_LIBRARY_PATH is set"
else
  echo "WARNING: LD_LIBRARY_PATH not set"
fi
echo ""
echo "[Service status]"
systemctl status "$SERVICE_NAME" --no-pager
echo ""
echo "[Bootstrap complete - v0.9.5]"
echo "  Native llama.cpp web UI : http://<container-ip>:80 (HIP+Vulkan dual, gfx1150-only chip)"
echo "  Switch models with      : igpu-switch-model.sh (MTP/ngram/none; HIP default, Vulkan via RADV_PERFTEST=nogttspill)"
echo "  GPU device              : gfx1150 (AMD Radeon 890M) — ROCm HIP + Vulkan RADV"
echo "  ROCm version            : ${ROCM_VERSION} (unpinned; override: ROCM_VERSION=x.y.z ./deploy-hlh-ai-engine.sh)"
echo "  Backend                 : HIP+Vulkan dual (GGML_HIP=ON + GGML_VULKAN=ON, AMDGPU_TARGETS=gfx1150)"
echo "  Verify HIP              : rocm-smi && hipconfig --version"
echo "  Verify Vulkan           : vulkaninfo --summary && RADV_PERFTEST=nogttspill llama-bench -dev Vulkan0,ROCm0"
    # --- END BOOTSTRAP LOGIC ---
    exit 0
fi

TARGET_HOST="${HOST_OVERRIDE:-$DEFAULT_HOST}"

# Prefer pct if available and not forced ssh
if ! $VIA_SSH && command -v pct >/dev/null 2>&1 && pct status "$LXC_ID" >/dev/null 2>&1; then
    if pct status "$LXC_ID" 2>&1 | grep -q "running"; then
        echo "[configure] Using pct exec for LXC $LXC_ID ($TARGET_HOST)..."
        pct exec "$LXC_ID" -- mkdir -p /root/ai-engine-bootstrap
        pct push "$LXC_ID" "$0" /root/ai-engine-bootstrap/configure-hlh-ai-engine-igpu.sh --perms 0755
        pct push "$LXC_ID" "${SCRIPT_DIR}/igpu-switch-model.sh" /root/ai-engine-bootstrap/igpu-switch-model.sh --perms 0755
        pct exec "$LXC_ID" -- env ROCM_VERSION="${ROCM_VERSION:-10.0.0}" bash /root/ai-engine-bootstrap/configure-hlh-ai-engine-igpu.sh --bootstrap-inside
        echo "[configure] Done via pct exec."
        exit 0
    fi
    echo "[configure] LXC $LXC_ID not running, falling back to ssh $TARGET_HOST"
fi

echo "[configure] Using ssh root@$TARGET_HOST..."
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
if [[ -f "$SSH_KEY" ]]; then SSH_OPTS="$SSH_OPTS -i $SSH_KEY"; fi
scp $SSH_OPTS "$0" root@"$TARGET_HOST":/tmp/configure-hlh-ai-engine-igpu.sh 2>&1 | head -n 20
scp $SSH_OPTS "${SCRIPT_DIR}/igpu-switch-model.sh" root@"$TARGET_HOST":/tmp/igpu-switch-model.sh 2>&1 | head -n 20
ssh $SSH_OPTS root@"$TARGET_HOST" "ROCM_VERSION='${ROCM_VERSION:-10.0.0}' bash /tmp/configure-hlh-ai-engine-igpu.sh --bootstrap-inside" 2>&1
echo "[configure] Done via ssh."
