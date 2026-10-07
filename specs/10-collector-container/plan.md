# Plan
Slices, each bisect-safe and each leaving `nix flake check --no-eval-cache` green:
1. image-and-ci: Dockerfile, CI job building and pushing the image, `image-clean` check.
2. https-publish-and-gate: HTTPS publish with credential helper; extended publish gate with empty-line control.
3. loop-runtime: container entrypoint loop, named cache volume, delete `systemd/` and `systemd-check`, update README and `docs/`.
Constraints: the SSH publish path, the systemd unit and `SSH_AUTH_SOCK` are gone by the end of slice 3. `collect.sh` keeps its `ssh` pulls until #11 and the journal read until #12; in the container those two sources show `error` until then, and the README says so. The moog read environment is a mounted file, never baked in.
