# Modules model
- `reporter/push-verdict.sh` (new): one-shot GitHub issue PATCH for one verdict line; same token-from-file / never-argv / bounded-curl discipline as `report/report.sh`; `report/report.sh` stays untouched.
- `collect/collect.sh`: `src_monitor` replaces the interim stub; `validate_status_payload` gains the monitor branch; `fetch_status` and the source loop are reused unchanged.
- `deploy/publish.sh`: the secrets gate gains a refusal scoped to the monitor payload (URL or mounted-secret literal); the existing whole-tree pattern and literal gates stay.
- `nix/checks.nix`: new `push-verdict-smoke` app; monitor legs inside `schema-reject` and `host-stale`; monitor leak cases inside `publish-gate`; render test unchanged (the page contract does not change).
Dependency direction: checks depend on reporter and collector behavior, never the reverse.
