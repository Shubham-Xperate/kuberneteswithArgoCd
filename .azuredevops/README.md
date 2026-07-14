# .azuredevops/ — CI pipeline

## Prerequisites (one-time setup in the Azure DevOps project)

1. **ACR service connection** — create a service connection of type
   *Docker Registry* (registry type: *Azure Container Registry*) named to
   match `acrServiceConnection` in `azure-pipelines.yml` (default:
   `acr-service-connection`). This provisions a Service Principal or
   Managed Identity with `AcrPush` on the registry — no credentials are
   ever stored in this repo.
2. **GitOps repo access** — this lab keeps `gitops/` in the same repo as the
   pipeline for simplicity (see the big comment above the
   `Update_GitOps_Dev` stage and `gitops/README.md`). If you split it into a
   real separate repo, the pipeline's default checkout token will no longer
   have push access to it, and you'll need either a second Git-type service
   connection or a PAT stored as a secret pipeline variable, plus a
   `checkout` step pointed at that repo's URL instead of `checkout: self`.
3. **Environments and approvals** — under **Pipelines > Environments**,
   create an environment named `production`, then add an **Approvals and
   checks** rule (Approvals) naming the people/group allowed to approve a
   prod promotion. This cannot be expressed in the YAML file itself — the
   `environment: 'production'` reference in the `Update_GitOps_Prod` stage
   is only the hook; the actual gate is configured in the UI.
4. **Variables** — update `acrName` at the top of `azure-pipelines.yml` to
   match your real ACR name (from the Terraform outputs), and confirm
   `dotnetSolution` / Dockerfile paths match this repo's layout.

## How the trigger flow works end to end

A pull request into `main` runs the `Build_And_Test` stage only (both the
.NET and Angular jobs, in parallel) so contributors get fast feedback without
any risk of pushing images or GitOps commits from unreviewed code. Once a PR
merges to `main`, the full pipeline runs: `Build_And_Test` again, then
`Build_And_Push_Images` builds and pushes both Docker images to ACR tagged
with the immutable `$(Build.BuildId)`. Immediately after, `Update_GitOps_Dev`
bumps the image tags in `gitops/apps/ecommerce-dev/values.yaml` and commits
with `[skip ci]` (so the bot's own commit doesn't retrigger the pipeline) —
ArgoCD notices this commit within its normal polling/webhook interval and
auto-syncs dev. In parallel, `Update_GitOps_Prod` starts but pauses at its
`environment: production` approval gate until someone approves it in the
Azure DevOps UI; once approved, it bumps
`gitops/apps/ecommerce-prod/values.yaml` the same way. That commit alone
does **not** deploy prod — ArgoCD's `ecommerce-prod` Application has
automated sync disabled on purpose, so a second, separate manual
`argocd app sync ecommerce-prod` (or UI click) is required before the new
version actually rolls out to the cluster.
