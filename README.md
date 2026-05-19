<p align="center"><a href="https://laravel.com" target="_blank"><img src="https://raw.githubusercontent.com/laravel/art/master/logo-lockup/5%20SVG/2%20CMYK/1%20Full%20Color/laravel-logolockup-cmyk-red.svg" width="400" alt="Laravel Logo"></a></p>

<p align="center">
<a href="https://github.com/laravel/framework/actions"><img src="https://github.com/laravel/framework/workflows/tests/badge.svg" alt="Build Status"></a>
<a href="https://packagist.org/packages/laravel/framework"><img src="https://img.shields.io/packagist/dt/laravel/framework" alt="Total Downloads"></a>
<a href="https://packagist.org/packages/laravel/framework"><img src="https://img.shields.io/packagist/v/laravel/framework" alt="Latest Stable Version"></a>
<a href="https://packagist.org/packages/laravel/framework"><img src="https://img.shields.io/packagist/l/laravel/framework" alt="License"></a>
</p>

## Deployment

This project ships with three Docker setups, each for a different scenario:

| File | Purpose |
| --- | --- |
| [docker-compose.local.yml](docker-compose.local.yml) | Local development — builds from `.docker/Dockerfile` (target `dev`) with hot-reload source mount. |
| [docker-compose-data-swarm.yml](docker-compose-data-swarm.yml) + [docker-compose-app-swarm.yml](docker-compose-app-swarm.yml) | Production deployment on Docker Swarm (data tier + app tier). |
| [docker-compose-proxy-swarm.yml](docker-compose-proxy-swarm.yml) | HTTPS reverse proxy (Nginx + Certbot) in front of the app stack. |

### 1. Local development (hot-reload)

```bash
docker compose -f docker-compose.local.yml up --build
# → http://localhost:8000
```

Stop & clean up:

```bash
docker compose -f docker-compose.local.yml down
```

### 2. Run the prebuilt production image locally

```bash
docker compose up -d
# → http://localhost:8001
```

```bash
docker compose down
```

### 3. Build & push production image

Multi-arch images are published to GHCR. Login first if you haven't:

```bash
echo $GITHUB_TOKEN | docker login ghcr.io -u mdonnyirwansyah --password-stdin
```

Tag the build with the current git SHA:

```bash
export TAG=$(git rev-parse --short HEAD)
```

**amd64** (servers, most cloud VMs):

```bash
docker buildx build \
  -f .docker/Dockerfile \
  --target release \
  --platform linux/amd64 \
  --tag ghcr.io/mdonnyirwansyah/laravel:$TAG \
  --tag ghcr.io/mdonnyirwansyah/laravel:latest \
  --cache-from type=registry,ref=ghcr.io/mdonnyirwansyah/laravel:buildcache \
  --cache-to type=registry,ref=ghcr.io/mdonnyirwansyah/laravel:buildcache,mode=max,ignore-error=true \
  --provenance=true \
  --sbom=true \
  --push \
  .
```

**arm64** (Apple Silicon, AWS Graviton, Raspberry Pi):

```bash
docker buildx build \
  -f .docker/Dockerfile \
  --target release \
  --platform linux/arm64 \
  --tag ghcr.io/mdonnyirwansyah/laravel:$TAG-arm64 \
  --tag ghcr.io/mdonnyirwansyah/laravel:latest-arm64 \
  --cache-from type=registry,ref=ghcr.io/mdonnyirwansyah/laravel:buildcache-arm64 \
  --cache-to type=registry,ref=ghcr.io/mdonnyirwansyah/laravel:buildcache-arm64,mode=max,ignore-error=true \
  --provenance=true \
  --sbom=true \
  --push \
  .
```

### 4. Production deploy on Docker Swarm

The Swarm setup is split into two stacks so data and app lifecycles are independent:

- `laravel_data` — Postgres + Redis (persistent volumes, internal-only)
- `laravel` — the Laravel app (3 replicas, rolling update, attaches to `laravel_data` network)

#### One-time prerequisites

```bash
# Initialize swarm (skip if already active)
docker swarm init

# Login to GHCR so Swarm nodes can pull the private image.
# Token is read from ~/.ghcr_token (PAT with read:packages scope).
cat ~/.ghcr_token | docker login ghcr.io -u mdonnyirwansyah --password-stdin

# Create secrets referenced by the stacks
echo "your-strong-db-password" | docker secret create laravel_db_password -
php artisan key:generate --show | xargs -I {} sh -c 'echo "{}" | docker secret create laravel_app_key -'

# Verify
docker secret ls   # expect: laravel_db_password, laravel_app_key
```

