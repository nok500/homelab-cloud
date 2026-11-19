#!/usr/bin/env bash
# Download, verify and prepare the VM base images into ./.cache/images.
#   OPNsense: SHA-256 checked against the release checksum file, which is itself
#             verified against the OPNsense release signing key (pinned fingerprint below).
#   Debian:   SHA-512 checked against the published SHA512SUMS.
# Raw images are converted to sparse qcow2 so the upload to libvirt is small.
set -euo pipefail

OPNSENSE_VERSION="26.7"
# sha256 of OPNsense-26.7.pub, pinned on first download (trust-on-first-use, 2026-11-19).
# Changes only with a new release key; re-pin deliberately when bumping OPNSENSE_VERSION.
OPNSENSE_PUBKEY_SHA256="9f3b76ffef38fb6405595038b324b61043c9a2c375ae5c151d628508e9a845ce"
DEBIAN_BUILD="20261116-2664"
DEBIAN_SHA512="37cb32b320820417eb04b335afcf489bfb4cecce4a957190d09cb2bffbe02b56a1cadd62d78c6ead92aa7839d5ea65e4260f994bbb4b54490df59fdf11ee1d97"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/.cache/images"
mkdir -p "${OUT}"
cd "${OUT}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need curl; need openssl; need bunzip2; need qemu-img; need sha256sum; need sha512sum

# --- OPNsense nano -----------------------------------------------------------
opn_qcow="opnsense-${OPNSENSE_VERSION}-nano-amd64.qcow2"
if [[ ! -f "${opn_qcow}" ]]; then
  base="https://pkg.opnsense.org/releases/${OPNSENSE_VERSION}"
  img="OPNsense-${OPNSENSE_VERSION}-nano-amd64.img"
  sums="OPNsense-${OPNSENSE_VERSION}-checksums-amd64.sha256"
  pub="OPNsense-${OPNSENSE_VERSION}.pub"
  for f in "${img}.bz2" "${sums}" "${sums}.sig" "${pub}"; do
    [[ -f "${f}" ]] || { echo ">> fetching ${f}"; curl -fsSL -o "${f}" "${base}/${f}"; }
  done

  pub_sha="$(sha256sum "${pub}" | cut -d' ' -f1)"
  if [[ -n "${OPNSENSE_PUBKEY_SHA256}" && "${pub_sha}" != "${OPNSENSE_PUBKEY_SHA256}" ]]; then
    echo "OPNsense signing key fingerprint mismatch: ${pub_sha}" >&2; exit 1
  fi
  openssl base64 -d -in "${sums}.sig" -out "${sums}.sig.bin"
  openssl dgst -sha256 -verify "${pub}" -signature "${sums}.sig.bin" "${sums}" >/dev/null \
    || { echo "OPNsense checksum file signature INVALID" >&2; exit 1; }
  want="$(sed -nE "s/^SHA256 \(${img}\.bz2\) = ([0-9a-f]{64})$/\1/p" "${sums}")"
  echo "${want}  ${img}.bz2" | sha256sum -c --quiet - || { echo "OPNsense image checksum mismatch" >&2; exit 1; }
  echo ">> OPNsense ${OPNSENSE_VERSION}: signature + checksum OK"

  [[ -f "${img}" ]] || bunzip2 -k "${img}.bz2"
  qemu-img convert -f raw -O qcow2 "${img}" "${opn_qcow}.tmp"
  mv "${opn_qcow}.tmp" "${opn_qcow}"
  rm -f "${img}"
fi

# --- Debian 13 genericcloud (test VM) ---------------------------------------
deb="debian-13-genericcloud-amd64-${DEBIAN_BUILD}.qcow2"
if [[ ! -f "${deb}" ]]; then
  echo ">> fetching ${deb}"
  curl -fsSL -o "${deb}.tmp" "https://cloud.debian.org/images/cloud/trixie/${DEBIAN_BUILD}/${deb}"
  echo "${DEBIAN_SHA512}  ${deb}.tmp" | sha512sum -c --quiet - || { echo "Debian image checksum mismatch" >&2; exit 1; }
  mv "${deb}.tmp" "${deb}"
fi

ls -lh "${OUT}"/*.qcow2
