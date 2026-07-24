#!/usr/bin/env bash
#
# local-tunnel.sh - A SECOND Cloudflare Tunnel, run by cloudflared on the Mac
#                   itself (not inside k3s), that exposes this host's SSH server
#                   to the internet. Lets you `ssh` into the MacBook from
#                   anywhere with no port forward, no static IP, no dynamic DNS.
#
# Usage:
#   chmod +x local-tunnel.sh
#   export CF_API_TOKEN=...
#   ./local-tunnel.sh          # NOT with sudo - the LaunchAgent is per-user
#
# This is deliberately independent of k8s.sh. That tunnel ("gstation") lives in
# the cluster and only speaks HTTP to Traefik; Cloudflare will not proxy raw SSH
# through an HTTP hostname. So SSH gets its own tunnel ("gstation-ssh") with its
# own hostname and its own cloudflared process running on the host.
#
#   your laptop  ->  Cloudflare edge  ->  this tunnel (outbound QUIC from the Mac)
#                ->  cloudflared on the Mac  ->  sshd on 127.0.0.1:22
#
# CF_API_TOKEN is the same token k8s.sh uses, with the same scopes:
#   Account -> Cloudflare Tunnel -> Edit
#   Zone    -> DNS               -> Edit   (on $DOMAIN)
#   Zone    -> Zone              -> Read   (to look the zone up by name)
# It is only needed while this script runs; the tunnel credential it derives
# lives on this host afterwards (see the security note in step 5).
#
# Override DOMAIN, SSH_TUNNEL_NAME or SSH_HOSTNAME from the environment.
#
# Safe to re-run: every step is idempotent and independently verified afterward.

set -euo pipefail

FAILURES=0
pass() { echo "  [OK]   $*"; }
fail() { echo "  [FAIL] $*" >&2; FAILURES=$((FAILURES + 1)); }

SSH_TUNNEL_NAME="${SSH_TUNNEL_NAME:-gstation-ssh}"
DOMAIN="${DOMAIN:-gerardosalazar.com}"
SSH_HOSTNAME="${SSH_HOSTNAME:-ssh.$DOMAIN}"

# cloudflared reads its config and credential from here. Unlike the cluster
# tunnel - whose secret only ever lives inside k3s - a tunnel run on the host
# has to keep its credential on the host, so this directory holds one. It is
# created 0700 and the files inside it 0600; see the note in step 5.
CFD_DIR="$HOME/.cloudflared"
CFD_CONFIG="$CFD_DIR/${SSH_TUNNEL_NAME}.yaml"
CFD_CREDS="$CFD_DIR/${SSH_TUNNEL_NAME}.json"

AGENT_LABEL="com.local.cloudflared-${SSH_TUNNEL_NAME}"
AGENT_PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
AGENT_LOG="$HOME/Library/Logs/cloudflared-${SSH_TUNNEL_NAME}.log"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: this script only runs on macOS." >&2
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  echo "Error: do NOT run this with sudo." >&2
  echo "  The LaunchAgent is per-user; as root it would be written under /var/root" >&2
  echo "  and never start for $SUDO_USER." >&2
  echo "  ./$(basename "$0")" >&2
  exit 1
fi

if [[ -z "${CF_API_TOKEN:-}" ]]; then
  echo "Error: CF_API_TOKEN is not set - refusing to start." >&2
  echo >&2
  echo "  This is the same token k8s.sh uses. Create it at" >&2
  echo "  dash.cloudflare.com > My Profile > API Tokens with:" >&2
  echo "    Account -> Cloudflare Tunnel -> Edit" >&2
  echo "    Zone    -> DNS               -> Edit   (on $DOMAIN)" >&2
  echo "    Zone    -> Zone              -> Read   (to look the zone up by name)" >&2
  echo >&2
  echo "  If you stored it in the Keychain for k8s.sh, reuse it:" >&2
  echo "    export CF_API_TOKEN=\$(security find-generic-password -a \"\$USER\" -s cloudflare-api-token -w)" >&2
  exit 1
fi

[[ "$(uname -m)" == "arm64" ]] && BREW_BIN="/opt/homebrew/bin/brew" || BREW_BIN="/usr/local/bin/brew"
BREW_PREFIX="$(dirname "$(dirname "$BREW_BIN")")"
export PATH="$BREW_PREFIX/bin:$PATH"
CLOUDFLARED_BIN="$BREW_PREFIX/bin/cloudflared"