#### Deploy

Order matters — data tier first, then app tier. Pass `--with-registry-auth` so each Swarm node receives the GHCR credentials needed to pull the private image:

```bash
docker stack deploy -c docker-compose-data-swarm.yml laravel_data
docker stack deploy -c docker-compose-app-swarm.yml --with-registry-auth laravel
```

#### Verify

```bash
docker stack services laravel_data   # postgres 1/1, redis 1/1
docker stack services laravel        # app 3/3
docker service logs laravel_app --tail 50
curl http://localhost:8001/up
```

#### Update the app (rolling)

```bash
docker service update --with-registry-auth --image ghcr.io/mdonnyirwansyah/laravel:latest-arm64 laravel_app
```

#### Tear down

```bash
docker stack rm laravel
docker stack rm laravel_data
# Volumes (postgres-data, redis-data) persist — remove manually if needed:
# docker volume rm laravel_data_postgres laravel_data_redis
```

### 5. HTTPS via Nginx + Certbot (Let's Encrypt)

Reverse proxy stack ([docker-compose-proxy-swarm.yml](docker-compose-proxy-swarm.yml)) sits in front of `laravel_app`. It exposes ports **80** and **443** to the internet — the app no longer publishes its own port.

> Heads-up: Let's Encrypt **does not issue certificates for IP addresses**. While you only have an IP, use a self-signed cert (steps below). Swap to certbot once a domain points at the server.

#### Step 1 — Prepare cert volume (self-signed for IP / pre-domain)

Create the named volumes and seed a self-signed cert so Nginx can start:

```bash
docker volume create laravel_proxy_certs
docker volume create laravel_proxy_webroot

docker run --rm -v laravel_proxy_certs:/certs alpine/openssl \
  req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /certs/privkey.pem \
  -out    /certs/fullchain.pem \
  -subj   "/CN=$(curl -s ifconfig.me)"
```

#### Step 2 — Deploy proxy stack first

```bash
docker stack deploy -c docker-compose-proxy-swarm.yml laravel_proxy
docker stack services laravel_proxy   # nginx 1/1
```

#### Step 3 — (Re)deploy app stack so it joins `laravel_proxy`

```bash
docker stack deploy -c docker-compose-app-swarm.yml laravel
```

Test:

```bash
curl -kI https://<server-ip>/up    # -k skips self-signed warning
```

#### Step 4 — Switch to Let's Encrypt (once domain is ready)

Point your domain's A record at the server, then issue a real cert via webroot challenge:

```bash
export DOMAIN=yourdomain.com
export EMAIL=is.dony77@gmail.com

docker run --rm \
  -v laravel_proxy_certs:/etc/letsencrypt \
  -v laravel_proxy_webroot:/var/www/certbot \
  certbot/certbot certonly \
    --webroot -w /var/www/certbot \
    -d $DOMAIN \
    --email $EMAIL --agree-tos --no-eff-email \
    --non-interactive
```

Certbot writes certs into the `laravel_proxy_certs` volume at `live/$DOMAIN/`. Update [.docker/nginx/proxy.conf](.docker/nginx/proxy.conf) to point there:

```nginx
ssl_certificate     /etc/nginx/certs/live/yourdomain.com/fullchain.pem;
ssl_certificate_key /etc/nginx/certs/live/yourdomain.com/privkey.pem;
server_name yourdomain.com;
```

Reload nginx — because the config is stored as an immutable Swarm config, you must remove and redeploy the proxy stack (the cert volume persists):

```bash
docker stack rm laravel_proxy && sleep 5
docker stack deploy -c docker-compose-proxy-swarm.yml laravel_proxy
```

#### Step 5 — Auto-renew (cron on host)

Add to host crontab (`crontab -e`):

```cron
0 3 * * * docker run --rm -v laravel_proxy_certs:/etc/letsencrypt -v laravel_proxy_webroot:/var/www/certbot certbot/certbot renew --quiet && docker stack rm laravel_proxy && sleep 5 && docker stack deploy -c /path/to/laravel/docker-compose-proxy-swarm.yml laravel_proxy
```

#### Customization

**Change exposed ports**

Edit the `ports:` block in [docker-compose-proxy-swarm.yml](docker-compose-proxy-swarm.yml):

```yaml
ports:
  - "8080:80"     # host:8080 → nginx HTTP
  - "8443:443"    # host:8443 → nginx HTTPS
```

Redeploy proxy stack:

