<p align="center"><a href="https://laravel.com" target="_blank"><img src="https://raw.githubusercontent.com/laravel/art/master/logo-lockup/5%20SVG/2%20CMYK/1%20Full%20Color/laravel-logolockup-cmyk-red.svg" width="400" alt="Laravel Logo"></a></p>

<p align="center">
<a href="https://github.com/laravel/framework/actions"><img src="https://github.com/laravel/framework/workflows/tests/badge.svg" alt="Build Status"></a>
<a href="https://packagist.org/packages/laravel/framework"><img src="https://img.shields.io/packagist/dt/laravel/framework" alt="Total Downloads"></a>
<a href="https://packagist.org/packages/laravel/framework"><img src="https://img.shields.io/packagist/v/laravel/framework" alt="Latest Stable Version"></a>
<a href="https://packagist.org/packages/laravel/framework"><img src="https://img.shields.io/packagist/l/laravel/framework" alt="License"></a>
</p>

## Deployment

This project provides multiple deployment options:

| File | Purpose |
| --- | --- |
| [docker-compose.local.yml](docker-compose.local.yml) | Local development — builds from `.docker/Dockerfile` (target `dev`) with hot-reload source mount |
| [docker-compose-data-swarm.yml](docker-compose-data-swarm.yml) + [docker-compose-app-swarm.yml](docker-compose-app-swarm.yml) | Docker Swarm production deployment (data tier + app tier) |
| [docker-compose-proxy-swarm.yml](docker-compose-proxy-swarm.yml) | HTTPS reverse proxy (Nginx + Certbot) for Docker Swarm |
| [podman-compose.yml](podman-compose.yml) | Podman production deployment (app + Postgres + Redis) |
| [podman-compose-proxy.yaml](podman-compose-proxy.yaml) | HTTPS reverse proxy (Nginx + Certbot) for Podman |

### 1. Local development (hot-reload)

```bash
docker compose -f docker-compose.local.yml up --build
# → http://localhost:8000
```

Stop and clean up:

```bash
docker compose -f docker-compose.local.yml down
```

### 2. Build and push production image

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

### 3. Production deployment on Docker Swarm

The Swarm setup separates data and application lifecycles into independent stacks:

- `laravel_data` — Postgres + Redis (persistent volumes, internal network only)
- `laravel` — Laravel application (3 replicas, rolling updates, attached to `laravel_data` network)

#### One-time prerequisites

```bash
# Initialize swarm (skip if already active)
docker swarm init

# Authenticate with GHCR (requires PAT with read:packages scope)
cat ~/.ghcr_token | docker login ghcr.io -u mdonnyirwansyah --password-stdin

# Create secrets referenced by the stacks
echo "your-strong-db-password" | docker secret create laravel_db_password -
php artisan key:generate --show | xargs -I {} sh -c 'echo "{}" | docker secret create laravel_app_key -'

# Verify
docker secret ls   # expect: laravel_db_password, laravel_app_key
```

#### Deploy

Deploy the data tier first, then the app tier. Use `--with-registry-auth` to propagate GHCR credentials to all Swarm nodes:

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

### 4. HTTPS via Nginx + Certbot (Let's Encrypt)

The reverse proxy stack ([docker-compose-proxy-swarm.yml](docker-compose-proxy-swarm.yml)) sits in front of `laravel_app`, exposing ports **80** and **443** to the internet. The app no longer publishes its own port.

> **Note:** Let's Encrypt **does not issue certificates for IP addresses**. Use a self-signed certificate until a domain is configured, then switch to Certbot.

#### Step 1 — Prepare certificate volumes (self-signed)

Create named volumes and generate a self-signed certificate for initial Nginx startup:

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

Reload Nginx — since Swarm configs are immutable, remove and redeploy the proxy stack (certificate volumes persist):

```bash
docker stack rm laravel_proxy && sleep 5
docker stack deploy -c docker-compose-proxy-swarm.yml laravel_proxy
```

#### Step 5 — Auto-renew (cron on host)

Add the following entry to the host crontab (`crontab -e`):

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

> ⚠️ Let's Encrypt **HTTP-01 challenge requires port 80 to be publicly reachable**. If port 80 is remapped, use the **DNS-01 challenge** instead (verifies ownership via TXT record). Example with Cloudflare:
> ```bash
> docker run --rm \
>   -v laravel_proxy_certs:/etc/letsencrypt \
>   -v ~/.cloudflare.ini:/cf.ini:ro \
>   certbot/dns-cloudflare certonly \
>     --dns-cloudflare --dns-cloudflare-credentials /cf.ini \
>     -d yourdomain.com -d '*.yourdomain.com' \
>     --email is.dony77@gmail.com --agree-tos --non-interactive
> ```
> The `~/.cloudflare.ini` file requires `dns_cloudflare_api_token = <token>` with `Zone:DNS:Edit` scope. DNS-01 also supports wildcard certificates.

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

