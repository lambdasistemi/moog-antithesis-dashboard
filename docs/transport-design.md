# Collector container, push transport, secret safety — design (revision 2)

Revision 2: no systemd anywhere in the design; the freshness monitor pushes its own verdict like the hosts.

Slice 1 (oracle) implemented: the oracle reporter (`reporter/report.sh` +
`reporter/loop.sh`, `Dockerfile.reporter`, `reporter/compose.yaml`) follows
design A below; the collector reads the oracle issue with the strict schema
Slice 2 (agent) implemented as well: `reporter/report.sh` accepts
`REPORTER_ROLE=agent`, counting `errors_6h` and `published_24h` from the
first `moog-agent` container through
`GET /containers/<id>/logs?stdout=1&stderr=1&since=<epoch>` (the 8-byte
multiplexed frames are demultiplexed in memory; only the two integers
leave the host). The collector validates both roles with one shared schema
and assembles `data.json.hosts` from both last-good values.

## Findings in the current code that shape the design

1. `src_monitor` reads the host journal (`journalctl -u antithesis-run-freshness-monitor`). A container cannot see it, and mounting `/var/log/journal` would hand the collector every host log (which embed credentials). It breaks silently in a container, so the monitor pushes instead (section 5).
2. `moog_env` sources `$MOOG_DIR/tmp/prod-setup.sh`, which defines `being_oracle`, `being_agent`, `being_requester` pointing at **wallet files**. The collector only runs read queries (`facts test-runs`, `token`), so it must not be handed wallet material at all.
3. `publish.sh` pushes over `git@github.com:` (SSH) and the unit exports `SSH_AUTH_SOCK`. Both go, and the systemd unit and timer with them.
4. The publish gate matches the key literal via `grep -F -f keyfile`. An empty line in a pattern file matches everything, and only that one file is scanned. Extending to more secrets needs a non-empty-line filter and a control that proves it fires.

## Decisions

### 1. Image
- `Dockerfile`: pinned base with bash, jq, curl, gh, git, coreutils. `COPY collect deploy site` only. No `ARG`/`ENV` for any credential; no `.git`, no `~/.secrets`, no moog checkout.
- CI job `image`: build, push to GHCR on merge to `main` (tag = commit SHA and `main`), package **public** so hosts pull without a credential. The workflow uses only `GITHUB_TOKEN` with `packages: write`; nothing else reaches the build.
- The systemd units and timer are deleted from the repo (swap rule: the replacement removes the old path in the same diff).

### 2. Runtime on development-epyc
No systemd. One always-on collector container, restart policy `unless-stopped`, looping `cycle.sh` then `sleep 600`; the existing `flock` still prevents overlap. It is the only always-on piece on the collector side. A named volume `dashboard-cache` holds `last/`, `props/`, `details/`, `nightly/`. If that volume is lost, every source loses its last good value and shows `error` rather than `stale`; documented.

### 3. Secrets, at rest and in transit

| secret | at rest (collector host) | transit into container | consumed by |
|---|---|---|---|
| Antithesis read key | user-only file (0400) | read-only file mount at `/run/secrets/antithesis-key` | `curl -K -` stdin config, one process, one pipe |
| GitHub read token (Actions artifacts, run list, reading status issues) | file, fine-grained PAT, public repos only, no scopes | file mount `/run/secrets/gh-read` | `gh`, `GH_TOKEN` set inside the single call from the file, never in the image or `docker run -e` |
| Pages push token | file, fine-grained PAT, Contents:write on this repo only | file mount `/run/secrets/pages-push` | `publish.sh` via git credential helper reading the file; HTTPS, no SSH |
| moog read environment | file with provider URL and read-only settings **only**, no wallet paths | read-only mount of the moog binary directory plus that one env file | `moog facts`, `moog token` |
| status tokens (3, below) | only on the oracle, agent and monitor hosts; never in the collector | — | that host's reporter |

Rules: no `-e SECRET=…`, no `ARG`, no `--env-file`; secrets are files. Dry-run `docker run … env` must be clean.

### 4. Status transport — two designs that meet the constraints

**Design A (recommended): each reporter edits its own GitHub issue.**
- Three reporters: oracle, agent, freshness monitor. Each host runs one reporter container (`restart: unless-stopped`, read-only filesystem, no inbound port) looping every 5 minutes over a ~20-line script. Oracle and agent: `docker ps` filtered to `moog`; on the agent, `docker logs --since` counts; output is today's JSON (`oracle`, `agent`, `agent_errors_6h`, `agent_published_24h`) plus `reported_at`. It `PATCH`es the body of issue "status: oracle" / "status: agent" on this repository over HTTPS. The Docker socket is mounted directly.
- Credential: one fine-grained PAT **per reporter** (three), repository = this repo only, permission = Issues: write, nothing else. It cannot touch code or `gh-pages`. Created by the repository owner at github.com → Settings → Developer settings; the owner rotates; maximum lifetime one year. While expired: that reporter's section goes stale (section 6), nothing else breaks.
- Slice 1 shipped the oracle reporter; slice 2 adds the agent role with the
  log counts above. `REPORT_DRY_RUN=1` prints the payload with no token and
  no outward request, and `DASHBOARD_DRY_RUN=1` does the same for the
  publish step.
