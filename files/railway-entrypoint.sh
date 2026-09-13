#!/bin/bash
#
# Railway boot wrapper for the official HumHub image.
#
# This is the image CMD. It ends by exec'ing upstream's own
# /docker-entrypoint.sh, which is left untouched, and covers the four things a
# Railway deployment needs that the stock image leaves to the operator:
#
#   1. FrankenPHP listens on Railway's $PORT over plain HTTP - the edge
#      terminates TLS - and Yii is told to trust that edge.
#   2. It waits for the database, because Railway has no start ordering.
#   3. On the first boot it completes the installation non-interactively, so
#      the public URL never serves an unclaimed setup wizard.
#   4. It seeds the SMTP and registration defaults once, leaving every later
#      change to the admin UI alone, and keeps every table on the database's
#      own collation.
#
set -uo pipefail

log() { echo "[railway] $*"; }
die() { echo "[railway] FATAL: $*" >&2; exit 1; }

#----------------------------------------------------------------------
# HTTP listener
#----------------------------------------------------------------------
export SERVER_NAME="${SERVER_NAME:-:${PORT:-8080}}"
log "FrankenPHP listen address: ${SERVER_NAME}"

# PHP memory headroom for image processing. The image's entrypoint appends its
# own php_ini lines to this variable, so the value has to end with a newline.
if [ -z "${FRANKENPHP_CONFIG:-}" ]; then
    FRANKENPHP_CONFIG="       php_ini memory_limit ${HUMHUB_PHP_MEMORY_LIMIT:-512M}
"
    export FRANKENPHP_CONFIG
fi

#----------------------------------------------------------------------
# Reverse proxy
#
# Railway's edge reaches the container from 100.64.0.0/10 and appends its own
# public address (152.233.0.0/17) to X-Forwarded-For. Yii walks that header
# right to left over the trusted list, so all three ranges are needed for
# $request->userIP to be the real client - and for isSecureConnection to be
# true, which is what puts the Secure flag on the session cookie.
#----------------------------------------------------------------------
: "${HUMHUB_WEB_CONFIG__COMPONENTS__REQUEST__TRUSTED_HOSTS:=[\"100.64.0.0/10\",\"fd00::/8\",\"152.233.0.0/17\"]}"
export HUMHUB_WEB_CONFIG__COMPONENTS__REQUEST__TRUSTED_HOSTS

#----------------------------------------------------------------------
# Console installer
#
# humhub\modules\installer\commands\InstallController documents itself as
# `php yii installer/...`, but the installer module's config.php registers no
# consoleControllerMap entry (checked on 1.18.5), so the route does not exist
# and the CLI answers "Unknown command: installer/install-db". Register the
# controller on the console application instead - HUMHUB_CLI_CONFIG__* is
# merged into the console config only.
#----------------------------------------------------------------------
if [ -z "${HUMHUB_CLI_CONFIG__CONTROLLER_MAP__INSTALLER:-}" ]; then
    HUMHUB_CLI_CONFIG__CONTROLLER_MAP__INSTALLER='humhub\modules\installer\commands\InstallController'
fi
export HUMHUB_CLI_CONFIG__CONTROLLER_MAP__INSTALLER

