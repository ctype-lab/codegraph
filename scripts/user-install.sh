#!/usr/bin/env bash
#
# Install CodeGraph into the CURRENT USER's home — no sudo, no pacman, no
# system Node. Everything that is CodeGraph is built from THIS checkout's
# source; nothing is ever fetched from GitHub Releases.
#
#   what                          where it comes from
#   ----------------------------- ------------------------------------------
#   native extraction kernel      cargo build (scripts/build-kernel.sh)
#   app (dist/)                   tsc      (npm run build)
#   production deps               npm registry (normal dependency install)
#   Node runtime                  nodejs.org official tarball + SHASUMS256
#
# The npm thin-installer (scripts/npm-shim.js) and `codegraph upgrade`
# (src/upgrade/index.ts) are the only code paths that download a prebuilt
# CodeGraph from GitHub Releases. This script deliberately uses NEITHER.
#
# A system Node is used only to RUN tsc/npm during the build; the installed
# CLI never touches it. That matters: CodeGraph hard-exits on Node >= 25 (V8
# turboshaft WASM Zone OOM, issues #293/#298/#81), so the installed launcher
# always execs the vendored runtime.
#
# Usage:
#   scripts/user-install.sh                 # build + install to ~/.local
#   scripts/user-install.sh --prefix DIR    # install elsewhere
#   scripts/user-install.sh --skip-kernel   # reuse the staged prebuilt kernel
#   scripts/user-install.sh --uninstall     # remove what this script installed
#
# Layout (identical to scripts/build-bundle.sh's release bundle, so the kernel
# loader's `<up3>/kernel/codegraph-kernel.node` candidate resolves):
#
#   <prefix>/lib/codegraph/node                        vendored Node
#   <prefix>/lib/codegraph/bin/codegraph               launcher
#   <prefix>/lib/codegraph/lib/dist/…                  app
#   <prefix>/lib/codegraph/lib/node_modules/…          prod deps
#   <prefix>/lib/codegraph/lib/kernel/codegraph-kernel.node
#   <prefix>/bin/codegraph -> ../lib/codegraph/bin/codegraph
set -euo pipefail

# Keep in sync with NODE_VERSION in scripts/build-bundle.sh.
NODE_VERSION="${CODEGRAPH_NODE_VERSION:-v24.16.0}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${CODEGRAPH_PREFIX:-$HOME/.local}"
SKIP_KERNEL=0
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --prefix=*) PREFIX="${1#*=}"; shift ;;
    --skip-kernel) SKIP_KERNEL=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done

# Normalize to an absolute path — a relative --prefix would otherwise make
# BUNDLE depend on the cwd at each use site.
mkdir -p "$PREFIX"
PREFIX="$(cd "$PREFIX" && pwd)"

BUNDLE="$PREFIX/lib/codegraph"
LINK="$PREFIX/bin/codegraph"

if [ "$UNINSTALL" = 1 ]; then
  # Only remove the symlink if it actually points into our bundle — never
  # clobber an unrelated `codegraph` the user put on PATH themselves.
  if [ -L "$LINK" ] && [ "$(readlink -f "$LINK" 2>/dev/null)" = "$(readlink -f "$BUNDLE/bin/codegraph" 2>/dev/null)" ]; then
    rm -f "$LINK"
    echo "→ removed $LINK"
  elif [ -e "$LINK" ]; then
    echo "→ left $LINK alone (does not point at $BUNDLE)"
  fi
  if [ -d "$BUNDLE" ]; then
    rm -rf "$BUNDLE"
    echo "→ removed $BUNDLE"
  fi
  echo "done."
  exit 0
fi

case "$(uname -s)" in
  Linux) OSFAM=linux ;;
  Darwin) OSFAM=darwin ;;
  *) echo "error: unsupported OS $(uname -s) — use scripts/build-bundle.sh" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=x64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) echo "error: unsupported arch $(uname -m)" >&2; exit 1 ;;
esac
TARGET="${OSFAM}-${ARCH}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "[user-install] target=${TARGET} node=${NODE_VERSION} prefix=${PREFIX}"

# 1. Native kernel — built from source. Optional by design: the loader falls
#    back to the wasm pipeline, so a cargo failure downgrades, never blocks.
if [ "$SKIP_KERNEL" = 1 ]; then
  echo "[user-install] --skip-kernel: reusing whatever is staged in codegraph-kernel/prebuilds/"
else
  echo "[user-install] building native kernel from source (cargo)"
  ( cd "$ROOT" && npm run build:kernel ) || {
    echo "[user-install] warning: kernel build failed — installing without it (wasm path still works)" >&2
  }
fi
KERNEL_NODE="$ROOT/codegraph-kernel/prebuilds/${TARGET}/codegraph-kernel.node"

# 2. App — built from source. tsc writes its diagnostics to STDOUT, so the
#    build's output is captured and replayed on failure rather than sent to
#    /dev/null — otherwise a compile error surfaces as a silent exit.
echo "[user-install] building app (tsc)"
if ! ( cd "$ROOT" && npm run build ) >"$WORK/build.log" 2>&1; then
  echo "[user-install] error: app build failed" >&2
  tail -40 "$WORK/build.log" >&2
  exit 1
fi

