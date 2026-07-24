# gstation

Scripts to configure a MacBook as an always-on, lid-closed server. It runs a single-node
k3s cluster inside a Lima VM on my home network exposed to the internet through Cloudflare
Tunnels.

```
internet ─→ CF edge ─→ CF tunnel ─→ cloudflared pod ─→ Traefik ─→ apps
```

Cloudflare Tunnels prevent you from having to punch holes in your home network. This is accomplished through `cloudflared` running outbound traffic to route through.

## Project Layout

| File | Purpose |
|---|---|
| `setup.sh` | Configures macOS as a headless server: battery, power, sleep, SSH, VNC, firewall |
| `lima.yaml` | The Lima VM definition and k3s install |
| `k8s.sh` | Builds the cluster, provisions the tunnel, deploys cloudflared |
| `local-tunnel.sh` | A second tunnel, run on the host, publishing this Mac's SSH |
| `teardown.sh` | Removes everything `k8s.sh` created, so it can be rebuilt clean |
| `k8s/cloudflared/` | Tunnel manifests — see [its README](k8s/cloudflared/README.md) |

## Requirements

**Hardware and OS**
- An Apple Silicon Mac, permanently on AC power
- macOS 13 or newer — `lima.yaml` uses `vmType: vz`, Apple's Virtualization
  framework
- Homebrew (`setup.sh` installs it if missing)

**Full Disk Access**, granted to the terminal app you run `setup.sh` from
(Terminal, iTerm, …), in **System Settings → Privacy & Security → Full Disk
Access**. Enabling Remote Login is gated by TCC *separately from root*, so
without it `setup.sh` silently fails to turn SSH on even under `sudo`. The
script detects this, tells you, and opens the settings pane — grant it and
re-run. Everything else in `setup.sh` works without it.

**Domain**

A domain already using Cloudflare's nameservers. `k8s.sh` defaults to
  `gerardosalazar.com`; override with `DOMAIN=example.com ./k8s.sh`, and
  `TUNNEL_NAME=… ` to name the tunnel something other than `gstation`.

**A Cloudflare API token** 

Exported as `CF_API_TOKEN`. Create it at
**dash.cloudflare.com → My Profile → API Tokens → Create Token → Custom**:

| Scope | Why |
|---|---|
| `Account → Cloudflare Tunnel → Edit` | create and read back the tunnel |
| `Zone → DNS → Edit` (on your domain) | create the proxied CNAMEs |
| `Zone → Zone → Read` | look up the zone and account ID by domain name |

`k8s.sh` exits immediately if `CF_API_TOKEN` is unset rather than discovering
it half an hour into a VM build.

Everything else — Lima, kubectl, helm, jq — is installed by the scripts.

## Deploying

```sh
# 1. Make the Mac a server. Needs root: pmset, systemsetup and launchctl do.
sudo ./setup.sh

# 2. Provide the Cloudflare token, without putting it in shell history
#    or a plaintext dotfile.
security add-generic-password -a "$USER" -s cloudflare-api-token -w
export CF_API_TOKEN=$(security find-generic-password -a "$USER" -s cloudflare-api-token -w)

# 3. Build the cluster and publish it. NOT with sudo - Lima state is per-user.
./k8s.sh
```

Budget several minutes for the first `k8s.sh`: it downloads an Ubuntu cloud
image, resizes a 100 GiB disk, and installs k3s from scratch. Later runs
reconcile in seconds.

### What `setup.sh` does

Six verified steps:

1. **Homebrew & AlDente** — installs Homebrew and AlDente
2. **Power management** — disables idle sleep, disk sleep and user-initiated
   sleep on AC
3. **Remote access** — enables Remote Login and Screen Sharing
4. **Keep-awake** — installs a `caffeinate` LaunchDaemon as a backstop
5. **Firewall** — turns the application firewall on
6. **Checklist** — prints what could not be automated

Three things it deliberately leaves to you:

- **Open AlDente once and set a charge ceiling** (~80%). A Mac pinned at 100%
  on AC indefinitely wears its battery out. The script installs it but cannot
  configure it.
