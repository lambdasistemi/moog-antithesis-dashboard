# The freshness monitor pushes its verdict (#12)

## User story
As the operator, I observe the monitor's verdict on the page coming from a pushed issue, and stale with the correct time when the monitor stops pushing.

## Requirements
- monitor-pushes-one-curl: a push step `reporter/push-verdict.sh` reads one verdict line from stdin or from a file argument, strips every `http(s)://…` run from it, builds `{role: "monitor", verdict, ok, reported_at}` (ok = the stripped line starts with `OK`), and PATCHes the body of the configured status issue over HTTPS with the token read from a file, never argv. `REPORT_DRY_RUN=1` prints the payload and makes no outward request. An empty verdict line exits non-zero.
- collector-reads-monitor-issue: `src_monitor` reads `STATUS_ISSUE_MONITOR` through the shared validator, which gains a monitor branch: `verdict` a non-empty string of at most 200 characters containing no URL, `ok` a boolean equal to `verdict | startswith("OK")`, same `reported_at` rules, unknown keys dropped. The page shape `monitor: {last, ok}` is preserved (`last` = the verdict). No `journalctl` anywhere in `collect/`.
- monitor-stale-and-recovers: when pushes stop, the monitor source goes stale with `last_success` = the last payload's `reported_at` and `data.json.monitor` keeps the last good `{last, ok}`; it recovers on the next push.
- publish-gate-refuses-monitor-leaks: the publish gate refuses publication when the monitor payload as staged carries a URL or a mounted-secret literal; URLs elsewhere in `data.json` (the runs) stay allowed.
- docs-third-token: the README documents the third status token (fine-grained, Issues: write, this repo only; while expired the monitor chip goes stale and nothing else breaks) and the exact one-line hook the monitor's script calls; the interim-state section is removed.

## Rejection behavior
A monitor body with extra keys, wrong types, a URL in the verdict, an `ok` that disagrees with the verdict prefix, or a future `reported_at` is refused and the last good value is served, marked stale.

## Out of scope
The monitor's verdict logic and its script (outside this repo); page redesign; the operator runbook (#13).
