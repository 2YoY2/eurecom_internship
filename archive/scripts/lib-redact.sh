# Shared secret-redaction filter. Source this, don't execute it.
#
# Blanks four shapes:
#   KEY=value            (container env, .env files)
#   Bearer <token>       (auth headers)
#   "auth": "..."        (docker config.json)
#   key: value           (YAML — the form Aerial and OAI configs actually use)
#
# Deliberately NOT redacted, because rebuilding the fronthaul needs them:
#   pkey (RoCE partition key), src_mac, dst_mac, eaxc_id, cell_group, vlan.
# The YAML rule requires the secret word to stand alone or follow an
# underscore, so `pkey:` survives while `api_key:` does not.
redact() {
  sed -E \
    -e 's/([A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|APIKEY)[A-Za-z0-9_]*)=[^ ;"]*/\1=***REDACTED***/gI' \
    -e 's/\b(Bearer|Basic)[[:space:]]+[A-Za-z0-9._~+\/-]+=*/\1 ***REDACTED***/gI' \
    -e 's/("(auth|password|identitytoken|registrytoken)":[[:space:]]*")[^"]*/\1***REDACTED***/gI' \
    -e 's/^([[:space:]]*(-[[:space:]]+)?([A-Za-z0-9-]+_)?(key|token|secret|password|passwd|credential|apikey)[[:space:]]*:)[[:space:]]*[^[:space:]].*/\1 ***REDACTED***/I'
}