- **It does not auto-restart after a power failure.** `autorestart` is set to
  `0` on purpose — if the battery also drains during an outage, the Mac stays
  off rather than powering on unattended.
- **Wake-on-LAN only works over wired Ethernet**, never Wi-Fi. The script
  enables it and prints which interface you are actually on.

### What `k8s.sh` does

Nine verified steps:

1. **Tooling** — installs lima, kubectl, helm, jq; validates `lima.yaml`
2. **VM** — creates or starts the Lima instance, confirms k3s is active
3. **kubeconfig** — merges a `gstation` context into `~/.kube/config` (leaving any other contexts intact) and makes it current, so a bare `kubectl` just works
4. **LaunchAgent** — restarts the VM after a reboot
5. **Readiness** — waits for the node, coredns, local-path, metrics-server, Traefik
6. **Tunnel** — finds or creates the Cloudflare tunnel, derives its credentials
7. **DNS** — reconciles a proxied CNAME per hostname
8. **cloudflared** — applies the manifests and the credentials Secret, then
   confirms Cloudflare reports the tunnel `healthy`
9. **Checklist** — prints what could not be automated

It exits non-zero if any check failed, and every failure line starts with
`[FAIL]`.

### Verifying

`k8s.sh` merges the `gstation` context into `~/.kube/config` and makes it
current, so no `KUBECONFIG` export is needed:

```sh
kubectl get nodes                                    # or: kubectl --context gstation …
kubectl -n cloudflared logs -l app=cloudflared --tail=50
```

A `healthy` tunnel means Cloudflare's edge is holding connections to the pod.
It does **not** mean anything is served yet — see *Serving something*.

## SSH from another machine

`local-tunnel.sh` creates a **second, independent** tunnel — `gstation-ssh` —
that reaches this Mac's own sshd. It has to be separate: the `gstation` tunnel
runs *inside* k3s and only speaks HTTP to Traefik, and Cloudflare will not carry
raw SSH over an HTTP hostname.

Its `cloudflared` runs on the host under a `KeepAlive` LaunchAgent rather than in
the cluster, so SSH still works when the VM is down — which is the whole point of
a remote console.

### Running it

Authorize a key **first**; step 2 refuses to publish the hostname without one.

```sh
export CF_API_TOKEN=…        # same token and scopes as k8s.sh
./local-tunnel.sh            # NOT with sudo - the LaunchAgent is per-user
```

Eight verified steps: installs cloudflared and jq; confirms sshd is listening and
that `~/.ssh/authorized_keys` exists (0600 inside a 0700 directory) with at least
one key in it; finds or creates the tunnel; reconciles a proxied CNAME for
`ssh.$DOMAIN`; writes credentials and config into `~/.cloudflared/`; loads the
LaunchAgent; and waits for Cloudflare to report the tunnel `healthy`.

`CF_API_TOKEN` is read straight from the environment and the script exits if it
is empty — nothing reads the Keychain, that is just a convenient way to fill the
variable. Override `SSH_TUNNEL_NAME` or `SSH_HOSTNAME` to change the tunnel name
or the published hostname.

### Authorizing a key

Step 2 creates `~/.ssh/authorized_keys` with the right modes if it is missing,
then **hard-exits when it contains no keys**. Every other failed check in these
scripts is counted and execution continues; this one stops, because the failure
mode is not a broken tunnel but a working one — publishing the hostname with no
key on the box leaves macOS's default `PasswordAuthentication yes` as the only
thing between the internet and your home directory.

From the client, over the LAN:

```sh
ssh-copy-id -i ~/.ssh/id_ed25519.pub gsalazar@10.0.0.34
ssh -o PreferredAuthentications=publickey gsalazar@10.0.0.34 true
```

Forcing `publickey` on the verify matters — a plain `ssh` that quietly falls back
to a password looks like success and proves nothing.

**The key's filename matters.** OpenSSH only auto-offers `id_rsa`, `id_ecdsa`,
`id_ed25519` and the `_sk` variants. A key named anything else — `id_rsa_gnode`,
`id_work` — gets copied to the server happily by `ssh-copy-id` and is then never
offered by `ssh`. The result is `Permission denied (publickey,…)` against a
perfectly correct `authorized_keys`, which is a confusing thing to debug. Use a
default name, or name the file in `~/.ssh/config`.

