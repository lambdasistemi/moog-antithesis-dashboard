# Plan
Slices, each bisect-safe and each leaving `nix flake check --no-eval-cache` green:
1. image-and-ci: Dockerfile, CI job building and pushing the image, `image-clean` check.
2. https-publish-and-gate: HTTPS publish with credential helper; extended publish gate with empty-line control.
3. loop-runtime: container entrypoint loop, named cache volume, delete `systemd/` and `systemd-check`, update README and `docs/`.
Constraints: `ssh`, `SSH_AUTH_SOCK` and `git@github.com` vanish from the repository by the end of slice 3. The moog read environment is a mounted file, never baked in.
