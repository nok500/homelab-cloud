#!/usr/bin/env bash
# Install pinned, checksum-verified dev tooling into ./.tools (no sudo, no global installs).
# Re-run safely: already-installed versions are skipped.
set -euo pipefail

TFLINT_VERSION="0.66.0"
GITLEAKS_VERSION="8.30.1"
PRE_COMMIT_VERSION="4.7.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${ROOT}/.tools"
BIN="${TOOLS}/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${BIN}"

[[ "$(uname -sm)" == "Linux x86_64" ]] || { echo "only linux/amd64 is supported" >&2; exit 1; }

verify() { # <checksums file> <asset>
  (cd "${TMP}" && grep " ${2}\$" "${1}" | sha256sum -c --quiet -) || { echo "checksum mismatch: ${2}" >&2; exit 1; }
}

if [[ "$("${BIN}/tflint" --version 2>/dev/null | head -1)" != *"${TFLINT_VERSION}"* ]]; then
  echo ">> tflint ${TFLINT_VERSION}"
  base="https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}"
  curl -fsSL -o "${TMP}/tflint_linux_amd64.zip" "${base}/tflint_linux_amd64.zip"
  curl -fsSL -o "${TMP}/tflint.sums" "${base}/checksums.txt"
  verify tflint.sums tflint_linux_amd64.zip
  python3 -m zipfile -e "${TMP}/tflint_linux_amd64.zip" "${TMP}/tflint"
  install -m 0755 "${TMP}/tflint/tflint" "${BIN}/tflint"
fi

if [[ "$("${BIN}/gitleaks" version 2>/dev/null)" != *"${GITLEAKS_VERSION}"* ]]; then
  echo ">> gitleaks ${GITLEAKS_VERSION}"
  asset="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
  base="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}"
  curl -fsSL -o "${TMP}/${asset}" "${base}/${asset}"
  curl -fsSL -o "${TMP}/gitleaks.sums" "${base}/gitleaks_${GITLEAKS_VERSION}_checksums.txt"
  verify gitleaks.sums "${asset}"
  tar -xzf "${TMP}/${asset}" -C "${TMP}" gitleaks
  install -m 0755 "${TMP}/gitleaks" "${BIN}/gitleaks"
fi

if [[ "$("${TOOLS}/venv/bin/pre-commit" --version 2>/dev/null)" != *"${PRE_COMMIT_VERSION}"* ]]; then
  echo ">> pre-commit ${PRE_COMMIT_VERSION}"
  python3 -m venv "${TOOLS}/venv"
  "${TOOLS}/venv/bin/pip" install --quiet --disable-pip-version-check "pre-commit==${PRE_COMMIT_VERSION}"
fi
ln -sf ../venv/bin/pre-commit "${BIN}/pre-commit"

echo "tools ready in ${BIN}"
