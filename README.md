# gstation

Macbook as a homelab.

A MacBook configured as an always-on, lid-closed server, running a single-node
k3s cluster inside a Lima VM, published to the internet through a Cloudflare
Tunnel.

```
internet ─→ Cloudflare edge ─→ tunnel ─→ cloudflared pod ─→ Traefik ─→ your app
                                              (k3s in a Lima VM on the MacBook)
LAN ──────────────────────────────────────→ Traefik on <mac-ip>:8080 / :8443
```

No port forwarding, no static IP, no dynamic DNS: the tunnel dials outward, so
the home router never needs an inbound hole.

| File | Purpose |
|---|---|
| `setup.sh` | Configures macOS as a headless server: battery, power, sleep, SSH, VNC, firewall |
| `lima.yaml` | The Lima VM definition and k3s install |
| `k8s.sh` | Builds the cluster, provisions the tunnel, deploys cloudflared |
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
- A domain already using Cloudflare's nameservers. `k8s.sh` defaults to
  `gerardosalazar.com`; override with `DOMAIN=example.com ./k8s.sh`, and
  `TUNNEL_NAME=… ` to name the tunnel something other than `gstation`.

**A Cloudflare API token**, exported as `CF_API_TOKEN`. Create it at
**dash.cloudflare.com → My Profile → API Tokens → Create Token → Custom**:

| Scope | Why |
|---|---|
| `Account → Cloudflare Tunnel → Edit` | create and read back the tunnel |
| `Zone → DNS → Edit` (on your domain) | create the proxied CNAMEs |
| `Zone → Zone → Read` | look up the zone and account ID by domain name |

`k8s.sh` exits immediately if `CF_API_TOKEN` is unset rather than discovering
it half an hour into a VM build.

Everything else — Lima, kubectl, helm, jq — is installed by the scripts.

> **If the domain already serves a live site, read the DNS warning below before
> running `k8s.sh`.** It repoints existing records at the tunnel.

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

Six verified steps: installs Homebrew and AlDente; disables idle sleep, disk
sleep and user-initiated sleep on AC; enables Remote Login and Screen Sharing;
installs a `caffeinate` LaunchDaemon as a backstop; and turns the application
firewall on.

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
3. **kubeconfig** — writes `~/.kube/gstation.yaml` with a `gstation` context
4. **LaunchAgent** — restarts the VM after a reboot
5. **Readiness** — waits for the node, coredns, local-path, metrics-server, Traefik
6. **Tunnel** — finds or creates the Cloudflare tunnel, derives its credentials
7. **DNS** — reconciles a proxied CNAME per hostname
8. **cloudflared** — applies the manifests and the credentials Secret, then
   confirms Cloudflare reports the tunnel `healthy`
9. **Checklist** — prints what could not be automated

It exits non-zero if any check failed, and every failure line starts with
`[FAIL]`.

### DNS: this can take a live site down

Step 7 reconciles `$DOMAIN` and `www.$DOMAIN` to proxied CNAMEs pointing at the
tunnel. If a record already exists and points somewhere else, **it is
repointed**, not skipped — the script warns loudly (`[WARN] … currently points
at A 203.0.113.10`) but does not stop. Only address records (`CNAME`/`A`/`AAAA`)
are touched; MX, TXT and CAA at the apex are left alone, so mail routing
survives.

If that is not what you want, run against a subdomain instead —
`DOMAIN=lab.example.com ./k8s.sh`.

### Verifying

```sh
export KUBECONFIG="$HOME/.kube/config:$HOME/.kube/gstation.yaml"
kubectl --context gstation get nodes
kubectl -n cloudflared logs -l app=cloudflared --tail=50
```

A `healthy` tunnel means Cloudflare's edge is holding connections to the pod.
It does **not** mean anything is served yet — see *Serving something*.

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

On a 48 GB machine, 16 GiB suits k3s plus a reasonable set of services and
24–32 GiB is safe once databases are involved; `vmType: vz` grows toward the
ceiling rather than reserving it up front. For CPUs, check `sysctl -n hw.ncpu`
and leave at least a third to the host so the Mac stays responsive over Screen
Sharing.

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

To tear the whole thing down, including the auto-start:

```sh
launchctl bootout "gui/$UID" ~/Library/LaunchAgents/com.local.lima-gstation.plist
rm ~/Library/LaunchAgents/com.local.lima-gstation.plist
limactl delete -f gstation
rm ~/.kube/gstation.yaml
```

The Cloudflare tunnel and DNS records outlive that — delete those in the
dashboard if you are done with them.

## Secrets

There are exactly two, and neither is in this repo:

| Secret | Needed | Lives |
|---|---|---|
| `CF_API_TOKEN` | only while `k8s.sh` runs | macOS Keychain |
| tunnel credentials | every pod start | the cluster, as a Secret |

The API token is not part of the steady-state deploy path. It provisions the
tunnel once and converts its own authority into a credential the cluster holds;
after that, redeploys and restarts need nothing from you. `k8s.sh` assembles
the tunnel credential in a `mktemp` directory shredded on exit, and passes it to
`kubectl` as a file rather than an argument so it never appears in `ps` output.

If you later want the cluster reproducible from the repo alone — no Cloudflare
token, no network — encrypt the Secret into git with SOPS + age. Prefer that
over Sealed Secrets here: Sealed Secrets encrypts to a key held *inside* the
cluster, and this cluster is a disposable VM.

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
- **HTTP(S) only.** Raw TCP — SSH, Postgres, the Kubernetes API — needs a
  separate tunnel rule plus `cloudflared access` on the client, or WARP.
- **Upload bodies are capped at the edge** (100 MB on the Free plan), and
  Cloudflare's ToS discourages bulk media streaming through the proxy.
- **Set SSL/TLS mode to Full (strict)** in the Cloudflare dashboard. `Flexible`
  buys nothing behind a tunnel and causes redirect loops as soon as an app
  issues its own HTTPS redirect.