```bash
docker stack rm laravel_proxy && sleep 5
docker stack deploy -c docker-compose-proxy-swarm.yml laravel_proxy
```

> ⚠️ Let's Encrypt **HTTP-01 challenge requires port 80 publicly reachable**. If you remap port 80 and certbot can't reach it, switch to **DNS-01 challenge** (verifies via a TXT record). Example with Cloudflare:
> ```bash
> docker run --rm \
>   -v laravel_proxy_certs:/etc/letsencrypt \
>   -v ~/.cloudflare.ini:/cf.ini:ro \
>   certbot/dns-cloudflare certonly \
>     --dns-cloudflare --dns-cloudflare-credentials /cf.ini \
>     -d yourdomain.com -d '*.yourdomain.com' \
>     --email is.dony77@gmail.com --agree-tos --non-interactive
> ```
> The `~/.cloudflare.ini` file holds `dns_cloudflare_api_token = <token>` with Zone:DNS:Edit scope. DNS-01 also enables wildcard certs.

**Add additional domains / subdomains**

Add another `server` block to [.docker/nginx/proxy.conf](.docker/nginx/proxy.conf):

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name api.yourdomain.com;

    ssl_certificate     /etc/nginx/certs/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/live/yourdomain.com/privkey.pem;

    location / {
        set $upstream "api:80";    # any service on the laravel_proxy overlay network
        proxy_pass http://$upstream;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

When issuing the cert, include every hostname:

```bash
certbot ... -d yourdomain.com -d api.yourdomain.com -d www.yourdomain.com
```

Then redeploy the proxy stack to pick up the new config.

#### Built-in DDoS / abuse mitigation

The Nginx proxy ([.docker/nginx/proxy.conf](.docker/nginx/proxy.conf)) ships with a layer of L7 protections that block or throttle abusive traffic **before it reaches Laravel**. No third-party WAF or module is required — everything below uses stock Nginx directives.

> ⚠️ This only mitigates **application-layer (L7)** abuse: HTTP floods, slowloris, brute-force, scanners. **Volumetric (L3/L4) DDoS** — SYN floods, UDP floods, amplification — cannot be stopped by Nginx; for that, put Cloudflare / AWS Shield / a scrubbing service in front.

**Blocking criteria:**

| Rule | Threshold / Pattern | Action |
| --- | --- | --- |
| **Global request rate** per IP | > 30 req/s sustained (burst 60) | Excess → `503` |
| **Auth endpoint rate** per IP (`/login`, `/register`, `/password*`, `/api/auth*`) | > 5 req/min (burst 3) | Excess → `503` |
| **Concurrent connections** per IP | > 20 | New conns → `503` |
| **Slowloris / slow-POST** | Body or header idle > 10s; send idle > 10s | Connection closed |
| **HTTP method** | Anything outside `GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS` | `405 Method Not Allowed` |
| **Scanner User-Agent** | `nikto`, `sqlmap`, `nmap`, `masscan`, `zgrab`, `fuzzer`, `wpscan` (case-insensitive substring) | `444` (connection dropped, no response) |
| **Empty User-Agent** | `User-Agent: ` header missing/blank | `444` |
| **Request body size** | > 10 MB | `413 Payload Too Large` |
| **Request header size** | > 8 KB × 4 buffers | `400 Bad Request` |

**Tune the thresholds** by editing the `limit_req_zone` / `limit_conn_zone` directives at the top of `proxy.conf`, then redeploy:

```bash
docker stack rm laravel_proxy && sleep 5
docker stack deploy -c docker-compose-proxy-swarm.yml laravel_proxy
```

**Adjust the auth-endpoint patterns** if your routes differ — edit the regex in the `location ~ ^/(login|register|password|api/auth)` block. The strict 5/min limit is mainly to defeat credential-stuffing.

**False positives to watch out for:**

- Mobile apps or scrapers behind a single egress IP can hit the per-IP limit — whitelist their CIDR with `geo` + `map` if needed.
- Health-checkers (uptime monitors) may send empty UA — give them an explicit `User-Agent` header.
- Long-running uploads will be killed by `client_body_timeout 10s`; raise it on the specific `location` (e.g. `/api/upload`) rather than globally.

**Inspect rate-limit hits** in the nginx error log:

```bash
docker service logs laravel_proxy_nginx --tail 100 | grep -E 'limiting requests|limiting connections'
```

#### Tear down proxy

```bash
docker stack rm laravel_proxy
# certs persist in volumes; remove manually if needed:
# docker volume rm laravel_proxy_certs laravel_proxy_webroot
```
