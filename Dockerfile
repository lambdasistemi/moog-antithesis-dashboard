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

WORKDIR /app
