#!/usr/bin/env bash
# Disaster-recovery restore for the homelab k3s cluster, pairing with
# copy_secrets.sh (mirrors scripts/env/apply_env.sh's role for *.env files).
#
# Reads the JSON produced by copy_secrets.sh (stdin or clipboard) and:
#   1. Restores the Sealed Secrets controller's signing key(s) into
#      kube-system, then restarts the controller so it picks them up.
#      Run this BEFORE the controller has generated its own key on a fresh
#      cluster (e.g. right after `helm install sealed-secrets-controller`,
#      before anything references it) — restoring after the fact still
#      works (the controller merges multiple active keys), but a key
#      generated first and replaced later can orphan anything sealed
#      against it in the meantime.
#   2. Recreates any plaintext secrets as real Secret objects directly —
#      this is the fallback path for anything that wasn't sealed yet, not a
#      replacement for the SealedSecret YAML already committed to each
#      chart (those recreate themselves once the controller + its key are
#      back, no action needed here).
set -euo pipefail

KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/k3s-homelab.yaml}"
if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
  echo "error: kubeconfig not found at ${KUBECONFIG_FILE} (set KUBECONFIG_FILE to override)" >&2
  exit 1
fi
export KUBECONFIG="${KUBECONFIG_FILE}"

read_clipboard() {
  if command -v wl-paste >/dev/null 2>&1; then
    wl-paste --no-newline 2>/dev/null || wl-paste
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --output
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard -o
  elif command -v pbpaste >/dev/null 2>&1; then
    pbpaste
  else
    echo "error: no clipboard read tool found (wl-paste, xclip, xsel, or pbpaste)" >&2
    exit 1
  fi
}

load_json() {
  if [[ ! -t 0 ]]; then
    cat
  else
    read_clipboard
  fi
}

INPUT="$(load_json)"
if [[ -z "${INPUT//[[:space:]]/}" ]]; then
  echo "error: empty JSON (pipe JSON on stdin or place it on the clipboard)" >&2
  exit 1
fi

# Both of these hold plaintext secrets, so both are mktemp'd (mode 0600, an
# unpredictable name) and both are removed by the trap — including on failure.
# MANIFEST_FILE used to be a fixed /tmp/apply_secrets_manifests.yaml written at
# the default umask and deleted only on the success path, so a failed
# `kubectl apply` left every restored secret readable on disk, at a name any
# other process could pre-create as a symlink.
JSON_FILE="$(mktemp)"
MANIFEST_FILE="$(mktemp)"
trap 'rm -f "${JSON_FILE}" "${MANIFEST_FILE}"' EXIT
printf '%s' "${INPUT}" > "${JSON_FILE}"

python3 - "${JSON_FILE}" "${MANIFEST_FILE}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

if not isinstance(data, dict) or "controller_keys" not in data or "secrets" not in data:
    print("error: expected JSON with 'controller_keys' and 'secrets' keys (output of copy_secrets.sh)", file=sys.stderr)
    sys.exit(1)

manifests = []

for name, b64data in data["controller_keys"].items():
    manifests.append({
        "apiVersion": "v1",
        "kind": "Secret",
        "type": "kubernetes.io/tls",
        "metadata": {
            "name": name,
            "namespace": "kube-system",
            "labels": {"sealedsecrets.bitnami.com/sealed-secrets-key": "active"},
        },
        "data": b64data,
    })

for path, b64data in data["secrets"].items():
    ns, _, name = path.partition("/")
    if not name:
        print(f"error: secret key {path!r} must be 'namespace/name'", file=sys.stderr)
        sys.exit(1)
    manifests.append({
        "apiVersion": "v1",
        "kind": "Secret",
        "type": "Opaque",
        "metadata": {"name": name, "namespace": ns},
        "data": b64data,
    })

with open(sys.argv[2], "w", encoding="utf-8") as f:
    for i, m in enumerate(manifests):
        if i:
            f.write("---\n")
        json.dump(m, f)
        f.write("\n")

print(f"wrote {len(manifests)} manifest(s)")
print(f"  controller key(s): {len(data['controller_keys'])}")
print(f"  plaintext secret(s): {len(data['secrets'])}")
PY

echo "Applying..."
kubectl apply -f "${MANIFEST_FILE}"

if python3 -c "import json; d=json.load(open('${JSON_FILE}')); exit(0 if d['controller_keys'] else 1)"; then
  echo "Restarting sealed-secrets-controller to pick up restored key(s)..."
  kubectl rollout restart deployment/sealed-secrets-controller -n kube-system 2>/dev/null || \
    echo "warning: could not restart sealed-secrets-controller (not installed yet? install it first, then re-run this script)"
fi

echo "Done. SealedSecret objects already committed to helm/*/templates/ will reconcile automatically now that the controller has its key back."
