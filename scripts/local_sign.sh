#!/bin/zsh
set -euo pipefail

# Give WonderBox a stable code-signing identity that lives on this machine.
#
# macOS identifies a signed app by its "designated requirement". An ad-hoc signature has no
# certificate, so the requirement degrades to the code hash (cdhash): every rebuild is therefore a
# *different* app to macOS, and Full Disk Access has to be granted again. A certificate-backed
# signature carries a requirement of `identifier "…" and certificate root = H"…"` instead, which
# does not depend on the code, so the grant survives rebuilds.
#
# This is the free, local alternative to a Developer ID. The identity it creates is only trusted on
# machines that imported this certificate; it does not make the app notarized or publicly trusted.
#
# Usage:
#   scripts/local_sign.sh                                  # re-sign /Applications/WonderBox.app
#   scripts/local_sign.sh path/to/WonderBox.app            # re-sign a downloaded or local build
#   scripts/local_sign.sh --setup-only                     # only create the identity, then build with
#                                                          # SIGN_IDENTITY="WonderBox Local Signing" ./scripts/package_app.sh
#
# Environment:
#   SIGN_IDENTITY          identity name (default: WonderBox Local Signing)
#   WONDERBOX_SIGNING_DIR  where key.pem/cert.pem are kept
#                          (default: ~/Library/Application Support/WonderBox/Signing)
#   WONDERBOX_KEYCHAIN     keychain to import into (default: login keychain)

IDENTITY="${SIGN_IDENTITY:-WonderBox Local Signing}"
SIGNING_DIR="${WONDERBOX_SIGNING_DIR:-$HOME/Library/Application Support/WonderBox/Signing}"
KEYCHAIN="${WONDERBOX_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
ROOT="${0:A:h:h}"

SETUP_ONLY=0
APP=""
for argument in "$@"; do
  case "$argument" in
    --setup-only) SETUP_ONLY=1 ;;
    -h|--help) sed -n '2,30p' "${0}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) APP="$argument" ;;
  esac
done

die() { print -u2 "error: $*"; exit 1 }
note() { print "  $*" }

# An existing identity must never be recreated: a new certificate means a new requirement, and every
# Full Disk Access grant the user already made would be void again.
identity_is_usable() {
  security find-identity -v -p codesigning 2>/dev/null | grep -q " \"${IDENTITY}\"$"
}

create_identity() {
  print "Creating local code-signing identity \"${IDENTITY}\""
  mkdir -p "${SIGNING_DIR}"
  chmod 700 "${SIGNING_DIR}"

  if [[ ! -f "${SIGNING_DIR}/cert.pem" || ! -f "${SIGNING_DIR}/key.pem" ]]; then
    # A config file rather than -addext: LibreSSL and OpenSSL disagree on that flag, but both read
    # x509_extensions from the [req] section.
    cat > "${SIGNING_DIR}/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${IDENTITY}
O = WonderBox Local
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -config "${SIGNING_DIR}/openssl.cnf" \
      -keyout "${SIGNING_DIR}/key.pem" -out "${SIGNING_DIR}/cert.pem" >/dev/null 2>&1
    chmod 600 "${SIGNING_DIR}/key.pem"
    note "wrote ${SIGNING_DIR}/cert.pem and key.pem"
  else
    note "reusing existing certificate material in ${SIGNING_DIR}"
  fi

  local password p12
  password="$(openssl rand -hex 12)"
  p12="${SIGNING_DIR}/import.p12"
  # `security import` rejects the AES-256/PBKDF2 defaults of OpenSSL 3, so pin legacy parameters.
  if [[ "$(openssl version)" == LibreSSL* ]]; then
    openssl pkcs12 -export -inkey "${SIGNING_DIR}/key.pem" -in "${SIGNING_DIR}/cert.pem" \
      -name "${IDENTITY}" -out "${p12}" -passout "pass:${password}" >/dev/null 2>&1
  else
    openssl pkcs12 -export -inkey "${SIGNING_DIR}/key.pem" -in "${SIGNING_DIR}/cert.pem" \
      -name "${IDENTITY}" -out "${p12}" -passout "pass:${password}" \
      -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1
  fi
  security import "${p12}" -k "${KEYCHAIN}" -P "${password}" \
    -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null
  rm -f "${p12}"

  # Without a trust setting the identity is present but not valid, and codesign refuses it.
  security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" "${SIGNING_DIR}/cert.pem"
  note "imported into ${KEYCHAIN:t} and marked trusted for code signing"
}

