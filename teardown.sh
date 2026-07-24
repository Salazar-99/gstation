#!/usr/bin/env bash
#
# teardown.sh - Remove everything k8s.sh created, leaving the Mac able to run
#               ./k8s.sh again from a clean slate.
#
# Usage:
#   ./teardown.sh                 # VM, LaunchAgent, kubeconfig, logs
#   ./teardown.sh --yes           # no confirmation prompt
#   ./teardown.sh --cloudflare    # also delete the tunnel and its DNS records
#   ./teardown.sh --cache         # also drop Lima's downloaded image cache
#
# Scope is deliberately narrow: this undoes k8s.sh, not setup.sh. The macOS
# server configuration (sleep, SSH, VNC, firewall, the keepawake LaunchDaemon)
# survives, as do the Homebrew packages - lima, kubectl, helm and jq are general
# tools and removing them is not this script's business.
#
# By default the Cloudflare tunnel and its DNS records SURVIVE too, and that is
# usually what you want: k8s.sh finds the existing tunnel, recovers its secret
# from the API, and a rebuilt cluster comes back on the same hostnames without
# any DNS change. Pass --cloudflare only when retiring the domain setup as well.
#
# Safe to re-run: every step tolerates the thing already being gone.

set -euo pipefail

FAILURES=0
pass() { echo "  [OK]   $*"; }
fail() { echo "  [FAIL] $*" >&2; FAILURES=$((FAILURES + 1)); }
skip() { echo "  [SKIP] $*"; }

VM_NAME="gstation"
KUBECONFIG_OUT="$HOME/.kube/config"
AGENT_LABEL="com.local.lima-${VM_NAME}"
AGENT_PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
AGENT_LOG="$HOME/Library/Logs/lima-${VM_NAME}.log"
LIMA_CACHE="$HOME/Library/Caches/lima"

TUNNEL_NAME="${TUNNEL_NAME:-gstation}"
DOMAIN="${DOMAIN:-gerardosalazar.com}"
HOSTNAMES=("$DOMAIN" "www.$DOMAIN")

ASSUME_YES=0
DO_CLOUDFLARE=0
DO_CACHE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)     ASSUME_YES=1 ;;
    --cloudflare) DO_CLOUDFLARE=1 ;;
    --cache)      DO_CACHE=1 ;;
    # Prints the header block: comment lines after the shebang, stopping at the
    # first line that is not one, so it cannot drift out of sync with edits.
    -h|--help)    awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
    *) echo "Error: unknown argument '$1' (try --help)." >&2; exit 1 ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: this script only runs on macOS." >&2
  exit 1
fi

# Same reasoning as k8s.sh: the instance, the LaunchAgent and the kubeconfig all
# live in a user's home directory. As root this would look in /var/root, find
# nothing, and report a clean teardown while everything survived.
if [[ "${EUID}" -eq 0 ]]; then
  echo "Error: do NOT run this with sudo." >&2
  echo "  Lima state is per-user; as root this would tear down nothing and say" >&2
  echo "  it succeeded. Run it as the user that ran k8s.sh." >&2
  exit 1
fi

if [[ "$DO_CLOUDFLARE" -eq 1 && -z "${CF_API_TOKEN:-}" ]]; then
  echo "Error: --cloudflare needs CF_API_TOKEN (same token k8s.sh used)." >&2
  echo "  export CF_API_TOKEN=\$(security find-generic-password -a \"\$USER\" -s cloudflare-api-token -w)" >&2
  exit 1
fi

[[ "$(uname -m)" == "arm64" ]] && BREW_BIN="/opt/homebrew/bin/brew" || BREW_BIN="/usr/local/bin/brew"
BREW_PREFIX="$(dirname "$(dirname "$BREW_BIN")")"
export PATH="$BREW_PREFIX/bin:$PATH"

# ---------------------------------------------------------------------------
# Confirmation
#    Deleting the instance destroys its disk, and with it every PersistentVolume
#    in the cluster - local-path-provisioner stores them inside the VM. Nothing
#    here is recoverable, so say plainly what is about to go.
# ---------------------------------------------------------------------------
echo "==> Tearing down the '$VM_NAME' cluster on $(hostname) (user: $USER)"
echo
echo "  This will permanently delete:"
echo "    - the Lima VM '$VM_NAME' and its virtual disk"
echo "    - every PersistentVolume in the cluster (they live on that disk)"
echo "    - the LaunchAgent, kubeconfig and log file"
if [[ "$DO_CLOUDFLARE" -eq 1 ]]; then
  echo "    - the Cloudflare tunnel '$TUNNEL_NAME' and DNS for: ${HOSTNAMES[*]}"
else
  echo "  Keeping (re-run with --cloudflare to remove):"
  echo "    - the Cloudflare tunnel '$TUNNEL_NAME' and its DNS records"
fi
[[ "$DO_CACHE" -eq 1 ]] && echo "    - Lima's image cache at $LIMA_CACHE"
echo

