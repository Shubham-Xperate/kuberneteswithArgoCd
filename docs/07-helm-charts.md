# 07 — Helm Charts

## What Helm adds beyond raw YAML and beyond Kustomize

Doc 06 covered Kustomize's approach to environment differences: patches layered on top of an unmodified base, with no templating language involved. Helm takes a different approach to a similar underlying problem, and it's worth being precise about what it actually adds. First, real templating logic: Helm manifests are Go templates, meaning you can use conditionals (`{{- if .Values.autoscaling.enabled }}`), loops, and functions inside the YAML itself — something Kustomize deliberately does not offer, by design. Second, a packaging format: a Helm **chart** is a versioned, distributable bundle (a `Chart.yaml` plus templates plus default values) that can be shared, versioned independently of the application code it deploys, and installed with one command against any cluster. Third, and distinctly useful operationally: Helm tracks **releases** — every `helm install`/`upgrade` is recorded as a numbered revision in the cluster itself, which is what makes `helm rollback` possible as a single command, rather than manually re-applying old YAML files you have to have kept around yourself.

## Chart.yaml: metadata, not application config

`helm/ecommerce-chart/Chart.yaml`:

```yaml
apiVersion: v2
name: ecommerce-chart
description: >-
  Helm chart for the ecommerce-devops-lab teaching project: a .NET 8 Web API
  behind an Angular + nginx frontend, with an optional in-cluster SQL Server
  StatefulSet for local practice...
type: application
version: 0.1.0
appVersion: "1.0.0"
```

