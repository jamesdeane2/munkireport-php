#!/usr/bin/env bash
# Deploy a CI-built MunkiReport tarball from a GitHub Release to one of
# the Iglu/SupportPlan hosts.
#
# Source of truth: the tagged GitHub Release on
#   https://github.com/jamesdeane2/munkireport-php
# Bytes are built by .github/workflows/build.yml. This script fetches
# the tarball and ssh-pushes it.
#
# Usage:
#   scripts/deploy.sh <host> [<tag>]
#   scripts/deploy.sh tuimunki                       # latest release to tuimunki
#   scripts/deploy.sh munki 5.8.1-2026.05.19.1       # specific tag to munki
#
# Hosts: tuimunki | munki | munkireport
# Requires: gh, sshpass, keepassxc-cli (master in ~/.soma/connections/master.txt)

set -euo pipefail

# Homebrew binaries (gh, sshpass, keepassxc-cli) need to be on PATH when
# the script is invoked from a sandboxed harness that doesn't inherit the
# operator shell's PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

REPO="jamesdeane2/munkireport-php"
KEEPASS_DB="${HOME}/.soma/connections/connections.kdbx"
KEEPASS_MASTER_FILE="${HOME}/.soma/connections/master.txt"

declare_host() {
  case "$1" in
    tuimunki)    HOST_IP="10.254.6.13"; HOST_INSTALL="/Users/Shared/munki_repo-php";  HOST_KEEPASS="/Servers/TUIMunki" ;;
    munki)       HOST_IP="10.254.6.12"; HOST_INSTALL="/Users/Shared/munki_repo-php";  HOST_KEEPASS="/Servers/Munki" ;;
    munkireport) HOST_IP="10.254.6.14"; HOST_INSTALL="/Users/Shared/munkireport-php"; HOST_KEEPASS="/Servers/MunkiReport" ;;
    *) echo "unknown host: $1 (try tuimunki | munki | munkireport)" >&2; exit 2 ;;
  esac
}

[[ $# -ge 1 ]] || { echo "usage: $0 <host> [<tag>]"; exit 2; }
HOST_ALIAS="$1"
TAG="${2:-}"
declare_host "$HOST_ALIAS"

if [[ -z "${TAG}" ]]; then
  TAG="$(gh release list --repo "$REPO" --limit 1 --json tagName -q '.[0].tagName')"
  [[ -n "${TAG}" ]] || { echo "no releases found on $REPO"; exit 3; }
  echo "→ resolved latest release tag: ${TAG}"
fi

# KeePass master password: env > file > interactive prompt.
# (Matches the cve-tracker collector pattern, plus interactive fallback.)
if [[ -n "${KEEPASS_MASTER:-}" ]]; then
  MASTER="$KEEPASS_MASTER"
elif [[ -f "$KEEPASS_MASTER_FILE" ]]; then
  MASTER="$(cat "$KEEPASS_MASTER_FILE")"
else
  read -rsp "KeePass master password: " MASTER
  echo
fi
SSH_USER="$(echo "$MASTER" | keepassxc-cli show -s "$KEEPASS_DB" "$HOST_KEEPASS" | awk -F': ' '/^UserName:/ {print $2}')"
SSH_PW="$(echo "$MASTER" | keepassxc-cli show -s "$KEEPASS_DB" "$HOST_KEEPASS" | awk -F': ' '/^Password:/ {print $2}')"
unset MASTER
[[ -n "$SSH_USER" && -n "$SSH_PW" ]] || { echo "failed to load creds from $HOST_KEEPASS"; exit 4; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "→ fetching ${REPO} release ${TAG}"
gh release download "$TAG" --repo "$REPO" --pattern "*.tar.gz" --dir "$WORKDIR"
LOCAL_TARBALL="$(ls "$WORKDIR"/*.tar.gz 2>/dev/null | head -1)"
[[ -f "$LOCAL_TARBALL" ]] || { echo "no tarball in release $TAG"; exit 5; }
echo "→ downloaded $(basename "$LOCAL_TARBALL") ($(du -h "$LOCAL_TARBALL" | cut -f1))"

REMOTE_STAGING="/tmp/munkireport-deploy-$(date +%Y%m%d-%H%M%S)"
REMOTE_TARBALL="${REMOTE_STAGING}.tar.gz"

echo "→ scp tarball to ${HOST_ALIAS} (${HOST_IP})"
sshpass -p "$SSH_PW" scp -o StrictHostKeyChecking=accept-new \
  "$LOCAL_TARBALL" "${SSH_USER}@${HOST_IP}:${REMOTE_TARBALL}"

# Public hostname per alias (used for the smoke test's Host header)
case "$HOST_ALIAS" in
  tuimunki)    VHOST="tuimunki.supportplan.com" ;;
  munki)       VHOST="munki.supportplan.com" ;;
  munkireport) VHOST="munkireport.supportplan.com" ;;
esac

echo "→ extract + swap + migrate on remote"
sshpass -p "$SSH_PW" ssh -o StrictHostKeyChecking=accept-new "${SSH_USER}@${HOST_IP}" \
  bash -se -- "$HOST_INSTALL" "$REMOTE_STAGING" "$REMOTE_TARBALL" "$TAG" "$VHOST" <<'REMOTE'
