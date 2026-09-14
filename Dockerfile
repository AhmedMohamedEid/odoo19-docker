ARG ODOO_VERSION=19.0
FROM odoo:${ODOO_VERSION}

USER root

COPY requirements/apt.txt /tmp/apt.txt
RUN set -eux; \
    sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' /tmp/apt.txt > /tmp/apt-packages.txt; \
    if [ -s /tmp/apt-packages.txt ]; then \
        apt-get update; \
        xargs -r apt-get install -y --no-install-recommends < /tmp/apt-packages.txt; \
        rm -rf /var/lib/apt/lists/*; \
    fi; \
    rm -f /tmp/apt.txt /tmp/apt-packages.txt

COPY requirements/requirements.txt /tmp/requirements.txt
RUN set -eux; \
    sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' /tmp/requirements.txt > /tmp/python-requirements.txt; \
    if [ -s /tmp/python-requirements.txt ]; then \
        python3 -m pip install --no-cache-dir --break-system-packages -r /tmp/python-requirements.txt; \
    fi; \
    rm -f /tmp/requirements.txt /tmp/python-requirements.txt

USER odoo
