#!/usr/bin/env bash
# Install a pre-commit hook that refuses to commit site-identifying data.
#
#   ./scripts/guardrails.sh
#
# This repo is PUBLIC and generic: it must work on any Aerial host. Anything
# specific to one deployment -- MAC addresses, fronthaul VLANs, PCIe addresses,
# management IPs, hostnames, NGC keys -- belongs in the untracked config/
# directory, never in a tracked file.
#
# Override for a false positive:  git commit --no-verify
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/.git/hooks/pre-commit"
[ -d "$ROOT/.git" ] || { echo "not a git repo: $ROOT" >&2; exit 1; }

cat > "$HOOK" <<'HOOK_EOF'
#!/usr/bin/env bash
# Block site-identifying data from entering a public repo.
# Bypass once with: git commit --no-verify
set -uo pipefail

staged() { git diff --cached --no-color -U0 -- . | grep -E '^\+' | grep -v '^+++'; }
# Neutralise obvious placeholders before scanning. An all-zero MAC is not a
# leak -- in Aerial configs `src_mac_addr: 00:00:00:00:00:00` is meaningful and
# means "use the NIC's own address" -- and example/template files need to show
# the shape of a value without being a real one.
DIFF="$(staged | sed -E \
  -e 's/(00:){5}00/PLACEHOLDER_MAC/g' \
  -e 's/([0-9a-f]{2}:){5}[0-9a-f]{2}/&/g' \
  -e 's/de:ad:be:ef:[0-9a-f]{2}:[0-9a-f]{2}/PLACEHOLDER_MAC/gI' \
  -e 's/0{4}:0{2}:0{2}\.0/PLACEHOLDER_BDF/g')"
[ -n "$DIFF" ] || exit 0

fail=0
block() { # block <label> <regex>
  local hits
  hits="$(printf '%s\n' "$DIFF" | grep -nEi "$2" | head -5)" || true
  if [ -n "$hits" ]; then
    echo "BLOCKED: $1"
    printf '%s\n' "$hits" | sed 's/^/    /'
    fail=1
  fi
}
warn() {
  local hits
  hits="$(printf '%s\n' "$DIFF" | grep -nEi "$2" | head -5)" || true
  [ -n "$hits" ] && { echo "warning: $1"; printf '%s\n' "$hits" | sed 's/^/    /'; }
  return 0
}

block "MAC address"            '([0-9a-f]{2}:){5}[0-9a-f]{2}'
block "PCIe address (BDF)"     '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]'
block "NGC / NVIDIA API key"   'nvapi-[A-Za-z0-9_-]{10,}'
block "private key block"      'BEGIN (RSA|EC|OPENSSH|PGP|DSA)? ?PRIVATE KEY'
block "bearer/authorization"   'authorization: *(bearer|basic) +[A-Za-z0-9]'
block "inventory capture"      '(aerial-inventory-|ran-recipe-)[a-z0-9]'

# Private IPv4: legitimate in generic examples, suspicious in bulk.
warn  "private IPv4 (fine if it is a generic example)" \
      '(^|[^0-9])(10\.[0-9]{1,3}|192\.168\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3})\.[0-9]{1,3}'

if [ "$fail" -ne 0 ]; then
  cat >&2 <<'MSG'

This repo is public and vendor-neutral. Site-specific values belong in the
untracked config/ directory (see README "Site-specific configuration").

If this is genuinely a false positive:  git commit --no-verify
MSG
  exit 1
fi
exit 0
HOOK_EOF

chmod +x "$HOOK"
mkdir -p "$ROOT/site"
[ -f "$ROOT/config/README.md" ] || cat > "$ROOT/config/README.md" <<'EOF'
# config/ — untracked, per-deployment values

Everything in this directory is ignored by git (except this file).

Put anything that identifies one deployment here: fronthaul MAC and VLAN,
PCIe addresses, cell identity, management IPs, NGC credentials, kubeconfigs.
The scripts and charts in this repo read from here so the tracked tree stays
generic and safe to publish.
EOF

echo ">> pre-commit hook installed: $HOOK"
echo ">> config/ created (untracked)"
# Self-test: stage a file with a MAC and invoke the hook directly. No commit is
# ever created, so there is nothing to roll back if the hook misbehaves.
echo ">> self-test:"
# Assembled at runtime: a literal MAC in this file would make the hook block
# its own installer. Deliberately NOT de:ad:be:ef:.. or all-zeros -- both are
# whitelisted as placeholders, so either would make this test vacuous.
printf 'dst_mac_addr: %02x:%02x:%02x:%02x:%02x:%02x\n' 18 52 86 120 154 188 > "$ROOT/.guardrail-test"
git -C "$ROOT" add -f .guardrail-test
if (cd "$ROOT" && "$HOOK" >/dev/null 2>&1); then
  echo "   FAILED: hook did not block a staged MAC address" >&2
  rc=1
else
  echo "   OK: a staged MAC address is blocked"
  rc=0
fi
git -C "$ROOT" rm -q --cached .guardrail-test >/dev/null 2>&1 || true
rm -f "$ROOT/.guardrail-test"
exit $rc
