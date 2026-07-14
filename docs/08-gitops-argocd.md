# 08 — GitOps and ArgoCD

## Push deployment vs. pull deployment: the distinction this whole doc hangs on

Before touching a single ArgoCD manifest, it's worth being precise about what "GitOps" actually means, because the term gets thrown around loosely. Historically, the most common way to get a build into a Kubernetes cluster was what you'd call a **push** model: your CI pipeline builds an image, and then, still inside the pipeline, runs `kubectl apply -f deployment.yaml` or `helm upgrade` directly against the cluster's API server. For that to work, the pipeline needs live, standing credentials to your cluster — a kubeconfig, a service account token, something with enough RBAC power to mutate Deployments and Services. Every pipeline that deploys anything has to be trusted with that power, and that credential has to exist somewhere the pipeline can read it: a secret variable, a vault, an environment file. If that pipeline (or the CI platform hosting it) is ever compromised, so is your cluster.

GitOps flips this around into a **pull** model. Instead of CI pushing changes into the cluster, a controller running *inside* the cluster — ArgoCD, in this project — continuously watches a Git repository and pulls whatever it finds there. CI's job shrinks to "build an image, then edit a file in Git and commit it." Nothing in CI ever holds a credential capable of changing the cluster's state, because CI never talks to the cluster at all — it only talks to Git. This is not just a stylistic preference; it is the concrete security property this whole design pattern is built around. Read the top of `.azuredevops/azure-pipelines.yml`, which states it outright:

```yaml
# It NEVER runs `kubectl apply`, `helm upgrade/install`, or anything else
# that touches the AKS cluster directly. That is deliberate. ArgoCD, running
# inside the cluster, is the only thing with write access to the cluster,
# and it works by continuously *pulling* the desired state from Git (the
# gitops/ folder) rather than having CI *push* changes into it.
```

The second property GitOps gives you, beyond the security boundary, is that **Git becomes the single source of truth and a complete audit log**. In a push model, the honest answer to "what's actually running in production right now, and who changed it, and when" often requires cross-referencing pipeline run logs, Slack messages, and whoever remembers running a manual `kubectl set image` at 2am. In a pull model, the answer is always: whatever the latest commit in the GitOps repo says, and `git log` tells you exactly who committed that change and when, with a message attached. If you need to know what was deployed to production last Tuesday, you check out last Tuesday's commit — no separate deployment-history system to maintain, because the deployment history *is* the commit history.

## ArgoCD's core loop: the reconciliation controller

ArgoCD implements this pull model through a **controller** — a long-running process that repeatedly executes the same three-step loop against every `Application` it's been told to manage: fetch the desired state from Git, fetch the live state from the Kubernetes API, and diff the two. If they differ, the Application's status becomes `OutOfSync`; if `automated` sync is enabled for that Application, ArgoCD immediately applies the difference (creating, updating, or deleting resources as needed) to bring the cluster back in line with Git. This loop runs continuously — by default on a polling interval against Git (roughly every three minutes, though it also supports webhooks for near-instant detection) — which is what makes ArgoCD fundamentally different from a one-shot `helm upgrade` run once by a pipeline and then never checked again.

## The `AppProject`: why scoping matters before you create a single Application

Look at `argocd/project.yaml` before looking at any `Application` manifest, because it defines the walls those Applications operate inside. ArgoCD ships with a built-in `default` project that every Application belongs to if you don't specify otherwise, and the default project is deliberately permissive: any source repo, any destination cluster and namespace, any Kubernetes resource kind. That's fine for a five-minute demo and dangerous for anything real, because it means an Application manifest — which might be edited by any contributor with merge access to the GitOps repo — could, in principle, point ArgoCD at an entirely different Git repo, a different destination namespace, or even try to create cluster-scoped resources like `ClusterRole` objects.

An **AppProject** is ArgoCD's RBAC and scoping boundary, sitting one level above individual Applications. The real `project.yaml` scopes the `ecommerce` project down along three axes:

```yaml
sourceRepos:
  - "https://dev.azure.com/your-org/ecommerce-devops-lab/_git/ecommerce-devops-lab"

destinations:
  - server: "https://kubernetes.default.svc"
    namespace: ecommerce

clusterResourceWhitelist: []

namespaceResourceWhitelist:
  - group: "*"
    kind: "*"
```

