#!/usr/bin/env bash
# Install pinned, checksum-verified dev tooling into ./.tools (no sudo, no global installs).
# Re-run safely: already-installed versions are skipped.
set -euo pipefail

TFLINT_VERSION="0.66.0"
GITLEAKS_VERSION="8.30.1"
PRE_COMMIT_VERSION="4.7.0"
TALOSCTL_VERSION="1.14.6"
SOPS_VERSION="3.13.3"
AGE_VERSION="1.3.2"
# age publishes Sigsum proofs, not a checksum file: hash pinned on first download (2026-11-20)
AGE_SHA256="cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10"
STEP_VERSION="0.31.0"

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

if [[ "$("${BIN}/talosctl" version --client --short 2>/dev/null)" != *"v${TALOSCTL_VERSION}"* ]]; then
  echo ">> talosctl ${TALOSCTL_VERSION}"
  base="https://github.com/siderolabs/talos/releases/download/v${TALOSCTL_VERSION}"
  curl -fsSL -o "${TMP}/talosctl-linux-amd64" "${base}/talosctl-linux-amd64"
  curl -fsSL -o "${TMP}/talos.sums" "${base}/sha256sum.txt"
  verify talos.sums talosctl-linux-amd64
  install -m 0755 "${TMP}/talosctl-linux-amd64" "${BIN}/talosctl"
fi

if [[ "$("${BIN}/sops" --version --disable-version-check 2>/dev/null)" != *"${SOPS_VERSION}"* ]]; then
  echo ">> sops ${SOPS_VERSION}"
  asset="sops-v${SOPS_VERSION}.linux.amd64"
  base="https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}"
  curl -fsSL -o "${TMP}/${asset}" "${base}/${asset}"
  curl -fsSL -o "${TMP}/sops.sums" "${base}/sops-v${SOPS_VERSION}.checksums.txt"
  verify sops.sums "${asset}"
  install -m 0755 "${TMP}/${asset}" "${BIN}/sops"
fi

if [[ "$("${BIN}/age" --version 2>/dev/null)" != "v${AGE_VERSION}" ]]; then
  echo ">> age ${AGE_VERSION}"
  asset="age-v${AGE_VERSION}-linux-amd64.tar.gz"
  curl -fsSL -o "${TMP}/${asset}" "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/${asset}"
  echo "${AGE_SHA256}  ${asset}" > "${TMP}/age.sums"
  verify age.sums "${asset}"
  tar -xzf "${TMP}/${asset}" -C "${TMP}" age/age age/age-keygen
  install -m 0755 "${TMP}/age/age" "${TMP}/age/age-keygen" "${BIN}/"
fi

if [[ "$("${BIN}/step" version 2>/dev/null | head -1)" != *"${STEP_VERSION}"* ]]; then
  echo ">> step ${STEP_VERSION}"
  asset="step_linux_${STEP_VERSION}_amd64.tar.gz"
  base="https://github.com/smallstep/cli/releases/download/v${STEP_VERSION}"
  curl -fsSL -o "${TMP}/${asset}" "${base}/${asset}"
  curl -fsSL -o "${TMP}/step.sums" "${base}/checksums.txt"
  verify step.sums "${asset}"
  tar -xzf "${TMP}/${asset}" -C "${TMP}" "step_${STEP_VERSION}/bin/step"
  install -m 0755 "${TMP}/step_${STEP_VERSION}/bin/step" "${BIN}/step"
fi

if [[ "$("${TOOLS}/venv/bin/pre-commit" --version 2>/dev/null)" != *"${PRE_COMMIT_VERSION}"* ]]; then
  echo ">> pre-commit ${PRE_COMMIT_VERSION}"
  python3 -m venv "${TOOLS}/venv"
  "${TOOLS}/venv/bin/pip" install --quiet --disable-pip-version-check "pre-commit==${PRE_COMMIT_VERSION}"
fi
ln -sf ../venv/bin/pre-commit "${BIN}/pre-commit"

echo "tools ready in ${BIN}"
