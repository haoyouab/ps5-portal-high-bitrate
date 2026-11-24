# Bidirectional header-NAT relay (raspberry-pi/linux_native.py) on a Docker macvlan.
FROM python:3.12-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends nftables iproute2 ethtool procps \
 && rm -rf /var/lib/apt/lists/*
COPY raspberry-pi/ /opt/portal-relay-pi4/
COPY deploy/docker-nat/patch_macvlan.py deploy/docker-nat/entrypoint.sh deploy/docker-nat/repair_arp.py /opt/
WORKDIR /opt/portal-relay-pi4
RUN rm -rf .venv tests && python -m venv .venv && .venv/bin/pip install --no-cache-dir -r requirements.txt \
 && python /opt/patch_macvlan.py linux_native.py && chmod 0755 /opt/entrypoint.sh
ENV PORTAL_ALLOW_MACVLAN=1 PYTHONUNBUFFERED=1
ENTRYPOINT ["/opt/entrypoint.sh"]
CMD ["service"]
