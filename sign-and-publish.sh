#!/usr/bin/env bash
set -euo pipefail

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "ERROR: GitHub OIDC environment is missing. Ensure 'permissions: id-token: write' is set." >&2
  exit 1
fi

echo "Requesting OIDC token from GitHub..."
OIDC_TOKEN=$(curl -fsS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=nono-registry" | jq -r '.value')

if [ -z "${OIDC_TOKEN}" ] || [ "${OIDC_TOKEN}" = "null" ]; then
  echo "ERROR: failed to obtain GitHub OIDC token" >&2
  exit 1
fi

echo "Exchanging OIDC token with registry..."
EXCHANGE_RESPONSE=$(curl -fsS -X POST "${REGISTRY_URL}/auth/oidc/exchange" \
  -H "Content-Type: application/json" \
  -d "{\"token\":\"${OIDC_TOKEN}\",\"package_namespace\":\"${PACKAGE_NAMESPACE}\",\"package_name\":\"${PACKAGE_NAME}\"}")

UPLOAD_TOKEN=$(printf '%s' "${EXCHANGE_RESPONSE}" | jq -r '.upload_token')
if [ -z "${UPLOAD_TOKEN}" ] || [ "${UPLOAD_TOKEN}" = "null" ]; then
  echo "ERROR: registry token exchange failed: ${EXCHANGE_RESPONSE}" >&2
  exit 1
fi

FILE_LIST="${RUNNER_TEMP}/nono_package_files.txt"
if [ ! -f "${FILE_LIST}" ]; then
  echo "ERROR: file list not found at ${FILE_LIST}" >&2
  exit 1
fi

README_PATH="${PACKAGE_PATH}/README.md"

echo "Publishing ${PACKAGE_NAMESPACE}/${PACKAGE_NAME}@${PACKAGE_VERSION}..."
CURL_ARGS=(-fsS -X POST "${REGISTRY_URL}/packages/${PACKAGE_NAMESPACE}/${PACKAGE_NAME}/versions")
CURL_ARGS+=(-H "Authorization: Bearer ${UPLOAD_TOKEN}")
CURL_ARGS+=(-F "version=${PACKAGE_VERSION}")

if [ -f "${README_PATH}" ]; then
  CURL_ARGS+=(-F "readme=<${README_PATH}")
fi

cd "${PACKAGE_PATH}"
while IFS= read -r file; do
  [ -z "${file}" ] && continue

  if [ ! -f "${file}" ]; then
    echo "ERROR: artifact missing at publish time: ${file}" >&2
    exit 1
  fi

  bundle_path="${file}.bundle"
  if [ ! -f "${bundle_path}" ]; then
    echo "ERROR: bundle missing for artifact: ${file}" >&2
    exit 1
  fi

  echo "Uploading ${file}"
  CURL_ARGS+=(-F "artifact=@${file};filename=${file}")
  CURL_ARGS+=(-F "bundle=@${bundle_path};filename=${bundle_path}")
done < "${FILE_LIST}"

RESPONSE=$(curl "${CURL_ARGS[@]}")
echo "Publish response: ${RESPONSE}"

VERSION_ID=$(printf '%s' "${RESPONSE}" | jq -r '.id')
if [ -z "${VERSION_ID}" ] || [ "${VERSION_ID}" = "null" ]; then
  echo "ERROR: publish failed" >&2
  exit 1
fi

echo "Published ${PACKAGE_NAMESPACE}/${PACKAGE_NAME}@${PACKAGE_VERSION} successfully"
