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
9. Starts Odoo and prints the selected ports, URL and master password.

The installer intentionally does **not** create an Odoo database. Open Odoo's Database Manager and create the database yourself so you can select the correct country, language and demo-data options.

## Automatic ports

Default ranges:

```text
Odoo HTTP:       10019 -> 19999
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

Python dependencies are installed at image build time, not every time Odoo restarts.

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
- `proxy_mode = False` by default.

Only set `proxy_mode = True` when the instance is actually behind a correctly configured trusted reverse proxy.

Instance-specific Docker values are stored in `.env`, including the selected ports and PostgreSQL password. `.env`, generated config, database data, filestore and logs are excluded from Git.

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
