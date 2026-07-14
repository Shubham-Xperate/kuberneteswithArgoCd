{{/*
_helpers.tpl -- reusable named templates ("partials").

Files starting with `_` are not rendered into a Kubernetes manifest
themselves; they only define `{{ define "..." }}` blocks that other
templates pull in via `{{ include "..." . }}`. This is the standard Helm
pattern (identical to what `helm create` scaffolds) for keeping naming and
labels consistent across every template in the chart instead of hand-typing
slightly-different label sets in each file.
*/}}

{{/*
Chart name, defaulting to Chart.Name but overridable via .Values.nameOverride
in case you fork this chart under a different values.yaml without renaming
Chart.yaml itself. `trunc 63` + `trimSuffix "-"` keep it within Kubernetes'
63-character label-value limit (DNS subdomain naming rules).
*/}}
{{- define "ecommerce-chart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name -- used as a prefix for most resource names so
multiple installs of this chart (e.g. two Helm releases in different
namespaces) don't collide. Mirrors the logic `helm create` generates:
- if fullnameOverride is set, use it verbatim
- else if the release name already contains the chart name, just use the
  release name (avoids "ecommerce-ecommerce-chart"-style stutter)
- else join them
*/}}
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

{{/* Chart name + version, e.g. "ecommerce-chart-0.1.0" -- handy for provenance/debugging annotations. */}}
{{- define "ecommerce-chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Standard Kubernetes "recommended labels" -- the app.kubernetes.io/* label
set documented at kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/.
Applied as `metadata.labels` on every resource (via `include ... | nindent`),
distinct from selectorLabels below because these include mutable/informational
fields (chart version, managed-by) that must NEVER be used in a Selector --
Selectors are immutable after creation, so if a label used in one changed
across a chart upgrade (like chart version does every release), the upgrade
would fail outright.
*/}}
{{- define "ecommerce-chart.labels" -}}
helm.sh/chart: {{ include "ecommerce-chart.chart" . }}
{{ include "ecommerce-chart.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels -- the minimal, STABLE subset of labels safe to use in
spec.selector.matchLabels (Deployments/Services/etc). Kept separate from the
full label set above specifically so it never picks up a field that could
change between upgrades.
*/}}
{{- define "ecommerce-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ecommerce-chart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Component-specific selector labels (api vs web vs sql) -- each workload
needs its OWN distinct selector so, e.g., the api Deployment's Service
doesn't accidentally also match web pods. Pass a dict like
`(dict "context" . "component" "api")` when including this.
*/}}
{{- define "ecommerce-chart.componentSelectorLabels" -}}
{{ include "ecommerce-chart.selectorLabels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}
