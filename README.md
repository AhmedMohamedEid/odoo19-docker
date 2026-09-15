# Odoo 19 Docker — Portable Multi-Instance Installer

A small Odoo 19 Docker template designed for fast, repeatable installations while keeping every instance self-contained inside one project directory.

## What an installed project contains

```text
customer-sa/
├── addons/
│   ├── custom/              # custom addons
│   └── enterprise/          # optional/private enterprise addons
├── config/
│   ├── odoo.conf            # generated instance configuration
│   └── odoo.conf.example
├── data/
│   ├── odoo/                # filestore, sessions and Odoo runtime data
│   └── postgresql/          # PostgreSQL data directory
├── docs/
│   └── nginx-subdomain.conf.example
├── logs/
│   └── odoo-server.log
├── requirements/
│   ├── requirements.txt     # custom Python packages
│   └── apt.txt              # custom Ubuntu/system packages
├── .env                     # generated ports and DB credentials
├── Dockerfile
├── docker-compose.yml
├── rebuild.sh
└── run.sh
```

The host-side data stays inside this directory. Inside the containers, standard Odoo/PostgreSQL paths are used:

- `./data/odoo` -> `/var/lib/odoo`
- `./data/postgresql` -> `/var/lib/postgresql/data`
- `./addons/custom` -> `/mnt/extra-addons`
- `./addons/enterprise` -> `/mnt/enterprise`
- `./config/odoo.conf` -> `/etc/odoo/odoo.conf`
- `./logs` -> `/var/log/odoo`

## Quick install

Docker and Docker Compose v2 must already be installed.

```bash
curl -fsSL https://raw.githubusercontent.com/AhmedMohamedEid/odoo19-docker/main/run.sh \
  | sudo bash -s /odoo/customer-sa
```

The installer automatically:

1. Finds the next safe Odoo HTTP port in the `10019-19999` range.
2. Reserves the matching gevent/WebSocket port at HTTP port + `10000`.
3. Checks listening system ports and Docker containers, including stopped containers.
4. Generates random PostgreSQL and Odoo master passwords.
5. Creates the portable project directory structure.
6. Pulls PostgreSQL 16 and builds the current `odoo:19.0` based image.
7. Applies service-specific ownership instead of `chmod 777`.
8. Waits for PostgreSQL health before starting Odoo.
9. Binds Odoo backend ports to `127.0.0.1` by default.
10. Starts Odoo and prints the selected ports and master password.

The installer intentionally does **not** create an Odoo database. Open Odoo's Database Manager and create the database yourself so you can select the correct country, language and demo-data options.

## Automatic ports

Default ranges:

```text
Odoo HTTP:        10019 -> 19999
Gevent/WebSocket: HTTP port + 10000
```

Example: if `10019`, `10020` and `10021` are already reserved, a new instance normally receives:

```text
HTTP:   10022
Gevent: 20022
```

The installer also verifies that both ports are actually free before using them.

The range can be changed for an installation:

```bash
sudo ODOO_PORT_START=12000 ODOO_PORT_END=12999 ./run.sh /odoo/customer-sa
```

## Backend bind address

By default each Odoo instance is published only on localhost:

```text
ODOO_BIND_IP=127.0.0.1
```

This means the raw Odoo ports are not exposed directly to the internet. Publish each instance through its own HTTPS subdomain and reverse proxy instead.

If a special deployment genuinely requires public/direct port access, the bind address can be overridden:

```bash
sudo ODOO_BIND_IP=0.0.0.0 ./run.sh /odoo/customer-sa
```

Direct public binding is not recommended for normal production deployments.

## Subdomains and session isolation

Use a unique hostname for every instance, for example:

```text
client-a.example.com -> 127.0.0.1:10019
client-b.example.com -> 127.0.0.1:10020
client-c.example.com -> 127.0.0.1:10021
```

The matching WebSocket/gevent ports would normally be `20019`, `20020`, and `20021`.

Do not use the same IP address with different ports as the normal browser URL when you need simultaneous logins to multiple Odoo instances. Browser cookies are scoped by host/domain and path, not by TCP port, while Odoo uses the common `session_id` cookie name. Two URLs such as:

```text
http://203.0.113.10:10019
http://203.0.113.10:10020
```

can therefore compete for the same browser cookie.

With unique subdomains, keep the Odoo session cookie host-scoped. Do **not** add reverse-proxy configuration that rewrites it to a shared parent domain such as:

```text
Domain=.example.com
```

The repository contains a reference Nginx configuration:

```text
docs/nginx-subdomain.conf.example
```

It passes the correct `Host`, `X-Forwarded-Host`, `X-Forwarded-Proto`, client IP headers, and WebSocket upgrade headers.

The generated Odoo config enables `proxy_mode = True` because the secure default is now localhost backend ports behind a trusted reverse proxy.

### Diagnosing unexpected cross-subdomain logout

