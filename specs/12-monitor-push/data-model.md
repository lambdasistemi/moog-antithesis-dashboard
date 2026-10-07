# Data model
- Monitor payload (issue body): `role` literal `"monitor"`; `verdict` string, 1–200 characters, no `http://`/`https://`; `ok` boolean, must equal `verdict | startswith("OK")`; `reported_at` UTC ISO 8601, at most 2 minutes in the future, stale after 15 minutes. Unknown keys dropped.
- `data.json.monitor`: `{last, ok}` with `last` = the verdict string and `ok` the payload boolean — the existing page shape, unchanged. `sources.monitor.last_success` = the payload's `reported_at`.
- Published artifacts carrying the monitor payload: `data.json` (`.monitor`) and, if present, `status/*.json`. URLs stay legal elsewhere in `data.json` (`runs[].url`).