if [[ "$ASSUME_YES" -ne 1 ]]; then
  if [[ ! -t 0 ]]; then
    echo "Error: not a terminal and --yes was not given; refusing to guess." >&2
    exit 1
  fi
  read -r -p "  Type the instance name ('$VM_NAME') to continue: " REPLY_NAME
  if [[ "$REPLY_NAME" != "$VM_NAME" ]]; then
    echo "  Aborted - nothing was changed."
    exit 1
  fi
  echo
fi

# ---------------------------------------------------------------------------
# 1. Auto-start LaunchAgent
#    Removed before the VM, so it cannot race the delete by starting it again.
# ---------------------------------------------------------------------------
echo "==> 1. Auto-start LaunchAgent"

if launchctl print "gui/$UID/${AGENT_LABEL}" >/dev/null 2>&1; then
  launchctl bootout "gui/$UID" "$AGENT_PLIST" >/dev/null 2>&1 || true
  launchctl print "gui/$UID/${AGENT_LABEL}" >/dev/null 2>&1 \
    && fail "$AGENT_LABEL is still loaded" \
    || pass "$AGENT_LABEL unloaded"
else
  skip "$AGENT_LABEL was not loaded"
fi

if [[ -f "$AGENT_PLIST" ]]; then
  rm -f "$AGENT_PLIST"
  [[ -f "$AGENT_PLIST" ]] && fail "could not remove $AGENT_PLIST" || pass "removed $AGENT_PLIST"
else
  skip "no plist at $AGENT_PLIST"
fi
echo

# ---------------------------------------------------------------------------
# 2. The VM
#    Done before the Cloudflare cleanup: stopping the pods drops the tunnel's
#    connections, and a tunnel with live connections refuses to be deleted.
# ---------------------------------------------------------------------------
echo "==> 2. Lima VM"

if limactl list -q 2>/dev/null | grep -qx "$VM_NAME"; then
  STATUS="$(limactl list "$VM_NAME" --format '{{.Status}}' 2>/dev/null || echo unknown)"
  if [[ "$STATUS" == "Running" ]]; then
    echo "  Stopping '$VM_NAME'..."
    limactl stop "$VM_NAME" >/dev/null 2>&1 || limactl stop --force "$VM_NAME" >/dev/null 2>&1 || true
  fi
  limactl delete --force "$VM_NAME" >/dev/null 2>&1 || true
  limactl list -q 2>/dev/null | grep -qx "$VM_NAME" \
    && fail "instance '$VM_NAME' still exists (limactl delete --force $VM_NAME)" \
    || pass "instance '$VM_NAME' deleted"

  [[ -d "$HOME/.lima/$VM_NAME" ]] \
    && fail "leftover directory $HOME/.lima/$VM_NAME" \
    || pass "instance directory removed"
else
  skip "no Lima instance named '$VM_NAME'"
fi
echo

# ---------------------------------------------------------------------------
# 3. kubeconfig and logs
# ---------------------------------------------------------------------------
echo "==> 3. kubeconfig and logs"

# k8s.sh merges a '$VM_NAME' context into the shared ~/.kube/config rather than
# writing a standalone file, so remove just those entries and leave the rest of
# the config - other clusters, the current-context - untouched.
if [[ -f "$KUBECONFIG_OUT" ]] \
   && kubectl --kubeconfig="$KUBECONFIG_OUT" config get-contexts "$VM_NAME" >/dev/null 2>&1; then
  kubectl --kubeconfig="$KUBECONFIG_OUT" config delete-context "$VM_NAME" >/dev/null 2>&1 || true
  kubectl --kubeconfig="$KUBECONFIG_OUT" config delete-cluster "$VM_NAME" >/dev/null 2>&1 || true
  kubectl --kubeconfig="$KUBECONFIG_OUT" config delete-user "$VM_NAME"    >/dev/null 2>&1 || true
  kubectl --kubeconfig="$KUBECONFIG_OUT" config get-contexts "$VM_NAME" >/dev/null 2>&1 \
    && fail "could not remove context '$VM_NAME' from $KUBECONFIG_OUT" \
    || pass "removed context/cluster/user '$VM_NAME' from $KUBECONFIG_OUT"
else
  skip "no '$VM_NAME' context in $KUBECONFIG_OUT"
fi

if [[ -f "$AGENT_LOG" ]]; then
  rm -f "$AGENT_LOG"
  [[ -f "$AGENT_LOG" ]] && fail "could not remove $AGENT_LOG" || pass "removed $AGENT_LOG"
else
  skip "no log at $AGENT_LOG"
fi
echo

# ---------------------------------------------------------------------------
# 4. Lima image cache (opt-in)
#    Keeping it makes the next k8s.sh much faster; it is only worth dropping to
#    reclaim the disk or to force a fresh image download.
# ---------------------------------------------------------------------------
if [[ "$DO_CACHE" -eq 1 ]]; then
  echo "==> 4. Lima image cache"
  if [[ -d "$LIMA_CACHE" ]]; then
    CACHE_SIZE="$(du -sh "$LIMA_CACHE" 2>/dev/null | cut -f1 || echo "?")"
    rm -rf "$LIMA_CACHE"
    [[ -d "$LIMA_CACHE" ]] && fail "could not remove $LIMA_CACHE" || pass "removed $LIMA_CACHE ($CACHE_SIZE reclaimed)"
  else
    skip "no cache at $LIMA_CACHE"
  fi
  echo