# 3. Stage. Production deps are installed into the STAGE, not the repo, so this
#    never disturbs the checkout's dev node_modules.
STAGE="$WORK/codegraph"
mkdir -p "$STAGE/lib" "$STAGE/bin"
cp -R "$ROOT/dist" "$STAGE/lib/dist"
cp "$ROOT/package.json" "$ROOT/package-lock.json" "$STAGE/lib/"
echo "[user-install] installing production dependencies"
if ! ( cd "$STAGE/lib" && npm ci --omit=dev --ignore-scripts ) >"$WORK/npm.log" 2>&1; then
  echo "[user-install] error: production dependency install failed" >&2
  tail -40 "$WORK/npm.log" >&2
  exit 1
fi
rm -f "$STAGE/lib/package-lock.json"

if [ -f "$KERNEL_NODE" ]; then
  mkdir -p "$STAGE/lib/kernel"
  cp "$KERNEL_NODE" "$STAGE/lib/kernel/codegraph-kernel.node"
  echo "[user-install] native kernel included"
else
  echo "[user-install] no native kernel for ${TARGET} — using the wasm extraction path"
fi

# 4. Vendored Node runtime, verified against nodejs.org's own SHASUMS256.txt.
NODE_DIST="node-${NODE_VERSION}-${TARGET}"
echo "[user-install] downloading ${NODE_DIST}.tar.gz"
curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/${NODE_DIST}.tar.gz" -o "$WORK/node.tar.gz"
curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt" -o "$WORK/SHASUMS256.txt"
EXPECTED="$(awk -v f="${NODE_DIST}.tar.gz" '$2 == f { print $1 }' "$WORK/SHASUMS256.txt")"
[ -n "$EXPECTED" ] || { echo "error: ${NODE_DIST}.tar.gz not listed in SHASUMS256.txt" >&2; exit 1; }
ACTUAL="$( { sha256sum "$WORK/node.tar.gz" 2>/dev/null || shasum -a 256 "$WORK/node.tar.gz"; } | awk '{print $1}' )"
[ "$ACTUAL" = "$EXPECTED" ] || {
  echo "error: checksum mismatch for ${NODE_DIST}.tar.gz" >&2
  echo "  expected $EXPECTED" >&2
  echo "  actual   $ACTUAL" >&2
  exit 1
}
echo "[user-install] checksum ok"
tar -xzf "$WORK/node.tar.gz" -C "$WORK"
cp "$WORK/${NODE_DIST}/bin/node" "$STAGE/node"
chmod 755 "$STAGE/node"

# 5. Launcher. Resolves its own symlink chain so `<prefix>/bin/codegraph` finds
#    the real bundle dir. Flags mirror scripts/build-bundle.sh's launcher:
#    --liftoff-only keeps tree-sitter's WASM grammars off V8's turboshaft tier
#    (whose Zone arena OOMs the process); --disable-warning silences
#    node:sqlite's per-thread experimental notice; CODEGRAPH_HOST_PPID threads
#    the MCP host's pid to the orphan watchdog.
cat > "$STAGE/bin/codegraph" <<'LAUNCH'
#!/bin/sh
SELF="$0"
while [ -L "$SELF" ]; do
  target="$(readlink "$SELF")"
  case "$target" in
    /*) SELF="$target" ;;
    *) SELF="$(dirname "$SELF")/$target" ;;
  esac
done
DIR="$(cd "$(dirname "$SELF")/.." && pwd)"
CODEGRAPH_HOST_PPID="${CODEGRAPH_HOST_PPID:-$PPID}"
export CODEGRAPH_HOST_PPID
exec "$DIR/node" --liftoff-only --disable-warning=ExperimentalWarning "$DIR/lib/dist/bin/codegraph.js" "$@"
LAUNCH
chmod +x "$STAGE/bin/codegraph"

# 6. Swap into place. Move the old bundle aside first and only delete it once
#    the new one has landed, so an interrupted install can't leave a half-tree.
mkdir -p "$PREFIX/lib" "$PREFIX/bin"
OLD=""
if [ -e "$BUNDLE" ]; then
  OLD="${BUNDLE}.old.$$"
  mv "$BUNDLE" "$OLD"
fi
if mv "$STAGE" "$BUNDLE"; then
  [ -n "$OLD" ] && rm -rf "$OLD"
else
  [ -n "$OLD" ] && mv "$OLD" "$BUNDLE"
  echo "error: failed to install into $BUNDLE" >&2
  exit 1
fi

PREV=""
if [ -L "$LINK" ]; then
  PREV="$(readlink "$LINK")"
elif [ -e "$LINK" ]; then
  PREV="(regular file, overwritten)"
fi
ln -sfn "$BUNDLE/bin/codegraph" "$LINK"

echo
echo "✓ installed to $BUNDLE"
echo "  launcher: $LINK"
[ -n "$PREV" ] && echo "  replaced: $PREV"
echo "  node:     $("$BUNDLE/node" --version)"
echo "  version:  $("$LINK" --version 2>/dev/null | tail -1)"
echo
RESOLVED="$(command -v codegraph || true)"
if [ "$RESOLVED" != "$LINK" ]; then
  echo "! PATH resolves 'codegraph' to ${RESOLVED:-(nothing)}, not $LINK"
  echo "  put $PREFIX/bin earlier in PATH to use this install."
fi
echo "To remove:  $0 --uninstall"
