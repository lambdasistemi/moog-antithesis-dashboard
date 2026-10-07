# Collector container image and loop runtime (#10)

## User story
As the operator, I start one container on the collector host with secrets mounted as files and observe a collect-and-publish cycle every 10 minutes that pushes `gh-pages` over HTTPS.

## Requirements
- image-contents-only-scripts: the image holds `collect`, `deploy` and `site`; nothing that can hold a secret.
- ci-publishes-public-image: every merge to `main` builds and pushes a public GHCR image tagged with the commit SHA and `main`, using only `GITHUB_TOKEN`.
- image-has-no-credential: the exported image filesystem and `docker run --rm <image> env` hold no key, token or bearer string.
- secrets-are-files: each secret is a read-only mounted file; none is in argv, an `ARG`, an `ENV` or `docker run -e`.
- publish-over-https: `publish.sh` pushes with a Contents-write token read from a mounted file through a credential helper; no SSH.
- publish-gate-covers-every-secret: the gate scans the literal of every mounted secret file and every exported value of the moog read environment, skips empty lines, and refuses on each plant.
- moog-env-has-no-wallet: the mounted moog environment names no wallet file.
- systemd-removed: `systemd/` and its checks are deleted in the same change; the cache sits on a named volume.
- design-documented: `docs/transport-design.md` is the secret inventory and the rejected alternatives.

## Rejection behavior
Any planted secret in `data.json`, a run detail file or a status payload makes `publish.sh` exit non-zero without pushing.

## Out of scope
Host status transport (#11, #12); page, detail view, filters, pagination.
