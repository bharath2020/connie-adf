#!/usr/bin/env bash
# Scripts/live-atlassian-fetch.sh — opt-in live check of ADFAtlassianMedia
# against a real Confluence page: runs
# Tests/ADFAtlassianMediaTests/LiveAtlassianMediaTests.swift with the email and
# scoped API token taken from the login Keychain. Details:
# docs/Atlassian-Media-Fetch.md, "Live check".
#
# ONE-TIME SETUP
#   security add-generic-password -s adf-live-test -a <your-atlassian-email> -U -w
#   (prompts for the token; nothing lands on screen or in shell history). The
#   token needs the scopes in AtlassianTokenScopes.required, including
#   read:attachment:confluence and readonly:content.attachment:confluence.
#
# USAGE
#   Scripts/live-atlassian-fetch.sh [extra swift test arguments]
#
# ENVIRONMENT (all optional)
#   ADF_LIVE_EMAIL  account email; default: the Keychain item's account
#   ADF_LIVE_SITE   default mycompany.atlassian.net
#   ADF_LIVE_PAGE   page ID with at least one image; default 229377
#
# Exits 0 with a "skipping" message when the Keychain item is missing. The
# token is held in a shell variable and handed to `swift test` through the
# environment only; it is never echoed or written to a file. The script never
# prints the email either.
set -euo pipefail
set +x

service="adf-live-test"
setup_hint="security add-generic-password -s $service -a <your-atlassian-email> -U -w"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

email="${ADF_LIVE_EMAIL:-}"
if [[ -z "$email" ]]; then
  # `security find-generic-password` prints the attributes, including
  #     "acct"<blob>="someone@example.com"
  email="$(security find-generic-password -s "$service" 2>/dev/null \
    | sed -n 's/^[[:space:]]*"acct"<blob>="\(.*\)"$/\1/p' \
    | head -n 1 || true)"
fi
if [[ -z "$email" ]]; then
  echo "live-atlassian-fetch: no token stored in Keychain item $service — skipping."
  echo "  One-time setup: $setup_hint"
  exit 0
fi

token="$(security find-generic-password -s "$service" -a "$email" -w 2>/dev/null || true)"
if [[ -z "$token" ]]; then
  echo "live-atlassian-fetch: no token stored in Keychain item $service for that account — skipping."
  echo "  One-time setup: $setup_hint"
  exit 0
fi

echo "live-atlassian-fetch: site ${ADF_LIVE_SITE:-mycompany.atlassian.net}, page ${ADF_LIVE_PAGE:-229377} (credentials from Keychain item $service)"
(
  cd "$repo_root"
  ADF_LIVE_EMAIL="$email" ADF_LIVE_TOKEN="$token" swift test --filter LiveAtlassianMediaTests "$@"
)