- The collector reads the issues over the API with the read token and validates each body with a strict `jq` schema (known keys, types, string length caps, `reported_at` not in the future) before using any of it. Anything written into an issue outside that shape is dropped.
- Direction of bytes: reporter → api.github.com → collector. No inbound port anywhere.
- Limits, named: the reporter container has root-equivalent access to its host's Docker (mitigation: the token can only edit one issue; the container is a tiny script with a read-only filesystem and no inbound port). Any two Issues-write tokens can overwrite each other's issue (the scope cannot be narrowed to one issue). Anyone with issue-edit rights can edit a body (mitigated by schema validation and the publish gate). Issue edit history keeps old payloads (public data already).
- New moving parts: 3 reporters, 3 tokens, 3 issues. No listening service.

**Design B: collector-side HTTPS receiver.**
- A small always-on service behind the existing reverse proxy accepts `POST /status/<name>` with a per-reporter HMAC and writes files the collector reads.
- Pros: no GitHub dependency for status, tighter per-reporter authentication. Cons: a new always-on public endpoint to supervise and patch, three HMAC secrets plus TLS and routing. More parts, same outcome.

Rejected: git branch pushes (token can write `gh-pages`); gists (classic PAT with account-wide gist scope, no fine-grained option); on-chain facts (barred); pulls of any kind (barred).

Recommendation: **A**, because it has no listening service and the smallest token blast radius. B wins only if GitHub as a dependency for status is unacceptable.

### 5. The monitor source
The freshness monitor pushes its own verdict. A push step in the monitor's script (one `curl`, URLs stripped from the verdict line, token read from a file) edits the "status: monitor" issue with `{verdict, reported_at}`. The collector validates it with the same schema check and staleness window. No journal access, no file mount, no systemd hook. The monitor's script is outside this repo and receives this one change.

### 6. Staleness contract
- Source split: `hosts` becomes `oracle` and `agent`, each its own `run_source` with its own `last/*.json` and `last/*.at`; `monitor` is read from its issue. `data.json.hosts` keeps today's shape, assembled from each side's last good value. The page's source chips are generated from `sources`, so the only page change is two more chips; `site/index.html` lines 113 and 165 need confirming.
- A reporter is `ok` only if its issue parses, matches the schema and `reported_at` is within 15 minutes (three missed pushes). `last_success` = the payload's `reported_at`, not the fetch time, so an unchanged old payload cannot look fresh.
- Per source, when a piece stops:
- Both status sources are implemented (`oracle`/`agent` in `sources` instead
  of `hosts`; `last_success` is the payload's `reported_at`; the page marks
  a hosts card stale with that time).

| stops | result |
|---|---|
| a reporter or its token | that source `stale`, `last_success` = last `reported_at`; recovers on the next push |
| GitHub API unreachable | oracle, agent, monitor `stale`; other sources unaffected |
| collector container | snapshot ages; existing 25-minute banner |
| cache volume lost | sources show `error` until first success |
| Antithesis key expired | `runs` stale; others unaffected |
| Pages push token expired | publish fails, snapshot ages, banner fires |

### 7. Leak surface and the control for each

| place | key | tokens (gh, push, status) | moog env |
|---|---|---|---|
| rest | file mode 0400, not in repo | same | read-only env file only |
| transit | stdin pipe to curl | file mounts, credential helper | read-only mount |
| build log / layer | no build arg; check exports the filesystem and greps | same | not copied |
| image env | dry-run `env` compared to empty | same | same |
| published file | gate matches the literal of every secret file plus patterns | same | gate scans the value of every exported variable from the env file |
| process list | check runs the fetch with a sniffer on `/proc/*/cmdline` | same (`reporter-smoke` asserts the token is absent from `docker top` and logs; the token travels via curl stdin config) | n/a |
| error message | check forces curl/gh failure and greps stderr and `data.json` `error` fields | same | same |

## Verification (each a Nix check of the existing shape, each shown red first)
1. `publish-gate`: plant each secret literal in `data.json`, a run detail file and a status payload; every plant refuses. Includes the empty-line control.
2. `image-clean`: `docker export` of the built image, grep for every planted-at-build canary and the token patterns; `docker run --rm image env` has no credential-shaped variable. Control: build once with a canary `ENV` and watch it fail.
3. `host-stale`: feed the collector a fixture issue body, stop updating it, assert `stale` plus the right `last_success`; update again, assert `ok` with no manual step.
4. `schema-reject`: a body with extra keys, wrong types or a future `reported_at` is refused.
5. Each is accompanied by a recorded break → red → restore → green run in the PR.

## Open questions for the operator
- Can the monitor's script be changed to add the push step? (Assumed yes.)
- Is a read-only moog environment (no wallet paths) acceptable to create, and who holds it?
- Is a public GHCR package acceptable? (It is the reason no pull credential exists.)
