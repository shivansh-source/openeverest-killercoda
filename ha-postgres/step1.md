
The environment prepared Helm, the OpenEverest chart repository and a container image
pre-pull in the background. Wait for it to finish before you start:

```
while [ ! -f /tmp/openeverest-setup-done ]; do echo "waiting for setup..."; sleep 3; done; echo "READY"
```{{exec}}

<br>

### Install the OpenEverest v2 core

Installing the OpenEverest v2 core is a single Helm install:

```
helm repo add openeverest https://openeverest.github.io/helm-charts/
helm repo update
```{{exec}}

```
helm install everest-core openeverest/openeverest \
    --devel --version "2.0.0-dev.2" \
    --namespace everest-system --create-namespace
```{{exec}}

> The `--devel` flag is required because `2.0.0-dev.2` is a pre-release version — Helm
> ignores pre-releases unless you ask for them.

<br>

Wait for the core to become available (this pulls images, give it a minute):

```
kubectl wait --for=condition=Available --timeout=300s \
    deployment --all -n everest-system
```{{exec}}

Three pods this time (`dev.2` adds a plugin hub alongside the controller and server):

```
kubectl get pods -n everest-system
```{{exec}}

```text
NAME                                       READY   STATUS    RESTARTS   AGE
everest-controller-77c7b89cd8-rqlts        1/1     Running   0          4m31s
everest-core-plugin-hub-6b5dbb49c4-bcgdc   1/1     Running   0          4m31s
everest-server-748d76868f-fqkpm            1/1     Running   0          4m31s
```

<br>

### Install the PostgreSQL provider

OpenEverest itself is technology-agnostic. A **provider** teaches it about one specific
database — its topologies, versions and parameters. Installing the provider also brings in
the Percona Operator for PostgreSQL, which it bundles as a chart dependency.

The provider installs the same way, as a tagged OCI artifact:

```
helm install provider-percona-postgresql \
    oci://ghcr.io/openeverest/charts/provider-percona-postgresql \
    --version 0.1.0 -n everest-system
```{{exec}}

Wait for both the provider and the operator it bundles:

```
kubectl rollout status -n everest-system deployment/provider-percona-postgresql --timeout=300s
kubectl rollout status -n everest-system deployment/provider-percona-postgresql-pg-operator --timeout=300s
```{{exec}}

<br>

### Confirm the provider registered itself

On startup the provider registers a `Provider` resource with the OpenEverest core. If it
is there, the core knows how to build a Postgres cluster:

```
kubectl get providers.core.openeverest.io -n everest-system
```{{exec}}

`Provider` comes up clean on the first try:

```text
NAME                          AGE
provider-percona-postgresql   8m11s
```

> If the list is empty, the provider deployment is still starting. Check it with
> `kubectl logs -n everest-system deploy/provider-percona-postgresql`{{exec}}
