
"Pods are Running" isn't proof of HA — so let's look at the actual replication state,
queried directly through Patroni, which the operator runs as the coordination layer.

### Who is the primary?

The operator labels every engine pod with its current role. Pod names carry a random
suffix, so discover them rather than typing them out:

```
kubectl get pods -n everest-system \
    -l postgres-operator.crunchydata.com/cluster=pg-ha-demo \
    -L postgres-operator.crunchydata.com/role
```{{exec}}

```text
NAME                           ROLE
pg-ha-demo-instance1-ppqh-0    primary
pg-ha-demo-instance1-64vj-0    replica
pg-ha-demo-instance1-6fm6-0    replica
```

One primary, two replicas — that is the HA layout you asked for.

> Those labels really do say `crunchydata.com`, not a Percona one — that's not a typo.
> Percona's PostgreSQL Operator v3.0.0, which the provider bundles, is itself built on top
> of CrunchyData's PGO, and hasn't renamed the CRD group or pod labels away from it. Worth
> knowing if you go looking for "percona" in your own cluster's labels and come up empty.

<br>

Save the pod names into shell variables so the rest of this step is copy-pasteable:

```
export NS=everest-system
export SEL=postgres-operator.crunchydata.com/cluster=pg-ha-demo
export PRIMARY=$(kubectl get pods -n $NS -l "$SEL,postgres-operator.crunchydata.com/role in (primary,master)" -o jsonpath='{.items[0].metadata.name}')
export REPLICAS=$(kubectl get pods -n $NS -l "$SEL,postgres-operator.crunchydata.com/role=replica" -o jsonpath='{.items[*].metadata.name}')
echo "primary : $PRIMARY"; echo "replicas: $REPLICAS"
```{{exec}}

<br>

### Replication state, from Postgres itself

Ask the primary who is streaming from it:

```
kubectl exec -n $NS $PRIMARY -c database -- \
    psql -U postgres -d postgres -c \
    "select application_name, state, sync_state, replay_lag from pg_stat_replication;"
```{{exec}}

```text
      application_name       |   state   | sync_state | replay_lag
-----------------------------+-----------+------------+------------
 pg-ha-demo-instance1-6fm6-0 | streaming | async      |
 pg-ha-demo-instance1-64vj-0 | streaming | async      |
```

Two rows, both `streaming` — the replicas are connected and caught up.

<br>

### Patroni's own cluster view

And Patroni's own view, zero lag across the board:

```
kubectl exec -n $NS $PRIMARY -c database -- patronictl list
```{{exec}}

```text
+ Cluster: pg-ha-demo-ha (7675637947551236217) ------+---------+-----------+----+-----------+
|            Member           |   Role  |   State   | TL | Lag in MB |
+-----------------------------+---------+-----------+----+-----------+
| pg-ha-demo-instance1-64vj-0 | Replica | streaming |  1 |         0 |
| pg-ha-demo-instance1-6fm6-0 | Replica | streaming |  1 |         0 |
| pg-ha-demo-instance1-ppqh-0 | Leader  | running   |  1 |           |
+-----------------------------+---------+-----------+----+-----------+
```

`TL` is the Patroni timeline. All three members share timeline `1`, meaning there has been
exactly one leader since the cluster came up — no failovers yet.

<br>

### Prove replication actually works

To be extra sure, write a row on the primary and read it back on both replicas
immediately — no delay, no manual sync:

```
kubectl exec -n $NS $PRIMARY -c database -- psql -U postgres -d postgres -c \
    "CREATE TABLE IF NOT EXISTS ha_demo_test (id serial primary key, note text);"

kubectl exec -n $NS $PRIMARY -c database -- psql -U postgres -d postgres -c \
    "INSERT INTO ha_demo_test (note) VALUES ('written on primary');"
```{{exec}}

Now read it back from each replica:

```
for r in $REPLICAS; do
  echo "--- $r ---"
  kubectl exec -n $NS $r -c database -- psql -U postgres -d postgres -c \
      "SELECT * FROM ha_demo_test;"
done
```{{exec}}

```text
 id |              note
----+---------------------------------
  1 | written on primary
```

The row is on both replicas. Writes on the primary reach the replicas immediately, with no
manual sync step.

<br>

> Worth stating plainly: replication here is **async** (`sync_state: async`, visible in the
> `pg_stat_replication` output above). Async replication can lose the most recently
> committed transaction if the primary dies before shipping it. If you need a stronger
> guarantee, that's a `synchronous_commit` / synchronous-replica question for the provider
> to answer.

That's the cluster verified: one primary, two streaming replicas, replication confirmed by
an actual round-trip. Press **Continue** to wrap up.
