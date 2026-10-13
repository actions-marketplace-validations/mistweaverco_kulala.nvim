#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>"
  exit 1
fi

BACKEND_VERSION_FILE="./lua/kulala/globals/versions/backend.lua"
BACKEND_CHECKSUMS_FILE="./lua/kulala/globals/versions/backend_checksums.lua"

GH_ORG="dont-be-evil-company"
GH_REPO="kulala-core"

CHECKSUMS=$(gh api repos/${GH_ORG}/${GH_REPO}/releases/latest | jq -r '.assets[] | {name: .name, digest: .digest} | @base64')
LATEST_VERSION=$(gh api repos/${GH_ORG}/${GH_REPO}/releases/latest | jq -r '.tag_name' | sed 's/^v//')

function _jq() {
  local decoded
  local needle="sha256:"
  decoded=$(echo "${1}" | base64 --decode | jq -r "${2}")
  if [[ $decoded == *"$needle"* ]]; then
    echo "${decoded#"$needle"}"
  else
    echo "${decoded}"
  fi
}

echo "$CHECKSUMS" | while read -r asset; do
  checksum=$(_jq "$asset" '.digest')
  name=$(_jq "$asset" '.name')
  sed -i "s/sha256digests\[\"$name\"\] = \".*\"/sha256digests\[\"$name\"\] = \"$checksum\"/" "$BACKEND_CHECKSUMS_FILE" || true
done

echo "return \"$LATEST_VERSION\"" > "$BACKEND_VERSION_FILE"