echo "==> Creating the '$SSH_TUNNEL_NAME' SSH tunnel on $(hostname) (user: $USER)"
echo

# ---------------------------------------------------------------------------
# 1. Tooling
#    cloudflared runs the tunnel; jq parses every Cloudflare API response.
#    curl and openssl are already in the macOS base system.
# ---------------------------------------------------------------------------
echo "==> 1. Tooling (cloudflared, jq)"

if [[ ! -x "$BREW_BIN" ]]; then
  fail "Homebrew missing at $BREW_BIN - run setup.sh first"
  exit 1
fi

for pkg in cloudflared jq; do
  "$BREW_BIN" list --formula "$pkg" &>/dev/null || "$BREW_BIN" install "$pkg"
  if command -v "$pkg" >/dev/null 2>&1; then
    pass "$pkg installed"
  else
    fail "$pkg install failed"
  fi
done
echo

# ---------------------------------------------------------------------------
# 2. SSH is actually on, and answers to a key
#    The tunnel is a dead end if Remote Login is off. setup.sh turns it on;
#    check rather than assume, since a failed TCC grant leaves it off silently.
# ---------------------------------------------------------------------------
echo "==> 2. Local SSH server"

if systemsetup -getremotelogin 2>/dev/null | grep -qi "on"; then
  pass "Remote Login (sshd) is on"
elif nc -z 127.0.0.1 22 >/dev/null 2>&1; then
  pass "something is listening on 127.0.0.1:22"
else
  fail "sshd is not listening on 127.0.0.1:22 - enable Remote Login (setup.sh does this)"
  echo "         System Settings > General > Sharing > Remote Login" >&2
fi

# sshd ignores an authorized_keys file that anyone but the owner can write, and
# it does so silently - the client just falls back to the next auth method. So
# the modes are set every run rather than only at creation.
SSH_DIR="$HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
[[ -f "$AUTH_KEYS" ]] || : > "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
pass "$AUTH_KEYS exists (0600 in a 0700 directory)"

# Blank lines and comments are not keys. grep -c exits 1 on no match, which
# would otherwise take `set -e` down with it.
KEY_COUNT="$(grep -cvE '^[[:space:]]*(#|$)' "$AUTH_KEYS" || true)"

if [[ "${KEY_COUNT:-0}" -gt 0 ]]; then
  pass "$KEY_COUNT authorized key(s) installed"
else
  # A hard stop, unlike the checks above. Everything else that fails here leaves
  # a tunnel that does not work; this one would leave a tunnel that works far
  # too well - publishing $SSH_HOSTNAME with no key on the box means the only
  # thing between the internet and this Mac is macOS's default
  # PasswordAuthentication yes. Refuse to open that door rather than warn about
  # it after the fact.
  fail "$AUTH_KEYS is empty - refusing to publish $SSH_HOSTNAME"
  echo >&2
  echo "  With no authorized key, sshd falls back to password auth, and this tunnel" >&2
  echo "  would expose that prompt to the entire internet." >&2
  echo >&2
  echo "  From the machine you want to connect FROM, while both are on your LAN:" >&2
  echo "    ssh-copy-id $USER@\$(ipconfig getifaddr en0)" >&2
  echo >&2
  echo "  Then turn passwords off on this Mac and restart sshd:" >&2
  echo "    printf 'PasswordAuthentication no\\nKbdInteractiveAuthentication no\\n' \\" >&2
  echo "      | sudo tee /etc/ssh/sshd_config.d/100-no-passwords.conf" >&2
  echo "    sudo launchctl kickstart -k system/com.openssh.sshd" >&2
  echo >&2
  echo "  Verify key-only login works over the LAN, keeping a session open, then" >&2
  echo "  re-run this script." >&2
  exit 1
fi
echo

# ---------------------------------------------------------------------------
# 3. Cloudflare Tunnel
#    Provisioned through the API rather than `cloudflared tunnel login`, which
#    needs an interactive browser and leaves a long-lived cert.pem on disk.
#    Mirrors k8s.sh step 6 exactly - same helpers, same idempotency.
# ---------------------------------------------------------------------------
echo "==> 3. Cloudflare Tunnel"

