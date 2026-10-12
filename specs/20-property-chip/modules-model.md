# Modules model
- `collect/collect.sh`: `props_for` changes population and cache namespace; nothing else in the collector changes.
- `nix/checks.nix`: new `props-summary` fixture check (no docker); the reproduce matrix gains its row.
- `.github/workflows/ci.yml`: one new job for the check, mirroring the other light fixture checks.
Dependency direction: the check reads the collector's summary path through fixtures, never the reverse.
