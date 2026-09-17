# Odoo 19 Docker — Production Multi-Instance Runbook

This repository is a production-oriented Odoo 19 Docker template for running many isolated customer instances on the same server.

Each installed project is self-contained on the host, uses its own PostgreSQL data directory and Odoo filestore, gets unique Docker DNS aliases, and is published through Nginx Proxy Manager (NPM) instead of exposing raw Odoo ports to the internet.

The template is designed for this architecture:

```text
Internet
   |
   | HTTPS :443
   v
Nginx Proxy Manager
   |
   | shared private Docker network (proxy-tier / odoo-proxy)
   v
<project>-odoo:8069
   |
   | private project network
   v
<project>-db:5432
```

When `workers > 0`, WebSocket traffic is routed separately:

```text
/websocket -> <project>-odoo:8072
```

## Table of contents

- [1. Installed project layout](#1-installed-project-layout)
- [2. New server preparation](#2-new-server-preparation)
- [3. Nginx Proxy Manager shared network](#3-nginx-proxy-manager-shared-network)
- [4. Naming convention for a new customer](#4-naming-convention-for-a-new-customer)
- [5. Create a new Odoo project](#5-create-a-new-odoo-project)
- [6. Configure DNS and Nginx Proxy Manager](#6-configure-dns-and-nginx-proxy-manager)
- [7. Create the Odoo database](#7-create-the-odoo-database)
- [8. Finalize a production database](#8-finalize-a-production-database)
- [9. Production smoke test](#9-production-smoke-test)
- [10. Custom addons](#10-custom-addons)
- [11. Python and system dependencies](#11-python-and-system-dependencies)
- [12. Upgrade Odoo modules safely](#12-upgrade-odoo-modules-safely)
- [13. Rebuild the Odoo image](#13-rebuild-the-odoo-image)
- [14. Daily operations](#14-daily-operations)
- [15. Ports and worker model](#15-ports-and-worker-model)
- [16. Docker network and database DNS isolation](#16-docker-network-and-database-dns-isolation)
- [17. Sessions and subdomains](#17-sessions-and-subdomains)
- [18. Security checklist](#18-security-checklist)
- [19. Troubleshooting](#19-troubleshooting)
- [20. Moving an instance](#20-moving-an-instance)
- [21. Updating an already-installed project template](#21-updating-an-already-installed-project-template)

---

## 1. Installed project layout

A project created as `/odoo/customer-sa` contains:

```text
customer-sa/
├── addons/
│   ├── custom/                 # custom/community addons
│   └── enterprise/             # optional/private Enterprise addons
├── config/
│   ├── odoo.conf               # generated instance configuration
│   └── odoo.conf.example
├── data/
│   ├── odoo/                   # filestore, sessions and Odoo runtime data
│   └── postgresql/             # PostgreSQL data directory
├── docs/
│   ├── nginx-proxy-manager.md
│   └── nginx-subdomain.conf.example
├── logs/
│   ├── odoo-server.log
│   └── module-upgrade-history.log
├── requirements/
│   ├── requirements.txt        # additional Python packages
│   └── apt.txt                 # additional Ubuntu/system packages
├── .env                        # generated per-instance settings/secrets
├── Dockerfile
├── docker-compose.yml
├── finalize.sh                 # lock production to one DB / disable DB Manager
├── rebuild.sh                  # rebuild Odoo image after dependencies change
├── upgrade-module.sh           # controlled module upgrade helper
└── run.sh                      # new-instance installer
```

Host paths map to standard container paths:

```text
./data/odoo          -> /var/lib/odoo
./data/postgresql    -> /var/lib/postgresql/data
./addons/custom      -> /mnt/extra-addons
./addons/enterprise  -> /mnt/enterprise
./config/odoo.conf   -> /etc/odoo/odoo.conf
./logs               -> /var/log/odoo
```

PostgreSQL and Odoo data are host bind mounts. The template does not hide production data in Docker named volumes.

---

## 2. New server preparation

### 2.1 Recommended host

Use a supported Ubuntu LTS server with sufficient CPU, RAM and storage for the expected number of Odoo workers and PostgreSQL databases.

Before installing Odoo projects, update the host and install the basic tools:

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y ca-certificates curl git openssl
```

### 2.2 Install Docker Engine and Docker Compose v2

Use Docker's official Ubuntu repository:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"${UBUNTU_CODENAME:-$VERSION_CODENAME}\") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

sudo systemctl enable --now docker
```

Verify:

```bash
docker version
docker compose version
```

This repository requires Docker Compose v2 (`docker compose`), not the legacy `docker-compose` Python command.

### 2.3 Create the project root

Recommended:

```bash
sudo mkdir -p /odoo
sudo chmod 755 /odoo
```

Each customer will then live under one directory:

```text
/odoo/customer-a
/odoo/customer-b
/odoo/customer-c
```

### 2.4 Firewall baseline

For a normal reverse-proxy deployment, the public services normally needed are SSH, HTTP and HTTPS only.

Example with UFW:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

Do not depend on UFW alone to protect Docker-published ports. This template binds Odoo's diagnostic host ports to `127.0.0.1` by default, which is the primary protection against direct public access.

### 2.5 Install Nginx Proxy Manager

Deploy Nginx Proxy Manager separately using your normal NPM deployment process.

This Odoo repository does not manage the NPM database or NPM lifecycle. It only expects NPM and Odoo to share a private Docker network.

---

## 3. Nginx Proxy Manager shared network

The preferred network name on the current production environment is:

```text
proxy-tier
```

Create it once on a new server:

```bash
docker network inspect proxy-tier >/dev/null 2>&1 || \
  docker network create proxy-tier
```

Nginx Proxy Manager must be attached to this network.

For a permanent setup, add the external network to the NPM Compose file rather than relying only on a manual `docker network connect`:

```yaml
services:
  app:
    # existing NPM settings...
    networks:
      - default
      - proxy-tier

networks:
  proxy-tier:
    external: true
    name: proxy-tier
```

Then recreate NPM using its own Compose project.

For a temporary/manual connection to an already-running NPM container:

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}' | grep -Ei 'nginx-proxy-manager|jc21'

docker network connect proxy-tier <NPM_CONTAINER_NAME>
```

Verify:

```bash
docker network inspect proxy-tier
```

The Odoo installer automatically:

1. reuses `PROXY_NETWORK` if explicitly supplied;
2. otherwise reuses `proxy-tier` if it exists;
3. otherwise reuses `odoo-proxy` if it exists;
4. otherwise creates `odoo-proxy`.

On the existing audited production server, `proxy-tier` is the expected network.

---

## 4. Naming convention for a new customer

Keep infrastructure names short, lowercase and stable.

Example company:

```text
محمد الرميحي اللوجيستيه
```

Recommended infrastructure values:

```text
Project directory : /odoo/rumaihi-logistics
Compose project   : rumaihi-logistics
Database          : rumaihi_logistics
Subdomain         : rumaihi.rs-sa.com
Odoo proxy alias  : rumaihi-logistics-odoo
DB private alias  : rumaihi-logistics-db
```

Rules:

- project directory: lowercase ASCII, preferably hyphens;
- database name: lowercase ASCII, usually underscores;
- public hostname: short and customer-friendly;
- do not reuse the same project name for two installations;
- do not use the public domain itself as a PostgreSQL service name.

`run.sh` normalizes the project directory basename to a Docker-safe lowercase name.

---

## 5. Create a new Odoo project

### 5.1 Standard install

From anywhere on the server:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/AhmedMohamedEid/odoo19-docker/main/run.sh \
  | sudo bash -s /odoo/rumaihi-logistics
```

The installer does all of the following:

1. validates Docker, Docker Compose v2, Git and OpenSSL;
2. derives a safe Compose project name from the destination directory;
3. refuses to reuse an existing Compose project name;
4. discovers ports already used by the host and Docker containers;
5. selects a free HTTP port in `10019-19999`;
6. selects the matching gevent/WebSocket port at HTTP + `10000`;
7. generates a random PostgreSQL password;
8. generates a random Odoo Database Manager master password;
9. detects/reuses the shared proxy network;
10. creates a unique Odoo Docker alias (`<project>-odoo`);
11. creates a unique private PostgreSQL alias (`<project>-db`);
12. pulls the current `odoo:19.0` and `postgres:16` images;
13. pins the exact image digests into `.env` for repeatable future rebuilds;
14. builds the project-specific Odoo image;
15. detects the real Odoo/PostgreSQL UID/GID values from the images;
16. applies service-specific ownership and permissions without `chmod 777`;
17. starts PostgreSQL and waits for it to become healthy;
18. starts Odoo and waits for its healthcheck;
19. publishes host diagnostic ports on `127.0.0.1` only;
20. prints the NPM targets, selected ports and Odoo master password.

The installer intentionally does **not** create the Odoo business database. Database creation remains manual so the administrator can choose the correct country, language, demo-data and localization options.

### 5.2 Optional installer overrides

Example:

```bash
sudo \
  ODOO_PORT_START=12000 \
  ODOO_PORT_END=12999 \
  ODOO_WORKERS=4 \
  ODOO_MAX_CRON_THREADS=1 \
  ODOO_DB_MAXCONN=16 \
  PROXY_NETWORK=proxy-tier \
  ./run.sh /odoo/customer-sa
```

Supported variables:

```text
ODOO_DOCKER_REF
ODOO_PORT_START
ODOO_PORT_END
ODOO_GEVENT_OFFSET
ODOO_BIND_IP
ODOO_VERSION
POSTGRES_VERSION
ODOO_WORKERS
ODOO_MAX_CRON_THREADS
ODOO_DB_MAXCONN
PROXY_NETWORK
```

Normal production default:

```text
ODOO_BIND_IP=127.0.0.1
```

Do not use `ODOO_BIND_IP=0.0.0.0` for normal customer deployments.

### 5.3 Check the generated project

```bash
cd /odoo/rumaihi-logistics

docker compose ps
cat .env | grep -E '^(COMPOSE_PROJECT_NAME|PROXY_NETWORK|ODOO_PROXY_ALIAS|DB_NETWORK_ALIAS|ODOO_BIND_IP|ODOO_PORT|ODOO_GEVENT_PORT|ODOO_WORKERS)='
```

Expected conceptually:

```text
COMPOSE_PROJECT_NAME=rumaihi-logistics
PROXY_NETWORK=proxy-tier
ODOO_PROXY_ALIAS=rumaihi-logistics-odoo
DB_NETWORK_ALIAS=rumaihi-logistics-db
ODOO_BIND_IP=127.0.0.1
ODOO_PORT=18xxx
ODOO_GEVENT_PORT=28xxx
ODOO_WORKERS=2
```

Do not paste `.env` publicly because it contains the PostgreSQL password.

---

## 6. Configure DNS and Nginx Proxy Manager

### 6.1 DNS

Create an A/AAAA record for the customer hostname pointing to the reverse-proxy server.

Example:

```text
rumaihi.rs-sa.com -> SERVER_PUBLIC_IP
```

### 6.2 Verify Docker DNS before configuring NPM

Find the NPM container:

```bash
NPM_CONTAINER="$(
  docker ps --format '{{.Names}} {{.Image}}' \
  | awk 'tolower($0) ~ /nginx-proxy-manager|jc21\/nginx-proxy-manager/ {print $1; exit}'
)"

echo "$NPM_CONTAINER"
```

Verify NPM can resolve the Odoo alias:

```bash
docker exec "$NPM_CONTAINER" getent hosts rumaihi-logistics-odoo
```

You can also test from the shared network:

```bash
docker run --rm --network proxy-tier curlimages/curl:latest \
  -I http://rumaihi-logistics-odoo:8069/web/health
```

### 6.3 NPM Proxy Host

Create a Proxy Host:

```text
Domain Names         : rumaihi.rs-sa.com
Scheme               : http
Forward Hostname/IP  : rumaihi-logistics-odoo
Forward Port         : 8069
Websockets Support   : ON
SSL                  : certificate enabled
Force SSL            : ON
```

NPM should use Docker DNS (`rumaihi-logistics-odoo`) instead of the server public IP and instead of the host `18xxx` port.

### 6.4 WebSocket custom location

The default template uses `workers=2`, so `/websocket` must go to Odoo's gevent port 8072.

Add a Custom Location:

```text
Location             : /websocket
Scheme               : http
Forward Hostname/IP  : rumaihi-logistics-odoo
Forward Port         : 8072
```

Where NPM exposes an Advanced configuration field, the following headers are suitable:

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Real-IP $remote_addr;
```

Final routing:

```text
/           -> rumaihi-logistics-odoo:8069
/websocket  -> rumaihi-logistics-odoo:8072
```

For legacy projects with `workers=0`, do not blindly add a 8072 route. Odoo's gevent port is not used in default threaded mode.

More detail is available in:

```text
docs/nginx-proxy-manager.md
```

---

## 7. Create the Odoo database

Open the HTTPS hostname in the browser.

The Database Manager is intentionally enabled only for first-time setup.

Create the database manually using the master password printed by `run.sh`.

Recommended checklist:

```text
Database name : customer-specific technical name (e.g. rumaihi_logistics)
Email         : production administrator email
Password      : strong administrator password
Language      : correct customer language
Country       : correct legal/localization country
Demo data     : normally disabled for production
```

Do not create multiple customer databases inside one project. The intended production model is one customer project / one production database.

---

## 8. Finalize a production database

Immediately after database creation and verification:

```bash
cd /odoo/rumaihi-logistics
./finalize.sh rumaihi_logistics
```

`finalize.sh`:

1. validates the database name;
2. checks that the PostgreSQL database really exists;
3. saves a timestamped copy of the previous `odoo.conf`;
4. sets `list_db = False`;
5. sets `db_name = rumaihi_logistics`;
6. sets an exact `dbfilter`;
7. restarts Odoo only;
8. waits for Odoo to become healthy;
9. restores the previous config automatically if finalization/restart/health verification fails.

Verify:

```bash
grep -E '^(list_db|db_name|dbfilter)' config/odoo.conf
```

Expected:

```ini
list_db = False
db_name = rumaihi_logistics
dbfilter = ^rumaihi_logistics$
```

The timestamped pre-finalize config is ignored by Git and remains available locally for troubleshooting.

---

## 9. Production smoke test

### 9.1 Container health

```bash
cd /odoo/rumaihi-logistics
docker compose ps
```

PostgreSQL and Odoo should be healthy.

### 9.2 Local backend health

Read the selected local port:

```bash
grep '^ODOO_PORT=' .env
```

Then:

```bash
curl -i http://127.0.0.1:<ODOO_PORT>/web/health
```

Expected HTTP status: `200`.

### 9.3 HTTPS domain

```bash
curl -I https://rumaihi.rs-sa.com/web/health
```

### 9.4 WebSocket

In the browser:

```text
Developer Tools -> Network -> WS
```

The `/websocket` connection should upgrade successfully (normally HTTP `101`) when workers are enabled.

The Odoo interface should not show:

```text
Real-time connection lost
```

### 9.5 Logs

```bash
tail -n 150 logs/odoo-server.log

docker compose logs --tail=150 db
```

Look for unexpected `ERROR`, `CRITICAL`, tracebacks, DB connection failures or WebSocket errors.

---

## 10. Custom addons

Put customer/community modules in:

```text
addons/custom/
```

Put optional Enterprise/private Enterprise modules in:

```text
addons/enterprise/
```

Both are already included in Odoo's `addons_path`.

After changing module source code, upgrade the affected module using `upgrade-module.sh` as described below.

If a new module also requires Python/system packages, update `requirements/` and rebuild the image **before** upgrading/installing the module.

---

## 11. Python and system dependencies

### Python requirements

Edit:

```text
requirements/requirements.txt
```

Example:

```text
paramiko==3.5.1
boto3==1.40.0
```

Then:

```bash
./rebuild.sh
```

### System/APT requirements

Edit:

```text
requirements/apt.txt
```

Example:

```text
ffmpeg
unixodbc
```

Then:

```bash
./rebuild.sh
```

Dependencies are installed at Docker **build time**, not every time Odoo starts.

Each installed project pins the exact Odoo/PostgreSQL image digests selected during installation. A later `./rebuild.sh` therefore does not silently move that project to a newer Odoo base-image digest.

---

## 12. Upgrade Odoo modules safely

The repository includes:

```text
upgrade-module.sh
```

The script performs a controlled module upgrade for one project/database.

### 12.1 Single module

After `finalize.sh`, the database is detected automatically from `config/odoo.conf`:

```bash
cd /odoo/rumaihi-logistics
./upgrade-module.sh my_custom_module
```

### 12.2 Multiple modules

Use comma-separated technical names:

```bash
./upgrade-module.sh module_a,module_b,module_c
```

### 12.3 Before finalize / explicit database

If `db_name` is not yet stored in `odoo.conf`:

```bash
./upgrade-module.sh --db rumaihi_logistics my_custom_module
```

### 12.4 Non-interactive execution

For controlled automation/CI:

```bash
./upgrade-module.sh --yes my_custom_module
```

Or:

```bash
./upgrade-module.sh --db rumaihi_logistics --yes my_custom_module
```

### 12.5 What the script does

The upgrade helper:

1. validates module technical names;
2. resolves the target database from `db_name` or `--db`;
3. verifies the database exists in PostgreSQL;
4. records whether Odoo was already running;
5. asks for confirmation unless `--yes` is used;
6. stops **Odoo only** while leaving PostgreSQL running;
7. runs a one-off Odoo container with:
   - `-u <modules>`;
   - `--stop-after-init`;
   - `--no-http`;
   - `--workers=0`;
   - `--max-cron-threads=0`;
8. starts Odoo again if it was running before the upgrade;
9. waits for Docker health;
10. writes an audit entry to `logs/module-upgrade-history.log`.

Odoo's documented CLI supports module updates through `-u/--update` together with a target database and `--stop-after-init`. The helper additionally disables HTTP/cron for the temporary upgrade process.

### 12.6 Production warning

A module upgrade can change database schema and business data.

Before upgrading a production database, ensure that a current database/filestore backup or infrastructure snapshot exists.

`upgrade-module.sh` does **not** create a backup automatically and does **not** promise to undo database changes if a module migration itself fails. It only attempts to restore the previous Odoo runtime state so the service is not intentionally left stopped.

If the module requires a new Python package or Ubuntu package, do this first:

```bash
# edit requirements files
./rebuild.sh

# then update the database module
./upgrade-module.sh my_custom_module
```

---

## 13. Rebuild the Odoo image

Normal rebuild:

```bash
./rebuild.sh
```

Clean rebuild:

```bash
./rebuild.sh --no-cache
```

The script rebuilds the project-specific Odoo image, applies it to the Odoo service only, and waits for service health when supported by the installed Docker Compose version.

Use this for dependency/image changes. Use `upgrade-module.sh` for database module upgrades.

They solve different problems:

```text
rebuild.sh         -> Docker image / Python / system packages
upgrade-module.sh  -> Odoo database module update (-u)
```

---

## 14. Daily operations

Run from the project directory.

### Status

```bash
docker compose ps
```

### Start

```bash
docker compose up -d
```

### Stop services without removing containers

```bash
docker compose stop
```

### Restart Odoo only

```bash
docker compose restart odoo19
```

### Restart PostgreSQL only

Only when you intentionally need to:

```bash
docker compose restart db
```

### Odoo logs

```bash
tail -f logs/odoo-server.log
```

Docker-level Odoo output:

```bash
docker compose logs -f --tail=200 odoo19
```

### PostgreSQL logs

```bash
docker compose logs -f --tail=200 db
```

### Stop and remove project containers/network

```bash
docker compose down
```

The bind-mounted project data remains on disk, but do not use destructive commands against `data/` unless you intentionally want to destroy the instance.

Never casually run:

```text
rm -rf data/postgresql
rm -rf data/odoo
```

on a production project.

---

## 15. Ports and worker model

Default host allocation:

```text
Odoo HTTP        : 10019 -> 19999
Gevent/WebSocket : HTTP port + 10000
```

Example:

```text
HTTP   : 18082 -> container 8069
Gevent : 28082 -> container 8072
```

Host bindings are localhost by default:

```text
127.0.0.1:18082 -> 8069
127.0.0.1:28082 -> 8072
```

NPM does **not** normally use these host ports. It uses Docker DNS directly:

```text
customer-odoo:8069
customer-odoo:8072
```

### workers > 0

The default template uses:

```ini
workers = 2
max_cron_threads = 1
```

With workers enabled:

```text
/           -> 8069
/websocket  -> 8072
```

### workers = 0

In Odoo threaded mode, gevent 8072 is not used. This matters mainly when maintaining legacy deployments.

---

## 16. Docker network and database DNS isolation

The Odoo container joins two networks:

```text
1. project private/default network
2. shared proxy network
```

PostgreSQL joins **only** the project private/default network.

Each project gets a unique PostgreSQL alias:

```text
rumaihi-logistics-db
customer-a-db
customer-b-db
```

Odoo connects to that unique alias instead of the generic hostname `db`.

This prevents Docker DNS collisions when many projects or shared networks contain services with common names.

Conceptually:

```text
proxy-tier
   |
   +---- NPM
   |
   +---- rumaihi-logistics-odoo
               |
               | rumaihi-logistics_default
               v
        rumaihi-logistics-db
```

PostgreSQL is not exposed to `proxy-tier`.

---

## 17. Sessions and subdomains

Use one unique hostname per Odoo instance.

Good:

```text
client-a.example.com
client-b.example.com
```

Do not use public raw IP + different TCP ports as the normal browser URLs for several Odoo instances:

```text
http://203.0.113.10:10019
http://203.0.113.10:10020
```

Browser cookie scoping is based on hostname/domain/path, not TCP port. Odoo uses the common cookie name `session_id`, so direct same-host/different-port access can create login/session conflicts.

Keep `session_id` host-scoped. Do not configure NPM to rewrite it to a shared parent domain such as:

```text
Domain=.example.com
```

Do not add `proxy_cookie_domain` for Odoo sessions unless there is an explicit, reviewed requirement.

### Saved passwords are different from sessions

Browsers may suggest saved credentials across sibling subdomains even when Odoo sessions are correctly isolated.

For administrators handling many customers, use a password manager with per-host matching or separate browser profiles where stronger separation is required.

---

## 18. Security checklist

Before declaring an instance production-ready:

- [ ] public access is HTTPS through Nginx Proxy Manager;
- [ ] Odoo raw host ports are bound to `127.0.0.1`, not `0.0.0.0`;
- [ ] NPM forwards to `<project>-odoo:8069` on the private Docker network;
- [ ] `/websocket` goes to `<project>-odoo:8072` when workers are enabled;
- [ ] `proxy_mode = True`;
- [ ] `finalize.sh <database>` has been executed;
- [ ] `list_db = False`;
- [ ] `db_name` and exact `dbfilter` are set;
- [ ] `.env` is not publicly shared;
- [ ] `.env` mode remains `600`;
- [ ] Odoo config is not world-writable;
- [ ] containers are not configured with `user: root`;
- [ ] no recursive `chmod 777` is used;
- [ ] PostgreSQL is not attached to the shared proxy network;
- [ ] no parent-domain session cookie rewrite exists;
- [ ] production module upgrades are preceded by a current backup/snapshot;
- [ ] `docker compose ps` reports healthy services;
- [ ] `/websocket` works without `Real-time connection lost`.

---

## 19. Troubleshooting

### Odoo container is unhealthy

```bash
docker compose ps
docker compose logs --tail=200 odoo19
docker compose logs --tail=200 db
```

If `logs/odoo-server.log` does not exist, the official image may be failing before the Odoo application logger starts (for example, DB connection/entrypoint failure). In that case, `docker compose logs odoo19` is the primary source.

### Database authentication appears to alternate between different IPs

Check the current database hostname:

```bash
docker compose exec odoo19 sh -c 'echo "$HOST"'
```

It should be unique, for example:

```text
rumaihi-logistics-db
```

Check resolution:

```bash
docker compose exec odoo19 getent hosts rumaihi-logistics-db
```

Do not use the generic cross-project hostname `db` as Odoo's database target in this multi-network architecture.

### NPM returns 502

Verify the proxy network and alias:

```bash
docker network inspect proxy-tier

docker exec <NPM_CONTAINER> getent hosts <project>-odoo
```

Then test:

```bash
docker run --rm --network proxy-tier curlimages/curl:latest \
  -I http://<project>-odoo:8069/web/health
```

### `Real-time connection lost`

For `workers > 0`, verify NPM has:

```text
/          -> <project>-odoo:8069
/websocket -> <project>-odoo:8072
```

In browser Developer Tools -> Network -> WS, `/websocket` should upgrade successfully.

### `finalize.sh` fails

The script verifies the DB before editing Odoo config and keeps a timestamped previous config.

Check:

```bash
docker compose ps
docker compose logs --tail=150 odoo19
grep -E '^(list_db|db_name|dbfilter)' config/odoo.conf
```

### Module upgrade fails

Check:

```bash
docker compose ps
tail -n 200 logs/odoo-server.log
tail -n 50 logs/module-upgrade-history.log
```

If the module required a missing Python/system dependency, fix `requirements/`, run `./rebuild.sh`, then retry the module upgrade after reviewing database state and backup availability.

### Local health test

```bash
source .env
curl -i "http://127.0.0.1:${ODOO_PORT}/web/health"
```

---

## 20. Moving an instance

The raw project directory is intentionally self-contained.

Before copying/moving it:

```bash
cd /odoo/customer-sa
docker compose down
```

Then copy the complete project directory, including:

```text
.env
addons/
config/
data/
logs/
requirements/
Dockerfile
docker-compose.yml
scripts
```

Do not copy a live PostgreSQL data directory while PostgreSQL is writing to it.

After moving to another server, ensure:

1. Docker/Compose are installed;
2. the shared proxy network exists;
3. NPM is connected to it;
4. required pinned Docker image digests are pullable;
5. ownership of PostgreSQL/Odoo data remains correct;
6. DNS/NPM are updated;
7. `docker compose up -d` succeeds and services become healthy.

Database backup/restore automation remains outside the current repository scope and should be designed as a dedicated backup policy/tooling layer.

---

## 21. Updating an already-installed project template

`run.sh` removes `.git` from each created customer project intentionally. Installed projects do not automatically follow future repository changes.

This prevents a Git pull from unexpectedly modifying a live customer deployment.

For a new project, always install from current `main`:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/AhmedMohamedEid/odoo19-docker/main/run.sh \
  | sudo bash -s /odoo/new-customer
```

For an existing live project, do **not** overwrite its Compose/config/scripts blindly.

When a template fix must be applied to an existing project:

1. review the relevant repository change;
2. save a copy of the current project deployment/config files;
3. update only the required files;
4. run `docker compose config --quiet` before recreation;
5. recreate only the affected service where possible;
6. verify health, logs, HTTPS and WebSocket behavior;
7. keep an explicit rollback path.

The repository's `main` branch is the source for **new installations**. Existing production projects should be migrated deliberately rather than silently auto-updated.