#### Built-in DDoS and abuse mitigation

The Nginx proxy ([.docker/nginx/proxy.conf](.docker/nginx/proxy.conf)) includes Layer 7 protections that block or throttle abusive traffic **before it reaches Laravel**. No third-party WAF or additional modules are required — all rules use stock Nginx directives.

> ⚠️ These protections only mitigate **application-layer (L7)** abuse: HTTP floods, slowloris, brute-force, and scanners. **Volumetric (L3/L4) DDoS** attacks (SYN floods, UDP floods, amplification) require an upstream scrubbing service such as Cloudflare or AWS Shield.

**Blocking rules:**

| Rule | Threshold / Pattern | Action |
| --- | --- | --- |
| **Global request rate** per IP | > 30 req/s sustained (burst 60) | Excess → `429` |
| **Auth endpoint rate** per IP (`/login`, `/register`, `/password*`, `/api/auth*`) | > 5 req/min (burst 3) | Excess → `429` |
| **Concurrent connections** per IP | > 20 | New conns → `429` |
| **Slowloris / slow-POST** | Body or header idle > 10s; send idle > 10s | Connection closed |
| **HTTP method** | Anything outside `GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS` | `405 Method Not Allowed` |
| **Scanner User-Agent** | `nikto`, `sqlmap`, `nmap`, `masscan`, `zgrab`, `fuzzer`, `wpscan` (case-insensitive substring) | `444` (connection dropped, no response) |
| **Empty User-Agent** | `User-Agent: ` header missing/blank | `444` |
| **Request body size** | > 10 MB | `413 Payload Too Large` |
| **Request header size** | > 8 KB × 4 buffers | `400 Bad Request` |

**Adjust thresholds** by editing the `limit_req_zone` / `limit_conn_zone` directives at the top of `proxy.conf`, then redeploy:

```bash
docker stack rm laravel_proxy && sleep 5
docker stack deploy -c docker-compose-proxy-swarm.yml laravel_proxy
```

**Modify auth endpoint patterns** by editing the regex in the `location ~ ^/(login|register|password|api/auth)` block. The strict 5 req/min limit is designed to prevent credential-stuffing attacks.

**Potential false positives:**

- Clients behind a shared egress IP may trigger per-IP limits — whitelist their CIDR using `geo` + `map` directives.
- Health-check monitors with empty User-Agent headers will be blocked — configure them to send a valid `User-Agent`.
- Large file uploads will be terminated by `client_body_timeout 10s` — increase the timeout on specific `location` blocks (e.g., `/api/upload`) rather than globally.

**Why ports 80/443 use `mode: host`**

Docker Swarm's default ingress routing mesh NATs all incoming traffic through the overlay network, causing every request to arrive at Nginx with the same source IP (typically `10.0.0.x`). This breaks per-IP rate limiting.

