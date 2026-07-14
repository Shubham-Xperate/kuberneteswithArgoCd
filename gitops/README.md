# gitops/ — simulated "ecommerce-gitops" repository

## Why this folder exists

In a real deployment of this project, this folder would **not** live inside
the application source repository at all. It would be its own, separate Git
repository — typically named something like `ecommerce-gitops` — with its
own history, its own access controls, and its own lifecycle.

For this teaching lab we keep everything in one repo/folder tree so it's easy
to clone and explore in one shot, but conceptually you should mentally
"cut" this `gitops/` folder out and imagine it living at, say,
`https://dev.azure.com/your-org/ecommerce-gitops` — a totally separate
project from the `ecommerce-devops-lab` app-source repo that contains
`backend/`, `frontend/`, `helm/`, and `terraform/`.

The Azure DevOps pipeline in `.azuredevops/azure-pipelines.yml` writes to
this folder to simulate "pushing a commit to the GitOps repo" (see the
`Update_GitOps_Dev` / `Update_GitOps_Prod` stages and the comments there
about what a real, separate-repo setup would require).

## What's in here

```
gitops/
  apps/
    ecommerce-dev/
      values.yaml   <- slim Helm values overlay, ONLY image tags + env-specific bits
    ecommerce-prod/
      values.yaml   <- same idea, promoted deliberately, not on every commit
```

ArgoCD (see `../argocd/`) watches this folder and reconciles the cluster to
match whatever is committed here. The pipeline's entire job, once images are
built and pushed to ACR, is to bump the `image.tag` fields in these files and
commit. That single commit is the trigger for a deployment — nothing in CI
ever runs `kubectl apply` or `helm upgrade` directly.

## Why separate app-source and deploy-config repos (and the alternative)

Splitting "what the app is" (source code, Dockerfiles, Helm chart *templates*)
from "what's currently deployed" (this `gitops/` repo's `values.yaml` files)
is a common GitOps pattern for a few reasons:

- **Clean audit trail**: the GitOps repo's commit log is a pure, linear
  history of "what changed in the cluster and when" — not buried among
  hundreds of unrelated application commits (refactors, docs, CSS tweaks).
- **Separate permissions**: you can let every engineer merge to the app repo
  freely, while requiring a smaller, more trusted group (or a bot + approval
  gate) to merge to the GitOps repo, since that repo has direct authority
  over production.
- **Separate blast radius for ArgoCD**: ArgoCD only needs read access to the
  GitOps repo, not your entire application source (secrets scanning,
  webhooks, etc. stay simpler).

**This is genuinely debated, though.** The alternative — a **monorepo**
where the Helm chart and values live alongside the application code, and
ArgoCD is configured with path-based triggers (e.g. `spec.source.path` plus
webhook filters, or tools like ArgoCD's `Application` per-path, or
Argo CD Image Updater) so it only reconciles when files under `helm/**`
change — is also widely used and avoids the overhead of keeping two repos
in sync. Smaller teams and simpler projects often prefer the monorepo
approach; larger orgs with stricter separation-of-duties requirements more
often reach for the split-repo approach used here. Neither is objectively
"more correct" — pick based on your team's size, compliance needs, and
tooling maturity.
