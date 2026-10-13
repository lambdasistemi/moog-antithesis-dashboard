# Delivery plan

## Reporter and transport

Reuse the reporter image, minute loop and successful-publication comparison contract. Add one MPFS observation command with strict identity and public payload limits. Install one reporter beside each existing service without altering MPFS. Assign a separate status issue to each instance to avoid competing writers and preserve independent freshness.

## Collection and view

Add two independently validated cached sources. Display MPFS observations in a separate section with links to their GitHub feeds and clear synchronization reference. Extend the published OpenAPI contract in the same delivery.

## Verification

Execute reporter cadence/retry and bounded-payload controls, actual collector stale/recovery and schema rejection controls, rendered view assertions, existing Nix checks and hosted CI. Verify exact merged image, real issue observations and public dashboard after deployment.

## Investigation

Legacy v1.3.0 revision fb8786967e7e7e21d46a7ca0ba90789dd5903f65 documents indexerStatus on GET /tokens. indexer/indexer.ts assigns response.result.slot to networkTip and response.result.block.slot to indexerTip; signingless/http.ts calls tips before returning tokens. OpenAPI's block-height wording contradicts the implementation. Publish slot lag explicitly against the backend network tip, not seconds or independently verified chain synchronization.