`sourceRepos` is an allow-list: any Application claiming membership in the `ecommerce` project must have a `repoURL` that matches an entry here, or ArgoCD refuses to sync it. `destinations` is the same idea applied to where things can be deployed — here, only the `ecommerce` namespace on `https://kubernetes.default.svc`, which is the special, well-known address of the Kubernetes API server *from inside the same cluster ArgoCD itself is running in* (this project's ArgoCD manages the same AKS cluster it's installed into, rather than managing some other, remote cluster). `clusterResourceWhitelist: []` is left empty on purpose — cluster-scoped resource kinds (things like `ClusterRole`, `ClusterRoleBinding`, or `Namespace` itself) are not permitted at all through this project, which keeps the blast radius of a misconfigured or compromised Application confined to the one namespace it's allowed to touch. Namespace creation for `ecommerce` still happens, but through a different, narrower mechanism — each Application's own `syncOptions: [CreateNamespace=true]`, which ArgoCD treats as a special-cased exception rather than a general cluster-scoped permission. `namespaceResourceWhitelist` with `group: "*", kind: "*"` is comparatively loose (any namespaced resource kind is allowed inside `ecommerce`), which the file's own comment flags as a reasonable simplification for a teaching project — a stricter production setup would enumerate exactly `Deployment`, `Service`, `ConfigMap`, `Secret`, `Ingress`, and nothing else.

## The `Application` CRD, field by field, from the real dev manifest

An ArgoCD `Application` is a **Custom Resource** — ArgoCD extends the Kubernetes API with its own resource types (`AppProject`, `Application`, and others), so `kubectl get applications -n argocd` works exactly like `kubectl get deployments` would, and ArgoCD's own controller is just another piece of software watching the Kubernetes API for changes to *its* custom resources, the same pattern every Kubernetes controller (including the built-in Deployment controller covered in doc 06) follows. Here is `argocd/apps/ecommerce-dev-app.yaml` in full:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ecommerce-dev
  namespace: argocd
spec:
  project: ecommerce

  sources:
    - repoURL: "https://dev.azure.com/your-org/ecommerce-devops-lab/_git/ecommerce-devops-lab"
      targetRevision: main
      path: helm/ecommerce-chart
      helm:
        valueFiles:
          - values-dev.yaml
          - $values/gitops/apps/ecommerce-dev/values.yaml

    - repoURL: "https://dev.azure.com/your-org/ecommerce-devops-lab/_git/ecommerce-devops-lab"
      targetRevision: main
      ref: values

  destination:
    server: "https://kubernetes.default.svc"
    namespace: ecommerce

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

`spec.project: ecommerce` ties this Application to the AppProject discussed above — if this repo, or the `ecommerce` destination namespace, weren't allowed by that project, ArgoCD would reject this Application outright. `destination` tells ArgoCD *where* to deploy: which cluster (again, the in-cluster API server) and which namespace.

The `source`/`sources` fields deserve their own explanation, because this manifest uses the plural, less common form. Normally an Application has a single `spec.source`: one repo, one path, done. This project needs two things that live at genuinely different paths — the Helm chart's templates and default values (`helm/ecommerce-chart`, owned by the application source repo) and a slim values overlay containing just the current image tags (`gitops/apps/ecommerce-dev/values.yaml`, conceptually owned by a separate "GitOps repo" — see `gitops/README.md` for why that split exists, and note this lab collapses both into one physical repo for convenience while keeping the logical separation in the folder structure). A single `source` block can only reference files inside its own `path`, so it has no way to reach a values file that lives elsewhere. ArgoCD's **multi-source Applications** feature is the fix: `sources` is a list, and one entry can be given a `ref` name (here, `ref: values`) purely so another entry can point into its checkout using the special `$<ref-name>/...` syntax. That's exactly what happens in `helm.valueFiles`: `$values/gitops/apps/ecommerce-dev/values.yaml` means "take the file at that path, from the checkout labeled `values`." The second `sources` entry contributes no chart of its own — it exists solely to make its checkout available for that reference.

