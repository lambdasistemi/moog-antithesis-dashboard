# Sample snapshot for PR previews

This is a frozen, sanitized sample of a real collection (two runs with
their detail files), served by pull-request previews so the dashboard UI
can be clicked through before merge. It is stale by design: the staleness
banner on a preview is expected.

Regenerate only from published data that already passed the secrets gate:

```sh
jq '{generated_at, started_at, refresh_seconds, tenant, repository, sources,
      chain, token, hosts, proxy, monitor, nightly, nightly_stages,
      runs: [.runs[] | select(.run_id == "fe222c247145a3186799298d5bd9a08b-62-14"
        or .run_id == "198bfff10e31159dfa8e967431d5ec5b-62-14")]}' \
  "$CACHE/out/data.json" > preview-sample/data.json
cp "$CACHE/out"/runs/{fe222c247145a3186799298d5bd9a08b-62-14,198bfff10e31159dfa8e967431d5ec5b-62-14}.json \
  preview-sample/runs/
```
