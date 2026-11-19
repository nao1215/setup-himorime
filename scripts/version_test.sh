#!/usr/bin/env bash
#
# version_test.sh — check that resolve_version normalizes explicit versions,
# resolves "latest" from a canned API response, and that extract_tag_name reads
# the tag of a large release document.
#
# Resolving "latest" against the real API is covered by the install job in
# .github/workflows/test.yml.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=install.sh
source "${here}/install.sh"

failures=0
check() {
  local input="$1" want_tag="$2" want_num="$3"
  INPUT_VERSION="$input"
  TAG="" NUM_VERSION=""
  resolve_version
  if [ "$TAG" != "$want_tag" ] || [ "$NUM_VERSION" != "$want_num" ]; then
    printf 'FAIL: %-8q -> TAG=%s NUM=%s (want TAG=%s NUM=%s)\n' \
      "$input" "$TAG" "$NUM_VERSION" "$want_tag" "$want_num"
    failures=$((failures + 1))
  else
    printf 'ok:   %-8q -> TAG=%s NUM=%s\n' "$input" "$TAG" "$NUM_VERSION"
  fi
}

# check_latest feeds resolve_version a canned API response, so any input that
# means "latest" must come out as the tag in that response.
check_latest() {
  local input="$1"
  INPUT_VERSION="$input"
  TAG="" NUM_VERSION=""
  gh_curl() {
    printf '%s\n' '{"url":"https://api.github.com/repos/nao1215/himorime/releases/1","tag_name":"v0.1.1","name":"v0.1.1"}'
  }
  resolve_version
  if [ "$TAG" != "v0.1.1" ] || [ "$NUM_VERSION" != "0.1.1" ]; then
    printf 'FAIL: %-8q -> TAG=%s NUM=%s (want TAG=v0.1.1 NUM=0.1.1)\n' "$input" "$TAG" "$NUM_VERSION"
    failures=$((failures + 1))
  else
    printf 'ok:   %-8q -> TAG=%s NUM=%s\n' "$input" "$TAG" "$NUM_VERSION"
  fi
}

# check_latest_fails makes the API return a body without tag_name, which must
# stop the install with an error instead of resolving to an empty tag.
check_latest_fails() {
  local out status
  INPUT_VERSION="latest"
  gh_curl() { printf '%s\n' '{"message":"Not Found"}'; }
  set +e
  out="$(resolve_version 2>&1)"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    printf 'FAIL: latest with no tag_name resolved (output: %s)\n' "$out"
    failures=$((failures + 1))
  else
    printf 'ok:   latest with no tag_name fails: %s\n' "$out"
  fi
}

# check_rejected expects resolve_version to stop with an "invalid version"
# error before any download, instead of turning the input into a tag such as
# vvX.Y.Z that only fails later as a 404 naming an asset nobody asked for.
check_rejected() {
  local input="$1" out status
  INPUT_VERSION="$input"
  gh_curl() { printf 'gh_curl must not be called for %s\n' "$INPUT_VERSION" >&2; return 1; }
  set +e
  out="$(resolve_version 2>&1)"
  status=$?
  set -e
  case "$status:$out" in
    0:*)
      printf 'FAIL: %-8q was accepted (TAG would be built from it)\n' "$input"
      failures=$((failures + 1))
      ;;
    *'invalid version'*)
      printf 'ok:   %-8q rejected\n' "$input"
      ;;
    *)
      printf 'FAIL: %-8q failed without naming the invalid version: %s\n' "$input" "$out"
      failures=$((failures + 1))
      ;;
  esac
}

check "v0.1.0" "v0.1.0" "0.1.0"
check "0.1.0"  "v0.1.0" "0.1.0"
check " 0.1.0" "v0.1.0" "0.1.0" # surrounding whitespace is trimmed
check $'v0.6.0\n' "v0.6.0" "0.6.0" # a trailing newline from a multi-line YAML value
check $'\tv0.6.0 ' "v0.6.0" "0.6.0"
check "v10.20.30" "v10.20.30" "10.20.30" # multi-digit components
check "v1.0.0-rc.1" "v1.0.0-rc.1" "1.0.0-rc.1" # pre-release suffix is kept
check "1.0.0-rc.1"  "v1.0.0-rc.1" "1.0.0-rc.1"
check_latest "latest"
check_latest ""   # the input left empty means latest
check_latest "  " # whitespace only means latest too
check_latest_fails
check_rejected "vv0.1.0"     # doubled prefix
check_rejected "V0.1.0"      # tags are lower-case v
check_rejected "Latest"      # only the exact word latest resolves the newest release
check_rejected "v"           # prefix without a version
check_rejected "0.1"         # missing patch component
check_rejected "0.1.0.0"     # extra component
check_rejected "v0.1.0 beta" # inner whitespace
check_rejected "0.1.0/../x"  # path segments in the download URL

# A release document larger than a pipe buffer, with tag_name before the
# assets as the GitHub API returns it.
padding="$(head -c 300000 /dev/zero | tr '\0' 'x')"
body="$(printf '{\n  "tag_name": "v0.1.0",\n  "assets": ["%s"]\n}\n' "$padding")"
if tag="$(extract_tag_name "$body")" && [ "$tag" = "v0.1.0" ]; then
  printf 'ok:   tag_name from a %d-byte release document\n' "${#body}"
else
  printf 'FAIL: tag_name from a large release document -> %s\n' "${tag:-}"
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  printf '%d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'all version-normalization tests passed\n'