For each public hostname, inspect the response cookie:

```bash
curl -skD - -o /dev/null https://client-a.example.com/web/login \
  | grep -i '^set-cookie:.*session_id'
```

Repeat for the second hostname.

The `session_id` cookie should not be rewritten to a shared parent `Domain=example.com`. In browser developer tools, each hostname should also have its own `session_id` cookie.

If an old parent-domain cookie already exists from a previous proxy configuration, remove that legacy cookie once after correcting the proxy configuration.

## Saved passwords across sibling subdomains

Session isolation and password-manager suggestions are separate issues.

Browsers such as Chrome can intentionally suggest saved credentials across sibling subdomains that belong to the same site. That does **not** mean the Odoo sessions are shared.

If strict saved-password isolation is important for administrators managing many customer instances, use one of these approaches:

- Use a password manager with per-host URI matching.
- Use customer-owned/custom domains where appropriate.
- Use separate browser profiles for strongly separated administration contexts.

Changing the Odoo session configuration cannot reliably force the browser's built-in password manager to stop suggesting credentials from sibling subdomains.

## Nginx Proxy Manager

For Nginx Proxy Manager deployments, the installer reuses an existing shared proxy network when possible. On the audited production host it detects and reuses:

```text
proxy-tier
```

If no known proxy network exists, it creates `odoo-proxy`.

Each Odoo container joins that network with a unique Docker-network alias based on the project, for example:

```text
customer-sa-odoo
```

The Nginx Proxy Manager container must be attached to the **selected** proxy network (`proxy-tier` on the audited server). The installer warns if it detects NPM but NPM is not attached. Then configure:

```text
/           -> customer-sa-odoo:8069
/websocket  -> customer-sa-odoo:8072
```

The `/websocket` route to 8072 is required when Odoo runs with `workers > 0` (the default template uses 2 workers). Simply enabling NPM's general "Websockets Support" while forwarding everything to 8069 does not reroute Odoo's WebSocket endpoint to its gevent port.

Legacy projects with `workers = 0` are different: Odoo's gevent port is not used in default threaded mode, so do not blindly add a 8072 route to those projects.

Detailed instructions are in:

```text
docs/nginx-proxy-manager.md
```

## Database DNS isolation

Odoo is connected to both its private project network and the shared proxy network. To prevent Docker DNS collisions with generic service names such as `db`, every installation generates a unique private PostgreSQL alias:

```text
customer-sa-db
```

Odoo connects to that alias rather than the generic hostname `db`. PostgreSQL remains only on the project's private/default network and is never attached to the shared proxy network.

## Start, stop and status

Run commands from the installed project directory:

```bash
docker compose up -d
docker compose stop
docker compose down
docker compose ps
```

Follow the Odoo application log:

```bash
tail -f logs/odoo-server.log
```

## Custom addons

Put custom modules in:

```text
addons/custom/
```

Optional Enterprise modules can be placed in:

```text
addons/enterprise/
```

Both paths are already present in `addons_path`.

## Custom Python requirements

Edit:

```text
requirements/requirements.txt
```

Example:

```text
paramiko==3.5.1
boto3==1.40.0
```

Then rebuild the instance image:

```bash
./rebuild.sh
```

To force a clean Docker build:

```bash
./rebuild.sh --no-cache
```

Python dependencies are installed at image build time, not every time Odoo restarts. Rebuilding keeps the exact Odoo base-image digest selected at installation time, so adding a requirement does not silently upgrade Odoo.

## Custom system packages

For packages that must be installed with `apt`, edit:

```text
requirements/apt.txt
```

Example:

```text
ffmpeg
unixodbc
```

Then run:

```bash
./rebuild.sh
```

## Configuration

Runtime configuration is generated at:

```text
config/odoo.conf
```

The generated configuration uses:

- `/var/lib/odoo` as Odoo's data directory.
- `/var/log/odoo/odoo-server.log` as the application log.
- 2 workers and 1 cron thread as conservative portable defaults.
- Database Manager enabled.
- `proxy_mode = True`.
- localhost-only backend publishing by default.

Instance-specific Docker values are stored in `.env`, including the selected ports, bind address, PostgreSQL password, proxy alias, worker settings, and the exact Odoo/PostgreSQL image digests pinned at installation time. `.env`, generated config, database data, filestore and logs are excluded from Git.

## Permissions and security

Odoo and PostgreSQL run with their image-default non-root service users. The installer configures only the runtime directories those users need and does not apply recursive `777` permissions.

No production passwords are stored in this public repository. Each installation receives fresh random credentials.

## Moving an instance directory

The layout is intentionally self-contained. If you want to move the raw project directory, stop its containers first:

```bash
docker compose down
```

Then move/copy the complete project directory together. Do not copy a live PostgreSQL data directory while PostgreSQL is writing to it.

This repository currently focuses on installation and runtime structure. Database backup/restore tooling is intentionally outside the current scope.
