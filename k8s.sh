#!/usr/bin/env bash
#
# k8s.sh - Bring up the gstation Kubernetes cluster: a single-node k3s server
#          running inside a Lima VM, set to come back on its own after a reboot,
#          and published to the internet through a Cloudflare Tunnel.
#
# Usage:
#   chmod +x k8s.sh
#   export CF_API_TOKEN=...
#   ./k8s.sh            # NOT with sudo - see below
#
# Run this *after* setup.sh. Unlike setup.sh this is a per-user script: Lima
# instances, their disk images and the LaunchAgent all belong to the invoking
# user, so running it as root would build the cluster in root's home directory.
# Nothing here needs elevation; it will never prompt for a password.
#
# CF_API_TOKEN is the only credential a human supplies, and it is only needed
# while this script runs - the tunnel secret it produces lives in the cluster
# afterwards, so nothing in this repo ever holds a secret. Create the token at
# dash.cloudflare.com > My Profile > API Tokens with:
#   Account -> Cloudflare Tunnel -> Edit
#   Zone    -> DNS               -> Edit   (on $DOMAIN)
#   Zone    -> Zone              -> Read   (to look the zone up by name)
#
# Override DOMAIN or TUNNEL_NAME from the environment to point elsewhere.
#
# Safe to re-run: every step is idempotent and independently verified afterward.

set -euo pipefail

FAILURES=0
pass() { echo "  [OK]   $*"; }
fail() { echo "  [FAIL] $*" >&2; FAILURES=$((FAILURES + 1)); }

VM_NAME="gstation"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/lima.yaml"
KUBECONFIG_OUT="$HOME/.kube/config"
AGENT_LABEL="com.local.lima-${VM_NAME}"
AGENT_PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
AGENT_LOG="$HOME/Library/Logs/lima-${VM_NAME}.log"

TUNNEL_NAME="${TUNNEL_NAME:-gstation}"
DOMAIN="${DOMAIN:-gerardosalazar.com}"
MANIFEST_DIR="$SCRIPT_DIR/k8s/cloudflared"

# Hostnames routed through the tunnel. Each becomes a proxied CNAME; each still
# needs an Ingress to claim it before anything is actually served there.
HOSTNAMES=("$DOMAIN" "www.$DOMAIN")

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: this script only runs on macOS." >&2
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  echo "Error: do NOT run this with sudo." >&2
  echo "  Lima instances and the LaunchAgent are per-user; as root they would be" >&2
  echo "  created in /var/root and never start for $SUDO_USER." >&2
  echo "  ./$(basename "$0")" >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Error: $TEMPLATE not found (it ships alongside this script)." >&2
  exit 1
fi

if [[ ! -d "$MANIFEST_DIR" ]]; then
  echo "Error: $MANIFEST_DIR not found (it ships alongside this script)." >&2
  exit 1
fi

# Checked here rather than at the Cloudflare step: building the VM takes
# minutes, and discovering a missing token afterwards wastes all of them.
if [[ -z "${CF_API_TOKEN:-}" ]]; then
  echo "Error: CF_API_TOKEN is not set - refusing to start." >&2
  echo >&2
  echo "  Create a token at dash.cloudflare.com > My Profile > API Tokens with:" >&2
  echo "    Account -> Cloudflare Tunnel -> Edit" >&2
  echo "    Zone    -> DNS               -> Edit   (on $DOMAIN)" >&2
  echo "    Zone    -> Zone              -> Read   (to look the zone up by name)" >&2
  echo >&2
  echo "  Then, keeping it out of shell history and out of any dotfile:" >&2
  echo "    security add-generic-password -a \"\$USER\" -s cloudflare-api-token -w" >&2
  echo "    export CF_API_TOKEN=\$(security find-generic-password -a \"\$USER\" -s cloudflare-api-token -w)" >&2
  exit 1
fi

