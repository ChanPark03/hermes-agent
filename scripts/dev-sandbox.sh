#!/usr/bin/env bash
# Run a command in a disposable, network-isolated fake Internet.
#
# The command runs in private user, mount, PID, and network namespaces (the
# user+net pair from `unshare`, the rest from bubblewrap — see the namespace
# plan near the bottom).  Its only writable filesystem is SANDBOX_ROOT.
# HTTP(S) goes to a local static MITM proxy. github.com SSH uses a
# sandbox-local git-upload-pack shim; neither transport can reach the host
# network.

set -euo pipefail

# Stage 2: we are already inside the user+network namespaces that stage 1
# created, at the target uid. bwrap therefore does NOT create a userns here —
# it only needs the mount/pid namespaces. (`unshare --user` grants its creator
# full capabilities in the new userns regardless of the uid it maps to, which
# is what lets bwrap mount as a non-root uid.)
if [ "${1:-}" = "--internal-sandbox" ]; then
  shift
  : "${DEV_SANDBOX_ROOT:?missing DEV_SANDBOX_ROOT}"
  : "${DEV_SANDBOX_BASH:?missing DEV_SANDBOX_BASH}"
  : "${DEV_SANDBOX_INTERACTIVE:?missing DEV_SANDBOX_INTERACTIVE}"
  : "${DEV_SANDBOX_USER:?missing DEV_SANDBOX_USER}"
  : "${DEV_SANDBOX_HOME:?missing DEV_SANDBOX_HOME}"

  # Announce our pid so stage 1 can point slirp4netns at these namespaces,
  # then hold until it reports the network is up.
  slirp_ready="$DEV_SANDBOX_ROOT/root/logs/slirp.ready"
  printf '%s\n' "$$" > "$DEV_SANDBOX_ROOT/root/logs/sandbox.pid"
  for _ in $(seq 1 200); do
    [ -s "$slirp_ready" ] && break
    sleep 0.05
  done
  if [ ! -s "$slirp_ready" ]; then
    echo 'error: timed out waiting for sandbox network setup' >&2
    cat "$DEV_SANDBOX_ROOT/root/logs/slirp.log" >&2 || true
    exit 1
  fi

  # The sandbox HOME is /root for a root install and /home/<user> for a
  # user-level one. Only the latter needs its parent created first; --dir /
  # is not a thing bwrap accepts.
  home_mounts=()
  home_parent="$(dirname "$DEV_SANDBOX_HOME")"
  if [ "$home_parent" != / ]; then
    home_mounts+=(--dir "$home_parent")
  fi
  home_mounts+=(--bind "$DEV_SANDBOX_ROOT/home" "$DEV_SANDBOX_HOME")

  node_env=()
  if [ -n "${DEV_SANDBOX_NODE_DIR:-}" ]; then
    node_env+=(--setenv npm_config_nodedir "$DEV_SANDBOX_NODE_DIR")
  fi
  electron_env=()
  if [ -n "${DEV_SANDBOX_ELECTRON_LD_LIBRARY_PATH:-}" ]; then
    electron_env+=(
      --setenv LD_LIBRARY_PATH "$DEV_SANDBOX_ELECTRON_LD_LIBRARY_PATH"
      --setenv HERMES_DESKTOP_DISABLE_GPU 1
    )
  fi
  gui_mounts=()
  if [ -n "${DEV_SANDBOX_WAYLAND_SOCKET:-}" ]; then
    runtime_dir="${DEV_SANDBOX_XDG_RUNTIME_DIR:?missing DEV_SANDBOX_XDG_RUNTIME_DIR}"
    runtime_parent="$(dirname "$runtime_dir")"
    runtime_grandparent="$(dirname "$runtime_parent")"
    gui_mounts+=(
      --dir "$runtime_grandparent"
      --dir "$runtime_parent"
      --dir "$runtime_dir"
      --bind "$DEV_SANDBOX_WAYLAND_SOCKET" "$DEV_SANDBOX_WAYLAND_SOCKET"
      --setenv XDG_RUNTIME_DIR "$runtime_dir"
      --setenv WAYLAND_DISPLAY "${DEV_SANDBOX_WAYLAND_DISPLAY:?missing DEV_SANDBOX_WAYLAND_DISPLAY}"
    )
  fi

  # How the sandbox gets a usable runtime, and where its own shims go.
  #
  # On Nix, every binary lives under /nix/store, so the sandbox can own /bin,
  # /lib64 and /usr/bin outright and fill them with symlinks into the store.
  #
  # Elsewhere the runtime IS /usr, /bin, /lib, /lib64 -- so binding the
  # sandbox's near-empty versions over them hides the real thing, and bwrap
  # dies with `execvp /usr/bin/bash: No such file or directory`. Keep the host
  # directories read-only and override only the individual files we shim.
  runtime_mounts=()
  shim_mounts=()
  if [ -d /nix ] && [[ "$(readlink -f "$DEV_SANDBOX_BASH")" == /nix/* ]]; then
    runtime_mounts+=(--ro-bind /nix /nix)
    shim_mounts+=(
      --dir /usr
      --dir /bin
      --dir /lib64
      --bind "$DEV_SANDBOX_ROOT/root/bin" /bin
      --bind "$DEV_SANDBOX_ROOT/root/lib64" /lib64
      --bind "$DEV_SANDBOX_ROOT/root/usr/bin" /usr/bin
    )
  else
    for path in /usr /bin /sbin /lib /lib64; do
      [ -e "$path" ] && runtime_mounts+=(--ro-bind "$path" "$path")
    done
    # The git-upload-pack shim standing in for github.com is the only file that
    # must beat the host's copy; sh/ls/env are already there for real.
    shim_mounts+=(--bind "$DEV_SANDBOX_ROOT/root/usr/bin/ssh" /usr/bin/ssh)
  fi

  exec bwrap \
    --unshare-pid \
    --die-with-parent --proc /proc --dev /dev --tmpfs /tmp \
    "${gui_mounts[@]}" \
    "${runtime_mounts[@]}" \
    --bind "$DEV_SANDBOX_ROOT/root" /work \
    "${shim_mounts[@]}" \
    --bind "$DEV_SANDBOX_ROOT/root/usr/local" /usr/local \
    "${home_mounts[@]}" \
    --bind "$DEV_SANDBOX_ROOT/etc" /etc \
    --chdir /work/repo \
    --clearenv \
    --setenv PATH "$DEV_SANDBOX_HOME/.local/bin:/usr/local/bin:/usr/bin:$PATH" \
    --setenv HOME "$DEV_SANDBOX_HOME" \
    --setenv USER "$DEV_SANDBOX_USER" \
    --setenv LOGNAME "$DEV_SANDBOX_USER" \
    --setenv CURL_CA_BUNDLE /work/certs/ca.pem \
    --setenv SSL_CERT_FILE /work/certs/ca.pem \
    --setenv GIT_SSL_CAINFO /work/certs/ca.pem \
    --setenv NODE_EXTRA_CA_CERTS /work/certs/real-ca.pem \
    --setenv HTTP_PROXY http://127.0.0.1:8080 \
    --setenv HTTPS_PROXY http://127.0.0.1:8080 \
    --setenv ALL_PROXY http://127.0.0.1:8080 \
    --setenv NO_PROXY '' \
    --setenv DEV_SANDBOX_INTERACTIVE "$DEV_SANDBOX_INTERACTIVE" \
    --setenv ELECTRON_DISABLE_SANDBOX 1 \
    "${node_env[@]}" \
    "${electron_env[@]}" \
    -- "$DEV_SANDBOX_BASH" -ceu '
      python3 /work/proxy.py /work/http /work/certs /work/certs/real-ca.pem >/work/logs/proxy.log 2>&1 &
      proxy_pid=$!
      cleanup() {
        kill "$proxy_pid" 2>/dev/null || true
        wait "$proxy_pid" 2>/dev/null || true
      }
      trap cleanup EXIT INT TERM
      # Bash opens /dev/tcp itself, so the readiness probe needs no netcat --
      # one less binary the sandbox has to find on the host (GitHub runners
      # ship no `nc`).
      proxy_up() { (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null; }
      for _ in $(seq 1 100); do
        proxy_up && break
        sleep 0.05
      done
      if ! proxy_up; then
        echo "error: the sandbox fake-internet proxy never came up" >&2
        cat /work/logs/proxy.log >&2 || true
        exit 1
      fi
      "$@"
    ' sandbox-command "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_help() {
  cat <<'EOF'
Usage: dev-sandbox.sh [options] [--] <command...>
       dev-sandbox.sh install [options] [--] [installer arguments...]

Run COMMAND in a throwaway chroot-like bubblewrap sandbox. The sandbox has no
writable host mounts: only its own root, mounted at /work, is writable.

Options:
  --persistent          Keep the whole sandbox under .hermes-sandbox/.
  --delete              Delete the persistent sandbox (asks first).
  --root                Install as uid 0 with the root FHS layout: code in
                        /usr/local/lib/hermes-agent, command in
                        /usr/local/bin. Default is the user-level layout.
  --from DIR            One-time copy of DIR into the sandbox's $HOME.
                        Existing persistent sandboxes are never overwritten.
  --http-root DIR       Copy DIR into the fake web server root for this run.
                        Requests map to DIR/<host>/<path>; no URL is forwarded.
  --installer PATH      With `install`, serve PATH at the canonical install.sh
                        URL. Default: scripts/install.sh in this worktree.
  --from-main           With `install`, fetch the real upstream main installer
                        and repository, then advance fake main to this folder
                        after a successful install for update testing.
  -h, --help            Show this help.

Option order matters: every option above is consumed by THIS script, and
parsing stops at the first argument it does not recognize. Everything from
that point on is passed through to the command (or, with `install`, to the
installer). Put sandbox options first and separate installer arguments with
`--`, otherwise they arrive here and fail:

  # WRONG — --from-main reaches install.sh, which rejects it
  scripts/dev-sandbox.sh install --skip-setup --from-main

  # RIGHT
  scripts/dev-sandbox.sh install --from-main -- --skip-setup

Install layout: `install.sh` picks its layout from `id -u` alone, so uid is what
separates the two real-world Linux installs. By default the sandbox runs as an
unprivileged `hermes` user, giving the layout most people have —
$HERMES_HOME/hermes-agent plus a ~/.local/bin launcher. Pass --root for the FHS
one. Both are worth testing; they differ in more than paths (root also relocates
uv's Python to /usr/local/share for world-readability).

The fake web server signs certificates with a CA trusted only inside this
sandbox. HTTP_PROXY/HTTPS_PROXY send fixture URLs there first; other HTTP(S)
requests pass through the sandbox's rootless outbound network. SSH to github.com
runs a sandbox-local upload-pack shim, never your SSH config, agent,
known-hosts file, or authorized keys.

Fake github main always comes from this folder. If it has staged, unstaged, or
non-ignored untracked changes, the sandbox warns and creates a temporary local
commit containing them; it never stages or commits the real worktree.

Examples:
  # create a sandbox, install this branch as `main`, and then drop to a shell,
  # skipping `hermes setup` & the browser tools for speed.
  scripts/dev-sandbox.sh install --persistent -- --skip-setup --skip-browser

  # Install the official upstream main. You're dropped into a shell where
  # you can run `hermes update`.
  scripts/dev-sandbox.sh install --persistent --from-main

EOF
}

PERSISTENT=false
DELETE=false
RUN_AS_USER=true
SEED_DIR=""
HTTP_ROOT=""
INSTALL_SHORTCUT=false
INSTALLER_PATH=""
INSTALL_FROM_MAIN=false

if [ "${1:-}" = install ]; then
  INSTALL_SHORTCUT=true
  shift
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --persistent) PERSISTENT=true; shift ;;
    --delete) DELETE=true; shift ;;
    --root) RUN_AS_USER=false; shift ;;
    --user) RUN_AS_USER=true; shift ;;   # the default; accepted for symmetry
    --from)
      [ "$#" -ge 2 ] || { echo 'error: --from needs a directory' >&2; exit 1; }
      SEED_DIR="$2"; shift 2 ;;
    --http-root)
      [ "$#" -ge 2 ] || { echo 'error: --http-root needs a directory' >&2; exit 1; }
      HTTP_ROOT="$2"; shift 2 ;;
    --installer)
      [ "$#" -ge 2 ] || { echo 'error: --installer needs a file' >&2; exit 1; }
      INSTALLER_PATH="$2"; shift 2 ;;
    --from-main) INSTALL_FROM_MAIN=true; shift ;;
    --from=*|--http-root=*|--installer=*)
      key="${1%%=*}"; value="${1#*=}"
      [ -n "$value" ] || { echo "error: $key needs a value" >&2; exit 1; }
      case "$key" in
        --from) SEED_DIR="$value" ;;
        --http-root) HTTP_ROOT="$value" ;;
        --installer) INSTALLER_PATH="$value" ;;
      esac
      shift ;;
    -h|--help) print_help; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [ "$INSTALL_SHORTCUT" = false ] && [ "$#" -eq 0 ]; then
  print_help >&2
  exit 1
fi

if [ -n "$INSTALLER_PATH" ] && [ "$INSTALL_SHORTCUT" = false ]; then
  echo 'error: --installer is only valid with the install shortcut' >&2
  exit 1
fi
if [ "$INSTALL_FROM_MAIN" = true ] && [ "$INSTALL_SHORTCUT" = false ]; then
  echo 'error: --from-main is only valid with the install shortcut' >&2
  exit 1
fi
if [ "$INSTALL_FROM_MAIN" = true ] && [ -n "$INSTALLER_PATH" ]; then
  echo 'error: --from-main and --installer cannot be combined' >&2
  exit 1
fi

for dir in "$SEED_DIR" "$HTTP_ROOT"; do
  [ -z "$dir" ] || [ -d "$dir" ] || { echo "error: directory '$dir' does not exist" >&2; exit 1; }
done

GIT_ROOT="${HERMES_SANDBOX_SOURCE_ROOT:-$(git rev-parse --show-toplevel)}"
GIT_ROOT="$(cd "$GIT_ROOT" && pwd)"
if [ "$INSTALL_SHORTCUT" = true ] && [ "$INSTALL_FROM_MAIN" = false ] && [ -z "$INSTALLER_PATH" ]; then
  INSTALLER_PATH="$GIT_ROOT/scripts/install.sh"
fi
if [ -n "$INSTALLER_PATH" ] && [ ! -f "$INSTALLER_PATH" ]; then
  echo "error: installer '$INSTALLER_PATH' does not exist" >&2
  exit 1
fi
COMMIT="$(git -C "$GIT_ROOT" rev-parse --verify 'HEAD^{commit}')" || {
  echo "error: current folder has no HEAD commit" >&2
  exit 1
}
SANDBOX_DIR_NAME="${HERMES_DEV_SANDBOX_DIR:-.hermes-sandbox}"
PERSISTENT_ROOT="$GIT_ROOT/$SANDBOX_DIR_NAME"

if [ "$DELETE" = true ]; then
  if [ ! -d "$PERSISTENT_ROOT" ]; then
    echo "[sandbox] nothing to delete at $PERSISTENT_ROOT" >&2
    exit 0
  fi
  read -r -p "[sandbox] delete $PERSISTENT_ROOT? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) rm -rf -- "$PERSISTENT_ROOT" ;;
    *) echo '[sandbox] aborted' >&2; exit 1 ;;
  esac
  exit 0
fi

if [ "$PERSISTENT" = true ]; then
  SANDBOX_ROOT="$PERSISTENT_ROOT"
else
  SANDBOX_ROOT="$(mktemp -d -t hermes-sandbox.XXXXXX)"
  cleanup() { chmod -R u+w "$SANDBOX_ROOT"; rm -rf -- "$SANDBOX_ROOT"; }
  trap cleanup EXIT INT TERM
fi

mkdir -p "$SANDBOX_ROOT"/{root,home,etc}
UPSTREAM_REPO=""
UPSTREAM_COMMIT=""
if [ "$INSTALL_FROM_MAIN" = true ]; then
  echo '[sandbox] fetching real upstream main for installer/update test' >&2
  UPSTREAM_REPO="$(mktemp -d -t hermes-sandbox-upstream.XXXXXX)"
  git -C "$UPSTREAM_REPO" init -q
  if ! git -C "$UPSTREAM_REPO" fetch -q https://github.com/NousResearch/hermes-agent.git refs/heads/main; then
    rm -rf -- "$UPSTREAM_REPO"
    echo 'error: failed to fetch real upstream main' >&2
    exit 1
  fi
  UPSTREAM_COMMIT="$(git -C "$UPSTREAM_REPO" rev-parse FETCH_HEAD)"
fi
if [ ! -e "$SANDBOX_ROOT/root/repo/.sandbox-source" ]; then
  mkdir -p "$SANDBOX_ROOT/root/repo"
  # Persistent roots live under the worktree, so copying with cp would recurse
  # into the sandbox itself. tar also lets us exclude a worktree's .git file,
  # which can point at the host's shared worktree metadata.
  tar -C "$GIT_ROOT" --exclude='./.git' --exclude="./$SANDBOX_DIR_NAME" -cf - . \
    | tar -C "$SANDBOX_ROOT/root/repo" -xf -
  : > "$SANDBOX_ROOT/root/repo/.sandbox-source"
fi

if [ -n "$SEED_DIR" ] && [ ! -e "$SANDBOX_ROOT/.seeded" ]; then
  echo "[sandbox] seeding home from $SEED_DIR" >&2
  cp -a "$SEED_DIR/." "$SANDBOX_ROOT/home/"
  : > "$SANDBOX_ROOT/.seeded"
fi

rm -rf "$SANDBOX_ROOT/root/http"
mkdir -p "$SANDBOX_ROOT/root/http"
if [ -n "$HTTP_ROOT" ]; then
  cp -a "$HTTP_ROOT/." "$SANDBOX_ROOT/root/http/"
fi
if [ "$INSTALL_SHORTCUT" = true ]; then
  mkdir -p "$SANDBOX_ROOT/root/http/hermes-agent.nousresearch.com"
  if [ "$INSTALL_FROM_MAIN" = true ]; then
    git -C "$UPSTREAM_REPO" show "$UPSTREAM_COMMIT:scripts/install.sh" \
      > "$SANDBOX_ROOT/root/http/hermes-agent.nousresearch.com/install.sh"
  else
    cp -a "$INSTALLER_PATH" "$SANDBOX_ROOT/root/http/hermes-agent.nousresearch.com/install.sh"
  fi
  set -- bash -c '
    set +e
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- "$@"
    install_status=$?
    if [ "$install_status" -eq 0 ] && [ -f /work/promote-main ]; then
      next_main=$(cat /work/promote-main)
      if git --git-dir=/work/repos/hermes-agent.git update-ref refs/heads/main "$next_main"; then
        rm -f /work/promote-main
        printf "[sandbox] fake main advanced to this folder for update testing\n" >&2
      else
        printf "[sandbox] failed to advance fake main after install\n" >&2
        install_status=1
      fi
    fi
    if [ "$DEV_SANDBOX_INTERACTIVE" = true ]; then
      printf "\n[sandbox] installer exited %s; entering sandbox shell\n" "$install_status" >&2
      exec </dev/tty >/dev/tty 2>&1
      exec bash -i
    fi
    exit "$install_status"
  ' sandbox-installer "$@"
fi

mkdir -p "$SANDBOX_ROOT/root"/{bin,certs,lib64,logs,repos,ssh,usr/bin,usr/local}
REAL_CA_CERT="${DEV_SANDBOX_REAL_CA_CERT:-}"
if [ -z "$REAL_CA_CERT" ]; then
  for candidate in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do
    if [ -f "$candidate" ]; then
      REAL_CA_CERT="$candidate"
      break
    fi
  done
fi
if [ ! -f "$REAL_CA_CERT" ]; then
  echo 'error: no system CA bundle found for outbound sandbox HTTPS' >&2
  exit 1
fi
if [ ! -f "$SANDBOX_ROOT/root/certs/real-ca.pem" ]; then
  cp "$REAL_CA_CERT" "$SANDBOX_ROOT/root/certs/real-ca.pem"
fi
printf 'nameserver 10.0.2.3\n' > "$SANDBOX_ROOT/etc/resolv.conf"
SANDBOX_SHELL="$(command -v bash)"
DYNAMIC_LINKER="${DEV_SANDBOX_DYNAMIC_LINKER:-}"
if [ -z "$DYNAMIC_LINKER" ]; then
  # Nix store first: NixOS also ships a /lib64/ld-linux-x86-64.so.2 compat stub,
  # so probing FHS paths first would quietly switch which loader a bare script
  # invocation uses on this host. Globs that match nothing expand to themselves,
  # so every candidate is -f tested. The FHS paths cover Debian/Ubuntu (where
  # the loader is under /lib64 or a multiarch /lib dir), which is what CI runs.
  for candidate in \
    /nix/store/*-glibc-*/lib/ld-linux-*.so.* \
    /lib64/ld-linux-x86-64.so.2 \
    /lib/ld-linux-aarch64.so.1 \
    /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
    /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1
  do
    if [ -f "$candidate" ]; then
      DYNAMIC_LINKER="$candidate"
      break
    fi
  done
fi
if [ ! -f "$DYNAMIC_LINKER" ]; then
  echo 'error: no glibc dynamic linker found for sandboxed release binaries' >&2
  echo '       Set DEV_SANDBOX_DYNAMIC_LINKER to its path.' >&2
  exit 1
fi
ln -sf "$SANDBOX_SHELL" "$SANDBOX_ROOT/root/bin/sh"
ln -sf "$(command -v ls)" "$SANDBOX_ROOT/root/bin/ls"
ln -sf "$(command -v env)" "$SANDBOX_ROOT/root/usr/bin/env"
ln -sf "$DYNAMIC_LINKER" "$SANDBOX_ROOT/root/lib64/$(basename "$DYNAMIC_LINKER")"
# Identity inside the sandbox. install.sh chooses its layout from `id -u`
# alone (see resolve_install_layout), so the uid here is what decides between
# the root FHS install and a user-level one.
if [ "$RUN_AS_USER" = true ]; then
  SANDBOX_UID=1000
  SANDBOX_GID=1000
  SANDBOX_USER=hermes
  SANDBOX_HOME=/home/hermes
else
  SANDBOX_UID=0
  SANDBOX_GID=0
  SANDBOX_USER=root
  SANDBOX_HOME=/root
fi
{
  printf 'root:x:0:0:Sandbox Root:/root:%s\n' "$SANDBOX_SHELL"
  if [ "$RUN_AS_USER" = true ]; then
    printf '%s:x:%s:%s:Sandbox User:%s:%s\n' \
      "$SANDBOX_USER" "$SANDBOX_UID" "$SANDBOX_GID" "$SANDBOX_HOME" "$SANDBOX_SHELL"
  fi
} > "$SANDBOX_ROOT/etc/passwd"
{
  printf 'root:x:0:\n'
  if [ "$RUN_AS_USER" = true ]; then
    printf '%s:x:%s:\n' "$SANDBOX_USER" "$SANDBOX_GID"
  fi
} > "$SANDBOX_ROOT/etc/group"
# A user-level install writes the `hermes` launcher to ~/.local/bin and the
# checkout to $HERMES_HOME; both live under the sandbox HOME, which is bound
# from $SANDBOX_ROOT/home. bwrap maps our real uid to $SANDBOX_UID, so the
# host-side ownership of that directory is what the sandbox sees as its own.
printf 'hosts: files dns\n' > "$SANDBOX_ROOT/etc/nsswitch.conf"
printf '127.0.0.1 localhost\n' > "$SANDBOX_ROOT/etc/hosts"

SOURCE_REPO="$GIT_ROOT"
SOURCE_REF="$COMMIT"
SNAPSHOT_REPO=""
FAKE_REPO="$SANDBOX_ROOT/root/repos/hermes-agent.git"
git -C "$SANDBOX_ROOT/root/repos" init --bare -q hermes-agent.git
if [ "$INSTALL_FROM_MAIN" = true ]; then
  git --git-dir="$FAKE_REPO" fetch -q --force "$UPSTREAM_REPO" \
    "$UPSTREAM_COMMIT:refs/heads/main"
fi
if [ -n "$(git -C "$GIT_ROOT" status --porcelain)" ]; then
  echo '[sandbox] warning: current folder is dirty; creating a temporary fake commit for main' >&2
  SNAPSHOT_REPO="$(mktemp -d -t hermes-sandbox-snapshot.XXXXXX)"
  git -C "$SNAPSHOT_REPO" init -q
  git -C "$SNAPSHOT_REPO" fetch -q "$GIT_ROOT" "$COMMIT"
  git -C "$SNAPSHOT_REPO" config user.name 'Hermes sandbox'
  git -C "$SNAPSHOT_REPO" config user.email 'sandbox@invalid'
  GIT_DIR="$SNAPSHOT_REPO/.git" GIT_WORK_TREE="$GIT_ROOT" git read-tree "$COMMIT"
  GIT_DIR="$SNAPSHOT_REPO/.git" GIT_WORK_TREE="$GIT_ROOT" \
    git add -A -- .
  SNAPSHOT_TREE="$(GIT_DIR="$SNAPSHOT_REPO/.git" git write-tree)"
  SNAPSHOT_PARENT="$COMMIT"
  if EXISTING_MAIN="$(git --git-dir="$FAKE_REPO" rev-parse --verify refs/heads/main 2>/dev/null)"; then
    git -C "$SNAPSHOT_REPO" fetch -q "$FAKE_REPO" "$EXISTING_MAIN"
    SNAPSHOT_PARENT="$EXISTING_MAIN"
  fi
  SOURCE_REF="$(GIT_DIR="$SNAPSHOT_REPO/.git" git commit-tree "$SNAPSHOT_TREE" -p "$SNAPSHOT_PARENT" \
    -m 'sandbox snapshot of dirty worktree')"
  SOURCE_REPO="$SNAPSHOT_REPO"
fi

if [ "$INSTALL_FROM_MAIN" = true ]; then
  git --git-dir="$FAKE_REPO" fetch -q --force "$SOURCE_REPO" \
    "$SOURCE_REF:refs/hermes-sandbox/next"
  printf '%s\n' "$SOURCE_REF" > "$SANDBOX_ROOT/root/promote-main"
else
  git --git-dir="$FAKE_REPO" fetch -q --force "$SOURCE_REPO" \
    "$SOURCE_REF:refs/heads/main"
fi
git --git-dir="$FAKE_REPO" symbolic-ref HEAD refs/heads/main
if [ -n "$SNAPSHOT_REPO" ]; then
  rm -rf -- "$SNAPSHOT_REPO"
fi
if [ -n "$UPSTREAM_REPO" ]; then
  rm -rf -- "$UPSTREAM_REPO"
fi

if [ ! -f "$SANDBOX_ROOT/root/certs/ca.pem" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj '/CN=Hermes dev sandbox CA' \
    -keyout "$SANDBOX_ROOT/root/certs/ca.key" \
    -out "$SANDBOX_ROOT/root/certs/ca.pem" >/dev/null 2>&1
fi
GIT_UPLOAD_PACK="$(command -v git-upload-pack)"
printf '#!%s\nexec %q /work/repos/hermes-agent.git\n' "$SANDBOX_SHELL" "$GIT_UPLOAD_PACK" \
  > "$SANDBOX_ROOT/root/usr/bin/ssh"
chmod 700 "$SANDBOX_ROOT/root/usr/bin/ssh"

cat > "$SANDBOX_ROOT/root/proxy.py" <<'PY'
import pathlib, socket, ssl, subprocess, sys, threading
from urllib.parse import unquote, urlsplit

ROOT, CERTS, REAL_CA = map(pathlib.Path, sys.argv[1:])

def read_request(conn):
    data = b""
    while b"\r\n\r\n" not in data and len(data) < 65536:
        part = conn.recv(4096)
        if not part:
            return b""
        data += part
    return data

def cert_for(host):
    safe = ''.join(char if char.isalnum() or char in '.-' else '_' for char in host)
    cert, key = CERTS / f'{safe}.pem', CERTS / f'{safe}.key'
    if not cert.exists():
        csr = CERTS / f'{safe}.csr'
        subprocess.run(['openssl', 'req', '-newkey', 'rsa:2048', '-nodes',
                        '-subj', f'/CN={host}', '-addext', f'subjectAltName=DNS:{host}',
                        '-keyout', str(key), '-out', str(csr)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(['openssl', 'x509', '-req', '-days', '2', '-in', str(csr),
                        '-CA', str(CERTS / 'ca.pem'), '-CAkey', str(CERTS / 'ca.key'),
                        '-CAcreateserial', '-copy_extensions', 'copy', '-out', str(cert)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return cert, key

def file_for(host, target):
    path = urlsplit(target).path or '/'
    parts = pathlib.PurePosixPath(unquote(path)).parts
    if '..' in parts:
        return None
    candidate = ROOT / host / pathlib.PurePosixPath(*[part for part in parts if part != '/'])
    if candidate.is_dir():
        candidate /= 'index.html'
    return candidate if candidate.is_file() else None

def respond_fixture(conn, found):
    body = found.read_bytes()
    header = b'HTTP/1.1 200 OK\r\n'
    conn.sendall(header + f'Content-Length: {len(body)}\r\nConnection: close\r\n\r\n'.encode() + body)

def close_request(request, target=None):
    headers, separator, body = request.partition(b'\r\n\r\n')
    lines = headers.split(b'\r\n')
    if target is not None:
        method, _, version = lines[0].split(b' ', 2)
        lines[0] = b' '.join((method, target.encode(), version))
    lines = [line for line in lines if not line.lower().startswith(b'proxy-connection:')]
    lines.append(b'Connection: close')
    return b'\r\n'.join(lines) + separator + body

def relay(source, destination):
    while True:
        chunk = source.recv(65536)
        if not chunk:
            return
        destination.sendall(chunk)

def forward_https(conn, host, port, request):
    context = ssl.create_default_context(cafile=str(REAL_CA))
    with socket.create_connection((host, port), timeout=30) as raw:
        with context.wrap_socket(raw, server_hostname=host) as upstream:
            upstream.sendall(close_request(request))
            relay(upstream, conn)

def forward_http(conn, host, port, request, target):
    parsed = urlsplit(target)
    path = parsed.path or '/'
    if parsed.query:
        path += f'?{parsed.query}'
    with socket.create_connection((host, port), timeout=30) as upstream:
        upstream.sendall(close_request(request, path))
        relay(upstream, conn)

def handle_request(conn):
    with conn:
        request = read_request(conn)
        if not request:
            return
        line = request.split(b'\r\n', 1)[0].decode('iso-8859-1')
        method, target, _ = line.split(' ', 2)
        if method.upper() == 'CONNECT':
            host, _, port_text = target.rpartition(':')
            port = int(port_text or '443')
            conn.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
            cert, key = cert_for(host)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            with context.wrap_socket(conn, server_side=True) as tls:
                nested = read_request(tls)
                if nested:
                    nested_target = nested.split(b'\r\n', 1)[0].decode('iso-8859-1').split(' ', 2)[1]
                    found = file_for(host, nested_target)
                    if found is not None:
                        respond_fixture(tls, found)
                    else:
                        forward_https(tls, host, port, nested)
            return
        parsed = urlsplit(target)
        host = parsed.hostname
        if not host:
            for header in request.split(b'\r\n')[1:]:
                if header.lower().startswith(b'host:'):
                    host = header.split(b':', 1)[1].strip().decode().split(':', 1)[0]
                    break
        host = host or 'unknown'
        found = file_for(host, target)
        if found is not None:
            respond_fixture(conn, found)
        else:
            forward_http(conn, host, parsed.port or 80, request, target)

def handle(conn):
    try:
        handle_request(conn)
    except Exception as error:
        print(f'proxy request failed: {error!r}', file=sys.stderr, flush=True)

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('127.0.0.1', 8080))
    server.listen()
    while True:
        conn, _ = server.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY

if [ "$INSTALL_FROM_MAIN" = true ]; then
  echo "[sandbox] fake main: real upstream main ($UPSTREAM_COMMIT)" >&2
  echo "[sandbox] prepared update: current folder ($SOURCE_REF)" >&2
else
  echo "[sandbox] fake main: current folder ($SOURCE_REF)" >&2
fi
echo "[sandbox] root: $SANDBOX_ROOT" >&2
echo "[sandbox] http root: $SANDBOX_ROOT/root/http" >&2
if [ "$RUN_AS_USER" = true ]; then
  echo "[sandbox] identity: $SANDBOX_USER (uid $SANDBOX_UID) — installs are user-level under $SANDBOX_HOME" >&2
else
  echo '[sandbox] identity: root (uid 0) — installs use the /usr/local FHS layout' >&2
fi
[ "$PERSISTENT" = true ] && echo '[sandbox] persistent' >&2 || echo '[sandbox] ephemeral' >&2

for command in awk bash bwrap curl git openssl python3 slirp4netns tar unshare; do
  command -v "$command" >/dev/null || {
    echo "error: missing required command: $command" >&2
    exit 1
  }
done

INTERACTIVE=false
if [ -t 0 ] && [ -t 1 ]; then
  INTERACTIVE=true
fi
NODE_DIR="${DEV_SANDBOX_NODE_DIR:-}"
if [ -z "$NODE_DIR" ] && command -v node >/dev/null; then
  NODE_DIR="$(dirname "$(dirname "$(command -v node)")")"
fi
WAYLAND_SOCKET=""
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -n "${WAYLAND_DISPLAY:-}" ] \
  && [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
  WAYLAND_SOCKET="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
fi

# Namespace plan (stage 1 -> stage 2).
#
# slirp4netns joins the target's userns and setuids to root before configuring
# the netns, so the userns MUST map a uid 0 — bwrap's own --unshare-user maps
# exactly one uid, which is why running the payload as uid 1000 used to fail
# with setns(CLONE_NEWNET): Operation not permitted.
#
# So we build the namespaces here with two ranges instead:
#   inner 0    <- a subuid, unused by the payload, present only so slirp can
#                become root inside the namespace
#   inner $SANDBOX_UID <- our real host uid, so everything the sandbox writes
#                stays owned by us and `rm -rf` on a persistent sandbox needs
#                no privileges or chown dance
# The payload then runs in stage 2, where bwrap adds the mount/pid namespaces
# without creating a userns at all.
#
# The root layout needs no subuid at all: inner 0 IS the host uid there.
netns_args=(--user --net)
if [ "$RUN_AS_USER" = true ]; then
  host_user="$(id -un)"
  subuid_base="$(awk -F: -v u="$host_user" '$1 == u {print $2; exit}' /etc/subuid)"
  subgid_base="$(awk -F: -v u="$host_user" '$1 == u {print $2; exit}' /etc/subgid)"
  if [ -z "$subuid_base" ] || [ -z "$subgid_base" ]; then
    echo "error: no /etc/subuid or /etc/subgid range for $host_user" >&2
    echo '       A user-level sandbox needs one spare subordinate id to host' >&2
    echo "       its internal root. Add e.g. '$host_user:100000:65536' to both," >&2
    echo '       or use --root.' >&2
    exit 1
  fi
  netns_args+=(
    --map-users="0:$subuid_base:1" --map-users="$SANDBOX_UID:$(id -u):1"
    --map-groups="0:$subgid_base:1" --map-groups="$SANDBOX_GID:$(id -g):1"
  )
else
  netns_args+=(--map-root-user)
fi

sandbox_pid_file="$SANDBOX_ROOT/root/logs/sandbox.pid"
slirp_ready="$SANDBOX_ROOT/root/logs/slirp.ready"
slirp_log="$SANDBOX_ROOT/root/logs/slirp.log"
: > "$sandbox_pid_file"
: > "$slirp_ready"

env \
  DEV_SANDBOX_ROOT="$SANDBOX_ROOT" \
  DEV_SANDBOX_BASH="$(command -v bash)" \
  DEV_SANDBOX_REAL_CA_CERT="$REAL_CA_CERT" \
  DEV_SANDBOX_INTERACTIVE="$INTERACTIVE" \
  DEV_SANDBOX_USER="$SANDBOX_USER" \
  DEV_SANDBOX_HOME="$SANDBOX_HOME" \
  DEV_SANDBOX_NODE_DIR="$NODE_DIR" \
  DEV_SANDBOX_ELECTRON_LD_LIBRARY_PATH="${DEV_SANDBOX_ELECTRON_LD_LIBRARY_PATH:-}" \
  DEV_SANDBOX_XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
  DEV_SANDBOX_WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
  DEV_SANDBOX_WAYLAND_SOCKET="$WAYLAND_SOCKET" \
  unshare "${netns_args[@]}" \
    "$BASH_SOURCE" --internal-sandbox "$@" &
sandbox_launcher=$!

for _ in $(seq 1 200); do
  [ -s "$sandbox_pid_file" ] && break
  if ! kill -0 "$sandbox_launcher" 2>/dev/null; then
    wait "$sandbox_launcher"
    exit $?
  fi
  sleep 0.05
done
sandbox_pid="$(tr -dc '0-9' < "$sandbox_pid_file")"
if [ -z "$sandbox_pid" ]; then
  echo 'error: sandbox did not report its PID' >&2
  exit 1
fi

slirp4netns --configure --disable-host-loopback --ready-fd=3 \
  --userns-path="/proc/$sandbox_pid/ns/user" "$sandbox_pid" tap0 \
  3>"$slirp_ready" >"$slirp_log" 2>&1 &
slirp_pid=$!
cleanup_slirp() {
  kill "$slirp_pid" 2>/dev/null || true
  wait "$slirp_pid" 2>/dev/null || true
}
trap cleanup_slirp EXIT INT TERM

for _ in $(seq 1 200); do
  [ -s "$slirp_ready" ] && break
  if ! kill -0 "$slirp_pid" 2>/dev/null; then
    cat "$slirp_log" >&2 || true
    exit 1
  fi
  sleep 0.05
done
if [ ! -s "$slirp_ready" ]; then
  echo 'error: timed out waiting for sandbox network setup' >&2
  exit 1
fi

wait "$sandbox_launcher"
exit $?