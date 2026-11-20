#!/usr/bin/env bash
# fixtures-check.sh [--repo DIR]: the committed fixtures are what the
# generator makes and what their manifest records. From the repository root
# (default: this script's checkout; --repo names another tree holding
# Tools/make-fixtures.swift and Fixtures/, such as a test's copy) it runs:
#   swift Tools/make-fixtures.swift --check
#       regenerates every generated fixture in memory and compares it with
#       the bytes in Fixtures/ (the generator resolves Fixtures/ from its
#       own path, so a copy checks the copy);
#   (cd Fixtures && shasum -a 256 -c SHA256SUMS)
#       every fixture's digest, the hand-authored ones included; and every
#       Fixtures/*.json must be listed there.
# Prints each step's result and, on a mismatch, the files that differ.
#
# Used by visual-parity.sh before a capture and by
# Scripts/tests/gate-scripts-tests.sh (a pass on this checkout and a
# changed byte in a copy). Needs only bash 3.2, swift and shasum.
#
# EXIT STATUS  0 both steps pass; 1 a fixture differs from the generator or
#   the manifest; 2 usage error.
set -uo pipefail

usage() { sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo) [ "$#" -ge 2 ] || { echo "fixtures-check: --repo needs a directory" >&2; exit 2; }
                REPO="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "fixtures-check: unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done
[ -f "$REPO/Tools/make-fixtures.swift" ] && [ -f "$REPO/Fixtures/SHA256SUMS" ] || {
    echo "fixtures-check: $REPO has no Tools/make-fixtures.swift or Fixtures/SHA256SUMS" >&2
    exit 2
}

status=0
generator_out="$(cd "$REPO" && swift Tools/make-fixtures.swift --check 2>&1)"
generator_rc=$?
if [ "$generator_rc" -eq 0 ]; then
    echo "fixtures-check: generator: ${generator_out##*$'\n'}"
else
    status=1
    echo "fixtures-check: generator: FAIL (make-fixtures --check exit $generator_rc)"
    printf '%s\n' "$generator_out" | sed 's/^/    /'
fi

# shasum -c reads the "#" comment lines as malformed; keep only digest lines.
manifest_out="$(cd "$REPO/Fixtures" && grep -E '^[0-9a-f]{64}  ' SHA256SUMS | shasum -a 256 -c - 2>&1)"
manifest_rc=$?
listed="$(grep -cE '^[0-9a-f]{64}  ' "$REPO/Fixtures/SHA256SUMS")"
unlisted=""
for path in "$REPO"/Fixtures/*.json; do
    [ -e "$path" ] || continue
    name="${path##*/}"
    grep -qE "^[0-9a-f]{64}  $name\$" "$REPO/Fixtures/SHA256SUMS" || unlisted="${unlisted:+$unlisted }$name"
done
if [ "$manifest_rc" -eq 0 ] && [ -z "$unlisted" ]; then
    echo "fixtures-check: manifest: all $listed digests in Fixtures/SHA256SUMS match"
else
    status=1
    if [ "$manifest_rc" -ne 0 ]; then
        echo "fixtures-check: manifest: FAIL (shasum -c exit $manifest_rc)"
        printf '%s\n' "$manifest_out" | grep -v ': OK$' | sed 's/^/    /'
    fi
    [ -z "$unlisted" ] || echo "fixtures-check: manifest: FAIL (not listed in SHA256SUMS: $unlisted)"
fi
exit "$status"
