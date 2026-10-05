# moog-antithesis-dashboard

Live status page for the moog → Antithesis test pipeline of
`cardano-foundation/cardano-node-antithesis`.

https://lambdasistemi.github.io/moog-antithesis-dashboard/

## How it works

A user systemd timer runs `deploy/cycle.sh` every 10 minutes:

1. `collect/collect.sh` fetches seven independent sources into one `data.json`:
   - Antithesis runs and their properties (Antithesis read API)
   - on-chain test-run facts and pending requests (`moog facts`, `moog token`)
   - oracle and agent containers, agent error and publication counts (ssh)
   - Antithesis proxy readiness
   - the run freshness monitor's last verdict (journal)
   - nightly Amaru integration runs and their receipts (GitHub Actions)
2. `deploy/publish.sh` runs a secrets gate and force-pushes `site/` plus
   `data.json` as a single orphan commit to `gh-pages`.

The page re-reads `data.json` every minute and warns when the snapshot is
older than 25 minutes.

## Caching

- A source that fails keeps its last good value, marked `stale` on the page.
- Properties of completed Antithesis runs and receipts of concluded nightly
  runs never change, so they are fetched once and kept in
  `~/.cache/moog-antithesis-dashboard`.

## What never leaves the host

- Antithesis report links (they carry access tokens) are dropped.
- Agent logs embed credentials; only counts computed on the agent host leave it.
- The publish step refuses to push anything matching an authenticated link,
  a bearer header, a basic-auth argument, or the Antithesis key itself.

## Install

```sh
git clone git@github.com:lambdasistemi/moog-antithesis-dashboard.git /code/moog-antithesis-dashboard
ln -s /code/moog-antithesis-dashboard/systemd/moog-antithesis-dashboard.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now moog-antithesis-dashboard.timer
```

Requirements on the host: `jq`, `curl`, `gh` (authenticated), ssh access to
the `oracle` and `agent` hosts, the moog checkout at `/code/moog`, and the
Antithesis key at `~/.secrets/antithesis-api-key`. Paths are overridable via
the environment variables at the top of each script.