#----------------------------------------------------------------------
# Public base URL - used for mail links and as the Mercure hub URL
#----------------------------------------------------------------------
BASE_URL="${HUMHUB_BASE_URL:-}"
if [ -z "$BASE_URL" ] && [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    BASE_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
fi

#----------------------------------------------------------------------
# Data folder - the image's entrypoint repeats all of this idempotently
#----------------------------------------------------------------------
mkdir -p /data/uploads /data/assets /data/logs /data/config \
         /data/modules /data/modules-custom /data/themes /data/caddy
touch /data/logs/app.log
cp -rn /opt/humhub/protected/config/ /data/ 2>/dev/null
chown -R www-data:www-data /data /app/runtime

#----------------------------------------------------------------------
# Wait for the database
#----------------------------------------------------------------------
if [ -n "${HUMHUB_CONFIG__COMPONENTS__DB__DSN:-}" ]; then
    log "Waiting for the database"
    db_ready=0
    for _ in $(seq 1 60); do
        if php /app/bin/railway-db-wait.php; then
            db_ready=1
            break
        fi
        sleep 5
    done
    [ "$db_ready" = 1 ] || die "database still unreachable after 5 minutes"
    log "Database reachable"
fi

is_installed() {
    /app/yii settings/list-module admin 2>&1 | grep -q installationId
}

#----------------------------------------------------------------------
# Keep every table on the database's own collation - see the script header
#----------------------------------------------------------------------
normalize_collation() {
    php /app/bin/railway-normalize-collation.php
}

#----------------------------------------------------------------------
# First boot: install without the web wizard
#----------------------------------------------------------------------
if is_installed; then
    log "HumHub is already installed"
    normalize_collation
    if [ -n "${HUMHUB_BASE_URL:-}" ]; then
        /app/yii installer/set-base-url "$HUMHUB_BASE_URL"
    fi
else
    log "First boot - installing HumHub"

    ADMIN_USERNAME="${HUMHUB_ADMIN_USERNAME:-admin}"
    ADMIN_EMAIL="${HUMHUB_ADMIN_EMAIL:-admin@example.com}"
    SITE_NAME="${HUMHUB_SITE_NAME:-HumHub}"
    SYSTEM_EMAIL="${HUMHUB_SYSTEM_EMAIL:-noreply@${RAILWAY_PUBLIC_DOMAIN:-example.com}}"
    ADMIN_PASSWORD="${HUMHUB_ADMIN_PASSWORD:-}"

    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20)"
        printf '%s\n' "$ADMIN_PASSWORD" > /data/config/initial-admin-password.txt
        chmod 600 /data/config/initial-admin-password.txt
        chown www-data:www-data /data/config/initial-admin-password.txt
        log "HUMHUB_ADMIN_PASSWORD was empty - generated one into /data/config/initial-admin-password.txt"
    fi

    /app/yii installer/install-db || die "installer/install-db failed"
    normalize_collation
    /app/yii installer/write-site-config "$SITE_NAME" "$SYSTEM_EMAIL" \
        || die "installer/write-site-config failed"
    /app/yii installer/create-admin-account "$ADMIN_USERNAME" "$ADMIN_EMAIL" "$ADMIN_PASSWORD" \
        || log "WARNING: create-admin-account failed - an account named '${ADMIN_USERNAME}' may already exist"

    if [ -n "$BASE_URL" ]; then
        /app/yii installer/set-base-url "$BASE_URL"
    fi

    # Mail. Seeded once so a later change in Administration -> Mailing sticks.
    if [ -n "${HUMHUB_SMTP_HOST:-}" ]; then
        /app/yii settings/set base mailerTransportType smtp
        /app/yii settings/set base mailerHostname "$HUMHUB_SMTP_HOST"
        /app/yii settings/set base mailerPort "${HUMHUB_SMTP_PORT:-1025}"
        /app/yii settings/set base mailerUseSmtps "${HUMHUB_SMTP_USE_SMTPS:-0}"
        /app/yii settings/set base mailerUsername "${HUMHUB_SMTP_USERNAME:-}"
        /app/yii settings/set base mailerPassword "${HUMHUB_SMTP_PASSWORD:-}"
        /app/yii settings/set base mailerSystemEmailAddress "$SYSTEM_EMAIL"
        /app/yii settings/set base mailerSystemEmailName "$SITE_NAME"
        log "Mail transport set to smtp://${HUMHUB_SMTP_HOST}:${HUMHUB_SMTP_PORT:-1025}"
    fi

    # Registration. Closed by default: a Railway domain is public, and the
    # admin can open it again under Administration -> Users -> Settings.
    case "${HUMHUB_ENABLE_REGISTRATION:-false}" in
        true|1|yes|on) REGISTRATION=1 ;;
        *)             REGISTRATION=0 ;;
    esac
    /app/yii settings/set user auth.anonymousRegistration "$REGISTRATION"
    log "Anonymous registration: ${REGISTRATION}"

    log "Installation finished - admin account '${ADMIN_USERNAME}'"
fi

#----------------------------------------------------------------------
# Hand over to the image's own entrypoint (frankenphp + scheduler + workers)
#----------------------------------------------------------------------
log "Starting HumHub"
exec /docker-entrypoint.sh
