#!/bin/bash
# Stable code-signing identity for CI builds.
#
#   ci_signing_keychain.sh setup     import the fixed signing certificate into a
#                                    throw-away keychain and report the identity
#   ci_signing_keychain.sh cleanup   delete that keychain again
#
# Why: an ad-hoc signature's designated requirement is the build's cdhash
# (Apple TN3127), so every new build looks like a different app to TCC and the
# Input Monitoring grant is lost on each update. Signing every build with the
# same certificate makes the requirement
#     identifier "<bundle id>" and certificate leaf = H"<cert sha1>"
# which does not change between builds.
#
# Builds that cannot read the secrets (pull requests from forks) fall back to
# the ad-hoc identity "-" and still succeed.
#
# Inputs (environment):
#   SIGNING_P12_BASE64     base64 of the PKCS#12 file (empty -> ad-hoc)
#   SIGNING_P12_PASSWORD   its password
#   SIGNING_CERT_SHA1      expected SHA-1 of the certificate (public value);
#                          a different certificate fails the build instead of
#                          silently changing the designated requirement
#   RUNNER_TEMP            scratch directory (CI sets it)
#   GITHUB_OUTPUT          step outputs file (CI sets it; optional locally)
#   GITHUB_ENV             exports SIGNING_KEYCHAIN_PASSWORD to later steps
set -euo pipefail

mode="${1:-}"
work="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/mle-signing"
keychain="$work/signing.keychain-db"
state="$work/state"

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "$1=$2" >> "$GITHUB_OUTPUT"
  fi
}

setup() {
  if [[ -z "${SIGNING_P12_BASE64:-}" ]]; then
    echo "::notice::No signing certificate is available to this build; using an ad-hoc signature."
    emit identity "-"
    emit keychain ""
    return 0
  fi
  if [[ -z "${SIGNING_P12_PASSWORD:-}" || -z "${SIGNING_CERT_SHA1:-}" ]]; then
    echo "::error::SIGNING_P12_PASSWORD and SIGNING_CERT_SHA1 are required together with SIGNING_P12_BASE64."
    return 1
  fi

  umask 077
  mkdir -p "$work"
  local keychain_password p12="$work/identity.p12"
  keychain_password="$(openssl rand -hex 24)"
  echo "::add-mask::$keychain_password"
  printf '%s' "$SIGNING_P12_BASE64" | base64 -D > "$p12"

  # Remember the user keychain search list so cleanup restores it.
  security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//' > "$state"

  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  security import "$p12" -k "$keychain" -f pkcs12 -P "$SIGNING_P12_PASSWORD" -T /usr/bin/codesign
  # Let codesign use the key without an interactive prompt.
  security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" > /dev/null
  rm -f "$p12"
  local -a previous=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && previous+=("$line")
  done < "$state"
  security list-keychains -d user -s "$keychain" ${previous[@]+"${previous[@]}"}

  local found
  found="$(security find-identity -p codesigning "$keychain" | awk '/^[[:space:]]+[0-9]+\)/ {print $2}' | sort -u)"
  local expected
  expected="$(printf '%s' "$SIGNING_CERT_SHA1" | tr -d ':' | tr '[:lower:]' '[:upper:]')"
  if [[ "$found" != "$expected" ]]; then
    echo "::error::The imported signing certificate does not match SIGNING_CERT_SHA1; refusing to sign with a different identity."
    return 1
  fi

  echo "Signing with the stable identity (certificate SHA-1 $expected)."
  emit identity "$expected"
  emit keychain "$keychain"
  # Later steps run in new shells; they unlock the keychain again with this.
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "SIGNING_KEYCHAIN_PASSWORD=$keychain_password" >> "$GITHUB_ENV"
  fi
}

cleanup() {
  if [[ -f "$state" ]]; then
    local -a previous=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && previous+=("$line")
    done < "$state"
    if [[ ${#previous[@]} -gt 0 ]]; then
      security list-keychains -d user -s "${previous[@]}" || true
    fi
  fi
  [[ -f "$keychain" ]] && security delete-keychain "$keychain" || true
  rm -rf "$work"
}

case "$mode" in
  setup) setup ;;
  cleanup) cleanup ;;
  *) echo "usage: $0 setup|cleanup" >&2; exit 2 ;;
esac