cf_api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method" "https://api.cloudflare.com/client/v4$path"
              -H "Authorization: Bearer $CF_API_TOKEN"
              -H "Content-Type: application/json")
  [[ -n "$body" ]] && args+=(--data "$body")
  curl "${args[@]}"
}

# curl exits 0 on an API-level rejection, so the envelope has to be checked
# explicitly or a failed call reads as success.
cf_ok() {
  local resp="$1" what="$2"
  if [[ "$(jq -r '.success' <<<"$resp" 2>/dev/null)" != "true" ]]; then
    fail "Cloudflare API call failed ($what)"
    jq -r '.errors[]? | "         [\(.code)] \(.message)"' <<<"$resp" >&2 2>/dev/null || echo "$resp" >&2
    exit 1
  fi
}

RESP="$(cf_api GET /user/tokens/verify)"
cf_ok "$RESP" "token verify"
pass "CF_API_TOKEN is valid"

RESP="$(cf_api GET "/zones?name=$DOMAIN")"
cf_ok "$RESP" "zone lookup"
ZONE_ID="$(jq -r '.result[0].id // empty' <<<"$RESP")"
ACCOUNT_ID="$(jq -r '.result[0].account.id // empty' <<<"$RESP")"
if [[ -z "$ZONE_ID" || -z "$ACCOUNT_ID" ]]; then
  fail "zone '$DOMAIN' is not on this Cloudflare account"
  echo "         The domain has to be using Cloudflare's nameservers first." >&2
  exit 1
fi
pass "zone $DOMAIN resolved"

# Tunnel names are NOT unique - POSTing twice yields two tunnels called
# "gstation-ssh" and every later lookup becomes ambiguous. Always look first.
RESP="$(cf_api GET "/accounts/$ACCOUNT_ID/cfd_tunnel?name=$SSH_TUNNEL_NAME&is_deleted=false")"
cf_ok "$RESP" "tunnel lookup"
TUNNEL_ID="$(jq -r '.result[0].id // empty' <<<"$RESP")"

if [[ -n "$TUNNEL_ID" ]]; then
  pass "tunnel '$SSH_TUNNEL_NAME' already exists ($TUNNEL_ID)"
else
  # config_src=local says the ingress rules live in our on-disk config file
  # below, not in the dashboard. The tunnel secret is symmetric and
  # caller-chosen: Cloudflare stores a copy, cloudflared presents a copy.
  RESP="$(cf_api POST "/accounts/$ACCOUNT_ID/cfd_tunnel" \
    "$(jq -nc --arg n "$SSH_TUNNEL_NAME" --arg s "$(openssl rand -base64 32)" \
        '{name:$n, tunnel_secret:$s, config_src:"local"}')")"
  cf_ok "$RESP" "tunnel create"
  TUNNEL_ID="$(jq -r '.result.id' <<<"$RESP")"
  pass "created tunnel '$SSH_TUNNEL_NAME' ($TUNNEL_ID)"
fi
echo

# ---------------------------------------------------------------------------
# 4. DNS
#    A proxied CNAME for the SSH hostname. cfargotunnel.com only resolves
#    inside Cloudflare's network, so an unproxied record here is a dead record.
# ---------------------------------------------------------------------------
echo "==> 4. DNS"

TUNNEL_TARGET="$TUNNEL_ID.cfargotunnel.com"

# Filtered to the address-record types only, exactly as k8s.sh does, so an MX
# or TXT record that happens to share the name is never clobbered.
RECORD_ID=""; RECORD_TYPE=""; RECORD_CONTENT=""
for TYPE in CNAME A AAAA; do
  RESP="$(cf_api GET "/zones/$ZONE_ID/dns_records?name=$SSH_HOSTNAME&type=$TYPE")"
  cf_ok "$RESP" "dns lookup for $SSH_HOSTNAME"
  RECORD_ID="$(jq -r '.result[0].id // empty' <<<"$RESP")"
  if [[ -n "$RECORD_ID" ]]; then
    RECORD_TYPE="$TYPE"
    RECORD_CONTENT="$(jq -r '.result[0].content // empty' <<<"$RESP")"
    break
  fi
done

BODY="$(jq -nc --arg n "$SSH_HOSTNAME" --arg c "$TUNNEL_TARGET" \
    '{type:"CNAME", name:$n, content:$c, proxied:true, ttl:1}')"