# The tunnel credentials are assembled here and shredded on exit, so the secret
# never lands in the repo, in ~/.cloudflared, or in this script's argv.
umask 077
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

[[ "$(uname -m)" == "arm64" ]] && BREW_BIN="/opt/homebrew/bin/brew" || BREW_BIN="/usr/local/bin/brew"
BREW_PREFIX="$(dirname "$(dirname "$BREW_BIN")")"
export PATH="$BREW_PREFIX/bin:$PATH"

echo "==> Building the '$VM_NAME' Kubernetes cluster on $(hostname) (user: $USER)"
echo

# ---------------------------------------------------------------------------
# 1. Tooling
#    lima runs the VM; kubectl and helm are the host-side clients. Everything
#    else (containerd, CNI, ingress) is bundled inside k3s.
# ---------------------------------------------------------------------------
echo "==> 1. Tooling (lima, kubectl, helm, jq)"

if [[ ! -x "$BREW_BIN" ]]; then
  fail "Homebrew missing at $BREW_BIN - run setup.sh first"
  exit 1
fi

# jq parses every Cloudflare API response below. curl and openssl are already
# in the macOS base system.
for pkg in lima kubectl helm jq; do
  "$BREW_BIN" list --formula "$pkg" &>/dev/null || "$BREW_BIN" install "$pkg"
  if command -v "$pkg" >/dev/null 2>&1; then
    pass "$pkg installed"
  else
    fail "$pkg install failed"
  fi
done

# lima.yaml uses `base: template:_images/...`, which is a 2.x-only spelling.
LIMA_VER="$(limactl --version 2>/dev/null | awk '{print $NF}')"
if [[ "${LIMA_VER%%.*}" -ge 2 ]] 2>/dev/null; then
  pass "limactl $LIMA_VER (>= 2.0 as the template requires)"
else
  fail "limactl ${LIMA_VER:-unknown} is too old; lima.yaml needs 2.0+ (brew upgrade lima)"
fi

limactl validate "$TEMPLATE" >/dev/null 2>&1 \
  && pass "lima.yaml is valid" \
  || fail "lima.yaml failed validation: $(limactl validate "$TEMPLATE" 2>&1 | tail -3)"
echo

# ---------------------------------------------------------------------------
# 2. The VM
# ---------------------------------------------------------------------------
echo "==> 2. Lima VM + k3s"

INSTANCE_CFG="$HOME/.lima/$VM_NAME/lima.yaml"

# Reads cpus/memory/disk as a bare number: `memory: "16GiB"` -> 16. Both files
# are written by Lima in the same shape, so the same parse works on each.
lima_cfg() {
  awk -v k="$2" -F': *' '$1 == k { gsub(/"/, "", $2); sub(/GiB$/, "", $2); print $2; exit }' "$1"
}

