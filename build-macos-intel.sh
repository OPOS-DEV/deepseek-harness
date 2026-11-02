#!/usr/bin/env bash
# Build the unsigned Intel (mac-x64) Desktop DMG from this checkout.
#
# Fork-only helper: it patches no tracked file, so syncing upstream never conflicts.
# Caches under apps/desktop/.desktop-build make repeat builds much faster.
#
# Usage:
#   ./build-macos-intel.sh [--build-version <version>] [--skip-install]
#
# Environment (optional):
#   NPM_REGISTRY                 npm registry for the workspace install
#   ELECTRON_MIRROR              Electron binary mirror
#   NODE_MIRROR                  Node.js runtime mirror
#   PYPI_MIRROR                  PyPI files host mirror
#   GITHUB_PROXY                 prefix used when GitHub downloads are blocked
#   DSH_DESKTOP_NPM_REGISTRY     registry for the bundled runtime install
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

NPM_REGISTRY=${NPM_REGISTRY:-https://registry.npmmirror.com}
ELECTRON_MIRROR=${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}
NODE_MIRROR=${NODE_MIRROR:-https://npmmirror.com/mirrors/node/}
PYPI_MIRROR=${PYPI_MIRROR:-https://pypi.tuna.tsinghua.edu.cn}
# Empty GITHUB_PROXY disables the proxy fallback.
GITHUB_PROXY=${GITHUB_PROXY-https://gh-proxy.com}
DSH_DESKTOP_NPM_REGISTRY=${DSH_DESKTOP_NPM_REGISTRY:-$NPM_REGISTRY}

BUILD_VERSION=
SKIP_INSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --build-version)
      [ $# -ge 2 ] || { echo "--build-version requires a value" >&2; exit 2; }
      BUILD_VERSION=$2
      shift 2
      ;;
    --skip-install)
      SKIP_INSTALL=1
      shift
      ;;
    -h|--help)
      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

[ "$(uname -s)" = Darwin ] || { echo "this build requires macOS" >&2; exit 1; }
command -v node >/dev/null || { echo "node >= 24.9 is required" >&2; exit 1; }
node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 24 || (major === 24 && minor < 9)) { console.error(`node ${process.versions.node} is too old; 24.9+ required`); process.exit(1) }'
command -v pnpm >/dev/null || { echo "pnpm is required (corepack enable pnpm)" >&2; exit 1; }
if [ "$(uname -m)" = arm64 ]; then
  arch -x86_64 /usr/bin/true 2>/dev/null || {
    echo "Rosetta 2 is required to build x64 on Apple Silicon: softwareupdate --install-rosetta --agree-to-license" >&2
    exit 1
  }
fi

# Primary-runtime archives download from GitHub, PyPI and nodejs.org. Seeding the
# content-addressed cache first keeps packaging offline-friendly and lets mirrors
# stand in for the unreachable hosts.
seed_primary_runtime() {
  local downloads="apps/desktop/.desktop-build/downloads"
  mkdir -p "$downloads"
  node -e '
    const { readFileSync } = require("node:fs")
    const lock = JSON.parse(readFileSync("scripts/primary-runtime/lock.json", "utf8"))
    const target = lock.targets["mac-x64"]
    const enc = encodeURIComponent
    const rows = [
      [target.nodeSha256, `https://nodejs.org/dist/v${lock.nodeVersion}/node-v${lock.nodeVersion}-${target.nodeArchive}`],
      [target.pythonSha256, `https://github.com/astral-sh/python-build-standalone/releases/download/${lock.pythonRelease}/${enc(`cpython-${lock.pythonVersion}+${lock.pythonRelease}-${target.pythonTarget}-install_only_stripped.tar.gz`)}`],
      ...target.wheels.map((wheel) => [wheel.sha256, wheel.url]),
    ]
    for (const [sha256, url] of rows) console.log(`${sha256}\t${url}`)
  ' | while IFS=$'\t' read -r sha256 url; do
    local destination="$downloads/$sha256"
    if [ -s "$destination" ] && [ "$(shasum -a 256 "$destination" | cut -d' ' -f1)" = "$sha256" ]; then
      continue
    fi
    rm -f "$destination" "$destination.part"
    local candidates=("$url")
    case "$url" in
      https://files.pythonhosted.org/*) [ -n "$PYPI_MIRROR" ] && candidates+=("${PYPI_MIRROR%/}${url#https://files.pythonhosted.org}") ;;
      https://github.com/*) [ -n "$GITHUB_PROXY" ] && candidates+=("${GITHUB_PROXY%/}/$url") ;;
      https://nodejs.org/dist/*) [ -n "$NODE_MIRROR" ] && candidates+=("${NODE_MIRROR%/}${url#https://nodejs.org/dist}") ;;
    esac
    local fetched=0 candidate
    for candidate in "${candidates[@]}"; do
      if curl -fsSL --retry 2 --connect-timeout 15 --max-time 900 -o "$destination.part" "$candidate"; then
        if [ "$(shasum -a 256 "$destination.part" | cut -d' ' -f1)" = "$sha256" ]; then
          mv "$destination.part" "$destination"
          fetched=1
          break
        fi
        echo "checksum mismatch: $candidate" >&2
      fi
    done
    rm -f "$destination.part"
    if [ "$fetched" -ne 1 ]; then
      echo "cannot download $url" >&2
      echo "set GITHUB_PROXY / PYPI_MIRROR / NODE_MIRROR or seed apps/desktop/.desktop-build/downloads/$sha256 manually" >&2
      exit 1
    fi
  done
}

echo "[build] seeding primary runtime cache"
seed_primary_runtime

if [ "$SKIP_INSTALL" -ne 1 ]; then
  echo "[build] installing workspace dependencies"
  # CI=true skips git-hook installation, which fails on exFAT (fstat/lstat inode mismatch).
  CI=true pnpm install --frozen-lockfile --registry="$NPM_REGISTRY"
fi

export ELECTRON_MIRROR
export ELECTRON_CUSTOM_DIR='{{ version }}'
export DSH_DESKTOP_NPM_REGISTRY

mkdir -p apps/desktop/.desktop-build/logs
log="apps/desktop/.desktop-build/logs/fork-build-$(date +%Y%m%d-%H%M%S).log"
build_args=()
if [ -n "$BUILD_VERSION" ]; then
  build_args+=(--build-version "$BUILD_VERSION")
fi

status=1
for attempt in 1 2; do
  echo "[build] packaging mac-x64 (attempt $attempt, log: $log)"
  set +e
  pnpm run package:desktop:mac:x64:unsigned "${build_args[@]}" 2>&1 | tee "$log"
  status=${PIPESTATUS[0]}
  set -e
  [ "$status" -eq 0 ] && break
  if [ "$attempt" -lt 2 ] && grep -q ENOTEMPTY "$log"; then
    # exFAT intermittently reports ENOTEMPTY after a recursive remove; a clean retry succeeds.
    echo "[build] ENOTEMPTY from the filesystem; retrying once" >&2
    continue
  fi
  break
done

if [ "$status" -ne 0 ]; then
  echo "[build] packaging failed; see $log" >&2
  exit "$status"
fi

# The ! -name '._*' skips exFAT AppleDouble sidecars, which would otherwise match.
dmg=$(find apps/desktop/.desktop-build/targets/mac-x64/unsigned-artifacts -maxdepth 1 -name '*-mac-x64-unsigned.dmg' ! -name '._*' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1 || true)
[ -n "$dmg" ] || { echo "[build] packaging succeeded but no DMG was found" >&2; exit 1; }

shasum -a 256 "$dmg" | tee "$(dirname "$dmg")/SHA256SUMS.txt"
echo "[build] artifact: $dmg"
echo "[build] first launch is blocked by Gatekeeper; allow it in System Settings or run:"
echo "        xattr -dr com.apple.quarantine \"/Applications/DeepSeek Harness.app\""
