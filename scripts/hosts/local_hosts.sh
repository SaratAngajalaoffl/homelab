#!/usr/bin/env bash
# Resolve every homelab hostname to 127.0.0.1 on this machine (the k3s node),
# so the services stay reachable from here when the internet, Cloudflare or the
# router's DNS is down.
#
# Traefik answers on 127.0.0.1:443 through its LoadBalancer Service, and the
# existing Let's Encrypt certs still validate offline, so the usual
# https://<app>.smugiwara.com URLs keep working unchanged. Other devices on the
# LAN are not affected — this only edits this machine's /etc/hosts.
#
# The entries live in one marked block in /etc/hosts. `off` comments the block
# out instead of deleting it, so `on` works without reaching the cluster API.
#
#   local_hosts.sh refresh   rebuild the block from live Ingress/IngressRoute
#                            hosts, keeping its current on/off state (new
#                            blocks start on). Run after adding a stack.
#   local_hosts.sh on        route the hostnames to 127.0.0.1
#   local_hosts.sh off       back to normal DNS (public path via Cloudflare)
#   local_hosts.sh status    show the state and the hosts in the block
#
# Run as your normal user: kubectl reads your homelab kubeconfig, and only the
# final write to /etc/hosts goes through sudo. The previous file is kept as
# /etc/hosts.homelab-bak.
set -euo pipefail

HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
TARGET_IP="${TARGET_IP:-127.0.0.1}"
BEGIN_MARK="# >>> homelab-local (managed by scripts/hosts/local_hosts.sh) >>>"
END_MARK="# <<< homelab-local <<<"

usage() {
  sed -n '/^#   local_hosts.sh/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

has_block() { grep -qxF "${BEGIN_MARK}" "${HOSTS_FILE}"; }

# Prints the lines between the markers.
block_lines() {
  awk -v b="${BEGIN_MARK}" -v e="${END_MARK}" \
    '$0==e{inb=0} inb{print} $0==b{inb=1}' "${HOSTS_FILE}"
}

block_state() {
  if ! has_block; then echo absent
  elif block_lines | grep -qE "^${TARGET_IP//./\\.}[[:space:]]"; then echo on
  else echo off
  fi
}

block_hosts() { block_lines | sed -E 's/^#? *//' | awk '{print $2}'; }

collect_hosts() {
  local kubeconfig="${KUBECONFIG_FILE:-$HOME/.kube/k3s-homelab.yaml}"
  if [[ ! -f "${kubeconfig}" ]]; then
    echo "error: kubeconfig not found at ${kubeconfig} (set KUBECONFIG_FILE to override)" >&2
    exit 1
  fi
  export KUBECONFIG="${kubeconfig}"

  {
    kubectl get ingress -A \
      -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}'
    # Traefik IngressRoutes carry hosts inside the match expression. The CRD
    # may be absent (or empty), which is fine.
    kubectl get ingressroutes.traefik.io -A -o json 2>/dev/null \
      | jq -r '.items[].spec.routes[]?.match // empty' \
      | grep -oE 'Host\(`[^`]+`\)' | sed -E 's/^Host\(`(.*)`\)$/\1/' || true
  } | grep -v '\*' | grep -v '^$' | sort -u
}

# write_block <on|off> <host>... — replaces (or appends) the marked block.
write_block() {
  local state="$1"; shift
  local prefix=""
  [[ "${state}" == off ]] && prefix="# "

  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' RETURN

  awk -v b="${BEGIN_MARK}" -v e="${END_MARK}" \
    '$0==b{skip=1} !skip{print} $0==e{skip=0}' "${HOSTS_FILE}" > "${tmp}"
  # Drop trailing blank lines left behind by a removed block.
  sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "${tmp}"
  {
    echo
    echo "${BEGIN_MARK}"
    local h
    for h in "$@"; do echo "${prefix}${TARGET_IP} ${h}"; done
    echo "${END_MARK}"
  } >> "${tmp}"

  sudo cp -p "${HOSTS_FILE}" "${HOSTS_FILE}.homelab-bak"
  # tee rather than mv keeps the file's inode, owner and mode.
  sudo tee "${HOSTS_FILE}" > /dev/null < "${tmp}"
}

warn_conflicts() {
  local h
  for h in "$@"; do
    if awk -v b="${BEGIN_MARK}" -v e="${END_MARK}" -v h="${h}" '
        $0==b{inb=1} $0==e{inb=0; next}
        !inb && $0 !~ /^[[:space:]]*#/ { for (i=2; i<=NF; i++) if ($i==h) found=1 }
        END{exit !found}' "${HOSTS_FILE}"; then
      echo "warning: ${h} also appears outside the managed block in ${HOSTS_FILE}" >&2
    fi
  done
}

cmd="${1:-status}"
case "${cmd}" in
  refresh)
    mapfile -t hosts < <(collect_hosts)
    if [[ ${#hosts[@]} -eq 0 ]]; then
      echo "error: no Ingress hosts found — is the cluster up?" >&2
      exit 1
    fi
    state="$(block_state)"
    [[ "${state}" == absent ]] && state=on
    warn_conflicts "${hosts[@]}"
    write_block "${state}" "${hosts[@]}"
    echo "wrote ${#hosts[@]} hosts to ${HOSTS_FILE} (${state})"
    ;;
  on|off)
    if ! has_block; then
      [[ "${cmd}" == off ]] && { echo "no managed block in ${HOSTS_FILE}; nothing to do"; exit 0; }
      exec "$0" refresh
    fi
    mapfile -t hosts < <(block_hosts)
    write_block "${cmd}" "${hosts[@]}"
    echo "homelab hosts now ${cmd} (${#hosts[@]} entries)"
    ;;
  status)
    state="$(block_state)"
    echo "state: ${state}"
    if [[ "${state}" != absent ]]; then block_hosts | sed 's/^/  /'; fi
    ;;
  -h|--help|help) usage ;;
  *) usage 1 >&2 ;;
esac