if limactl list -q 2>/dev/null | grep -qx "$VM_NAME"; then
  STATUS="$(limactl list "$VM_NAME" --format '{{.Status}}' 2>/dev/null || echo unknown)"
  echo "  Instance '$VM_NAME' already exists (status: $STATUS)"

  # Lima copies the template into the instance directory at creation, so an
  # edit to lima.yaml never reaches an existing VM on its own. Reconcile the
  # two. There is no in-place path: cpus and memory are fixed at VM boot, and
  # `limactl edit` refuses to touch a running instance outright.
  EDIT_ARGS=()
  DRIFT=()
  if [[ -f "$INSTANCE_CFG" ]]; then
    for KEY in cpus memory disk; do
      WANT="$(lima_cfg "$TEMPLATE" "$KEY")"
      HAVE="$(lima_cfg "$INSTANCE_CFG" "$KEY")"
      # Only reconcile what both files express as a plain GiB integer. Anything
      # exotic (MiB, a bare byte count) is left alone rather than guessed at -
      # but say so, since silently ignoring an edit to lima.yaml is worse than
      # declining to act on it.
      if [[ ! "$WANT" =~ ^[0-9]+$ || ! "$HAVE" =~ ^[0-9]+$ ]]; then
        [[ "$WANT" != "$HAVE" ]] && echo "  [WARN] cannot compare $KEY ('$WANT' vs '$HAVE'); expected whole GiB. Skipping."
        continue
      fi
      [[ "$WANT" == "$HAVE" ]] && continue
      if [[ "$KEY" == "disk" && "$WANT" -lt "$HAVE" ]]; then
        echo "  [WARN] lima.yaml asks for a ${WANT}GiB disk, the instance has ${HAVE}GiB."
        echo "         Lima can grow a disk but never shrink one; leaving it alone."
        continue
      fi
      DRIFT+=("$KEY ${HAVE}->${WANT}")
      EDIT_ARGS+=("--$KEY=$WANT")
    done
  fi

  if [[ "${#EDIT_ARGS[@]}" -gt 0 ]]; then
    echo "  Drift vs lima.yaml: ${DRIFT[*]}"
    echo "  Applying this restarts the VM - the cluster is down until it is back."
    [[ "$STATUS" == "Running" ]] && limactl stop "$VM_NAME"
    limactl edit "$VM_NAME" "${EDIT_ARGS[@]}" --tty=false
    limactl start "$VM_NAME" --tty=false
    pass "reconciled: ${DRIFT[*]}"
  elif [[ "$STATUS" != "Running" ]]; then
    limactl start "$VM_NAME" --tty=false
  else
    pass "sizing matches lima.yaml"
  fi
else
  echo "  Creating '$VM_NAME' - first boot pulls an image and installs k3s, so"
  echo "  this takes a few minutes."
  limactl start --name="$VM_NAME" "$TEMPLATE" --tty=false
fi

STATUS="$(limactl list "$VM_NAME" --format '{{.Status}}' 2>/dev/null || echo unknown)"
[[ "$STATUS" == "Running" ]] \
  && pass "VM '$VM_NAME' is running" \
  || fail "VM '$VM_NAME' is '$STATUS' (limactl start $VM_NAME)"

limactl shell "$VM_NAME" sudo systemctl is-active --quiet k3s \
  && pass "k3s service is active" \
  || fail "k3s is not active (limactl shell $VM_NAME sudo journalctl -u k3s)"

VM_DIR="$(limactl list "$VM_NAME" --format '{{.Dir}}')"
echo

# ---------------------------------------------------------------------------
# 3. kubeconfig
#    The file Lima copies out names its cluster, user and context all "default".
#    Rebuild those under the instance name so they cannot collide, then merge
#    into the default ~/.kube/config - so a bare `kubectl` finds the cluster
#    with no KUBECONFIG juggling - preserving any other contexts already there.
# ---------------------------------------------------------------------------
echo "==> 3. kubeconfig"

SRC_KUBECONFIG="$VM_DIR/copied-from-guest/kubeconfig.yaml"
if [[ ! -s "$SRC_KUBECONFIG" ]]; then
  fail "no kubeconfig at $SRC_KUBECONFIG - k3s may not have finished starting"
else
  CA="$(kubectl --kubeconfig="$SRC_KUBECONFIG" config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  CRT="$(kubectl --kubeconfig="$SRC_KUBECONFIG" config view --raw -o jsonpath='{.users[0].user.client-certificate-data}')"
  KEY="$(kubectl --kubeconfig="$SRC_KUBECONFIG" config view --raw -o jsonpath='{.users[0].user.client-key-data}')"

  mkdir -p "$(dirname "$KUBECONFIG_OUT")"
  umask 077
  NEW_CFG="$(mktemp)"
  cat > "$NEW_CFG" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${VM_NAME}
  cluster:
    server: https://127.0.0.1:6443
    certificate-authority-data: ${CA}
users:
- name: ${VM_NAME}
  user:
    client-certificate-data: ${CRT}
    client-key-data: ${KEY}