### Client config

`cloudflared` has to be installed on the client too — it is what dials the edge.

```
Host gstation
  HostName 10.0.0.34
  User gsalazar

Host ssh.gerardosalazar.com
  User gsalazar
  ProxyCommand cloudflared access ssh --hostname %h
```

`User` is required whenever your account name differs between the two machines.
If the key is not a default filename, add `IdentityFile ~/.ssh/<key>` and
`IdentitiesOnly yes` to both entries — the `ProxyCommand` alone does not save you
from the filename problem above.

### Locking it down

The hostname is an SSH door reachable from the whole internet. Cloudflare proxies
the bytes but authenticates nobody by default, so sshd is the only gate until you
add one.

Once key auth is verified, turn passwords off:

```sh
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
  | sudo tee /etc/ssh/sshd_config.d/100-no-passwords.conf
sudo launchctl kickstart -k system/com.openssh.sshd
```

Keep a session open while testing that, and authorize a second key before you do
it — a bad sshd config plus a locked door is a trip to the physical keyboard.

Then put a **Cloudflare Access** self-hosted app over the hostname: Zero Trust →
Access → Applications → Add → Self-hosted, domain `ssh.$DOMAIN`, plus a policy
allowing your email. One-time PIN works with no identity provider to configure.
Access then authenticates you at the edge, before the SSH handshake ever reaches
the Mac.

That is a **dashboard-only change — nothing on this Mac changes**: not sshd, not
cloudflared, not the tunnel. The client does not change either, since
`cloudflared access ssh` already handles it, opening a browser on first connect
and caching the token. The one variant that *would* touch the Mac is Access
short-lived certificates, which replace `authorized_keys` with `TrustedUserCAKeys`
in sshd_config.

### Notes

- `~/.cloudflared/gstation-ssh.json` is this tunnel's credential — a bearer secret
  that anyone reading it can use to impersonate the tunnel. It is written 0600 in
  a 0700 directory. Exclude `~/.cloudflared` from Time Machine if you would rather
  it not be in backups. This is the one on-disk secret the setup cannot avoid,
  precisely because cloudflared runs on the host rather than in the cluster.
- **The two tunnels are entirely independent.** Deleting one never affects the
  other, and `teardown.sh` does not know about `gstation-ssh` at all — remove it
  by hand (`launchctl bootout`, the plist, `~/.cloudflared/`, and the tunnel and
  its DNS record in the dashboard).
- LAN SSH is unchanged and keeps working.
- Same LaunchAgent caveat as the cluster: it fires at login, not at boot.

## Sizing the VM

CPU, memory and disk live in `lima.yaml`, not in any script:

```yaml
cpus: 6
memory: "16GiB"
disk: "100GiB"
```

Lima copies that template into `~/.lima/gstation/lima.yaml` when the instance is
created, so the two can diverge. **`k8s.sh` step 2 compares them and applies the
template's values** — edit `lima.yaml`, re-run, done.

That is not an in-place change. CPU and memory are fixed at VM boot and
`limactl` refuses to edit a running instance at all (`cannot edit a running
instance`), so reconciling means stop → edit → start. **The cluster is down for
that window.** The script says so before it acts:

```
Drift vs lima.yaml: cpus 6->8 memory 16->24
Applying this restarts the VM - the cluster is down until it is back.
```

Two limits:

- **Disks only grow.** A smaller `disk:` is warned about and ignored; shrinking
  means recreating the instance.
- **Whole GiB only.** Values the script cannot compare as plain integers
  (`8192MiB`, a raw byte count) are skipped with a warning rather than guessed
  at. Lima accepts them; the drift check does not.

To resize without a full `k8s.sh` run:

```sh
limactl stop gstation
limactl edit gstation --cpus=8 --memory=24 --disk=200
limactl start gstation
```

Change `lima.yaml` too, or the next re-run reverts you.

Reserving about 2/3rds of the resources for the VM is safe.

## Re-running

