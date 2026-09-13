# config/ — the configuration datastore

Everything that identifies *this* deployment lives here, and nothing here is
tracked by git except this file and `site.example.yaml`. The rest of the repo is
generic: given the same `site.yaml`, two different servers render byte-identical
configs.

```
config/
├── site.example.yaml   TRACKED. The schema, commented. Copy it to site.yaml.
├── site.yaml           Your values: the RU, the cell, the fronthaul, the core.
├── versions.env        Optional. Overrides any pin from ../versions.env.
├── rendered/           Written by 4-render.sh — do not hand-edit.
│   ├── cuphycontroller_site.yaml     L1
│   ├── l2_adapter_config_site.yaml   L1 <-> L2 adapter
│   ├── gnb-du.conf                   DU-High
│   ├── gnb-cu.conf                   CU
│   └── manifests/      ConfigMaps, also written by 4-render.sh
│       ├── l1-config.yaml  oai-du-conf.yaml  oai-cu-conf.yaml
│       └── applied/    What 6-deploy.sh actually sent to the cluster
└── ue-capture-*/       Written by watch-ue.sh
```

## Two rules

**`site.yaml` is the only file you edit.** Everything under `rendered/` is
derived from it and is overwritten on the next render. Hand-editing a rendered
config produces a cluster whose behaviour no longer follows from any input —
which is exactly the state this repo exists to avoid.

**Nothing here is safe to publish.** It carries the fronthaul MAC and VLAN, PCIe
addresses, cell identity, management IPs, and whatever a UE capture recorded
about the network. `scripts/guardrails.sh` installs a pre-commit hook
that refuses to commit those shapes; that hook is a backstop, not permission to
be careless.

## Getting started

```bash
cp config/site.example.yaml config/site.yaml && $EDITOR config/site.yaml
```

The values in `site.example.yaml` are placeholders, not a working deployment.
The ones that will not work by accident, and that no default can guess:

- `ru.mac`, `ru.vlan`, `fronthaul.nic_pcie` — read off the RU and the host
- `ru.eaxc.*` — read off the **RU**, not from another deployment's config. A
  PRACH mismatch does not announce itself; see `docs/TROUBLESHOOTING.md` §7.
- `core.amf_ip`, `core.gnb_n2_ip` — the core is external to this repo
- `cpu.*` — absolute core ids, inside the kernel's `isolcpus` range
