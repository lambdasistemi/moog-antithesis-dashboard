# Collector image for the moog Antithesis dashboard.
#
# The image holds only the collection and publication scripts plus the static
# site. Every secret (Antithesis key, GitHub tokens, moog read environment)
# arrives as a read-only file mounted at runtime; nothing secret-shaped is
# baked in here: no ARG, no ENV, no secret file, no SSH client.
FROM debian:bookworm-20250811-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        curl \
        gh \
        git \
        jq \
    && rm -rf /var/lib/apt/lists/*

COPY collect /app/collect
COPY deploy /app/deploy
COPY site /app/site

# File modes belong to the image, not the build context: checkouts and
# daemons that strip modes must still yield a runnable, readable tree.
# Directories 0755, regular files 0644, scripts 0755, all root-owned and
# never writable by the runtime user.
RUN find /app -type d -exec chmod 0755 {} + \
    && find /app -type f -exec chmod 0644 {} + \
    && find /app/collect /app/deploy -name '*.sh' -exec chmod 0755 {} + \
    && chown -R root:root /app

# Non-root runtime user. /cache is owned by it so a fresh named volume
# mounted there inherits the ownership; HOME comes from the passwd entry
# (Docker sets it for USER), so no ENV is needed for any of this.
RUN groupadd -g 1000 collector \
    && useradd -m -u 1000 -g 1000 -d /home/collector -s /bin/bash collector \
    && mkdir -p /cache \
    && chown collector:collector /cache /home/collector
USER collector

WORKDIR /app

CMD ["/app/deploy/loop.sh"]