Every step is find-or-create, so re-running reconciles drift rather than
duplicating anything. In particular an existing tunnel is reused, not
recreated — its secret is recovered from Cloudflare's token endpoint, so a
rebuilt cluster gets the same tunnel back without touching DNS.

The one re-run that is *not* free is VM sizing: changing `lima.yaml` and
re-running restarts the VM, as described above.

To rebuild the cluster from scratch, keeping the tunnel and its DNS:

```sh
limactl delete -f gstation && ./k8s.sh
```

## Uninstalling

```sh
./teardown.sh                 # VM, LaunchAgent, kubeconfig, logs
./teardown.sh --yes           # skip the confirmation prompt
./teardown.sh --cloudflare    # also delete the tunnel and its DNS records
./teardown.sh --cache         # also drop Lima's downloaded image cache
```

It asks you to type the instance name before doing anything, and refuses to run
non-interactively without `--yes`. Every step tolerates the thing already being
gone, so it is safe to re-run.

**The Cloudflare tunnel and DNS survive by default, and usually should.**
`k8s.sh` finds the existing tunnel and recovers its secret from the API, so a
rebuilt cluster comes back on the same hostnames with no DNS change at all.
`--cloudflare` is for retiring the domain setup, not for rebuilding. When it is
used, only records actually pointing at *this* tunnel are deleted — anything
else at those hostnames is left alone.

What it deliberately does **not** touch: the macOS server configuration from
`setup.sh` (sleep, SSH, VNC, firewall, the keepawake daemon) and the Homebrew
packages, which are general tools.

Note that deleting the instance destroys its virtual disk, and every
PersistentVolume with it — local-path-provisioner stores them inside the VM.
Nothing there is recoverable afterwards.

A full uninstall/reinstall cycle:

```sh
./teardown.sh --yes
export CF_API_TOKEN=$(security find-generic-password -a "$USER" -s cloudflare-api-token -w)
./k8s.sh
```

## Serving something

Nothing is served at your domain until an Ingress claims the hostname. The
tunnel hands every request to Traefik with the `Host` header intact, so routing
is ordinary Kubernetes:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: website
spec:
  ingressClassName: traefik
  rules:
    - host: gerardosalazar.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: website
                port:
                  number: 80
```

No `tls:` block and no cert-manager: TLS terminates at Cloudflare's edge.

## Known limits

- **Uptime is the MacBook's uptime.** One node, one host, in your house.
- **The LaunchAgent fires at login, not at boot.** Without automatic login
  enabled, the cluster stays down after an unattended reboot. `k8s.sh` warns
  about this.
- **Clamshell mode needs an external display or a paired keyboard/mouse**, plus
  AC power. With neither attached, closing the lid sleeps the Mac regardless of
  every `pmset` setting `setup.sh` applies.
- **arm64 images only.** Rosetta is off in `lima.yaml`, so an `amd64`-only
  image fails with `exec format error` rather than running translated. Almost
  everything mainstream is multi-arch; `lima.yaml` documents how to turn it back
  on, but Rosetta 2 is being retired in macOS 28, so it is a stopgap.
- **k3s upgrades are manual.** The provision script installs only when
  `/var/lib/rancher/k3s` is absent, so restarts never move you a minor version.
  Change `k3sChannel` in `lima.yaml` and re-run the installer inside the guest.
- **Persistent volumes live inside the VM** (local-path-provisioner, at
  `/var/lib/rancher/k3s/storage`). No host directory is mounted in, so back data
  *out* rather than expecting it on the Mac's filesystem.
- **The cluster tunnel is HTTP(S) only.** Raw TCP — Postgres, the Kubernetes
  API — needs its own tunnel rule plus `cloudflared access` on the client, or
  WARP. SSH already has one: see *SSH from another machine*.
- **Upload bodies are capped at the edge** (100 MB on the Free plan), and
  Cloudflare's ToS discourages bulk media streaming through the proxy.
- **Set SSL/TLS mode to Full (strict)** in the Cloudflare dashboard. `Flexible`
  buys nothing behind a tunnel and causes redirect loops as soon as an app
  issues its own HTTPS redirect.
