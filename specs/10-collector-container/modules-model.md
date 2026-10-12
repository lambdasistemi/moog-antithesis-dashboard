# Modules
- image build: owns `nix/image.nix` and the CI job; application source includes only `collect`, `deploy`, `site`, with runtime dependencies pinned by `flake.lock`.
- publish gate: lives in `deploy/publish.sh`; reads mounted secret files; owns the refusal.
- runtime loop: the container entrypoint; calls `deploy/cycle.sh`; owns sleep and lock.
- nix checks: `nix/checks.nix`; one check per concern, `image-clean` new.
