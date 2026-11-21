#!/usr/bin/env bash
# Scripts/live-confluence-write.sh — opt-in live check of ConfluenceWriteClient.
#
# !!! WARNING: THIS CREATES REAL CONTENT IN CONFLUENCE !!!
# Every run creates, in YOUR PERSONAL SPACE (the space that holds the anchor
# page ADF_LIVE_PAGE):
#   - a page "ADFReader write test", with a footer comment, a reply and one
#     edit (plus one stale edit that must be refused), and
#   - a blog post "ADFReader write test".
# Page titles are unique in a space, so a second run stops at createPage
# until the earlier scratch page is deleted or renamed.
# The test refuses to write unless the anchor page's space key starts with "~"
# (a personal space), and never writes to the anchor page itself. The scratch
# page and blog post stay; delete them by hand when no longer needed. Details:
# docs/Atlassian-Auth.md, section 6 "Writing (GraphQL)".
#
# ONE-TIME SETUP
#   adf-auth login --site <site>   (or adf-auth rotate <site> for an old token)
#   The token needs every scope in AtlassianTokenScopes.required, including the
#   write scopes and read:comment:confluence; a read-only token fails up front.
#
# USAGE
#   Scripts/live-confluence-write.sh [extra swift test arguments]
#
# ENVIRONMENT
#   ADF_LIVE_SITE       site name or host; default mycompany
#   ADF_LIVE_PAGE       anchor page ID in your personal space; default 229377
#   ADF_LIVE_SPACE_KEY  optional: the anchor page's space key must equal this
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
  echo "live-confluence-write: no adf-auth account saved for $host — skipping."
  echo "  One-time setup: adf-auth login --site $site"
  exit 0
fi

echo "live-confluence-write: site $host, anchor page ${ADF_LIVE_PAGE:-229377}"
echo "live-confluence-write: THIS CREATES A PAGE, A COMMENT, A REPLY AND A BLOG POST IN YOUR PERSONAL SPACE."
(
  cd "$repo_root"
  ADF_LIVE_WRITE=1 ADF_LIVE_SITE="$host" swift test --filter LiveConfluenceWriteTests "$@"
)
