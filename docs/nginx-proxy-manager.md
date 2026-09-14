# Nginx Proxy Manager + Odoo 19

This template is designed to let Nginx Proxy Manager (NPM) reach each Odoo
instance over a shared private Docker network while the host-published Odoo
ports remain bound to 127.0.0.1.

## One-time NPM network connection

The installer creates the external Docker network:

```text
odoo-proxy
```

Connect the Nginx Proxy Manager application/container to that network once.

Find the NPM container name:

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}' | grep -i 'nginx-proxy-manager\|jc21'
```

Then connect it:

```bash
docker network connect odoo-proxy <NPM_CONTAINER_NAME>
```

Running the command again on an already-connected container is unnecessary.

Verify:

```bash
docker network inspect odoo-proxy
```

Each installed Odoo instance is attached automatically to this network.

## Proxy Host

Assume the project directory is named:

```text
customer-sa
```

The installer uses:

```text
COMPOSE_PROJECT_NAME=customer-sa
```

and the Odoo container is therefore:

```text
customer-sa-odoo19
```

In Nginx Proxy Manager create a Proxy Host:

- Domain Names: your Odoo subdomain, e.g. `erp.customer.com`
- Scheme: `http`
- Forward Hostname / IP: `customer-sa-odoo19`
- Forward Port: `8069`
- Websockets Support: enabled
- Block Common Exploits: enabled if compatible with your deployment
- SSL: request/use a certificate and enable Force SSL

Do not forward the normal Proxy Host to the host's public IP and do not use the
host-mapped 100xx port when NPM is on the shared Docker network.

## Required /websocket custom location

Odoo 19 with workers enabled serves WebSocket traffic on the gevent port 8072,
not on the normal HTTP port 8069.

In the same NPM Proxy Host add a Custom Location:

```text
Location: /websocket
Scheme: http
Forward Hostname / IP: customer-sa-odoo19
Forward Port: 8072
```

Enable WebSocket support for the location where the NPM version exposes that
option.

If the Custom Location has an Advanced configuration field, use:

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

The main Proxy Host and the `/websocket` custom location must point to the
same Odoo container but different internal ports:

```text
/           -> customer-sa-odoo19:8069
/websocket  -> customer-sa-odoo19:8072
```

## Test the WebSocket route

First verify that NPM can resolve the Odoo container from inside its own
container:

```bash
docker exec <NPM_CONTAINER_NAME> getent hosts customer-sa-odoo19
```

Then inspect the browser Developer Tools -> Network -> WS section while Odoo is
open. The `/websocket` request should upgrade successfully instead of
returning 400/404/502.

A failed Odoo WebSocket normally shows in the UI as:

```text
Real-time connection lost
```

## Session isolation

Use a different hostname/subdomain for each Odoo instance. Do not configure NPM
to rewrite the Odoo `session_id` cookie onto a shared parent domain such as
`.example.com`.

The shared Docker proxy network does not share browser sessions; it is only
private backend connectivity between NPM and Odoo.
