#!/usr/bin/env bash
set -euo pipefail

# Configure git to authenticate with GitHub via a GitHub App installation token.
# Reads credentials from env vars or local git config, mints a short-lived token,
# and sets up git credentials + author identity.

repo_root="$(git rev-parse --show-toplevel)"

# --- Read settings from env or git config ---

read_setting() {
  local env_name="$1"
  local git_key="$2"

  if [[ -n "${!env_name:-}" ]]; then
    printf '%s' "${!env_name}"
  else
    printf '%s' "$(git config --local --get "${git_key}" || true)"
  fi
}

require_env() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "${value}" ]]; then
    echo "${name} is required" >&2
    exit 1
  fi
  if [[ "${value}" == "<"*">" ]]; then
    echo "${name} still has placeholder value (${value}). Replace it with a real value." >&2
    exit 1
  fi
}

GH_APP_ID="$(read_setting GH_APP_ID claude.githubAppId)"
GH_APP_INSTALLATION_ID="$(read_setting GH_APP_INSTALLATION_ID claude.githubAppInstallationId)"
GH_APP_PRIVATE_KEY_PATH="$(read_setting GH_APP_PRIVATE_KEY_PATH claude.githubAppPrivateKeyPath)"

export GH_APP_ID
export GH_APP_INSTALLATION_ID
export GH_APP_PRIVATE_KEY_PATH

require_env GH_APP_ID
require_env GH_APP_INSTALLATION_ID
require_env GH_APP_PRIVATE_KEY_PATH

if [[ ! -f "${GH_APP_PRIVATE_KEY_PATH}" ]]; then
  echo "Private key file not found: ${GH_APP_PRIVATE_KEY_PATH}" >&2
  exit 1
fi

# --- Mint GitHub App installation token (JWT + RS256) ---

if [[ -z "${GH_APP_TOKEN:-}" ]]; then
  b64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
  }

  now="$(date +%s)"
  iat="$((now - 60))"
  exp="$((now + 540))"

  header='{"alg":"RS256","typ":"JWT"}'
  payload="{\"iat\":${iat},\"exp\":${exp},\"iss\":${GH_APP_ID}}"

  header_b64="$(printf '%s' "${header}" | b64url)"
  payload_b64="$(printf '%s' "${payload}" | b64url)"
  unsigned="${header_b64}.${payload_b64}"

  signature_b64="$(printf '%s' "${unsigned}" | openssl dgst -binary -sha256 -sign "${GH_APP_PRIVATE_KEY_PATH}" | b64url)"
  jwt="${unsigned}.${signature_b64}"

  response="$(curl -sS -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${GH_APP_INSTALLATION_ID}/access_tokens")"

  GH_APP_TOKEN="$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("token",""))' <<<"${response}")"

  if [[ -z "${GH_APP_TOKEN}" ]]; then
    echo "Failed to mint GitHub App installation token" >&2
    echo "Response: ${response}" >&2
    exit 1
  fi
fi

# --- Configure git identity and credentials ---

git config --local user.name "donut"
git config --local user.email "donut-bot@users.noreply.github.com"

origin_url="$(git remote get-url origin)"
if [[ "${origin_url}" == git@github.com:* ]]; then
  repo_path="${origin_url#git@github.com:}"
  git remote set-url origin "https://x-access-token@github.com/${repo_path}"
elif [[ "${origin_url}" == ssh://git@github.com/* ]]; then
  repo_path="${origin_url#ssh://git@github.com/}"
  git remote set-url origin "https://x-access-token@github.com/${repo_path}"
elif [[ "${origin_url}" == https://github.com/* ]]; then
  repo_path="${origin_url#https://github.com/}"
  git remote set-url origin "https://x-access-token@github.com/${repo_path}"
fi

git config --local --replace-all url."https://github.com/".insteadOf git@github.com:
git config --local --add url."https://github.com/".insteadOf ssh://git@github.com/

git config --local credential.https://github.com.helper "!f() { test \"\${1-}\" = get || exit 0; echo username=x-access-token; echo password=\"${GH_APP_TOKEN}\"; }; f"

echo "GitHub App auth configured for this repo."
echo "Author: $(git config --local user.name) <$(git config --local user.email)>"
echo "Origin (stored): $(git config --local --get remote.origin.url)"
echo "Git credentials for github.com are now backed by GitHub App installation token."