set -euo pipefail
INSTALL_PATH="$1"
STAGING="$2"
TARBALL="$3"
TAG="$4"
VHOST="$5"

mkdir -p "$STAGING"
tar xzf "$TARBALL" -C "$STAGING"
EXTRACTED="$(ls -d "$STAGING"/*/ | head -1)"
EXTRACTED="${EXTRACTED%/}"
[[ -d "$EXTRACTED" ]] || { echo "tarball did not contain a top-level directory"; exit 11; }

# Preserve data from current install
if [[ -d "$INSTALL_PATH" ]]; then
  [[ -f "$INSTALL_PATH/.env"                 ]] && cp -a "$INSTALL_PATH/.env"                 "$EXTRACTED/"
  [[ -f "$INSTALL_PATH/app/db/db.sqlite"     ]] && { mkdir -p "$EXTRACTED/app/db"; cp -a "$INSTALL_PATH/app/db/db.sqlite" "$EXTRACTED/app/db/"; }
  [[ -d "$INSTALL_PATH/local/users"          ]] && cp -a "$INSTALL_PATH/local/users"          "$EXTRACTED/local/"
  [[ -d "$INSTALL_PATH/local/views"          ]] && cp -a "$INSTALL_PATH/local/views"          "$EXTRACTED/local/"
  [[ -d "$INSTALL_PATH/local/modules"        ]] && cp -a "$INSTALL_PATH/local/modules"        "$EXTRACTED/local/"
  [[ -d "$INSTALL_PATH/local/dashboards"     ]] && cp -a "$INSTALL_PATH/local/dashboards"     "$EXTRACTED/local/"
  [[ -d "$INSTALL_PATH/local/module_configs" ]] && cp -a "$INSTALL_PATH/local/module_configs" "$EXTRACTED/local/"
  [[ -d "$INSTALL_PATH/local/certs"          ]] && cp -a "$INSTALL_PATH/local/certs"          "$EXTRACTED/local/"
  shopt -s nullglob
  for f in "$INSTALL_PATH"/public/*.zip "$INSTALL_PATH"/public/*.dmg; do
    cp -a "$f" "$EXTRACTED/public/" 2>/dev/null || true
  done
  shopt -u nullglob
fi

TS="$(date +%Y%m%d-%H%M%S)"
if [[ -d "$INSTALL_PATH" ]]; then
  mv "$INSTALL_PATH" "${INSTALL_PATH}.prev-${TS}"
fi
mv "$EXTRACTED" "$INSTALL_PATH"

# Pick a php binary that matches the currently-running php-fpm.
# Avoids the broken /opt/homebrew/bin/php (icu4c v74 mismatch on some hosts)
# and ensures migrate runs against the same version as the live workers.
PHP_BIN=""
RUNNING_FPM_PATH="$(ps -o args= -p "$(pgrep -f 'php-fpm: master' | head -1)" 2>/dev/null \
  | awk '{print $1}')"
if [[ -n "$RUNNING_FPM_PATH" && "$RUNNING_FPM_PATH" == */sbin/php-fpm ]]; then
  CANDIDATE="${RUNNING_FPM_PATH%/sbin/php-fpm}/bin/php"
  [[ -x "$CANDIDATE" ]] && PHP_BIN="$CANDIDATE"
fi
if [[ -z "$PHP_BIN" ]]; then
  for v in php@8.3 php@8.2 php@8.1; do
    if [[ -x "/opt/homebrew/opt/$v/bin/php" ]]; then
      PHP_BIN="/opt/homebrew/opt/$v/bin/php"; break
    fi
  done
fi
[[ -n "$PHP_BIN" ]] || { echo "no usable php binary found"; exit 12; }
echo "→ using $PHP_BIN for migrate"
cd "$INSTALL_PATH"
echo "→ please migrate (Deprecated noise from MigrationCommand.php filtered)"
"$PHP_BIN" please migrate 2>&1 | grep -v "^Deprecated:" | grep -v "^$" | tail -20 || true

rm -f "$TARBALL"
rm -rf "$STAGING"

echo "→ smoke test (Host: $VHOST)"
# Try HTTPS first (tuimunki/munkireport terminate TLS locally), fall back to
# HTTP (munki only serves HTTP locally; TLS is at the upstream proxy).
HTTPS_CODE=$(curl -sS --max-time 4 -k -o /dev/null -w "%{http_code}" \
  -H "Host: $VHOST" https://127.0.0.1/index.php 2>/dev/null || echo "000")
if [[ "$HTTPS_CODE" =~ ^[23] ]]; then
  echo "  HTTPS:443  HTTP $HTTPS_CODE"
else
  HTTP_CODE=$(curl -sS --max-time 4 -o /dev/null -w "%{http_code}" \
    -H "Host: $VHOST" http://127.0.0.1/index.php 2>/dev/null || echo "000")
  echo "  HTTP:80   HTTP $HTTP_CODE  (HTTPS=$HTTPS_CODE, expected for hosts behind a TLS-terminating proxy)"
fi

echo "✓ deployed $TAG to $INSTALL_PATH"
echo "  rollback: mv $INSTALL_PATH $INSTALL_PATH.failed && mv ${INSTALL_PATH}.prev-${TS} $INSTALL_PATH"
REMOTE

echo
echo "→ deploy complete: $HOST_ALIAS = $TAG"