`syncPolicy` is where the GitOps loop becomes concrete. `automated: {prune: true, selfHeal: true}` turns on fully automatic reconciliation, and both sub-fields matter independently. `prune: true` means that if a resource is *removed* from the Helm chart's templates in Git — say, a ConfigMap gets deleted from `helm/ecommerce-chart/templates/` — ArgoCD deletes the corresponding live resource from the cluster too, rather than leaving an orphan behind that nobody remembers creating. `selfHeal: true` is the field that makes the earlier "Git is the single source of truth" claim actually enforced rather than aspirational. Walk through the concrete scenario: someone, perhaps during an incident, runs `kubectl scale deployment ecommerce-api --replicas=10 -n ecommerce` directly against the cluster, bypassing Git entirely. Without `selfHeal`, that change would simply stick — the cluster and Git would silently diverge, and the Application would show `OutOfSync` in the ArgoCD UI, but nothing would act on it. With `selfHeal: true`, ArgoCD's reconciliation loop notices on its very next pass that live `replicas: 10` doesn't match Git's `replicas: 2` (from `values-dev.yaml`), and it reverts the Deployment back to 2 — automatically, within roughly the polling interval, with no human involved. This is the mechanism, not just the philosophy, that makes "manual, undocumented changes never stick" a true statement about this cluster rather than a slogan. `syncOptions: [CreateNamespace=true]` is a narrower, one-time convenience: it lets this Application create the `ecommerce` namespace itself the first time it syncs, instead of requiring an operator to pre-create it by hand.

## Why prod's Application omits `automated` entirely

`argocd/apps/ecommerce-prod-app.yaml` is structurally identical to dev's, with the same multi-source `$values` trick pointed at `values-prod.yaml` and `gitops/apps/ecommerce-prod/values.yaml` — but its `syncPolicy` block has no `automated` key at all:

```yaml
syncPolicy:
  syncOptions:
    - CreateNamespace=true
```

Without `automated`, ArgoCD still does the *detection* half of its job continuously — it will keep comparing Git to the live cluster and will keep showing `OutOfSync` the moment they diverge — but it stops there. It will not act on that drift by itself. Bringing the cluster in line with Git now requires an explicit, deliberate action: an operator running `argocd app sync ecommerce-prod` from the CLI, or clicking "Sync" in the ArgoCD web UI. This is a design choice with two consequences worth naming directly. First, it means merging to `main` alone can never change what's running in production — the tag bump lands in `gitops/apps/ecommerce-prod/values.yaml` (gated by its own approval, covered in doc 13), but the cluster doesn't move until someone takes that second, separate action. Second, `selfHeal` being off here is equally deliberate and for a related reason: if an on-call engineer needs to apply an emergency manual patch to a production Deployment while an incident is being triaged, an automated self-heal would silently revert that hotfix the moment ArgoCD's next reconciliation pass ran — exactly the wrong behavior in the middle of an incident. Prod trades away automation for control at both of these points, on purpose, and the two Application manifests read almost identically once you know to look for that one missing `automated:` block.

## The app-of-apps pattern: `root-app.yaml`

With two child Applications (`ecommerce-dev`, `ecommerce-prod`) and potentially more in the future, you'd otherwise need to `kubectl apply -f argocd/apps/ecommerce-dev-app.yaml` and `kubectl apply -f argocd/apps/ecommerce-prod-app.yaml` by hand every time one changes or a new one is added. **App-of-apps** is the pattern that eliminates this: you create exactly one root `Application` whose `source` points not at a Helm chart, but at a *directory of other Application manifests*, and ArgoCD applies the same reconciliation logic to that directory as it would to any other set of Kubernetes manifests — the fact that the manifests it finds happen to themselves be `Application` resources is what makes the trick work. `argocd/root-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ecommerce-root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: ecommerce
  source:
    repoURL: "https://dev.azure.com/your-org/ecommerce-devops-lab/_git/ecommerce-devops-lab"
    targetRevision: main
    path: argocd/apps
    directory:
      recurse: false
  destination:
    server: "https://kubernetes.default.svc"
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

The `directory: { recurse: false }` block is the key to reading this correctly: rather than a Helm chart or Kustomize overlay, this source type just means "apply every plain manifest file found directly in `argocd/apps/`." Since `ecommerce-dev-app.yaml` and `ecommerce-prod-app.yaml` are themselves `Application` resources, applying them doesn't deploy application workloads directly — it creates two more Applications for ArgoCD to separately reconcile, each with its own sync policy exactly as described above. This root Application is the *only* one you ever apply by hand (a one-time bootstrap: `kubectl apply -f argocd/project.yaml -f argocd/root-app.yaml`). Because the root Application also has `automated: {prune, selfHeal}` turned on, it is self-managing in a genuinely useful way: add a third file, say `argocd/apps/ecommerce-staging-app.yaml`, push it to `main`, and on its next reconciliation pass the root Application notices the new file in its watched directory and creates that Application automatically — no second manual `kubectl apply` required, ever again. The `finalizers: [resources-finalizer.argocd.argoproj.io]` entry is a safety measure specific to being the root of this tree: it prevents this Application from being swept away by an accidental cascading delete of everything in the project, since deleting the root would otherwise risk deleting every child Application (and, depending on their own prune settings, their managed resources) along with it.