if [[ -z "$RECORD_ID" ]]; then
  RESP="$(cf_api POST "/zones/$ZONE_ID/dns_records" "$BODY")"
  cf_ok "$RESP" "dns create for $SSH_HOSTNAME"
  pass "$SSH_HOSTNAME -> $TUNNEL_TARGET (created)"
elif [[ "$RECORD_TYPE" == "CNAME" && "$RECORD_CONTENT" == "$TUNNEL_TARGET" ]]; then
  pass "$SSH_HOSTNAME -> $TUNNEL_TARGET (already correct)"
else
  echo "  [WARN] $SSH_HOSTNAME currently points at $RECORD_TYPE $RECORD_CONTENT"
  echo "         Repointing it at the SSH tunnel."
  RESP="$(cf_api PUT "/zones/$ZONE_ID/dns_records/$RECORD_ID" "$BODY")"
  cf_ok "$RESP" "dns update for $SSH_HOSTNAME"
  pass "$SSH_HOSTNAME -> $TUNNEL_TARGET (updated)"
fi
echo

# ---------------------------------------------------------------------------
# 5. Credentials + config on disk
#    The token endpoint returns base64 of {"a":account,"t":tunnel,"s":secret},
#    the same shape k8s.sh decodes - which is what makes a re-run idempotent for
#    a tunnel whose secret this run never saw, rather than forcing a recreate.
# ---------------------------------------------------------------------------
echo "==> 5. Credentials + config"

umask 077
mkdir -p "$CFD_DIR"
chmod 700 "$CFD_DIR"

RESP="$(cf_api GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token")"
cf_ok "$RESP" "tunnel token"
# openssl rather than base64(1), whose decode flag differs between BSD and GNU.
jq -r '.result' <<<"$RESP" | openssl base64 -d -A \
  | jq '{AccountTag: .a, TunnelID: .t, TunnelSecret: .s}' > "$CFD_CREDS"
chmod 600 "$CFD_CREDS"

jq -e '(.TunnelSecret // "") != "" and (.TunnelID // "") != ""' "$CFD_CREDS" >/dev/null 2>&1 \
  && pass "wrote $CFD_CREDS" \
  || { fail "could not derive tunnel credentials from the token endpoint"; exit 1; }

# The ingress: one named rule for SSH, then the mandatory catch-all. cloudflared
# refuses to start without a hostname-less final rule. http_status:404 makes
# anything but the SSH hostname a dead end rather than reaching a real service.
cat > "$CFD_CONFIG" <<EOF
# Managed by local-tunnel.sh. Edits are overwritten on the next run.
tunnel: $TUNNEL_ID
credentials-file: $CFD_CREDS

# Pin the version; do not let cloudflared rewrite its own binary (brew owns it).
no-autoupdate: true

ingress:
  - hostname: $SSH_HOSTNAME
    service: ssh://localhost:22
  - service: http_status:404
EOF
chmod 600 "$CFD_CONFIG"
pass "wrote $CFD_CONFIG (ssh://localhost:22)"

# The credential is a bearer secret for this tunnel: anyone who reads it can
# impersonate the tunnel and receive its traffic. It stays 0600 in a 0700
# directory, out of the repo and out of Time Machine's reach only if you
# exclude it - see the checklist. This is the one on-disk secret this tunnel
# cannot avoid, because cloudflared runs here rather than in the cluster.
echo

# ---------------------------------------------------------------------------
# 6. LaunchAgent
#    Keeps the tunnel up and brings it back after login. Unlike k8s.sh's agent
#    - which shells out to `limactl start`, a command that EXITS once the VM is
#    up - `cloudflared ... run` stays in the foreground for the life of the
#    tunnel. So this agent sets KeepAlive: a clean exit means the tunnel died
#    and must be restarted, the opposite of what KeepAlive would mean there.
# ---------------------------------------------------------------------------
echo "==> 6. LaunchAgent"

