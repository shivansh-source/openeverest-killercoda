
This is the whole definition for a 3-node HA Postgres cluster. Write it to a file:

```
cat > pg-ha-demo.yaml <<'EOF'
apiVersion: core.openeverest.io/v1alpha1
kind: Instance
metadata:
  name: pg-ha-demo
spec:
  providerRef:
    name: provider-percona-postgresql
  topology:
    type: cluster
  components:
    engine:
      type: postgresql
      replicas: 3
      resources:
        requests: { cpu: "250m", memory: 512Mi }
      storage:
        size: 1Gi
    proxy:
      type: pgbouncer
      replicas: 2
EOF
```{{exec}}

> Volumes can only be as big as there is disk space on the nodes, so this lab asks for
> `1Gi` per engine instead of the `5Gi` used in the blog post. Everything else is
> unchanged.

<br>

### What the fields mean

The only settings actually tuned here are replica count and storage size —
`engine.replicas: 3` and `engine.storage.size` are the two knobs that matter for an HA
layout. The provider's `cluster` topology defaults to exactly this shape: one primary, two
replicas, fronted by a two-node PgBouncer proxy tier — a connection-pooling layer clients
connect to instead of the Postgres pods directly, so pod churn during a failover doesn't
require any client-side reconnect logic.

`spec.version` is omitted, so the provider's default version bundle (`18.4-1`) applies.
For a heavier workload you would raise the resource requests; for this lab, minimal is
plenty.

<br>

### Apply it

```
kubectl apply -f pg-ha-demo.yaml -n everest-system
```{{exec}}

The provider translates this into a `PerconaPGCluster`, and the operator brings up five
pods — three Postgres engines, two PgBouncer proxies. That takes a few minutes, mostly
image pulls:

```
kubectl wait --for=jsonpath='{.status.phase}'=Ready \
    instance/pg-ha-demo -n everest-system --timeout=900s
```{{exec}}

> While you wait, watch the pods appear in a second terminal, or run
> `kubectl get pods -n everest-system -w`{{exec}} and press <kbd>Ctrl+C</kbd> when five
> `pg-ha-demo-*` pods are `Running`.

<br>

### Check what you got

```
kubectl get instances -n everest-system
kubectl get pods -n everest-system -l postgres-operator.crunchydata.com/cluster=pg-ha-demo
```{{exec}}

```text
NAME         PROVIDER                      VERSION   PHASE   AGE
pg-ha-demo   provider-percona-postgresql   18.4-1    Ready   9m32s

NAME                                    READY   STATUS    RESTARTS   AGE
pg-ha-demo-instance1-64vj-0             2/2     Running   0          9m30s
pg-ha-demo-instance1-6fm6-0             2/2     Running   0          9m30s
pg-ha-demo-instance1-ppqh-0             2/2     Running   0          9m30s
pg-ha-demo-pgbouncer-569ddb6844-8ghd9   2/2     Running   0          9m30s
pg-ha-demo-pgbouncer-569ddb6844-jnfdl   2/2     Running   0          9m30s
```

<br>

### Credentials

Credentials are minted automatically by the operator and land in a Kubernetes Secret — no
manual wiring, and a ready-to-use connection URI comes included. The Instance tells you
which secret:

```
kubectl get instance pg-ha-demo -n everest-system -o jsonpath='{.status.connectionSecretRef}'; echo
```{{exec}}

```
for k in host port dbname username password uri; do
  printf '%-9s: %s\n' "$k" "$(kubectl get secret pg-ha-demo-conn -n everest-system -o jsonpath="{.data.$k}" | base64 -d)"
done
```{{exec}}

```text
host     : pg-ha-demo-pgbouncer.everest-system.svc
port     : 5432
dbname   : pg-ha-demo
username : pg-ha-demo
password : <generated>
uri      : postgresql://pg-ha-demo:<generated>@pg-ha-demo-pgbouncer.everest-system.svc:5432/pg-ha-demo?sslmode=require
```

<br>

Once all five pods are `Running` and the Instance reports `Ready`, press **Check** to
verify this step.

> Stuck in `Provisioning`? Look at the conditions with
> `kubectl describe instance pg-ha-demo -n everest-system`{{exec}}, then the provider logs
> with `kubectl logs -n everest-system deploy/provider-percona-postgresql`{{exec}}.
