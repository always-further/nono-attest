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

if [ -z "${PACKAGE_NAMESPACE:-}" ]; then
  if [ -z "${GITHUB_REPOSITORY:-}" ]; then
    echo "ERROR: package-namespace not provided and GITHUB_REPOSITORY is unavailable" >&2
    exit 1
  fi
  PACKAGE_NAMESPACE="${GITHUB_REPOSITORY%%/*}"
fi

echo "Requesting OIDC token from GitHub..."
OIDC_TOKEN=$(curl -fsS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=nono-registry" | jq -r '.value')

if [ -z "${OIDC_TOKEN}" ] || [ "${OIDC_TOKEN}" = "null" ]; then
  echo "ERROR: failed to obtain GitHub OIDC token" >&2
  exit 1
fi

echo "Exchanging OIDC token with registry..."
EXCHANGE_STATUS=$(curl -sS -o /tmp/nono_oidc_exchange_response.json -w '%{http_code}' -X POST "${REGISTRY_URL}/auth/oidc/exchange" \
  -H "Content-Type: application/json" \
  -d "{\"token\":\"${OIDC_TOKEN}\",\"package_namespace\":\"${PACKAGE_NAMESPACE}\",\"package_name\":\"${PACKAGE_NAME}\"}")
EXCHANGE_RESPONSE=$(cat /tmp/nono_oidc_exchange_response.json)
rm -f /tmp/nono_oidc_exchange_response.json

if [ "${EXCHANGE_STATUS}" -lt 200 ] || [ "${EXCHANGE_STATUS}" -ge 300 ]; then
  echo "ERROR: registry token exchange failed (${EXCHANGE_STATUS}): ${EXCHANGE_RESPONSE}" >&2
  exit 1
fi

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

cd "${PACKAGE_PATH}"

BUNDLE_PATH=".nono-trust.bundle"
if [ ! -f "${BUNDLE_PATH}" ]; then
  echo "ERROR: multi-subject bundle not found: ${BUNDLE_PATH}" >&2
  exit 1
fi

echo "Publishing ${PACKAGE_NAMESPACE}/${PACKAGE_NAME}@${PACKAGE_VERSION}..."
ARTIFACT_ARGS=()

while IFS= read -r file; do
  [ -z "${file}" ] && continue

  if [ ! -f "${file}" ]; then
    echo "ERROR: artifact missing at publish time: ${file}" >&2
    exit 1
  fi

  echo "Uploading ${file}"
  ARTIFACT_ARGS+=(-F "artifact=@${file};filename=${file}")
done < "${FILE_LIST}"

PUBLISH_STATUS=$(curl -sS -o /tmp/nono_publish_response.json -w '%{http_code}' \
  -X POST "${REGISTRY_URL}/packages/${PACKAGE_NAMESPACE}/${PACKAGE_NAME}/versions" \
  -H "Authorization: Bearer ${UPLOAD_TOKEN}" \
  -F "version=${PACKAGE_VERSION}" \
  -F "bundle=@${BUNDLE_PATH};filename=${BUNDLE_PATH}" \
  "${ARTIFACT_ARGS[@]}")
RESPONSE=$(cat /tmp/nono_publish_response.json)
rm -f /tmp/nono_publish_response.json
echo "Publish response (${PUBLISH_STATUS}): ${RESPONSE}"

if [ "${PUBLISH_STATUS}" -lt 200 ] || [ "${PUBLISH_STATUS}" -ge 300 ]; then
  echo "ERROR: publish failed (${PUBLISH_STATUS})" >&2
  exit 1
fi

VERSION_ID=$(printf '%s' "${RESPONSE}" | jq -r '.id')
if [ -z "${VERSION_ID}" ] || [ "${VERSION_ID}" = "null" ]; then
  echo "ERROR: publish failed: no version id in response" >&2
  exit 1
fi

echo "Published ${PACKAGE_NAMESPACE}/${PACKAGE_NAME}@${PACKAGE_VERSION} successfully"
