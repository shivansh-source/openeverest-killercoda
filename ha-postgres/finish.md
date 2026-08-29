
<br>

### WELL DONE!

You went from an empty Kubernetes cluster to a highly-available PostgreSQL cluster in
three steps:

- **Installed OpenEverest v2** — the core, plus `provider-percona-postgresql`, both via
  Helm. The provider brought the Percona Operator for PostgreSQL along with it.
- **Provisioned HA PostgreSQL** — a single `Instance` manifest became three Postgres
  engines and a two-node PgBouncer proxy tier, with credentials minted automatically into
  a Kubernetes Secret.
- **Verified it is genuinely HA** — one primary and two replicas, confirmed through
  Patroni and a real write-and-read-back round trip, not just "pods are Running".

The thing worth taking away: OpenEverest's job here is **orchestration**. The HA logic —
leader election, timeline promotion, replica rejoin — is the same battle-tested
Patroni-based mechanism Percona ships in production. OpenEverest turned a small
declarative `Instance` spec into that cluster, correctly configured and correctly sized,
without you touching a single operator-specific CRD.

<br>

### Try next: break it on purpose

This lab stopped at a healthy cluster. The blog post this scenario is based on goes one
step further and kills the primary to time the failover — twice, because the first attempt
turned out not to test what it looked like it was testing. Both runs promoted a new leader
with zero data loss:

```
kubectl delete pod $PRIMARY -n everest-system --grace-period=0 --force
```

Then watch the timeline advance:

```
NEW_PRIMARY=$(kubectl get pods -n everest-system \
    -l "postgres-operator.crunchydata.com/cluster=pg-ha-demo,postgres-operator.crunchydata.com/role in (primary,master)" \
    -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n everest-system $NEW_PRIMARY -c database -- patronictl history
```

Read the full write-up for why a plain pod delete isn't a real failover test, and what to
do instead:

<br>

### Where to go from here

- 📝 [**High Availability PostgreSQL: From Zero to Cluster**](https://openeverest.io/blog/ha-postgresql-openeverest/)
  — the blog post this scenario is based on, including the failover chaos tests
- 🏔️ [**OpenEverest**](https://openeverest.io/) — project home
- 📚 [**Documentation**](https://openeverest.io/documentation/current/) — install guides and reference
- 💻 [**github.com/openeverest/openeverest**](https://github.com/openeverest/openeverest) — the core project
- 🐘 [**provider-percona-postgresql**](https://github.com/openeverest/provider-percona-postgresql) — the PostgreSQL provider used here
- 🧩 [**OpenEverest Hub**](https://github.com/openeverest/hub) — the community catalog of installable providers and plugins

<br>

> OpenEverest isn't tied to Percona. It is built to be provider-agnostic, and CloudNativePG
> is already available as a community-contributed provider alongside Percona's.
> `provider-percona-postgresql` is just the one this lab happened to use.

Contributions welcome — OpenEverest is an independent open source project with open
governance and a growing, multi-vendor community.
