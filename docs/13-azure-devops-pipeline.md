# 13 — Azure DevOps Pipelines

## YAML pipelines vs. classic pipelines

Azure DevOps has historically supported two ways of defining a pipeline. **Classic pipelines** are built through a visual, drag-and-drop UI — you click to add tasks, configure them through forms, and the resulting definition lives inside Azure DevOps's own database, not in your repository. **YAML pipelines** — what this project uses, `.azuredevops/azure-pipelines.yml` — define the entire pipeline as a text file committed alongside the rest of your code. The practical advantage is the same one that motivates almost everything else in this project's design: a YAML pipeline is version-controlled, reviewable in a pull request, and diffable, the same as any other code change, whereas a classic pipeline's configuration changes leave no comparable trail. This project uses YAML pipelines exclusively.

## The pipeline/stage/job/step hierarchy

Azure Pipelines structures a build into four nested levels, and understanding the hierarchy is necessary before any individual line of the real YAML makes sense. A **pipeline** is the whole file — the top-level definition triggered by an event (a push, a PR). A pipeline contains one or more **stages**, which are the highest-level grouping, typically representing a distinct phase of the overall process (build, test, deploy) that can depend on other stages completing successfully first. Each stage contains one or more **jobs**, which run on their own separate agent (a VM allocated to execute that job) — jobs within the same stage can run in parallel unless you explicitly declare a dependency between them. Each job contains an ordered sequence of **steps** — individual actions like running a script or invoking a pre-built task.

The real pipeline has exactly this shape, with four stages:

```yaml
stages:
  - stage: Build_And_Test
    jobs:
      - job: Build_Test_Api
      - job: Build_Test_Web
  - stage: Build_And_Push_Images
    dependsOn: Build_And_Test
    jobs:
      - job: Push_Api_Image
      - job: Push_Web_Image
  - stage: Update_GitOps_Dev
    dependsOn: Build_And_Push_Images
    jobs:
      - job: Bump_Dev_Tags
  - stage: Update_GitOps_Prod
    dependsOn: Build_And_Push_Images
    jobs:
      - deployment: Bump_Prod_Tags
```

Note that `Update_GitOps_Dev` and `Update_GitOps_Prod` both declare `dependsOn: Build_And_Push_Images` rather than depending on each other — meaning they run in parallel once the image-push stage finishes, and prod's approval gate (covered below) doesn't block dev's automatic tag bump from proceeding immediately.

## Triggers: branch pushes vs. pull requests

Azure Pipelines distinguishes two separate trigger mechanisms, both configured at the top of the real file, and the distinction between them is one of the more security-relevant design decisions in this pipeline:

```yaml
trigger:
  branches:
    include:
      - main
  paths:
    exclude:
      - "**/*.md"
      - gitops/**

pr:
  branches:
    include:
      - main
  paths:
    exclude:
      - "**/*.md"
      - gitops/**
```

`trigger:` governs what happens on an actual push/merge to `main` — a full run of every stage. `pr:` governs what happens when a pull request is opened or updated *targeting* `main` — and, critically, only the `Build_And_Test` stage actually executes for a PR run, enforced by the `condition` on the later stages (shown below), not by the trigger block itself. This split exists for a concrete reason: a PR can be opened by anyone with contribution access, from a branch that hasn't been reviewed yet, and its code hasn't earned the trust required to push images to your registry or write commits to the GitOps repo. Giving every PR build+test feedback quickly, without also giving every PR branch the ability to push to ACR or bump a deploy tag, is exactly the right balance — fast, safe feedback for contributors, with the higher-trust actions reserved for code that has actually merged. The `paths.exclude` entries on both triggers serve a narrower but still important purpose: they prevent a pointless full pipeline run every time someone only edits documentation, and — more importantly — they exclude `gitops/**` specifically so the pipeline's *own* automated commits (the tag bumps, covered below) don't retrigger the pipeline that made them, which would otherwise create an infinite build loop.

## Hosted vs. self-hosted agents