## The full loop, end to end

Putting every piece together, here is the complete path a code change takes from a developer's laptop to a running pod, referencing the concrete files involved at each step (the CI half is covered in full in doc 13, and is only summarized here):

1. A merge to `main` triggers the Azure DevOps pipeline, which builds Docker images for the API and web frontend and pushes them to ACR (doc 11), tagged with the immutable `$(Build.BuildId)`.
2. The pipeline's `Update_GitOps_Dev` stage edits `gitops/apps/ecommerce-dev/values.yaml`, bumping `api.image.tag` and `web.image.tag` to that new build ID, and commits that change directly to `main`.
3. ArgoCD's `ecommerce-dev` Application, on its next reconciliation pass (polling Git roughly every few minutes, or immediately if a webhook is configured), detects that the content of `values.yaml` in its watched path has changed since the last commit it synced against.
4. ArgoCD renders the Helm chart (`helm/ecommerce-chart`, using `values-dev.yaml` layered with the just-updated `gitops/apps/ecommerce-dev/values.yaml`) into concrete Kubernetes manifests — the same rendering `helm template` would produce locally, covered in doc 07 — and diffs the result against the live cluster state.
5. Because `automated: {prune: true, selfHeal: true}` is set on this Application, ArgoCD immediately applies the diff: the Deployment's pod template now specifies the new image tag.
6. Kubernetes' own Deployment controller (doc 06) takes over from there, performing the actual rolling update — creating pods with the new image, waiting for them to become ready, and terminating old pods — exactly as it would if you'd run `kubectl apply` yourself, because that's ultimately what ArgoCD did on your behalf.

Prod follows the identical technical path, with two deliberate pauses inserted by design (the pipeline's approval gate before the tag bump commits, and the missing `automated` block requiring a manual `argocd app sync ecommerce-prod` before step 5 happens) — both covered above and cross-referenced in doc 13.

## Operating ArgoCD day to day: `app sync` and `app get`

Two CLI commands cover most manual interaction you'll need beyond what automation handles. `argocd app get ecommerce-dev` prints the Application's current status — whether it's `Synced` or `OutOfSync`, whether its resources are `Healthy`, `Degraded`, or `Progressing`, and a resource-by-resource breakdown, which is usually the first thing to check when something looks wrong. `argocd app sync ecommerce-prod` is the manual trigger discussed above for any Application without automated sync — it tells ArgoCD "reconcile right now, using whatever's currently in Git," and is also useful even on automated Applications when you don't want to wait for the next polling interval. Both commands assume you're authenticated to an ArgoCD server, which doc 15's runbook covers setting up via `kubectl port-forward svc/argocd-server`.

## Key terms

- **GitOps** — an operating model where a Git repository is the sole source of truth for desired system state, and a controller continuously reconciles the live system to match it, rather than external tooling pushing changes into the system directly.
- **Push deployment** — CI/CD tooling authenticates directly to the target system (here, the Kubernetes API) and applies changes itself; requires the pipeline to hold live credentials to that system.
- **Pull deployment** — a controller inside the target system watches an external source (Git) and applies changes on its own initiative; the external tooling (CI) never needs credentials to the target system.
- **Reconciliation loop** — the repeated cycle of comparing desired state (Git) against actual state (the live cluster) and correcting any difference.
- **AppProject** — ArgoCD's RBAC/scoping resource; restricts which source repos, destination clusters/namespaces, and resource kinds a group of Applications may use.
- **Application (CRD)** — ArgoCD's custom resource describing one deployable unit: where its manifests come from (`source`/`sources`), where they go (`destination`), and how sync behaves (`syncPolicy`).
- **App-of-apps** — a pattern where one root Application's source is a directory of other Application manifests, letting a single bootstrap apply cascade into managing arbitrarily many child Applications.
- **Multi-source Application** — an Application using `sources` (plural) to combine files from more than one repo/path checkout, cross-referenced via the `$<ref-name>` syntax.
- **Prune** — deleting live cluster resources that no longer appear in Git, keeping the cluster free of orphaned objects.
- **Self-heal** — automatically reverting manual, out-of-band changes to cluster resources back to what Git specifies.
- **OutOfSync** — an Application status meaning the live cluster state currently differs from what's declared in Git.
