#!/usr/bin/env bash
# Mint a short-lived (~1 hour) GitHub App installation access token.
#
# Nothing secret lives in this script or the repo — it reads config from the
# environment. The App ID and Installation ID are not secrets; the private key is.
#
#   GH_APP_ID               GitHub App's App ID
#   GH_APP_INSTALLATION_ID  installation ID on this repo
#   GH_APP_KEY_FILE         path to the App private-key .pem
#                           (default: ~/.config/loonvault/agent.pem)
#
# Prints the installation token to stdout. Requires: openssl, curl, jq.
# Usage:  export GH_TOKEN=$(just gh-token)
set -euo pipefail

: "${GH_APP_ID:?set GH_APP_ID}"
: "${GH_APP_INSTALLATION_ID:?set GH_APP_INSTALLATION_ID}"
GH_APP_KEY_FILE="${GH_APP_KEY_FILE:-$HOME/.config/loonvault/agent.pem}"
[ -r "$GH_APP_KEY_FILE" ] || { echo "Cannot read private key: $GH_APP_KEY_FILE" >&2; exit 1; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now=$(date +%s)
header='{"alg":"RS256","typ":"JWT"}'
# iat backdated 60s for clock drift; exp must be <= 10 min from iat
payload="{\"iat\":$((now - 60)),\"exp\":$((now + 540)),\"iss\":\"${GH_APP_ID}\"}"

h=$(printf '%s' "$header" | b64url)
p=$(printf '%s' "$payload" | b64url)
sig=$(printf '%s' "$h.$p" | openssl dgst -sha256 -sign "$GH_APP_KEY_FILE" | b64url)
jwt="$h.$p.$sig"

token=$(curl -fsS -X POST \
  -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${GH_APP_INSTALLATION_ID}/access_tokens" \
  | jq -r '.token')

[ -n "$token" ] && [ "$token" != "null" ] || { echo "Failed to mint installation token" >&2; exit 1; }
printf '%s\n' "$token"