contexts:
- name: ${VM_NAME}
  context:
    cluster: ${VM_NAME}
    user: ${VM_NAME}
current-context: ${VM_NAME}
EOF

  # Merge into ~/.kube/config without clobbering other contexts. The fresh file
  # goes first in the chain so rotated certs and current-context win over any
  # stale gstation entry from a previous run; a missing target file is ignored.
  MERGED="$(mktemp)"
  KUBECONFIG="$NEW_CFG:$KUBECONFIG_OUT" kubectl config view --flatten > "$MERGED"
  mv "$MERGED" "$KUBECONFIG_OUT"
  rm -f "$NEW_CFG"
  chmod 600 "$KUBECONFIG_OUT"
  [[ "$(kubectl --kubeconfig="$KUBECONFIG_OUT" config current-context 2>/dev/null)" == "$VM_NAME" ]] \
    && pass "merged context '$VM_NAME' into $KUBECONFIG_OUT (now current)" \
    || fail "kubeconfig at $KUBECONFIG_OUT is not usable"
fi
echo

# ---------------------------------------------------------------------------
# 4. Auto-start on boot
#    A Lima VM does not come back by itself. This is a LaunchAgent, not a
#    LaunchDaemon, because the instance lives in this user's home directory -
#    which means it fires at *login*, not at boot. See the checklist below.
# ---------------------------------------------------------------------------
echo "==> 4. Auto-start LaunchAgent"

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
        <string>${BREW_PREFIX}/bin/limactl</string>
        <string>start</string>
        <string>--tty=false</string>
        <string>${VM_NAME}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${BREW_PREFIX}/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${AGENT_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${AGENT_LOG}</string>
</dict>
</plist>
EOF
chmod 644 "$AGENT_PLIST"

# KeepAlive is deliberately absent: `limactl start` exits once the VM is up, so
# KeepAlive would treat a healthy cluster as a crashed job and restart forever.
launchctl bootout "gui/$UID" "$AGENT_PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$AGENT_PLIST" >/dev/null 2>&1 || true
launchctl print "gui/$UID/${AGENT_LABEL}" >/dev/null 2>&1 \
  && pass "$AGENT_LABEL is loaded (logs: $AGENT_LOG)" \
  || fail "$AGENT_LABEL failed to load"
echo

# ---------------------------------------------------------------------------
# 5. Cluster readiness
# ---------------------------------------------------------------------------
echo "==> 5. Cluster readiness"

if [[ -s "$KUBECONFIG_OUT" ]]; then
  export KUBECONFIG="$KUBECONFIG_OUT"

  # No `timeout` on stock macOS (it is GNU coreutils), so poll by hand.
  NODE_READY=0
  for _ in $(seq 1 36); do
    if kubectl wait --for=condition=Ready node --all --timeout=5s >/dev/null 2>&1; then
      NODE_READY=1
      break
    fi
    sleep 5
  done
  [[ "$NODE_READY" -eq 1 ]] \
    && pass "node is Ready: $(kubectl get nodes -o jsonpath='{.items[0].metadata.name} {.items[0].status.nodeInfo.kubeletVersion}')" \
    || fail "node did not become Ready within 3 minutes"

  # k3s creates its bundled add-ons through a controller *after* the API server
  # is up, and Traefik arrives later still via a Helm install Job - so for the
  # first minute of a fresh cluster these deployments do not exist at all.
  # Poll for existence before asking about the rollout; a missing deployment
  # here means "not yet", not "broken".
  for dep in coredns local-path-provisioner metrics-server traefik; do
    DEP_OK=0
    for _ in $(seq 1 36); do
      if kubectl -n kube-system get deploy "$dep" >/dev/null 2>&1 \
         && kubectl -n kube-system rollout status deploy/"$dep" --timeout=10s >/dev/null 2>&1; then
        DEP_OK=1
        break
      fi
      sleep 5
    done
    [[ "$DEP_OK" -eq 1 ]] \
      && pass "$dep is rolled out" \
      || fail "$dep is not ready (kubectl -n kube-system get pods)"
  done
fi
echo

# ---------------------------------------------------------------------------
# 6. Cloudflare Tunnel
#    Provisioned through the API rather than `cloudflared tunnel login`, which
#    needs an interactive browser and leaves a long-lived cert.pem on disk.
# ---------------------------------------------------------------------------
echo "==> 6. Cloudflare Tunnel"

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
# "gstation" and every later lookup becomes ambiguous. Always look first.
RESP="$(cf_api GET "/accounts/$ACCOUNT_ID/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false")"
cf_ok "$RESP" "tunnel lookup"
TUNNEL_ID="$(jq -r '.result[0].id // empty' <<<"$RESP")"

if [[ -n "$TUNNEL_ID" ]]; then
  pass "tunnel '$TUNNEL_NAME' already exists ($TUNNEL_ID)"
else
  # The tunnel secret is symmetric and caller-chosen: Cloudflare stores a copy,
  # cloudflared presents a copy. Nothing has to be generated on their side.
  # config_src=local is load-bearing - it says the ingress rules live in our
  # ConfigMap. With "cloudflare" the dashboard owns routing and configmap.yaml
  # is silently ignored.
  RESP="$(cf_api POST "/accounts/$ACCOUNT_ID/cfd_tunnel" \
    "$(jq -nc --arg n "$TUNNEL_NAME" --arg s "$(openssl rand -base64 32)" \
        '{name:$n, tunnel_secret:$s, config_src:"local"}')")"
  cf_ok "$RESP" "tunnel create"
  TUNNEL_ID="$(jq -r '.result.id' <<<"$RESP")"
  pass "created tunnel '$TUNNEL_NAME' ($TUNNEL_ID)"
fi

# The token endpoint returns base64 of {"a":account,"t":tunnel,"s":secret}, so
# the credentials stay recoverable for a tunnel whose secret this run never
# saw. That is what makes a re-run idempotent instead of forcing a delete and
# recreate. openssl rather than base64(1), whose decode flag differs between
# the BSD and GNU builds.
RESP="$(cf_api GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token")"
cf_ok "$RESP" "tunnel token"
jq -r '.result' <<<"$RESP" | openssl base64 -d -A \
  | jq '{AccountTag: .a, TunnelID: .t, TunnelSecret: .s}' > "$WORK_DIR/credentials.json"

