#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>"
  exit 1
fi

BACKEND_VERSION_FILE="./lua/kulala/globals/versions/backend.lua"
BACKEND_CHECKSUMS_FILE="./lua/kulala/globals/versions/backend_checksums.lua"
CHECKSUM_URL="https://core.kulala.app/checksums/${1}"

headers=$(mktemp)
body=$(mktemp)
trap 'rm -f "$headers" "$body"' EXIT

status=$(
  curl --silent --show-error --location \
    --dump-header "$headers" \
    --output "$body" \
    --write-out '%{http_code}' \
    "$CHECKSUM_URL"
)
if [[ "$status" != "200" ]]; then
  echo "Checksum request failed (${status}): $(<"$body")" >&2
  exit 1
fi

version="$1"
if [[ "$version" =~ ^[vV] ]]; then
  version="${version:1}"
fi
if [[ "$version" == "latest" ]]; then
  version=$(
    grep -i '^x-kulala-version:' "$headers" |
      tail -n 1 |
      cut -d' ' -f2- |
      tr -d '[:space:]' || true
  )
  if [[ -z "$version" ]]; then
    echo "Checksum response did not include X-Kulala-Version" >&2
    exit 1
  fi
fi

jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$body" |
  while IFS=$'\t' read -r name checksum; do
    if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]] || [[ ! "$checksum" =~ ^[0-9a-f]{64}$ ]]; then
      echo "Unexpected checksum entry: ${name}" >&2
      exit 1
    fi
    sed -i "s/sha256digests\[\"${name}\"\] = \".*\"/sha256digests[\"${name}\"] = \"${checksum}\"/" "$BACKEND_CHECKSUMS_FILE" || true
  done

echo "return \"${version}\"" > "$BACKEND_VERSION_FILE"
