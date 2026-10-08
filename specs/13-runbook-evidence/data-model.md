# Data model
- Reproduce record: per verification item, a line with the item name, the command, the observed exit (red break, green restore) and the file it came from; a final summary (items run, reds observed, greens observed); written to stdout and one artifact file; no secrets ever appear in it.
- Comparison report: per-field difference list between dry-run and live `data.json` after the ignore list is applied (generated_at, started_at, refresh_seconds, sources.* status/error/last_success, monitor, per-run volatile fields); a structural-mismatch flag for missing sections or type changes.
- Token inventory (runbook): for each of the six secrets — name, kind, where created, scope, who rotates, maximum lifetime, what breaks on expiry.