jq -e '(.TunnelSecret // "") != "" and (.TunnelID // "") != ""' "$WORK_DIR/credentials.json" >/dev/null 2>&1 \
  && pass "tunnel credentials derived" \
  || { fail "could not derive tunnel credentials from the token endpoint"; exit 1; }
echo

# ---------------------------------------------------------------------------
# 7. DNS
#    A proxied CNAME per hostname. cfargotunnel.com only resolves inside
#    Cloudflare's network, so an unproxied record here is a dead record. The
#    apex works because Cloudflare flattens CNAMEs.
# ---------------------------------------------------------------------------
echo "==> 7. DNS"

TUNNEL_TARGET="$TUNNEL_ID.cfargotunnel.com"

for HOST in "${HOSTNAMES[@]}"; do
  # Filtered to the address-record types only. A bare ?name= lookup also
  # returns MX/TXT/CAA records at the apex, and taking .result[0] from that
  # would happily overwrite the domain's mail routing with a CNAME.
  RECORD_ID=""; RECORD_TYPE=""; RECORD_CONTENT=""
  for TYPE in CNAME A AAAA; do
    RESP="$(cf_api GET "/zones/$ZONE_ID/dns_records?name=$HOST&type=$TYPE")"
    cf_ok "$RESP" "dns lookup for $HOST"
    RECORD_ID="$(jq -r '.result[0].id // empty' <<<"$RESP")"
    if [[ -n "$RECORD_ID" ]]; then
      RECORD_TYPE="$TYPE"
      RECORD_CONTENT="$(jq -r '.result[0].content // empty' <<<"$RESP")"
      break
    fi
  done

  BODY="$(jq -nc --arg n "$HOST" --arg c "$TUNNEL_TARGET" \
      '{type:"CNAME", name:$n, content:$c, proxied:true, ttl:1}')"

  if [[ -z "$RECORD_ID" ]]; then
    RESP="$(cf_api POST "/zones/$ZONE_ID/dns_records" "$BODY")"
    cf_ok "$RESP" "dns create for $HOST"
    pass "$HOST -> $TUNNEL_TARGET (created)"
  elif [[ "$RECORD_TYPE" == "CNAME" && "$RECORD_CONTENT" == "$TUNNEL_TARGET" ]]; then
    pass "$HOST -> $TUNNEL_TARGET (already correct)"
  else
    # This is the one step that can take an existing site down, so it says so
    # rather than silently repointing the record.
    echo "  [WARN] $HOST currently points at $RECORD_TYPE $RECORD_CONTENT"
    echo "         Repointing it at the tunnel."
    RESP="$(cf_api PUT "/zones/$ZONE_ID/dns_records/$RECORD_ID" "$BODY")"
    cf_ok "$RESP" "dns update for $HOST"
    pass "$HOST -> $TUNNEL_TARGET (updated)"
  fi
