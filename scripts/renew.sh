#!/bin/sh
# Renew all certificates via webroot (edge nginx serves the challenge on :80),
# then reload nginx. Safe to run any time; certbot only renews near expiry.
# Extra args pass through, e.g. scripts/renew.sh --dry-run
#
# Cron (droplet): 0 4 * * 1 /opt/edge/scripts/renew.sh >> /var/log/edge-renew.log 2>&1
set -eu
cd "$(dirname "$0")/.."

docker compose run --rm certbot renew --webroot -w /var/www/certbot --quiet "$@"
docker compose exec -T nginx nginx -s reload
