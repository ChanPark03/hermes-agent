#!/usr/bin/env bash
# Prove a user on main can reach this commit.
#
# For each supported Linux update route: install GENUINE upstream main the way a
# real user does, apply the route, and require the checkout to land on this
# commit with a working `hermes` afterwards.
#
# Nothing here is mocked. scripts/dev-sandbox.sh provides the fake Internet --
# a bubblewrap sandbox with no writable host mounts, a MITM proxy serving the
# canonical install.sh URL, and a git-upload-pack shim standing in for
# github.com -- so `install.sh` really installs uv, a managed Python, Node and
# the venv, cloning "github.com" over the ssh-first path a user hits.
#
# Routes (see docs/plans/2026-08-03-update-path-e2e-testing-plan.md):
#   update     `hermes update`
#   installer  re-running the curl one-liner over an existing checkout
#
# Usage:
#   tests/install/install-update-e2e.sh [--route update|installer|both] [--keep]
#
# Requires a CLEAN worktree: every dev-sandbox invocation re-derives fake main
# from the working copy, so uncommitted changes move the update target between
# the call that installs and the call that verifies.

set -euo pipefail

ROUTE=both
KEEP=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --route)
      [ "$#" -ge 2 ] || { echo 'error: --route needs a value' >&2; exit 1; }
      ROUTE="$2"; shift 2 ;;
    --keep) KEEP=true; shift ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "$ROUTE" in
  update|installer|both) ;;
  *) echo "error: --route must be update, installer, or both" >&2; exit 1 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Keep sandbox state out of the default .hermes-sandbox so a run never clobbers
# a developer's own sandbox. dev-sandbox.sh joins this onto the worktree root
# and feeds it to `tar --exclude`, so it MUST be a relative directory name.
SANDBOX_DIR_NAME=".hermes-sandbox-e2e"
export HERMES_DEV_SANDBOX_DIR="$SANDBOX_DIR_NAME"

SANDBOX_ROOT="$REPO_ROOT/$SANDBOX_DIR_NAME"
INSTALL_DIR="/home/hermes/.hermes/hermes-agent"   # user-level layout (sandbox default)
FAKE_REMOTE="/work/repos/hermes-agent.git"

# Installer transcripts live outside the sandbox root: the sandbox is recreated
# and (unless --keep) deleted, and these logs are the most useful artifact when
# a real install breaks. Created after the dirty check below, so that a log dir
# pointed inside the repo cannot be the thing that makes the tree dirty.
LOG_DIR="${HERMES_E2E_LOG_DIR:-$(mktemp -d -t hermes-install-e2e-logs.XXXXXX)}"

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# The sandbox's internal logs (fake-internet proxy, slirp) explain failures that
# happen BEFORE install.sh gets to say anything -- a TLS handshake the proxy
# rejected looks like a bare `curl: (35)` from outside. Copy them out where a CI
# artifact upload can find them, and echo the proxy log since it is the usual
# culprit.
collect_sandbox_logs() {
  local tag="$1" src="$SANDBOX_ROOT/root/logs" dest="$LOG_DIR/sandbox-$tag"
  [ -d "$src" ] || return 0
  mkdir -p "$dest"
  cp -a "$src/." "$dest/" 2>/dev/null || true
  if [ -s "$dest/proxy.log" ]; then
    echo "--- sandbox proxy.log (last 40 lines) ---" >&2
    tail -40 "$dest/proxy.log" >&2
  fi
}

# ── preflight ──────────────────────────────────────────────────────────────
# Prefer the `sandbox` wrapper from the Nix devShell: it supplies both the PATH
# (bwrap, slirp4netns, openssl, ...) and the DEV_SANDBOX_* variables the script
# needs -- notably DEV_SANDBOX_DYNAMIC_LINKER, without which it cannot find a
# glibc loader on NixOS. Off Nix, the script is the entry point and finds its
# dependencies on the system PATH.
if command -v sandbox >/dev/null 2>&1; then
  SANDBOX=(sandbox)
elif command -v bwrap >/dev/null 2>&1; then
  SANDBOX=("$REPO_ROOT/scripts/dev-sandbox.sh")
else
  fail 'no usable sandbox: enter the Nix devShell (for `sandbox`) or install bubblewrap'
fi

if [ -n "$(git status --porcelain)" ]; then
  printf '\033[1;31m✗ working tree is dirty:\033[0m\n' >&2
  git status --porcelain | sed 's/^/    /' >&2
  fail 'Every sandbox invocation re-snapshots the working copy into a new
  fake-main commit, so the update target would move mid-run. Commit or stash
  first. (If a path above is build or log output, it needs gitignoring or to
  live outside the repo.)'