Every job needs an **agent** — the actual machine that checks out code and executes the job's steps. Azure DevOps offers **Microsoft-hosted agents** (ephemeral VMs Microsoft provisions, runs your job on, then destroys — no infrastructure for you to maintain, at the cost of a fresh environment every run and Microsoft's own available toolset) and **self-hosted agents** (a machine you provision and register yourself, useful when you need persistent state, specific software preinstalled, or — relevant if this project's AKS cluster were made a private cluster in a real deployment, per doc 12 — network line-of-sight into a VNet a public internet-facing Microsoft-hosted agent could never reach). This pipeline uses Microsoft-hosted agents throughout — every job specifies `pool: { vmImage: "ubuntu-latest" }` — a reasonable default for a project whose pipeline only needs to build code, build Docker images, and edit files in Git, none of which require anything a hosted agent can't already do.

## Service connections: why they replace pasted credentials

A **service connection** is Azure DevOps's mechanism for storing a credential (an API key, a Service Principal, a Managed Identity) once, centrally, in an encrypted store scoped to the project, and letting pipeline tasks reference it *by name* rather than ever writing the actual secret value into a YAML file. This matters because a YAML pipeline file is committed to Git — anything written directly into it is visible to everyone with read access to the repo, forever, in the commit history, even if you later remove it. The real pipeline references exactly one:

```yaml
variables:
  acrServiceConnection: "acr-service-connection"
```

used later in the `Docker@2` task:

```yaml
- task: Docker@2
  inputs:
    containerRegistry: "$(acrServiceConnection)"
    repository: "$(apiImageName)"
    command: "buildAndPush"
    tags: |
      $(imageTag)
```

`acrServiceConnection` is not a credential — it's a *name*, pointing at a service connection of type "Docker Registry" (Azure Container Registry flavor) that must be created once, ahead of time, through the Azure DevOps UI under Project Settings > Service connections (documented in `.azuredevops/README.md`). That service connection itself holds a Service Principal or Managed Identity with `AcrPush` permission on the registry. At run time, the `Docker@2` task exchanges that stored identity for a short-lived token and uses it to authenticate `docker push` — the pipeline YAML, and by extension this project's Git history, never contains a username, password, or any other literal secret material for ACR access, ever.

## Variables and immutable image tags

```yaml
variables:
  acrName: "ecommerceacr"
  acrLoginServer: "$(acrName).azurecr.io"
  apiImageName: "ecommerce-api"
  webImageName: "ecommerce-web"
  imageTag: "$(Build.BuildId)"
  buildConfiguration: "Release"
  dotnetSolution: "backend/ECommerce.sln"
```

`variables:` at the pipeline level defines values reused across stages and jobs via `$(variableName)` interpolation, keeping things like the solution path or registry name defined exactly once rather than repeated (and potentially drifting) across every step that needs them. `$(Build.BuildId)` is a **predefined system variable** Azure Pipelines provides automatically to every run — an integer, unique to that specific pipeline execution, that only ever increases. Doc 11 covers in depth why this beats a floating tag like `latest`; the short version repeated here in pipeline terms is that it's what makes every build's resulting image traceable back to the exact run (and therefore exact commit) that produced it, and it's what gives the GitOps commit described below an actual, meaningful diff to act on.

## `Build_And_Test`: two parallel jobs

The first stage runs on every trigger — PR or main push — and its two jobs, `Build_Test_Api` and `Build_Test_Web`, have no `dependsOn` between them, meaning Azure Pipelines schedules them onto separate agents and runs them concurrently:

```yaml
- job: Build_Test_Api
  steps:
    - task: UseDotNet@2
      inputs: { packageType: "sdk", version: "8.x" }
    - script: dotnet restore "$(dotnetSolution)"
    - script: dotnet build "$(dotnetSolution)" --configuration $(buildConfiguration) --no-restore
    - script: dotnet test "$(dotnetSolution)" --configuration $(buildConfiguration) --no-build --logger trx ...
    - task: PublishTestResults@2
      condition: succeededOrFailed()
```

```yaml
- job: Build_Test_Web
  steps:
    - task: NodeTool@0
      inputs: { versionSpec: "20.x" }
    - script: npm ci
      workingDirectory: frontend
    - script: npm run build -- --configuration production
      workingDirectory: frontend
    - script: npx --no-install ng test --watch=false --browsers=ChromeHeadless --code-coverage || npm test ...
      workingDirectory: frontend
```

The .NET and Angular toolchains are entirely independent of each other, so making them separate jobs (rather than separate steps within one job) means they genuinely execute in parallel rather than sequentially, shortening the overall time from push to feedback — a meaningful difference once a codebase is large enough that either build takes more than a minute or two. `condition: succeededOrFailed()` on `PublishTestResults@2` is worth noting as a small but important detail: it ensures test results get published to the pipeline UI even when some tests failed, rather than only on success — so a broken build actually shows you *which* tests broke, instead of just "the job failed" with no further detail.

## `Build_And_Push_Images`: the dependency chain and the PR guard

```yaml
- stage: Build_And_Push_Images
  dependsOn: Build_And_Test
  condition: >
    and(
      succeeded(),
      eq(variables['Build.SourceBranch'], 'refs/heads/main'),
      ne(variables['Build.Reason'], 'PullRequest')
    )
```

`dependsOn: Build_And_Test` establishes the ordering — this stage waits for the build/test stage to finish before starting at all. The `condition` is what actually enforces the PR guard described earlier: even though the `pr:` trigger *could* in principle run this whole YAML file for a pull request, this explicit condition checks `Build.Reason` (a predefined variable indicating what kind of event triggered this run) and refuses to proceed unless the run came from an actual push to `main`, not a PR validation run. This is a deliberate belt-and-suspenders design: the `pr:` trigger block already limits *which events* start a run at all, and this `condition` is a second, independent check ensuring that even if this YAML were somehow triggered another way, image pushes and GitOps commits still can't happen from unreviewed code. Once the condition passes, `Push_Api_Image` and `Push_Web_Image` run in parallel (again, no `dependsOn` between them), each a single `Docker@2` task performing a combined build-and-push using the service connection covered above.

## `Update_GitOps_Dev`: where ArgoCD picks up a new deploy

```yaml
- stage: Update_GitOps_Dev
  dependsOn: Build_And_Push_Images
  condition: succeeded()
  jobs:
    - job: Bump_Dev_Tags
      steps:
        - checkout: self
          persistCredentials: true
          fetchDepth: 0
        - script: sudo snap install yq
        - script: |
            yq -i ".api.image.tag = \"$(imageTag)\"" "$VALUES_FILE"
            yq -i ".web.image.tag = \"$(imageTag)\"" "$VALUES_FILE"
        - script: |
            git config user.email "devops-bot@ecommerce-lab.local"
            git config user.name "ecommerce-devops-bot"
            git add gitops/apps/ecommerce-dev/values.yaml
            git commit -m "ci: bump dev image tags to $(imageTag) [skip ci]" --allow-empty
            git push origin HEAD:main
```

This stage does not touch the AKS cluster in any way — it edits one YAML file (using `yq`, a command-line YAML editor, to precisely target the `api.image.tag`/`web.image.tag` fields without disturbing anything else in the file) and pushes a commit, using a bot identity, back to `main`. `persistCredentials: true` on the `checkout` step is what allows the later `git push` to authenticate using the pipeline's own built-in OAuth token rather than requiring a separately configured credential — this only works because, in this lab's simplified setup, `gitops/` lives in the same repository the pipeline itself runs against (`gitops/README.md` explains what a real split-repo setup would additionally require: a second Git-type service connection or a PAT with write access to a genuinely separate GitOps repository). The `[skip ci]` marker in the commit message, combined with the `gitops/**` path exclusion on the `trigger:` block from earlier, is a deliberate double-safeguard against the pipeline retriggering itself infinitely from its own bot commits. This is the exact commit doc 08 describes ArgoCD detecting on its next reconciliation pass — this pipeline's responsibility ends the moment this `git push` succeeds; everything after that is ArgoCD's job, not this pipeline's, which is the whole point of the GitOps split covered in that doc.

## Environments and approvals: the manual gate before prod

```yaml
- stage: Update_GitOps_Prod
  dependsOn: Build_And_Push_Images
  condition: succeeded()
  jobs:
    - deployment: Bump_Prod_Tags
      environment: "production"
      strategy:
        runOnce:
          deploy:
            steps:
              - checkout: self
              ...
```

Two things distinguish this stage from dev's structurally. First, it uses `deployment:` rather than plain `job:` — a `deployment` job is specifically the construct that understands an `environment:` reference and enforces whatever approval/check rules are attached to it; a plain `job` has no such concept. Second, `environment: "production"` is a reference to an Azure DevOps **Environment** — a named target (created once, ahead of time, under Pipelines > Environments in the UI) that can have **Approvals and checks** rules attached to it. Critically, the actual approval rule — who is allowed to approve, how many approvers are required, any timeout — is **not expressible in this YAML file at all**; it's configured entirely in the Azure DevOps web UI, and the `environment: "production"` line here is only the hook that rule attaches to. When this stage reaches that deployment job, Azure Pipelines pauses execution and waits for a qualifying human to click "Approve" before a single step inside it runs.

This is a deliberate manual gate, and the reason it exists here rather than letting prod auto-deploy exactly like dev does comes down to risk tolerance: dev auto-deploying on every merge is desirable (fast feedback, low cost of being wrong), while production changes should require a conscious, accountable human decision at the moment they're promoted — not just "whoever happened to merge a PR an hour ago." Once approved, the steps that follow are structurally identical to dev's — bump `gitops/apps/ecommerce-prod/values.yaml`, commit with the same bot identity and `[skip ci]` marker, push. The stage's final step is a plain, informational echo, worth reading because it makes the remaining gate explicit rather than leaving it as tribal knowledge:

```yaml
- script: |
    echo "Prod values.yaml updated. ArgoCD will show 'ecommerce-prod' as OutOfSync."
    echo "A human must now run 'argocd app sync ecommerce-prod' (or use the ArgoCD UI) to actually roll this out."
  displayName: "Reminder: manual ArgoCD sync still required"
```

## Why this pipeline never runs `kubectl` or `helm` against the cluster

This is worth stating one more time, explicitly, because it's the single most important design decision in this whole file, and the file's own header comment leads with it:

```yaml
# It NEVER runs `kubectl apply`, `helm upgrade/install`, or anything else
# that touches the AKS cluster directly. That is deliberate. ArgoCD, running
# inside the cluster, is the only thing with write access to the cluster
```

Tie this directly back to doc 08's push-vs-pull distinction: if this pipeline *did* run `kubectl apply` or `helm upgrade` at the end of `Update_GitOps_Dev`, it would need a live, standing credential capable of mutating the AKS cluster's state, stored somewhere the pipeline could access it — turning this pipeline into exactly the kind of high-value target doc 08 explains GitOps is designed to eliminate. Instead, this pipeline's last responsibility, for both dev and (after approval) prod, is making a Git commit. It never authenticates to the cluster, never holds a kubeconfig, and never has the ability to change what's running on AKS directly — that entire capability belongs solely to ArgoCD, running inside the cluster, pulling from Git on its own schedule. The pipeline building and pushing images, and ArgoCD deploying them, are two separate systems with two separate, non-overlapping sets of permissions, and that separation is the actual security property this whole architecture is built to deliver.

## Key terms

- **YAML pipeline** — a pipeline defined as a version-controlled text file, as opposed to a classic (UI-configured) pipeline.
- **Stage / job / step** — the nested hierarchy of an Azure Pipeline: stages group jobs, jobs run on independent agents (potentially in parallel), steps are individual actions within a job.
- **Trigger vs. PR trigger** — separate mechanisms controlling what runs on a push to a branch versus what runs when a pull request is opened/updated against it.
- **Agent (hosted vs. self-hosted)** — the machine executing a job; Microsoft-hosted agents are ephemeral and provider-managed, self-hosted agents are provisioned and maintained by you (often needed for private-network access).
- **Service connection** — a centrally stored, named credential (Service Principal/Managed Identity) that pipeline tasks reference by name, so no secret value is ever written into pipeline YAML.
- **Predefined variable** — a variable Azure Pipelines supplies automatically about the current run (e.g. `$(Build.BuildId)`, `Build.SourceBranch`, `Build.Reason`).
- **Condition** — an expression on a stage/job/step controlling whether it runs, evaluated against variables and prior step outcomes.
- **Environment (Azure DevOps)** — a named deployment target that can have Approvals and checks rules attached, enforced only by `deployment:`-type jobs.
- **Deployment job** — a job type (`deployment:` instead of `job:`) that understands `environment:` references and enforces their approval gates.
- **[skip ci]** — a commit message marker recognized by Azure Pipelines to prevent that specific commit from retriggering the pipeline that made it.
