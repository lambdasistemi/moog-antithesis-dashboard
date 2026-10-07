# Modules
- image build: owns the Dockerfile and the CI job; depends only on `collect`, `deploy`, `site`.
- publish gate: lives in `deploy/publish.sh`; reads mounted secret files; owns the refusal.
- runtime loop: the container entrypoint; calls `deploy/cycle.sh`; owns sleep and lock.
- nix checks: `nix/checks.nix`; one check per concern, `image-clean` new.