resign_bundle() {
  local app="$1"

  # Sign nested code first, inside out. `--deep` would also work but is discouraged by Apple and
  # hides the order, which matters here because the helper requirement is copied into Info.plist.
  local nested helper
  for nested in "${app}"/Contents/Library/LoginItems/*.app(N); do
    codesign --force --sign "${IDENTITY}" "${nested}"
    note "signed ${nested:t}"
  done
  for helper in "${app}"/Contents/Helpers/*(N); do
    codesign --force --sign "${IDENTITY}" "${helper}"
    note "signed ${helper:t}"
  done

  # The app declares which helper it owns by embedding the helper's requirement. That requirement
  # just changed with the identity, so it has to be rebuilt before the parent is sealed.
  if [[ -f "${ROOT}/scripts/configure_helper_identity.py" && -f "${app}/Contents/Helpers/WonderFanHelper" ]]; then
    python3 "${ROOT}/scripts/configure_helper_identity.py" "${app}"
    note "rebound SMPrivilegedExecutables to the new helper requirement"
  fi

  codesign --force --sign "${IDENTITY}" "${app}"
}

print_requirement() {
  local app="$1"
  codesign -d -r- "${app}" 2>&1 | awk '/designated =>/ { sub(/^.*designated => /, ""); print }'
}

[[ -f "${ROOT}/Package.swift" ]] || die "run this from a WonderBox checkout (scripts/local_sign.sh)"

if ! identity_is_usable; then
  create_identity
  identity_is_usable || die "identity \"${IDENTITY}\" is still not usable after import"
else
  print "Using existing identity \"${IDENTITY}\""
  note "reusing it on purpose — recreating the certificate would invalidate every existing grant"
fi

fingerprint="$(security find-certificate -c "${IDENTITY}" -Z "${KEYCHAIN}" 2>/dev/null | awk '/SHA-1 hash:/ { print $3; exit }')"
[[ -n "${fingerprint}" ]] && note "certificate SHA-1 ${fingerprint}"

if [[ "${SETUP_ONLY}" == "1" ]]; then
  print ""
  print "Identity ready. Build with:"
  print "  SIGN_IDENTITY=\"${IDENTITY}\" ./scripts/package_app.sh"
  exit 0
fi

[[ -n "${APP}" ]] || die "no app bundle given and the default was empty"
[[ -d "${APP}" ]] || die "no such bundle: ${APP}"
[[ -w "${APP}" ]] || die "cannot write ${APP} (use sudo, or pass a bundle you own)"

if pgrep -f "${APP}/Contents/MacOS/" >/dev/null 2>&1; then
  print "warning: ${APP:t} is running; quit it and relaunch after signing"
fi

before="$(print_requirement "${APP}")"
resign_bundle "${APP}"

# A downloaded archive carries quarantine; launchd and Gatekeeper both misbehave on signed-but-
# quarantined code, and the user already chose to run it.
xattr -dr com.apple.quarantine "${APP}" 2>/dev/null || true

codesign --verify --strict --deep "${APP}" || die "signature verification failed after signing"

after="$(print_requirement "${APP}")"
print ""
print "${APP:t} re-signed"
print "  before: ${before}"
print "  after : ${after}"
print ""
print "Next, in this order:"
print "  1. Relaunch the app."
print "  2. Grant Full Disk Access once (System Settings > Privacy & Security > Full Disk Access)."
print "     This grant is now tied to the certificate, so later rebuilds will not ask again."
print "  3. If the fan background service reports an error, reinstall it from the Fan page — its"
print "     client authorization is bound to the app's previous signing identity."
print ""
print "Keep ${SIGNING_DIR} backed up (it holds the private key); without it the identity is gone"
print "and the grants have to be made again."
