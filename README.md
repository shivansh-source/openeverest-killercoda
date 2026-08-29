# OpenEverest on Killercoda

An interactive, browser-based lab that walks through installing
[OpenEverest](https://openeverest.io/) and provisioning a highly-available PostgreSQL
cluster on Kubernetes — no local install, no cloud account, nothing to clean up
afterwards.

The scenario mirrors the OpenEverest blog post
[**High Availability PostgreSQL: From Zero to Cluster**](https://openeverest.io/blog/ha-postgresql-openeverest/),
reusing its commands and manifests so the lab and the post stay in step.

> **Why Killercoda:** scenarios are plain Markdown, JSON and shell files in a Git repo.
> A push triggers a webhook and the live scenario updates — there is no build step, no
> image to publish and no infrastructure to run. Maintenance is editing files in this
> repo.

## The scenario

**`ha-postgres/`** — *Deploy OpenEverest & Provision HA PostgreSQL*

| Step | What the user does | Verified? |
|------|--------------------|-----------|
| Intro | Reads while `setup.sh` prepares the cluster in the background | — |
| 1. Install OpenEverest | Helm-installs the v2 core, then `provider-percona-postgresql` | — |
| 2. Provision HA PostgreSQL | Applies one `Instance` manifest → 3 Postgres engines + 2 PgBouncer proxies | ✅ `verify.sh` |
| 3. Verify cluster health | Confirms one primary and two streaming replicas via Patroni | — |
| Finish | Recap and links, including the failover chaos test from the post | — |

### Files

```
ha-postgres/
├── index.json    # scenario definition: steps, scripts, backend image
├── intro.md      # what OpenEverest is and what the lab covers
├── step1.md      # install the v2 core + PostgreSQL provider (Helm)
├── step2.md      # apply the Instance manifest
├── step3.md      # verify replication and roles
├── finish.md     # wrap-up and links
├── setup.sh      # background prep: waits for the cluster, installs Helm, pre-pulls images
└── verify.sh     # gates step 2 — checks real cluster state, exit 0/1
```

### Pinned versions

The lab pins every version so it keeps working as OpenEverest moves. Bump these together
when the blog post is refreshed.

| Component | Version | Where it's set |
|---|---|---|
| OpenEverest core (`openeverest` chart) | `2.0.0-dev.2` | `step1.md`, `setup.sh` |
| `provider-percona-postgresql` | `0.1.0` | `step1.md`, `setup.sh` |
| Percona Operator for PostgreSQL | `3.0.0` | bundled as a chart dependency of the provider |
| PostgreSQL | `18.4-1` | the provider's default version bundle |
| PgBouncer | `1.25.2-1` | the provider's default version bundle |
| Killercoda backend image | `kubernetes-kubeadm-2nodes` | `index.json` |

> OpenEverest v2 and this provider are **pre-alpha** — CRD schemas and chart values change
> frequently, including in breaking ways. Expect to re-test after a version bump.

## Testing it

### 1. Validate locally

Before pushing, check the things that break a scenario silently:

```bash
# index.json must be valid JSON
python3 -m json.tool ha-postgres/index.json > /dev/null && echo "index.json OK"

# every file index.json references must exist and be non-empty
python3 - <<'PY'
import json, os
d = json.load(open("ha-postgres/index.json"))
refs = []
det = d["details"]
for sec in ("intro", "finish"):
    refs += [v for k, v in det.get(sec, {}).items() if k in ("text", "background", "foreground")]
for s in det.get("steps", []):
    refs += [v for k, v in s.items() if k in ("text", "background", "foreground", "verify")]
for r in refs:
    p = os.path.join("ha-postgres", r)
    ok = os.path.isfile(p) and os.path.getsize(p) > 0
    print(("OK   " if ok else "MISS "), r)
PY

# shell scripts must be valid bash
bash -n ha-postgres/setup.sh && bash -n ha-postgres/verify.sh && echo "scripts OK"
```

`verify.sh` is also runnable directly against any cluster that has the lab deployed:

```bash
NS=everest-system INSTANCE=pg-ha-demo ./ha-postgres/verify.sh; echo "exit=$?"
```

It honours `NS`, `INSTANCE`, `MIN_REPLICAS` and `VERIFY_TIMEOUT`, so you can point it at a
kind or k3d cluster while iterating instead of waiting on a Killercoda session.

### 2. Run it on Killercoda

Killercoda serves scenarios straight from a GitHub repo, so testing means pointing your
creator profile at this repo and opening the scenario.

1. Sign in at **[killercoda.com/creators](https://killercoda.com/creators)** with GitHub.
2. Add this repository under **Creator → Repository**. A **deploy key** is required even
   for public repos (it avoids GitHub rate limiting) — the page gives you the key to add
   under *GitHub repo → Settings → Deploy keys*.
3. Set up the **webhook** so pushes republish automatically: copy the *Payload URL* and
   *Secret* from the same page into *GitHub repo → Settings → Webhooks*, and set
   **Content type** to `application/json`.
4. Your scenario appears under **Creator → Scenarios**, served at:

   ```
   https://killercoda.com/<your-profile>/scenario/ha-postgres
   ```

   The path segment is the directory name, so `ha-postgres/` becomes `.../ha-postgres`.

5. Push a change and reload — the webhook republishes it. There is no build step.

### 3. What to watch on a first real run

These are the things most likely to need adjusting, and where to look:

- **Pod capacity.** The lab asks for 3 engines (250m CPU / 512Mi each) plus 2 PgBouncer
  proxies, the operator, and the OpenEverest core. `setup.sh` logs per-node allocatable
  CPU/memory and any control-plane taints to `/var/log/killercoda` for exactly this
  reason. If engine pods sit `Pending`, that log says why.
- **Scheduling across 2 nodes.** Three engine replicas on a two-node cluster relies on the
  operator's pod anti-affinity being *preferred* rather than *required*. If a third engine
  stays `Pending` with an anti-affinity message, drop `engine.replicas` to 2 in `step2.md`
  and `setup.sh`, and set `MIN_REPLICAS=1` in `verify.sh`.
- **Timings.** Step 2 waits up to 900s for the Instance to go `Ready`. If image pulls make
  that tight, the pre-pull list in `setup.sh` is where to look first.
- **Storage.** A default StorageClass must exist or the PVCs never bind. Killercoda's
  kubeadm images ship local-path-provisioner; `setup.sh` waits for it and warns loudly if
  it is missing.

## Deviations from the blog post

The lab follows the post's commands as written, with two adaptations for the Killercoda
environment. Both are called out in the lab text where they apply:

1. **Storage `5Gi` → `1Gi` per engine.** Killercoda volumes are limited by node disk.
2. **Pod names are discovered, not hardcoded.** The post uses real pod names like
   `pg-ha-demo-instance1-ppqh-0`; those suffixes are random per cluster, so step 3 exports
   `$PRIMARY` and `$REPLICAS` from label selectors instead.

The post's failover chaos tests are referenced from `finish.md` rather than being a fourth
step, keeping the lab to the three steps it sets out to teach.

## Scope

This is a first proof-of-concept scenario, not full OpenEverest coverage. Additional
scenarios would live as sibling directories (`ha-mysql/`, `backup-restore/`, …), each with
its own `index.json`.

## Links

- [High Availability PostgreSQL: From Zero to Cluster](https://openeverest.io/blog/ha-postgresql-openeverest/) — the post this scenario mirrors
- [OpenEverest](https://openeverest.io/) · [Documentation](https://openeverest.io/documentation/current/) · [github.com/openeverest/openeverest](https://github.com/openeverest/openeverest)
- [provider-percona-postgresql](https://github.com/openeverest/provider-percona-postgresql)
- [Killercoda creator docs](https://killercoda.com/creators) · [scenario examples](https://github.com/killercoda/scenario-examples)
