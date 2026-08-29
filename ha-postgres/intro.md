
<br>

### Welcome!

PostgreSQL is the workhorse of the web, but running it highly available is where most
setups quietly fall short. This lab walks you through doing it properly with
**[OpenEverest](https://openeverest.io/)** — an open-source platform for automated
database provisioning and management, which runs on any Kubernetes cluster, in the cloud
or on-premises.

You will use OpenEverest **v2** together with the `provider-percona-postgresql` provider.
The provider manages Postgres by driving [Percona's own Kubernetes
operator](https://github.com/percona/percona-postgresql-operator) underneath — so the HA
logic you will see here (leader election, timeline promotion, replica rejoin) is the same
battle-tested Patroni-based mechanism Percona ships in production, not something
OpenEverest reimplemented itself. OpenEverest's job is orchestration: turning a single
`Instance` spec into a correctly-configured, correctly-sized cluster.

<br>

### What you'll do

1. **Install OpenEverest** — the v2 core and the PostgreSQL provider, both via Helm.
2. **Provision HA PostgreSQL** — one `Instance` manifest becomes a 3-node Postgres
   cluster fronted by a 2-node PgBouncer proxy tier.
3. **Verify cluster health** — confirm one primary and two streaming replicas, straight
   from Patroni.

<br>

> This scenario follows the walkthrough in
> [**High Availability PostgreSQL: From Zero to Cluster**](https://openeverest.io/blog/ha-postgresql-openeverest/)
> on the OpenEverest blog, adapted to run on a two-node Killercoda cluster.

> <strong>Note</strong>: a background script is preparing your cluster right now (Helm,
> the chart repository and a container image pre-pull). Its logs are at
> `/var/log/killercoda`. Step 1 waits for it to finish, so you can read ahead safely.

> <strong>Heads up</strong>: OpenEverest v2 and `provider-percona-postgresql` are
> **pre-alpha**. CRD schemas and chart values change frequently. This lab pins exact
> versions so it keeps working.

**HAVE FUN**
