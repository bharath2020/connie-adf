#!/usr/bin/env bash
# Scripts/live-atlassian-fetch.sh — opt-in live check of ADFAtlassianMedia
# against a real Confluence page: runs
# Tests/ADFAtlassianMediaTests/LiveAtlassianMediaTests.swift with the account
# adf-auth saved for the site. Details: docs/Atlassian-Media-Fetch.md,
# "Live check".
#
# ONE-TIME SETUP
#   adf-auth login --site <site>
#   Create the token from the prefilled link with every scope in
#   AtlassianTokenScopes.required, including read:attachment:confluence and
#   readonly:content.attachment:confluence. adf-auth saves it in the login
#   Keychain item "ADFReader – <site>.atlassian.net".
#
# USAGE
#   Scripts/live-atlassian-fetch.sh [extra swift test arguments]
#
# ENVIRONMENT (all optional)
#   ADF_LIVE_SITE   site name or host; default mycompany
#   ADF_LIVE_PAGE   page ID with at least one image; default 229377
#
# The test reads the credential itself through KeychainCredentialStore at run
# time (macOS may ask to allow keychain access). This script only checks that
# the item exists, without reading its secret, and exits 0 with a "skipping"
# message when it does not. Nothing here prints the token or the email.
set -euo pipefail
set +x

service="com.connie.adfreader.atlassian"
site="${ADF_LIVE_SITE:-mycompany}"
host="$site"
[[ "$host" == *.* ]] || host="$host.atlassian.net"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Attributes only (no -w / -g): never touches the secret, never prompts.
if ! security find-generic-password -s "$service" -a "$host" >/dev/null 2>&1; then
  echo "live-atlassian-fetch: no adf-auth account saved for $host — skipping."
  echo "  One-time setup: adf-auth login --site $site"
  exit 0
fi

echo "live-atlassian-fetch: site $host, page ${ADF_LIVE_PAGE:-229377} (credential from the adf-auth Keychain item)"
(
  cd "$repo_root"
  ADF_LIVE_SITE="$host" swift test --filter LiveAtlassianMediaTests "$@"
)
