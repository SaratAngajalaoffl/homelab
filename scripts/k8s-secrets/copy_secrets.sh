#!/usr/bin/env bash
# Disaster-recovery export for the homelab k3s cluster, mirroring
# scripts/env/copy_env.sh's role for *.env files. Two things are backed up,
# since neither lives safely in git on its own:
#
#   1. The Sealed Secrets controller's active signing key(s) (kube-system).
#      Without this, a rebuilt cluster gets a NEW key and every committed
#      SealedSecret YAML in helm/*/templates/ becomes permanently
#      undecryptable — they'd all need re-sealing from scratch.
#   2. A plaintext safety-net copy of every Secret in a homelab-* namespace
#      that ISN'T owned by a SealedSecret (i.e. not yet converted to the
#      sealed-secrets pattern) — same reasoning as *.env: something has to
#      hold the plaintext outside git, and until now that's been your head.
#
# Output is JSON copied to the clipboard, same as copy_env.sh — paste it into
# your vault (e.g. Bitwarden), not into this repo.
set -euo pipefail

KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/k3s-homelab.yaml}"
if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
  echo "error: kubeconfig not found at ${KUBECONFIG_FILE} (set KUBECONFIG_FILE to override)" >&2
  exit 1
fi
export KUBECONFIG="${KUBECONFIG_FILE}"

copy_to_clipboard() {
  if command -v wl-copy >/dev/null 2>&1; then
    wl-copy
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --input
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard
  elif command -v pbcopy >/dev/null 2>&1; then
    pbcopy
  else
    echo "error: no clipboard tool found (install wl-copy, xclip, xsel, or use macOS pbcopy)" >&2
    exit 1
  fi
}

OUT="$(python3 - <<'PY'
import json
import subprocess
import sys

def kubectl_json(*args):
    result = subprocess.run(
        ["kubectl", *args, "-o", "json"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"error: kubectl {' '.join(args)} failed: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout)

# 1. Sealed Secrets controller signing key(s) — labeled by the controller itself.
key_secrets = kubectl_json(
    "get", "secret", "-n", "kube-system",
    "-l", "sealedsecrets.bitnami.com/sealed-secrets-key",
)
controller_keys = {}
for item in key_secrets.get("items", []):
    name = item["metadata"]["name"]
    controller_keys[name] = item.get("data", {})

# 2. Plaintext secrets in homelab-* namespaces not owned by a SealedSecret.
namespaces = kubectl_json("get", "namespaces")
homelab_namespaces = [
    ns["metadata"]["name"] for ns in namespaces.get("items", [])
    if ns["metadata"]["name"].startswith("homelab-")
]

secrets = {}
for ns in homelab_namespaces:
    ns_secrets = kubectl_json("get", "secret", "-n", ns)
    for item in ns_secrets.get("items", []):
        if item.get("type") != "Opaque":
            continue
        owners = item["metadata"].get("ownerReferences", [])
        if any(o.get("kind") == "SealedSecret" for o in owners):
            continue  # already reconstructible from a committed SealedSecret
        name = item["metadata"]["name"]
        secrets[f"{ns}/{name}"] = item.get("data", {})

print(json.dumps({"controller_keys": controller_keys, "secrets": secrets}, indent=2))
PY
)"

printf '%s\n' "${OUT}" | copy_to_clipboard

CONTROLLER_COUNT="$(printf '%s' "${OUT}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["controller_keys"]))')"
SECRET_COUNT="$(printf '%s' "${OUT}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["secrets"]))')"
printf 'Copied %s controller key(s) and %s plaintext secret(s) (base64 values, not yet sealed) to the clipboard.\n' "${CONTROLLER_COUNT}" "${SECRET_COUNT}"
if [[ "${SECRET_COUNT}" != "0" ]]; then
  printf 'Note: those %s secret(s) are not yet backed by a committed SealedSecret — consider sealing them (see helm/atuin for the pattern).\n' "${SECRET_COUNT}"
fi
