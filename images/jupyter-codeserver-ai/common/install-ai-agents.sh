#!/usr/bin/env bash
# Shared AI-agent recipe for the jupyter-codeserver-ai image family.
#
# Both jupyterlab.def and codeserver.def stage this directory into /opt/build and
# run this script in %post. It is the ONLY place the agents and their governance
# files are installed, which is what keeps the two images identical in the
# surface that matters -- there is no shared base image to guarantee it.
#
# Staging is /opt/build, NOT /tmp: Apptainer bind-mounts the host /tmp over the
# container's during %post, so files staged there are invisible to the build.

set -euo pipefail

this_script="common/install-ai-agents.sh"

log() {
    echo -e "[$(date -Iseconds)][${this_script}] $1"
}

BUILD_DIR=/opt/build
# shellcheck source=versions.env
. "${BUILD_DIR}/versions.env"

# ---------------------------------------------------------------------------
# Architecture. Both images build on either arch; the artifact is arch-specific
# and build-image.sh refuses to publish one that does not match the cluster.
# ---------------------------------------------------------------------------
case "$(uname -m)" in
    x86_64)  NODE_ARCH=x64;   CS_ARCH=amd64; MM_ARCH=64      ;;
    aarch64) NODE_ARCH=arm64; CS_ARCH=arm64; MM_ARCH=aarch64 ;;
    *)       log "ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac
log "architecture $(uname -m) -> node=${NODE_ARCH} code-server=${CS_ARCH} micromamba=${MM_ARCH}"

# ---------------------------------------------------------------------------
# OS packages. Bubblewrap and socat back Claude Code's sandbox; the rest are the
# utilities a session needs. The Jupyter base already carries most of these, but
# installing them unconditionally keeps the recipe identical across both bases.
# ---------------------------------------------------------------------------
log "installing OS packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    bubblewrap \
    socat \
    bzip2 \
    ca-certificates \
    curl \
    git \
    unzip \
    xz-utils \
    tzdata \
    vim-tiny
rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Node. From nodejs.org rather than NodeSource, which the build environment
# cannot reach. The checksum is verified against the release's own SHASUMS file.
# ---------------------------------------------------------------------------
log "installing Node ${NODE_VERSION}"
NODE_TARBALL="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
NODE_BASE="https://nodejs.org/dist/v${NODE_VERSION}"
curl -fsSL -o "${BUILD_DIR}/${NODE_TARBALL}" "${NODE_BASE}/${NODE_TARBALL}"
curl -fsSL -o "${BUILD_DIR}/SHASUMS256.txt" "${NODE_BASE}/SHASUMS256.txt"
( cd "${BUILD_DIR}" && grep " ${NODE_TARBALL}\$" SHASUMS256.txt | sha256sum -c - )
mkdir -p /usr/local/lib/nodejs
tar -xJf "${BUILD_DIR}/${NODE_TARBALL}" -C /usr/local/lib/nodejs
NODE_HOME="/usr/local/lib/nodejs/node-v${NODE_VERSION}-linux-${NODE_ARCH}"
for b in node npm npx; do
    ln -sf "${NODE_HOME}/bin/${b}" "/usr/local/bin/${b}"
done
log "node $(node --version), npm $(npm --version)"

# ---------------------------------------------------------------------------
# The AI CLIs, at exact pinned versions. Both floors are load-bearing: below
# Codex 0.138.0 the permission-profile policy is ignored outright, and below
# Claude Code 2.1.223 `env` is not merged per variable across administrative
# sources.
# ---------------------------------------------------------------------------
log "installing Claude Code ${CLAUDE_CODE_VERSION} and Codex ${CODEX_VERSION}"
# npm computes its default global prefix from the resolved path of the running
# node binary, which is under NODE_HOME -- never on PATH. Force the prefix to
# /usr/local so the claude and codex executables land in /usr/local/bin.
export NPM_CONFIG_PREFIX=/usr/local
npm install -g --no-fund --no-audit \
    "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    "@openai/codex@${CODEX_VERSION}"

# ---------------------------------------------------------------------------
# Environment managers, image-owned for course provisioning and staff
# maintenance. Neither is used to build this image.
# ---------------------------------------------------------------------------
log "installing uv ${UV_VERSION}"
UV_TARGET="$(uname -m)-unknown-linux-gnu"
UV_TARBALL="uv-${UV_TARGET}.tar.gz"
UV_BASE="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}"
curl -fsSL -o "${BUILD_DIR}/${UV_TARBALL}" "${UV_BASE}/${UV_TARBALL}"
curl -fsSL -o "${BUILD_DIR}/${UV_TARBALL}.sha256" "${UV_BASE}/${UV_TARBALL}.sha256"
( cd "${BUILD_DIR}" && sha256sum -c "${UV_TARBALL}.sha256" )
tar -xzf "${BUILD_DIR}/${UV_TARBALL}" -C /usr/local/bin --strip-components=1 \
    "uv-${UV_TARGET}/uv" "uv-${UV_TARGET}/uvx"

log "installing micromamba ${MICROMAMBA_VERSION}"
curl -fsSL "https://micro.mamba.pm/api/micromamba/linux-${MM_ARCH}/${MICROMAMBA_VERSION}" \
    | tar -xj -C /usr/local bin/micromamba

# ---------------------------------------------------------------------------
# Governance files. Contents map 1:1 onto /etc/claude-code/ and /etc/codex/.
# Mode 0644: every user must read them, no user may write them.
# ---------------------------------------------------------------------------
log "installing governance files"
install -d -m 0755 /etc/claude-code /etc/codex
install -m 0644 "${BUILD_DIR}/claude-code/managed-settings.json" /etc/claude-code/
install -m 0644 "${BUILD_DIR}/claude-code/managed-mcp.json"      /etc/claude-code/
install -m 0644 "${BUILD_DIR}/codex/requirements.toml"           /etc/codex/
install -m 0644 "${BUILD_DIR}/codex/managed_config.toml"         /etc/codex/

# ---------------------------------------------------------------------------
# Record what was installed, so the parity test can compare the two images and
# a session can be traced to its build without rebuilding anything.
# ---------------------------------------------------------------------------
log "recording the AI surface manifest"
# Each version is captured into a variable BEFORE the manifest is assembled, with
# no stderr suppression. A plain assignment from a failing command substitution
# trips `set -e` immediately, so a broken CLI install aborts the build loudly
# instead of being recorded as a blank manifest field.
claude_version=$(claude --version | head -1)
codex_version=$(codex --version | head -1)
node_version=$(node --version)
uv_version=$(uv --version | head -1)
micromamba_version=$(micromamba --version | head -1)
install -d -m 0755 /etc/ood-ai
{
    echo "claude_code=${claude_version}"
    echo "codex=${codex_version}"
    echo "node=${node_version}"
    echo "uv=${uv_version}"
    echo "micromamba=${micromamba_version}"
    echo "arch=$(uname -m)"
    for f in /etc/claude-code/*.json /etc/codex/*.toml; do
        echo "sha256:$(sha256sum "$f")"
    done
} > /etc/ood-ai/manifest.txt
chmod 0644 /etc/ood-ai/manifest.txt

rm -rf /opt/build
log "recipe complete"