done
echo

# ---------------------------------------------------------------------------
# 8. Deploy cloudflared
# ---------------------------------------------------------------------------
echo "==> 8. Deploy cloudflared"

if [[ ! -s "$KUBECONFIG_OUT" ]]; then
  fail "no usable kubeconfig - skipping the cloudflared deploy"
else
  export KUBECONFIG="$KUBECONFIG_OUT"

  kubectl apply -f "$MANIFEST_DIR/namespace.yaml" >/dev/null \
    && kubectl apply -f "$MANIFEST_DIR/configmap.yaml" >/dev/null \
    && pass "namespace and tunnel config applied" \
    || fail "could not apply namespace/configmap"

  # `create --dry-run=client | apply` is the idempotent form: plain `create
  # secret` fails on a re-run, and `apply` alone cannot build a Secret from a
  # file. Passing the file rather than --from-literal keeps the secret out of
  # argv, where any user on the box could read it from ps.
  kubectl -n cloudflared create secret generic cloudflared-creds \
    --from-file=credentials.json="$WORK_DIR/credentials.json" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
    && pass "secret 'cloudflared-creds' reconciled" \
    || fail "could not reconcile the cloudflared-creds secret"

  # cloudflared reads its config only at startup, and editing a ConfigMap
  # restarts nothing. Stamping the config's hash onto the pod template makes a
  # changed config roll the pods and an unchanged one a no-op.
  CONFIG_SHA="$(shasum -a 256 "$MANIFEST_DIR/configmap.yaml" | cut -c1-16)"
  sed "s|replace-me-or-run-kubectl-rollout-restart|$CONFIG_SHA|" \
    "$MANIFEST_DIR/deployment.yaml" | kubectl apply -f - >/dev/null \
    && pass "deployment applied (config checksum $CONFIG_SHA)" \
    || fail "could not apply the cloudflared deployment"

  if kubectl -n cloudflared rollout status deploy/cloudflared --timeout=180s >/dev/null 2>&1; then
    pass "cloudflared pods are ready"
  else
    fail "cloudflared rollout did not complete (kubectl -n cloudflared logs -l app=cloudflared)"
  fi

  # Pod readiness only proves cloudflared started. "healthy" from the API is
  # what proves Cloudflare's edge is actually holding connections to it.
  TUNNEL_STATUS="unknown"
  for _ in $(seq 1 12); do
    TUNNEL_STATUS="$(jq -r '.result.status // "unknown"' \
      <<<"$(cf_api GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID")")"
    [[ "$TUNNEL_STATUS" == "healthy" ]] && break
    sleep 5
  done
  [[ "$TUNNEL_STATUS" == "healthy" ]] \
    && pass "tunnel is healthy - the edge is holding connections to the cluster" \
    || fail "tunnel status is '$TUNNEL_STATUS', expected healthy"
