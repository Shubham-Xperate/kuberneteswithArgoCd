# argocd/ — GitOps continuous delivery (app-of-apps)

This folder contains everything needed to bootstrap ArgoCD to manage the
`ecommerce` application on AKS. ArgoCD is the **CD** half of this project's
CI/CD split — see the root-level explanation in `gitops/README.md` for why
CI (Azure DevOps) never touches the cluster directly.

## Files

| File | Purpose |
|---|---|
| `project.yaml` | `AppProject` named `ecommerce` — scopes allowed source repos, destination namespace (`ecommerce`), and resource kinds. |
| `root-app.yaml` | The one `Application` you apply by hand. Points at `argocd/apps/` in this repo; ArgoCD treats every manifest it finds there as a child `Application` to also create — this is the "app of apps" pattern. |
| `apps/ecommerce-dev-app.yaml` | Child `Application` for dev. Fully automated (`prune: true`, `selfHeal: true`). Uses a multi-source (`sources:`) definition to combine the Helm chart (`helm/ecommerce-chart`) with the GitOps repo's slim values overlay (`gitops/apps/ecommerce-dev/values.yaml`). |
| `apps/ecommerce-prod-app.yaml` | Child `Application` for prod. Same shape, but `syncPolicy.automated` is omitted — sync must be triggered manually after the tag bump lands in Git. |

## How to bootstrap (one-time, per cluster)

```bash
# 1. Install ArgoCD itself into the cluster
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. Wait for ArgoCD's own pods to come up
kubectl -n argocd wait --for=condition=available --timeout=300s deployment/argocd-server

# 3. Apply the project scope and the root Application.
#    This single step bootstraps EVERYTHING else (ecommerce-dev and
#    ecommerce-prod Applications get created automatically by root-app.yaml).
kubectl apply -f argocd/project.yaml -f argocd/root-app.yaml

# 4. (optional) Get the initial admin password to log into the ArgoCD UI/CLI
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

After step 3, within a couple minutes you should see three Applications in
`argocd app list`: `ecommerce-root`, `ecommerce-dev`, and `ecommerce-prod`.
`ecommerce-dev` will sync automatically. `ecommerce-prod` will show as
`OutOfSync` until someone runs `argocd app sync ecommerce-prod` (or clicks
Sync in the UI) — that's intentional; see the comments in
`apps/ecommerce-prod-app.yaml`.

## Before you use this for real

Replace every `https://dev.azure.com/your-org/ecommerce-devops-lab/_git/ecommerce-devops-lab`
placeholder in `project.yaml`, `root-app.yaml`, and both files under `apps/`
with your actual repo URL. If ArgoCD needs credentials to read a private
repo, register them first with `argocd repo add <url> --username ... --password ...`
(or an SSH key / GitHub App), separately from anything in this folder.
