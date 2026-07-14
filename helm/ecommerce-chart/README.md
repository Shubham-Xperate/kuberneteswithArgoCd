# ecommerce-chart

Helm chart for the ecommerce-devops-lab teaching project: a .NET 8 Web API
behind an Angular + nginx frontend, with an optional in-cluster SQL Server
StatefulSet for free local practice.

This is the Helm-packaged equivalent of the raw manifests under `../../k8s/`
(Kustomize base + dev/prod overlays). Both deploy the same application;
pick whichever tool fits how you want to teach/learn/operate it. See the
`NOTE:` comments inside each template for where and why the Helm version
diverges from its `k8s/base/` counterpart (mostly: `.Release.Namespace`
instead of a hardcoded namespace, and release-scoped resource names via the
`ecommerce-chart.fullname` helper).

## Prerequisites

- A local Kubernetes cluster (kind or minikube) or an AKS cluster.
- Helm 3.x.
- For Ingress access: the `ingress-nginx` controller installed in-cluster.
- For autoscaling to actually report numbers: `metrics-server` installed
  in-cluster.

## Install (local/dev)

```bash
helm install ecommerce ./ecommerce-chart -f values.yaml -f values-dev.yaml -n ecommerce --create-namespace
```

## Install (production-shaped, still with placeholder secrets/images)

```bash
helm install ecommerce ./ecommerce-chart -f values.yaml -f values-prod.yaml -n ecommerce --create-namespace
```

Before doing this for real: override `secrets.*` with real values (never by
editing `values.yaml`/`values-prod.yaml` directly -- both are meant to be
committed to git). Use one of:

```bash
# one-off / local testing only (ends up in shell history -- least safe)
helm install ecommerce ./ecommerce-chart -f values.yaml -f values-prod.yaml \
  --set secrets.dbPassword='...' --set secrets.jwtKey='...' \
  -n ecommerce --create-namespace

# a git-ignored overrides file (safer, repeatable)
helm install ecommerce ./ecommerce-chart -f values.yaml -f values-prod.yaml -f values-secrets.yaml \
  -n ecommerce --create-namespace
```

In actual production on AKS, prefer neither of the above: set
`secrets.create=false` and let the Secrets Store CSI Driver sync secrets
from Azure Key Vault instead, using the AAD Workload Identity this project's
Terraform already wires up on the AKS cluster for exactly this purpose.

## Upgrade

```bash
helm upgrade ecommerce ./ecommerce-chart -f values.yaml -f values-dev.yaml -n ecommerce
```

## Uninstall

```bash
helm uninstall ecommerce -n ecommerce
```

## Verify

```bash
helm lint ./ecommerce-chart
helm template ./ecommerce-chart -f ./ecommerce-chart/values.yaml -f ./ecommerce-chart/values-dev.yaml
```

## Values files

| File               | Purpose                                                        |
|--------------------|-----------------------------------------------------------------|
| `values.yaml`      | Base defaults, always passed first.                              |
| `values-dev.yaml`  | Overrides for local kind/minikube (1 replica, `dev` image tag).  |
| `values-prod.yaml` | Overrides for AKS (3 replicas, pinned semver tag, PDB on, `sql.enabled=false`). |

See the comments inside `values.yaml` for a full explanation of every key,
including the `secrets:` block's three supported ways to supply real
credentials safely.