mkdir -p "$(dirname "$AGENT_PLIST")" "$(dirname "$AGENT_LOG")"
cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CLOUDFLARED_BIN}</string>
        <string>tunnel</string>
        <string>--config</string>
        <string>${CFD_CONFIG}</string>
        <string>--no-autoupdate</string>
        <string>run</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${BREW_PREFIX}/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>${AGENT_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${AGENT_LOG}</string>
</dict>
</plist>
EOF
chmod 644 "$AGENT_PLIST"

# bootout then bootstrap so a re-run picks up an edited plist. bootout on a
# not-loaded agent is a harmless error, hence the guard.
launchctl bootout "gui/$UID" "$AGENT_PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$AGENT_PLIST" >/dev/null 2>&1 || true
# kickstart forces an immediate (re)start rather than waiting on RunAtLoad
# semantics for an already-known label.
launchctl kickstart -k "gui/$UID/${AGENT_LABEL}" >/dev/null 2>&1 || true

launchctl print "gui/$UID/${AGENT_LABEL}" >/dev/null 2>&1 \
  && pass "$AGENT_LABEL is loaded (logs: $AGENT_LOG)" \
  || fail "$AGENT_LABEL failed to load"
echo

# ---------------------------------------------------------------------------
# 7. Health
#    Pod-style readiness does not apply here; ask Cloudflare whether the edge
#    is actually holding connections to this cloudflared, same as k8s.sh does.
# ---------------------------------------------------------------------------
echo "==> 7. Health"

TUNNEL_STATUS="unknown"
for _ in $(seq 1 12); do
  TUNNEL_STATUS="$(jq -r '.result.status // "unknown"' \
    <<<"$(cf_api GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID")")"
  [[ "$TUNNEL_STATUS" == "healthy" ]] && break
  sleep 5
done
[[ "$TUNNEL_STATUS" == "healthy" ]] \
  && pass "tunnel is healthy - the edge is holding connections to this Mac" \
  || fail "tunnel status is '$TUNNEL_STATUS', expected healthy (tail $AGENT_LOG)"
echo

# ---------------------------------------------------------------------------
# 8. Manual checklist
# ---------------------------------------------------------------------------
echo "==> 8. Manual checklist"

if [[ "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)" == "$USER" ]]; then
  pass "automatic login is enabled for $USER (the LaunchAgent will fire after a reboot)"
else
  echo "  [WARN] Automatic login is NOT enabled for $USER. This LaunchAgent runs at"
  echo "         *login*, not at boot - after an unattended reboot SSH-over-tunnel"
  echo "         stays down until someone signs in. Same caveat as the cluster agent."
  echo "         System Settings > Users & Groups > Automatically log in as"
fi

echo "  [SECURITY] The hostname $SSH_HOSTNAME is now an SSH door reachable from the"
echo "         whole internet. Cloudflare proxies the bytes but does NOT authenticate"
echo "         anyone by default - your sshd is the only gate. Before relying on this:"
echo "           - Use key-only auth: PasswordAuthentication no in /etc/ssh/sshd_config."
echo "           - Strongly consider a Cloudflare Access (Zero Trust) self-hosted app"
echo "             over $SSH_HOSTNAME, so Cloudflare enforces your identity BEFORE the"
echo "             SSH handshake ever reaches the Mac. Dashboard: Zero Trust > Access"
echo "             > Applications > Add (Self-hosted) > $SSH_HOSTNAME."
echo "  [NOTE] $CFD_CREDS is this tunnel's secret. Exclude ~/.cloudflared from Time"
echo "         Machine (System Settings > General > Time Machine > Options) if you do"
echo "         not want the credential in backups."
echo "  [NOTE] This tunnel is entirely separate from the cluster's 'gstation' tunnel."
echo "         Deleting one never touches the other."
echo

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo unknown)"
echo "=================================================================="
if [[ "$FAILURES" -eq 0 ]]; then
  echo " All automated checks passed."
else
  echo " $FAILURES check(s) failed - see [FAIL] lines above."
fi
echo " Tunnel:   ${SSH_TUNNEL_NAME}${TUNNEL_ID:+ ($TUNNEL_ID)}"
echo " Hostname: $SSH_HOSTNAME  ->  ssh://localhost:22 on this Mac"
echo " LAN SSH:  ssh $USER@${LAN_IP}   (unchanged, still works on the local network)"
echo
echo " From a remote client, once cloudflared is installed there:"
echo
echo "   # ~/.ssh/config"
echo "   Host $SSH_HOSTNAME"
echo "     User $USER"
echo "     ProxyCommand $(basename "$CLOUDFLARED_BIN") access ssh --hostname %h"
echo
echo "   ssh $SSH_HOSTNAME"
echo "=================================================================="

exit $(( FAILURES > 0 ? 1 : 0 ))