The proxy stack publishes ports in [host mode](https://docs.docker.com/engine/swarm/services/#publish-a-services-ports-directly-on-the-swarm-node) so Nginx terminates connections directly on the node, preserving the real client IP. Trade-offs:

- Nginx is pinned to a single node (`node.role == manager`, `replicas: 1`). Horizontal scaling requires `mode: global` with an external L4 load balancer.
- No automatic cross-node load balancing — this is delegated to the upstream load balancer or Cloudflare.

> **Note:** On Docker Desktop (macOS/Windows), external requests pass through the VM NAT and may still appear as `192.168.65.1`. This does not affect Linux hosts.

**Inspect rate-limit events** in the Nginx error log:

```bash
docker service logs laravel_proxy_nginx --tail 100 | grep -E 'limiting requests|limiting connections'
```

**Distinguishing `429` from `503` during load testing:**

- **`429 Too Many Requests`** — triggered by Nginx rate-limit rules; the request never reached the application. Check for `limiting requests` / `limiting connections` in the error log.
- **`503 Service Unavailable`** — upstream failure: application returned 5xx, container crashed, or `proxy_pass` timed out. Check for `upstream prematurely closed`, `connect() failed`, or `upstream timed out` in the error log.

To **bypass rate limiting during load tests**, temporarily raise the thresholds in `proxy.conf`:

```nginx
limit_req_zone  $binary_remote_addr zone=req_global:10m rate=1000r/s;
# in server block:
limit_req  zone=req_global burst=2000 nodelay;
limit_conn conn_per_ip 1000;
```

Alternatively, whitelist the load-tester IP using a `geo` + `map` pair (empty key bypasses the limit):

```nginx
geo $limit { default 1; 203.0.113.50/32 0; }
map $limit $limit_key { 0 ""; 1 $binary_remote_addr; }
limit_req_zone $limit_key zone=req_global:10m rate=30r/s;
```

#### Tear down proxy

```bash
docker stack rm laravel_proxy
# Certificate volumes persist; remove manually if needed:
# docker volume rm laravel_proxy_certs laravel_proxy_webroot
```

### 5. Production deployment with Podman

An alternative to Docker Swarm using [Podman](https://podman.io/) and `podman-compose`. The setup consists of two compose projects:

- `proxy` — Nginx reverse proxy with TLS termination ([podman-compose-proxy.yaml](podman-compose-proxy.yaml))
- `laravel` — Application, Postgres, and Redis ([podman-compose.yml](podman-compose.yml))

The app connects to the proxy via the shared `laravel_proxy` external network.

#### Prerequisites

```bash
# Verify Podman and podman-compose are installed
podman --version
podman-compose --version

# Authenticate with GHCR (requires PAT with read:packages scope)
cat ~/.ghcr_token | podman login ghcr.io -u mdonnyirwansyah --password-stdin
```

#### Create secrets

Podman secrets are used for sensitive values (app key and database password):

```bash
# Generate and store the application key
php artisan key:generate --show | podman secret create laravel_app_key -

# Store the database password
echo "your-strong-db-password" | podman secret create laravel_db_password -

# Verify
podman secret ls   # expect: laravel_app_key, laravel_db_password
```

#### Step 1 — Prepare certificate volumes (self-signed)

Create named volumes and generate a self-signed certificate for initial Nginx startup:

```bash
podman volume create laravel_proxy_certs
podman volume create laravel_proxy_webroot

podman run --rm -v laravel_proxy_certs:/certs alpine/openssl \
  req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /certs/privkey.pem \
  -out    /certs/fullchain.pem \
  -subj   "/CN=$(curl -s ifconfig.me)"
```

#### Step 2 — Deploy the proxy

The proxy must start first to create the `laravel_proxy` network, which the app stack joins as an external network:

```bash
podman-compose -f podman-compose-proxy.yaml up -d
```

#### Step 3 — Deploy the application

```bash
podman-compose -f podman-compose.yml up -d
```

#### Verify

```bash
# Check all containers are running and healthy
podman ps --format "table {{.Names}}\t{{.Status}}"

# Test the health endpoint
curl -kI https://localhost/up    # -k skips self-signed certificate warning
```

#### Update the application

Pull the latest image and recreate the app container:

```bash
podman-compose -f podman-compose.yml pull app
podman-compose -f podman-compose.yml up -d app
```

#### Switch to Let's Encrypt (once domain is ready)

Point your domain's A record at the server, then issue a certificate via webroot challenge:

```bash
export DOMAIN=yourdomain.com
export EMAIL=is.dony77@gmail.com

podman run --rm \
  -v laravel_proxy_certs:/etc/letsencrypt \
  -v laravel_proxy_webroot:/var/www/certbot \
  certbot/certbot certonly \
    --webroot -w /var/www/certbot \
    -d $DOMAIN \
    --email $EMAIL --agree-tos --no-eff-email \
    --non-interactive
```

Update [.podman/nginx/proxy.conf](.podman/nginx/proxy.conf) to use the issued certificate:

```nginx
ssl_certificate     /etc/nginx/certs/live/yourdomain.com/fullchain.pem;
ssl_certificate_key /etc/nginx/certs/live/yourdomain.com/privkey.pem;
server_name yourdomain.com;
```

Restart the proxy to apply the new configuration:

```bash
podman-compose -f podman-compose-proxy.yaml down
podman-compose -f podman-compose-proxy.yaml up -d
```

#### Auto-renew (cron on host)

Add the following entry to the host crontab (`crontab -e`):

```cron
0 3 * * * podman run --rm -v laravel_proxy_certs:/etc/letsencrypt -v laravel_proxy_webroot:/var/www/certbot certbot/certbot renew --quiet && podman-compose -f /path/to/laravel/podman-compose-proxy.yaml restart nginx
```

#### Tear down

```bash
# Stop the application stack
podman-compose -f podman-compose.yml down

# Stop the proxy stack
podman-compose -f podman-compose-proxy.yaml down

# Data volumes persist; remove manually if needed:
# podman volume rm laravel_postgres laravel_redis
# podman volume rm laravel_proxy_certs laravel_proxy_webroot
```
