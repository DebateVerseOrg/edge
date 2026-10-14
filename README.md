# edge

The front door for every app on the droplet. edge is the only Compose project that binds host ports 80/443. It terminates TLS, renews certificates, and routes each hostname or path to an app. It contains no app logic.

## Model: one Compose project per app

```
$ docker compose ls
edge              nginx: 80/443, TLS, routing        /opt/edge
market-sentinel   nginx web worker beat db redis      /opt/market-sentinel
insurance-mcp     mcp                                 /opt/insurance-mcp
```

- Each app is its own Compose project (`name:` in its compose file), with its own directory, `.env`, volumes and default network.
- Each app gets **one** external network to edge, called `edge-<app>`. Only edge nginx joins all of them, so apps can't reach each other.
- Only the app's front service joins `edge-<app>`, with a network alias and **no `ports:`**. Databases and workers stay on the app's private default network.
- To see one app's containers: `docker ps --filter label=com.docker.compose.project=<app>`.

```
internet :80/:443
 └─ edge nginx
     ├─ edge-market-sentinel   market-sentinel.tw/*     → ms-nginx:443
     └─ edge-insurance-mcp     market-sentinel.tw/mcp   → insurance-mcp:8000
```

## Layout

| Path | Purpose |
|---|---|
| `conf.d/00-common.conf` | Docker DNS resolver, TLS defaults, port 80 (ACME + redirect to https), rejects unknown hosts on 443, includes `sites/` |
| `sites/<host>.conf` | One `server {}` per hostname: cert, body size, default upstream, and `include routes/<host>/*.conf` |
| `routes/<host>/<app>.conf` | One `location` per app mounted on a path of that host |
| `snippets/proxy.conf` | Standard proxy headers (`Host`, `X-Forwarded-*`, websocket upgrade) |
| `snippets/proxy-stream.conf` | No buffering and 1h timeouts, for SSE and other streaming responses |
| `scripts/renew.sh` | Certificate renewal (webroot) and nginx reload |
| `certbot/` | Certificates and ACME webroot. Gitignored; lives only on the server |

Every upstream uses `set $up http://<alias>:<port>; proxy_pass $up;`. Names then resolve per request through Docker DNS, so edge starts and keeps serving when an app is down; only that app's route returns 502.

## Add an app

1. `docker network create edge-<app>`
2. Add `edge-<app>` to the `networks:` lists in `docker-compose.yml`, both under the nginx service and at the top level as `external: true`.
3. In the app's compose file, put the front service on that network:
   ```yaml
   services:
     <front>:
       networks:
         default: {}
         edge-<app>: { aliases: [<alias>] }
   networks:
     edge-<app>: { external: true }
   ```
   Don't publish ports. Keep `default` listed if the service talks to the app's other containers.
4. Route it:
   - Path on an existing host: `routes/<host>/<app>.conf` with a `location`.
   - New hostname: `sites/<host>.conf`. Point DNS at the droplet and issue a cert first (see below).
5. `docker compose up -d`. This is needed when the network list changed; otherwise `docker compose exec nginx nginx -s reload` is enough.

## Deploy (droplet)

```bash
git clone <edge repo> /opt/edge && cd /opt/edge
docker network create edge-market-sentinel
docker network create edge-insurance-mcp
docker compose run --rm --no-deps nginx nginx -t   # config check
docker compose up -d
```

After changing `sites/`, `routes/` or `snippets/`: `git pull && docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload`.

## Certificates

Issue a cert for a new hostname (edge must be running so it can serve the challenge):
```bash
docker compose run --rm certbot certonly --webroot -w /var/www/certbot \
  -d <host> --email <you> --agree-tos --no-eff-email
docker compose exec nginx nginx -s reload
```

Renewal runs from cron (`crontab -e`):
```
0 4 * * 1 /opt/edge/scripts/renew.sh >> /var/log/edge-renew.log 2>&1
```
Test it with `scripts/renew.sh --dry-run`. The script always passes `--webroot`, so certs first issued with `--standalone` switch to webroot on their next renewal.

## Rollback to the pre-edge setup

market-sentinel's nginx used to own 80/443. To return to that:
```bash
cd /opt/edge && docker compose down
cp -a /opt/edge/certbot/. /opt/market-sentinel/certbot/   # edge has the freshest certs
cd /opt/market-sentinel && git revert <edge overlay commit>
docker compose -f docker-compose.yml -f docker-compose.prod.yml --profile production up -d nginx
```
insurance-mcp is unreachable from outside until edge is back.
