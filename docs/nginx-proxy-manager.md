# Nginx Proxy Manager + Odoo 19

The preferred production path is:

```text
Browser
  -> HTTPS hostname
  -> Nginx Proxy Manager
  -> shared private Docker network
  -> Odoo container
```

The Odoo host ports remain bound to `127.0.0.1` for local diagnostics only and
are not the normal public path.

## Shared proxy network

The installer selects the proxy network in this order:

1. an explicit `PROXY_NETWORK` value, if supplied;
2. an existing `proxy-tier` network;
3. an existing `odoo-proxy` network;
4. otherwise it creates `odoo-proxy`.

On the audited production server, Nginx Proxy Manager already uses
`proxy-tier`, so new instances reuse that existing network instead of creating
a parallel proxy network.

Each new Odoo instance gets a unique Docker-network alias:

```text
<project>-odoo
```

Example:

```text
customer-sa-odoo
```

## Proxy Host for the default template

The default template uses `workers = 2`, therefore Odoo runs in
multiprocessing mode.

Configure the main NPM Proxy Host:

- Domain Names: e.g. `erp.customer.com`
- Scheme: `http`
- Forward Hostname / IP: `customer-sa-odoo`
- Forward Port: `8069`
- Websockets Support: enabled
- SSL: certificate + Force SSL

Do not point NPM at the server public IP or the host-mapped 100xx port when NPM
and Odoo share a Docker network.

## /websocket routing when workers > 0

With Odoo multiprocessing/gevent mode (`workers > 0`), WebSocket traffic uses
the gevent port 8072.

Add a Custom Location:

```text
Location: /websocket
Scheme: http
Forward Hostname / IP: customer-sa-odoo
Forward Port: 8072
```

If an Advanced field is available:

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

Result:

```text
/           -> customer-sa-odoo:8069
/websocket  -> customer-sa-odoo:8072
```

## Important: workers = 0 is different

Do not blindly copy the 8072 rule to legacy Odoo instances running the default
threaded mode (`workers = 0` or workers unset).

In Odoo's default threaded mode, the gevent port is not used. Those instances
must be assessed separately; the fact that a host maps 200xx -> 8072 does not
mean a gevent worker is actually listening there.

This distinction is especially important when migrating older live projects.

## Verify

Check that NPM can resolve the Odoo alias:

```bash
docker exec <NPM_CONTAINER_NAME> getent hosts customer-sa-odoo
```

For a multiprocessing instance, open browser Developer Tools -> Network -> WS.
The `/websocket` request should upgrade successfully, typically with HTTP 101.

A routing error commonly appears in Odoo as:

```text
Real-time connection lost
```

and may produce a server-side error saying the websocket was not opened on the
evented port.

## Session isolation

Keep a separate hostname/subdomain per Odoo instance and keep the
`session_id` cookie host-only.

Do not add NPM cookie rewriting such as:

```text
Domain=.example.com
```

The audited server currently has host-only Odoo session cookies, so that
behavior should be preserved.