fi

# ---------------------------------------------------------------------------
# 5. Cloudflare tunnel and DNS (opt-in)
# ---------------------------------------------------------------------------
if [[ "$DO_CLOUDFLARE" -eq 1 ]]; then
  echo "==> 5. Cloudflare tunnel and DNS"

  if ! command -v jq >/dev/null 2>&1; then
    fail "jq is required for --cloudflare (brew install jq)"
  else
    cf_api() {
      local method="$1" path="$2" body="${3:-}"
      local args=(-sS -X "$method" "https://api.cloudflare.com/client/v4$path"
                  -H "Authorization: Bearer $CF_API_TOKEN"
                  -H "Content-Type: application/json")
      [[ -n "$body" ]] && args+=(--data "$body")
      curl "${args[@]}"
    }
    cf_ok() { [[ "$(jq -r '.success' <<<"$1" 2>/dev/null)" == "true" ]]; }

    RESP="$(cf_api GET "/zones?name=$DOMAIN")"
    ZONE_ID="$(jq -r '.result[0].id // empty' <<<"$RESP" 2>/dev/null || true)"
    ACCOUNT_ID="$(jq -r '.result[0].account.id // empty' <<<"$RESP" 2>/dev/null || true)"

    if [[ -z "$ZONE_ID" || -z "$ACCOUNT_ID" ]]; then
      fail "could not resolve zone '$DOMAIN' (token scope, or the zone is gone)"
    else
      RESP="$(cf_api GET "/accounts/$ACCOUNT_ID/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false")"
      TUNNEL_ID="$(jq -r '.result[0].id // empty' <<<"$RESP" 2>/dev/null || true)"

      if [[ -z "$TUNNEL_ID" ]]; then
        skip "no tunnel named '$TUNNEL_NAME'"
      else
        TUNNEL_TARGET="$TUNNEL_ID.cfargotunnel.com"

        # Only delete records that actually point at THIS tunnel. Anything else
        # at these hostnames belongs to something the teardown did not create.
        for HOST in "${HOSTNAMES[@]}"; do
          RESP="$(cf_api GET "/zones/$ZONE_ID/dns_records?name=$HOST&type=CNAME")"
          RECORD_ID="$(jq -r --arg t "$TUNNEL_TARGET" \
            '.result[] | select(.content == $t) | .id' <<<"$RESP" 2>/dev/null | head -1 || true)"
          if [[ -z "$RECORD_ID" ]]; then
            skip "$HOST does not point at this tunnel; left alone"
          else
            RESP="$(cf_api DELETE "/zones/$ZONE_ID/dns_records/$RECORD_ID")"
            cf_ok "$RESP" && pass "deleted DNS record for $HOST" \
                          || fail "could not delete DNS record for $HOST"
          fi
        done

        # The VM is already gone, but the edge can hold connections open for a
        # short while and a tunnel with live connections refuses to delete.
        cf_api DELETE "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/connections" >/dev/null 2>&1 || true

        TUNNEL_GONE=0
        for _ in $(seq 1 12); do
          RESP="$(cf_api DELETE "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID")"
          if cf_ok "$RESP"; then TUNNEL_GONE=1; break; fi
          sleep 5
        done
        if [[ "$TUNNEL_GONE" -eq 1 ]]; then
          pass "deleted tunnel '$TUNNEL_NAME' ($TUNNEL_ID)"
        else
          fail "could not delete tunnel '$TUNNEL_NAME' - it may still have active connections"
          jq -r '.errors[]? | "         [\(.code)] \(.message)"' <<<"$RESP" >&2 2>/dev/null || true
        fi
      fi
    fi
  fi
  echo
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=================================================================="
if [[ "$FAILURES" -eq 0 ]]; then
  echo " Teardown complete."
else
  echo " $FAILURES step(s) failed - see [FAIL] lines above."
fi
echo
echo " Left in place:"
echo "   - macOS server config from setup.sh (sleep, SSH, VNC, firewall)"
echo "   - Homebrew packages: lima, kubectl, helm, jq"
[[ "$DO_CACHE" -ne 1 ]] && echo "   - Lima's image cache (--cache to drop it; keeping it speeds up a rebuild)"
[[ "$DO_CLOUDFLARE" -ne 1 ]] && echo "   - the Cloudflare tunnel and DNS (--cloudflare to remove them)"
echo
echo " To rebuild:"
echo "   export CF_API_TOKEN=\$(security find-generic-password -a \"\$USER\" -s cloudflare-api-token -w)"
echo "   ./k8s.sh"
echo "=================================================================="

exit $(( FAILURES > 0 ? 1 : 0 ))