fi
echo

# ---------------------------------------------------------------------------
# 9. Manual checklist
# ---------------------------------------------------------------------------
echo "==> 9. Manual checklist"

# A LaunchAgent is bound to a GUI login session. On a headless box that reboots
# unattended, nothing logs in, so nothing starts the VM.
if [[ "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)" == "$USER" ]]; then
  pass "automatic login is enabled for $USER (the LaunchAgent will fire after a reboot)"
else
  echo "  [WARN] Automatic login is NOT enabled for $USER. The LaunchAgent in step 4"
  echo "         runs at *login*, not at boot - after a reboot this cluster stays down"
  echo "         until someone signs in. Enable it in:"
  echo "         System Settings > Users & Groups > Automatically log in as"
fi

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo unknown)"
echo "  [NOTE] Ingress is published on the LAN through this Mac, on high ports"
echo "         because macOS reserves everything under 1024 for root:"
echo "           http://${LAN_IP}:8080   ->  Traefik :80"
echo "           https://${LAN_IP}:8443  ->  Traefik :443"
echo "         The Kubernetes API stays on 127.0.0.1:6443 and is not exposed."
echo "  [NOTE] To give the VM its own LAN address instead (real :80/:443, addressable"
echo "         independently of the Mac), install socket_vmnet into a root-owned path,"
echo "         run 'limactl sudoers | sudo tee /etc/sudoers.d/lima', then uncomment the"
echo "         'networks: - lima: shared' block in lima.yaml and recreate the VM."
echo "  [NOTE] Persistent volumes live on the VM's virtual disk via k3s's"
echo "         local-path-provisioner, at /var/lib/rancher/k3s/storage inside the guest."
echo "         No host directory is mounted in - back data out rather than running"
echo "         databases off a virtiofs share."
echo "  [NOTE] Upgrading k3s is deliberately manual: the provision script only installs"
echo "         when /var/lib/rancher/k3s is absent. Change 'k3sChannel' in lima.yaml, then"
echo "         re-run the installer inside the guest. To start clean:"
echo "           limactl delete -f $VM_NAME && ./$(basename "$0")"
echo "  [NOTE] Set SSL/TLS encryption mode to 'Full (strict)' for $DOMAIN in the"
echo "         Cloudflare dashboard. 'Flexible' buys nothing behind a tunnel and causes"
echo "         redirect loops as soon as an app issues its own HTTPS redirect."
echo "  [NOTE] The tunnel hands every request to Traefik with its Host header intact,"
echo "         so routing is plain Ingress objects - nothing is served at the hostnames"
echo "         above until an Ingress claims them. See k8s/cloudflared/README.md."
echo "  [NOTE] CF_API_TOKEN is not needed again unless you add hostnames or rebuild the"
echo "         tunnel. The cluster keeps its own copy of the tunnel secret, and this"
echo "         repo holds no credentials at all."
echo

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=================================================================="
if [[ "$FAILURES" -eq 0 ]]; then
  echo " All automated checks passed."
else
  echo " $FAILURES check(s) failed - see [FAIL] lines above."
fi
echo " Cluster:    $VM_NAME (k3s, single node)"
echo " Kubeconfig: $KUBECONFIG_OUT"
echo " Tunnel:     ${TUNNEL_NAME}${TUNNEL_ID:+ ($TUNNEL_ID)}"
echo " Published:  ${HOSTNAMES[*]}"
echo
echo "   kubectl get nodes    # '$VM_NAME' is merged into ~/.kube/config as the current context"
echo "=================================================================="

exit $(( FAILURES > 0 ? 1 : 0 ))
