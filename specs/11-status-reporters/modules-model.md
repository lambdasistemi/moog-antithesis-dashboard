# Modules
- reporter: `reporter/report.sh` plus `nix/reporter-image.nix` and `reporter/compose.yaml`; depends on the Docker socket and the GitHub API only.
- status reader: functions in `collect/collect.sh` (sources `oracle`, `agent`); depends on the reporter's payload contract only.
- page: `site/index.html` marks the hosts section stale from `sources`.
