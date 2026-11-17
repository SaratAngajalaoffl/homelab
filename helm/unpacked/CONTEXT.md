# unpacked — manual bootstrap

Website for the Unpacked by Mugiwara YouTube channel, served at
`unpackedbymugiwara.com` (`www.` 301s to the apex). Source, Dockerfile and CI live in the
private `SaratAngajalaoffl/unpacked-by-mugiwara-web` repo; this chart only deploys the image.

## 1. GHCR pull secret (required before the pod can start)

The image package is **private**, so the Deployment references an `imagePullSecret` named
`ghcr-pull`. Until it exists the pod sits in `ImagePullBackOff`.

1. Create a **classic PAT** scoped to `read:packages` only (github.com/settings/tokens). Reusing
   the jeeva PAT is fine if it's already `read:packages`-only.
2. ```bash
   KUBECONFIG=~/.kube/k3s-homelab.yaml kubectl create secret docker-registry ghcr-pull \
     -n homelab-unpacked --dry-run=client -o json \
     --docker-server=ghcr.io --docker-username=<your-gh-username> --docker-password=<the-PAT> \
     > /tmp/ghcr-pull.json
   KUBECONFIG=~/.kube/k3s-homelab.yaml kubeseal \
     --controller-namespace kube-system --controller-name sealed-secrets-controller \
     --format yaml < /tmp/ghcr-pull.json > helm/unpacked/templates/sealed-ghcr-pull-secret.yaml
   shred -u /tmp/ghcr-pull.json
   ```
3. Check the sealed file has `metadata.name: ghcr-pull`, `namespace: homelab-unpacked`, and
   `type: kubernetes.io/dockerconfigjson` under `spec.template`. Commit, push — ArgoCD syncs it.

## 2. Image pinning

`values.yaml` pins CI's immutable `sha-<short>` tag because the digest couldn't be resolved
without GHCR credentials. Once you have the PAT, switch to the digest-pinned form used by every
other stack:

```bash
echo <the-PAT> | docker login ghcr.io -u <your-gh-username> --password-stdin
docker buildx imagetools inspect ghcr.io/saratangajalaoffl/unpacked-by-mugiwara-web:latest \
  --format '{{json .Manifest.Digest}}'
# web.image.tag: "latest@sha256:<digest>"
```

Renovate has no GHCR credentials (no `hostRules`), so like jeeva it can't see this private
image — after a push to the site's `main`, bump the tag/digest here by hand and `git push`.

## 3. In-cluster DNS (already applied)

The router blocks hairpin traffic, so cert-manager's HTTP-01 self-check for this domain needs the
`unpackedbymugiwara.server` block in `helm/coredns-custom.yaml` (bootstrap-applied:
`khl apply -f helm/coredns-custom.yaml`).