`apiVersion: v2` marks this as a Helm 3 chart (v1 was Helm 2's legacy format, which required a separate Tiller server component inside the cluster — Helm 3 removed that entirely, talking to the Kubernetes API directly using your own kubeconfig credentials, which is a meaningfully simpler and more secure model). `type: application` distinguishes an installable chart from a `library` chart (a chart that only exists to be imported by other charts as shared helper templates, never installed on its own). The two version fields are easy to conflate but track genuinely different things: `version` is the **chart's own version** — bump it whenever the chart's templates or `values.yaml` schema change, independent of the application. `appVersion` is purely informational metadata recording which version of the actual application this chart currently defaults to deploying; it has no functional effect by itself (this project's templates reference `.Values.api.image.tag`, falling back to `.Chart.AppVersion` only if a tag isn't explicitly set).

## `values.yaml` and the `{{ .Values.x }}` templating syntax

`values.yaml` is the chart's default configuration — every value a template might need, with sensible defaults, all overridable per-environment. A representative excerpt:

```yaml
api:
  image:
    repository: youracr.azurecr.io/ecommerce-api
    tag: latest
    pullPolicy: IfNotPresent
  replicaCount: 2
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  service:
    port: 8080
```

and the corresponding fragment of `templates/api-deployment.yaml` that consumes it:

```yaml
spec:
  replicas: {{ .Values.api.replicaCount }}
  ...
  containers:
    - name: api
      image: "{{ .Values.api.image.repository }}:{{ .Values.api.image.tag | default .Chart.AppVersion }}"
      imagePullPolicy: {{ .Values.api.image.pullPolicy }}
      ...
      resources:
        {{- toYaml .Values.api.resources | nindent 12 }}
```

`{{ .Values.api.replicaCount }}` is Helm's Go-template syntax for substituting a value from `values.yaml` (or whatever override files were supplied at install time) directly into the rendered manifest — `.Values` is the root object exposing the entire merged values tree. `{{ .Values.api.image.tag | default .Chart.AppVersion }}` demonstrates a **pipeline**: the value is passed through the `default` function, which substitutes `.Chart.AppVersion` if `.Values.api.image.tag` is empty/unset — a fallback so the chart still renders something sensible even if a caller forgets to specify a tag. `{{- toYaml .Values.api.resources | nindent 12 }}` is a very common Helm idiom worth understanding on its own: `toYaml` takes an arbitrarily-shaped value (here, the whole `requests`/`limits` map) and serializes it back to YAML text, and `nindent 12` re-indents that text block by 12 spaces so it lines up correctly inside the surrounding manifest — this avoids hand-templating every possible sub-field (`cpu`, `memory`, potentially `ephemeral-storage`) individually; instead, whatever shape you put under `api.resources` in `values.yaml` gets dropped in verbatim.

## `_helpers.tpl` and named templates

Files prefixed with an underscore, like `templates/_helpers.tpl`, are not rendered into any Kubernetes manifest on their own — they exist purely to define reusable named template blocks via `{{ define "..." }}`, which other templates then pull in via `{{ include "..." . }}`. This project's `_helpers.tpl` defines, among others, `ecommerce-chart.fullname` and `ecommerce-chart.labels`:

```
{{- define "ecommerce-chart.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}
```

and it's used in `templates/api-deployment.yaml` as `name: {{ include "ecommerce-chart.fullname" . }}-api`. The point of centralizing this logic in one named template, rather than repeating similar name-construction logic in every single template file, is consistency: if this chart is installed twice in the same cluster under two different release names (say, `ecommerce-dev` and `ecommerce-staging`, each in its own namespace), every resource each release creates gets a name prefixed consistently and uniquely, without every template author having to remember and reimplement that exact naming convention correctly by hand. The chart also separates `ecommerce-chart.labels` (the full recommended label set, including things like chart version that legitimately change between upgrades) from `ecommerce-chart.selectorLabels` (a deliberately smaller, stable subset) — the comments explain this split exists because Kubernetes selectors are immutable after a resource is created, so if a label used in a selector ever changed between chart versions, the next `helm upgrade` would fail outright trying to apply an immutable field change; keeping selector labels minimal and stable avoids ever hitting that failure mode.

## Layering values files: `-f` ordering and environment promotion

`values-dev.yaml` and `values-prod.yaml` don't repeat the entire `values.yaml` file — they only list the specific keys that differ. `values-dev.yaml`:

```yaml
aspnetEnvironment: Development
api:
  image:
    tag: dev
  replicaCount: 1
  ...
```

`values-prod.yaml`:

```yaml
aspnetEnvironment: Production
api:
  image:
    tag: "1.0.0"
  replicaCount: 3
  ...
ingress:
  host: ecommerce.example.com
sql:
  enabled: false
```

Helm installs/upgrades accept multiple `-f` flags, and the documented convention in this project is:

```bash
helm install ecommerce ./ecommerce-chart -f values.yaml -f values-dev.yaml -n ecommerce --create-namespace
```

Helm **deep-merges** each successive `-f` file on top of the ones before it — it does not replace the whole document, only overrides the specific keys present in the later file, leaving everything else from the earlier file(s) intact. Critically, **order matters and the last file specified wins** on any key present in more than one file. This ordering is the actual mechanism this project uses for environment promotion: the base `values.yaml` defines every default, and each environment-specific file only needs to state its deltas — `values-prod.yaml` disabling the in-cluster `sql:` StatefulSet entirely (`sql.enabled: false`) is a good example of a meaningful behavioral difference expressed as a single overridden key, without duplicating the rest of the chart's configuration at all.

## `helm install` vs. `helm upgrade --install`

`helm install <release> <chart>` only works the first time — it fails if a release by that name already exists. In any repeatable deployment process (a CI/CD pipeline, or ArgoCD as covered in doc 08), you almost always want `helm upgrade --install <release> <chart> -f ...` instead: it installs the release if it doesn't exist yet, or upgrades it in place if it does — a single idempotent command that works correctly whether this is the very first deploy or the hundredth, which is exactly the property you need for something that runs automatically and unattended.

## Release history and `helm rollback`

Every `helm install` or `helm upgrade` is recorded by Helm as a numbered **revision** of a named **release**, stored inside the cluster itself (as Secrets, by default, in Helm 3). `helm history ecommerce` lists every past revision with its chart version and values; `helm rollback ecommerce <revision-number>` re-applies a prior revision's exact rendered manifests directly, without needing to check out an old commit, re-render anything, or remember what values were used at the time — Helm already recorded the fully-resolved state. This is a meaningfully faster, lower-risk recovery path during an incident than "figure out what the previous known-good configuration was and reconstruct it," which is the operational value proposition of Helm's release tracking beyond just templating convenience.

## `helm lint` and `helm template`: pre-flight checks

Two commands are worth running habitually before ever touching a real cluster. `helm lint ./ecommerce-chart` statically checks the chart for structural problems — malformed YAML, missing required fields, common template mistakes — without rendering or touching any cluster at all. `helm template ./ecommerce-chart -f values.yaml -f values-dev.yaml` performs a full **dry-run render**: it executes the exact same templating engine Helm would use for a real install, printing the fully-resolved Kubernetes YAML to your terminal, but never sends anything to a cluster. This is invaluable for actually reading what a values change will produce before committing to it — e.g., confirming that setting `sql.enabled: false` genuinely causes `templates/sql-statefulset.yaml` to render nothing, rather than assuming it based on reading the conditional logic alone.

## Helm vs. Kustomize: a genuine, neutral tradeoff

This project deliberately includes both `k8s/` (Kustomize) and `helm/ecommerce-chart/` (Helm) as parallel, independent ways to deploy the identical application, specifically so you can compare them directly rather than take either one on faith. In most real teams, you would pick one, not run both permanently — maintaining two deployment mechanisms for the same app is duplicated effort with no ongoing benefit once you've learned the tradeoffs. The genuine tradeoffs, stated neutrally: Kustomize has no templating language at all, which some teams consider a feature — patches are plain, valid Kubernetes YAML with no `{{ }}` syntax to learn, and "what you see is close to what you get" with less indirection to trace through mentally. Helm's templating is more powerful for genuinely complex conditional logic (this chart's `sql.enabled` toggle, entirely omitting a set of resources based on one flag, is more naturally expressed in Helm's `{{- if }}` than in Kustomize's patch model) and its packaging/versioning/rollback story is considerably more mature — there's no direct Kustomize equivalent to `helm rollback` or a chart's own semantic version. Kustomize, on the other hand, integrates especially cleanly with GitOps tools that just want to apply plain rendered YAML with minimal moving parts, and its patch-based model can feel more transparent for small, well-understood environment differences like replica counts and resource sizing — exactly the kind of differences this project's dev/prod overlays contain. Neither is objectively correct; the decision in a real team usually comes down to how much conditional templating logic the application genuinely needs versus how much value the team places on Helm's release/rollback tooling.

## How Helm fits into the GitOps/ArgoCD picture

This project's `helm/ecommerce-chart` is not merely a standalone teaching example — it's the exact artifact ArgoCD renders in production (doc 08 covers this fully). Looking ahead briefly: ArgoCD `Application` objects in this project (`argocd/apps/ecommerce-dev-app.yaml`, `argocd/apps/ecommerce-prod-app.yaml`) point directly at `helm/ecommerce-chart` as their source, specifying which values files to layer (e.g., `values-prod.yaml` plus a values file from the separate GitOps repo carrying the current image tag). ArgoCD internally performs the equivalent of a `helm template` render against the exact chart version and values combination recorded in Git, then applies the resulting manifests to the cluster and continuously reconciles any drift — meaning everything explained in this document about how values layer, how templates resolve, and what a given values combination actually produces is directly and literally what happens on every automated deployment, not just what happens when a human runs `helm install` by hand.

## Key terms

- **Chart**: a versioned, packaged bundle of Kubernetes manifest templates plus default configuration values, installable as a unit.
- **Release**: a named, tracked instance of a chart installed into a cluster; each install/upgrade creates a new numbered revision of that release.
- **Values deep-merge**: Helm's behavior when given multiple `-f` files — later files override matching keys from earlier ones, without discarding unrelated keys.
- **Named template (`_helpers.tpl`)**: a reusable, non-rendered block of template logic defined once and pulled into multiple manifest templates via `{{ include }}`, ensuring consistent naming/labeling across a chart.
- **`helm template` (dry-run render)**: fully resolves a chart's templates against given values and prints the resulting YAML locally, without touching any cluster — the standard way to preview a change before applying it.
- **`helm rollback`**: reverts a release to a previously recorded revision's exact rendered state, using Helm's own stored release history rather than manually reconstructing prior configuration.
