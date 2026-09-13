# archive

Nothing in here is part of deploying the RAN. It is kept because it was written
against this stack and some of it is the only recipe for something the deploy
path still depends on — not because it is expected to run as-is. Paths inside
these files point at the repo as it was; treat them as reference.

## Superseded by the current deploy path

| | |
|---|---|
| `charts/aerial-du/` | The Helm chart for the older shape: one pod, one monolithic gNB, no CU. Replaced by `deploy/*.yaml` + `scripts/6-deploy.sh`, which deploy the CU/DU split. |
| `scripts/34-deploy-du.sh` | The Helm deploy for that chart. Also reads `rendered/gnb.conf`, which the renderer no longer produces — it renders `gnb-du.conf` and `gnb-cu.conf` now. |

## Build, not deploy

| | |
|---|---|
| `scripts/31-build-stack.sh` | Compiles cuBB with the `10_02` FAPI preset and builds the OAI L2 image. The deploy path pulls images instead — but **this is still the only recipe for the two OAI images**, which exist in no registry. Read it before you need to rebuild them, and mind that the FAPI preset is not a detail: `docs/TROUBLESHOOTING.md` §1 is what the wrong one looks like. |
| `scripts/22-build-dapp.sh` | Builds and runs NVIDIA's PRB-Power reference dApp over E3. An application on top of the RAN, not part of bringing the RAN up. |

## Reading an existing deployment

These predate the repo being able to build a site from scratch: they exist to
get facts *out* of a box someone else set up. Read-only, and their output is
redacted because it describes a network.

| | |
|---|---|
| `scripts/10-inventory-server.sh` | Capture everything about an already-deployed server. |
| `scripts/11-share-digest.sh` | Paste-sized, secret-redacted digest of such a capture. |
| `scripts/12-ran-recipe.sh` | The exact launch recipe a running stack is using. |
| `scripts/30-harvest-params.sh` | Read site *parameters* out of an old deployment into a `site.yaml`. Its output schema is one generation behind: it does not know about the `split:` block the CU/DU renderer needs. |
| `scripts/lib-redact.sh` | The redaction filter `11` and `12` share. |
