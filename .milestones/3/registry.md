# Cross-boundary contracts

- Reporter → GitHub issue payload → collector: producer agent/oracle hosts; consumer collector; JSON schema and timestamps must match. Enforced: NONE verified by the desk; epic owner to map preserved child gates at PR17 and PR18.
- Freshness monitor → collector: one source outage marks only its own section stale, retains last good value and last-success time. Enforced: NONE verified by the desk; recover PR18/PR19 evidence.
- Collector → published dashboard: schemas and detail/filter/preview behavior preserved; private credentials and authenticated report URLs excluded. Enforced: existing publish/secrets gates observed in hosted check names; full contract coverage not yet established.
- CI image → host runtime: image provenance, runtime dependencies, mounted-file secrets and supported startup agree. Enforced: collector-image hosted check observed at PR15 head; deployed-image evidence not established.

NONE is an evidence gap, not a statement that no candidate check exists. The epic owner must supply the check and immutable evidence before acceptance.
