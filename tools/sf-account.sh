#!/usr/bin/env bash
# The project's service account on GitHub (specs/root.xml, decision service-accounts): prints the shell lines that make
# this shell act as the SchemaForge GitHub App, so a build's commits, pushes and pull request are the App's, never a
# person's. Use it as: eval "$(tools/sf-account.sh)"
#
# It needs, on the machine of whoever runs the build (never in the repository or a profile):
#   SF_APP_ID         the App's id
#   SF_APP_KEY_FILE   the path of the App's private key (.pem)
# and openssl, curl and python3. It mints a JWT from the key, exchanges it for an installation token of the
# repository, and prints: GH_TOKEN (used by gh, and by git through gh's credential helper), and the bot's name and
# email for git's author and committer. The token lasts an hour.
set -euo pipefail
: "${SF_APP_ID:?set SF_APP_ID to the SchemaForge App's id}"
: "${SF_APP_KEY_FILE:?set SF_APP_KEY_FILE to the path of the App's private key}"
repo="${SF_REPO:-k8nstantin/schema-forge}"
api="https://api.github.com"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$SF_APP_ID" | b64url)
signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$SF_APP_KEY_FILE" | b64url)
jwt="$header.$payload.$signature"

get() { curl -fsS -H "Authorization: Bearer $1" -H "Accept: application/vnd.github+json" "$api$2"; }
field() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }

slug=$(get "$jwt" /app | field "['slug']")
installation=$(get "$jwt" "/repos/$repo/installation" | field "['id']")
token=$(curl -fsS -X POST -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
    "$api/app/installations/$installation/access_tokens" | field "['token']")
bot="$slug[bot]"
bot_id=$(curl -fsS -H "Accept: application/vnd.github+json" "$api/users/$bot" | field "['id']")

printf 'export GH_TOKEN=%q\n' "$token"
printf 'export GIT_AUTHOR_NAME=%q GIT_COMMITTER_NAME=%q\n' "$bot" "$bot"
printf 'export GIT_AUTHOR_EMAIL=%q GIT_COMMITTER_EMAIL=%q\n' "$bot_id+$bot@users.noreply.github.com" "$bot_id+$bot@users.noreply.github.com"
printf 'gh auth setup-git >/dev/null\n'
printf 'echo "acting as %s on %s for the next hour" >&2\n' "$bot" "$repo"