fi

mkdir -p "$LOG_DIR"

if [ "$KEEP" = false ]; then
  trap 'rm -rf -- "$SANDBOX_ROOT"' EXIT INT TERM
fi
rm -rf -- "$SANDBOX_ROOT"

# ── helpers ────────────────────────────────────────────────────────────────
# Run the real install one-liner inside the sandbox. With --from-main the
# sandbox serves upstream main's installer and promotes THIS checkout to fake
# main afterwards, leaving the state a user is in when an update is waiting.
install_in_sandbox() {
  local what="$1" from_main="$2" log="$LOG_DIR/${3}.log"
  local args=(install --persistent)
  [ "$from_main" = true ] && args+=(--from-main)
  # Sandbox flags must precede `--`; the rest goes to install.sh.
  args+=(-- --skip-setup --skip-browser)

  if ! "${SANDBOX[@]}" "${args[@]}" >"$log" 2>&1; then
    echo "--- last 40 lines of $log ---" >&2
    tail -40 "$log" >&2
    collect_sandbox_logs "$3"
    fail "$what failed"
  fi
  grep -q 'Installation Complete' "$log" \
    || { tail -40 "$log" >&2; collect_sandbox_logs "$3"; \
         fail "$what did not report a completed install"; }
  ok "$what completed (log: $log)"
}

in_sandbox() { "${SANDBOX[@]}" --persistent bash -lc "$1"; }

# fake main's SHA is read fresh each time it is needed, never cached across a
# sandbox invocation: each invocation re-derives it from the worktree.
sandbox_target() { in_sandbox "git --git-dir=$FAKE_REMOTE rev-parse main" | tr -d '[:space:]'; }
sandbox_head()   { in_sandbox "cd $INSTALL_DIR && git rev-parse HEAD" | tr -d '[:space:]'; }

require_landed_on_target() {
  local what="$1" head target
  head="$(sandbox_head)"
  target="$(sandbox_target)"
  [ "$head" = "$target" ] || fail "$what left HEAD at $head, wanted $target"
  ok "$what landed on ${head:0:12}"
}

# The real smoke test: goes through the venv launcher and imports the app, so it
# fails if the venv, dependencies, or entry point are broken.
require_hermes_works() {
  local when="$1" out
  out="$(in_sandbox "hermes --version" 2>&1)" \
    || { printf '%s\n' "$out" >&2; fail "hermes --version failed $when"; }
  printf '%s\n' "$out" | sed 's/^/    /'
  ok "hermes runs $when"
}

# ── install upstream main once; both routes start from it ──────────────────
step 'installing genuine upstream main (real curl | install.sh: uv, Python, Node, venv)'
install_in_sandbox 'install of upstream main' true install

BASE="$(sandbox_head)"
TARGET="$(sandbox_target)"
[ -n "$BASE" ] || fail "could not read the installed commit"
[ "$BASE" != "$TARGET" ] \
  || fail "install landed on the update target ($BASE); base and target must differ"
ok "installed upstream main at ${BASE:0:12}; update target is ${TARGET:0:12}"
require_hermes_works 'after install'

reset_to_base() {
  in_sandbox "cd $INSTALL_DIR && git reset -q --hard $BASE" >/dev/null
  ok "checkout reset to base ${BASE:0:12}"
}

# ── route: hermes update ───────────────────────────────────────────────────
if [ "$ROUTE" = update ] || [ "$ROUTE" = both ]; then
  step 'ROUTE: hermes update'
  reset_to_base
  if ! in_sandbox "cd $INSTALL_DIR && hermes update --yes"; then
    fail 'hermes update failed'
  fi
  require_landed_on_target 'hermes update'
  require_hermes_works 'after hermes update'
fi

# ── route: installer re-run ────────────────────────────────────────────────
if [ "$ROUTE" = installer ] || [ "$ROUTE" = both ]; then
  step 'ROUTE: installer re-run over the existing checkout'
  reset_to_base
  # No --from-main: serves this worktree's installer and points fake main at
  # this checkout, which is what the re-run must land on.
  install_in_sandbox 'installer re-run' false reinstall
  require_landed_on_target 'installer re-run'
  require_hermes_works 'after installer re-run'
fi

printf '\n\033[1;32m✓ install/update E2E passed (route: %s)\033[0m\n' "$ROUTE"
[ "$KEEP" = true ] && echo "  sandbox kept at $SANDBOX_ROOT"
exit 0
