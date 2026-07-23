# cloudflared

Cloudflare Tunnel as the public front door for the gstation cluster.

Traffic path:

```
browser -> Cloudflare edge (terminates TLS)
        -> tunnel (outbound QUIC, opened by these pods)
        -> traefik.kube-system.svc.cluster.local:80
        -> Ingress host match -> Service -> Pod
```

`cloudflared` holds a single catch-all rule and does no routing of its own.
All hostname and path routing lives in ordinary `Ingress` objects handled by
the Traefik that k3s ships. Adding a site never means touching this directory.

Because the tunnel dials outbound, the home router needs no port forward and
no static IP. The Lima port forwards in `lima.yaml` are unrelated to this path
-- they exist so the cluster is also reachable directly from the LAN.

## Bootstrap

Nothing here is applied by hand. `../../k8s.sh` provisions the tunnel through
the Cloudflare API, derives its credentials, loads them into the cluster as the
`cloudflared-creds` Secret, and applies these manifests. See the repo README
for the token it needs.

The credential never touches this repo or `~/.cloudflared` -- the script
assembles it in a `mktemp` directory that is shredded on exit, and the cluster
holds the only lasting copy.

Re-running is the supported way to reconcile drift. An existing tunnel is
reused rather than recreated: its secret is recovered from the API's token
endpoint, which returns base64 of `{"a":account,"t":tunnel,"s":secret}`.

Verify:

```sh
kubectl -n cloudflared get pods
kubectl -n cloudflared logs -l app=cloudflared --tail=50   # expect 2 conns on the single pod
```

## Routing a site to a Deployment

TLS terminates at the Cloudflare edge under the Universal SSL cert, which
covers the apex and `*.gerardosalazar.com`. Inside the tunnel it is plain HTTP
to Traefik, so the Ingress carries no `tls:` block and needs no cert-manager.

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

## Operational notes

- **Set SSL/TLS mode to Full (strict)** in the Cloudflare dashboard. `Flexible`
  buys nothing behind a tunnel and causes redirect loops as soon as an app
  issues its own HTTPS redirect.
- **Client IP** arrives in `CF-Connecting-IP`. Anything that logs or rate-limits
  on remote address will otherwise see only the cloudflared pod.
- **Config changes need a restart.** `cloudflared` reads its config at startup
  only: `kubectl -n cloudflared rollout restart deploy/cloudflared`.
- **Uptime is the MacBook's uptime.** Anything served here is down when the host
  reboots. Cloudflare's cache covers static sites; dynamic apps just go dark.
- **Upload bodies are capped at the edge** (100 MB on the Free plan), and
  Cloudflare's ToS discourages bulk media streaming through the proxy.
