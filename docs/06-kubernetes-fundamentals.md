# 06 — Kubernetes Fundamentals

## Why Kubernetes exists, past what Compose already does

Doc 05 covered Compose, which orchestrates multiple containers on one machine. Kubernetes exists for the next problem: running containers reliably across a *fleet* of machines (nodes), where any individual machine can fail, where load varies over time, and where you want a system that continuously enforces "this is what should be running" rather than a one-shot `up` command. Kubernetes' central idea is the **declarative, reconciling controller**: you tell the Kubernetes API "I want 2 replicas of this container image, with these resource limits," and a controller running inside the cluster continuously compares that desired state against actual state, taking action (starting, stopping, rescheduling containers) whenever they diverge — whether that divergence was caused by a node dying, a pod crashing, or you deliberately editing the desired replica count.

## Pods, Deployments, and ReplicaSets

The smallest deployable unit in Kubernetes is a **Pod** — one or more tightly-coupled containers that always get scheduled together onto the same node and share a network namespace (so containers in the same pod can reach each other over `localhost`). In this project, each pod runs a single container (the API, or the web frontend, or SQL Server), which is the common case; pods only need multiple containers when two processes genuinely must share network/filesystem namespaces (a sidecar pattern), which this project doesn't use. Pods are not, by themselves, self-healing — if you create a bare Pod and it crashes, nothing restarts it.

That's what a **Deployment** is for. Looking at `k8s/base/api-deployment.yaml`, the `spec.replicas: 2` field, combined with a pod `template` and a `selector`, tells Kubernetes "maintain 2 running pods matching this template, forever." A Deployment doesn't manage pods directly, though — it manages an intermediate object called a **ReplicaSet**, which is the thing actually responsible for ensuring the requested number of pods matching a label selector exist at any given time. The reason Deployments exist as a layer on top of ReplicaSets, rather than you managing ReplicaSets by hand, is rolling updates: when you change the pod template (say, deploying a new image tag), the Deployment controller creates a *new* ReplicaSet with the new template and gradually shifts pod count from the old ReplicaSet to the new one, giving you a controlled rollout (and the ability to `kubectl rollout undo` back to the previous ReplicaSet) instead of a hard cutover.

## Services and cluster DNS: why `ecommerce-api` matters

A Pod's IP address is not stable — pods are routinely destroyed and recreated (rollouts, crashes, node failures), and each new pod gets a new IP. A **Service** solves this by giving a stable virtual IP and DNS name to a *set* of pods matched by a label selector, and load-balancing traffic across whichever pods currently match. `k8s/base/api-service.yaml` defines exactly this for the API:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ecommerce-api
  namespace: ecommerce
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: ecommerce-api
  ports:
    - port: 8080
      targetPort: 8080
```

`type: ClusterIP` (the default Service type) means this Service is only reachable from *inside* the cluster — appropriate here, since nothing outside the cluster should ever talk to the API directly; all external traffic is meant to arrive via the Ingress, hit the frontend, and only reach the API through this internal Service. Kubernetes runs a cluster-internal DNS system called **CoreDNS**, which automatically creates a DNS record for every Service, in the form `<service-name>.<namespace>.svc.cluster.local` — and, crucially, the short form `<service-name>` alone also resolves correctly for anything running inside the *same* namespace, thanks to DNS search-domain configuration Kubernetes injects into every pod automatically. This is exactly why the frontend's `nginx.conf` can say `proxy_pass http://ecommerce-api:8080;` (doc 03/04) with zero additional configuration: as long as this Service is named `ecommerce-api` and lives in the same namespace as the `ecommerce-web` pods, that DNS name simply resolves. The file's own comment states this bluntly: "THE NAME OF THIS SERVICE IS LOAD-BEARING — DO NOT RENAME," because the frontend's compiled, already-built nginx configuration has that exact hostname baked in; renaming the Service without also rebuilding the frontend image would silently break the app.

## Namespaces

`k8s/base/namespace.yaml` creates a dedicated `ecommerce` namespace, and every other manifest in this project explicitly targets `namespace: ecommerce`. A **Namespace** is a logical partition inside a single cluster — it scopes names (two objects can share a name if they're in different namespaces), and it's the boundary most access-control (RBAC), resource quotas, and network policies attach to. Using a dedicated namespace instead of dumping everything into the cluster's default `default` namespace keeps `kubectl get pods -n ecommerce` meaningful and sets you up to apply namespace-scoped policies later without needing to first untangle unrelated workloads sharing the same space.

## ConfigMaps vs. Secrets

`k8s/base/configmap.yaml` and `k8s/base/secret.example.yaml` illustrate the split. A **ConfigMap** holds non-sensitive configuration — this project's `ecommerce-config` ConfigMap holds `ASPNETCORE_ENVIRONMENT`, `Cors__AllowedOrigin`, `Jwt__Issuer`, `Jwt__Audience`, and the frontend's `API_URL` — values that are fine to see in `kubectl describe`, in logs, or committed to git in plain text. A **Secret** holds sensitive values — this project's `ecommerce-db-secret` (the SQL `sa` password) and `ecommerce-api-secret` (the JWT signing key and the full database connection string) — and it's essential to understand precisely what protection a Kubernetes Secret does and does not provide by default: a Secret's values are stored **base64-encoded**, not encrypted. Base64 is an *encoding*, not a cipher — anyone with read access to that Secret object (or to `etcd`, the cluster's backing datastore, if it isn't separately configured with encryption-at-rest) can trivially decode it back to plaintext in one command. Kubernetes Secrets are a mechanism for keeping sensitive values *out of your regular manifests and container images* and controlling *who/what can read them via RBAC* — they are not, on their own, a strong encryption-at-rest guarantee. This is exactly why doc 13 discusses layering Azure Key Vault (via the Secrets Store CSI Driver) on top in production: it moves the actual plaintext-at-rest and rotation responsibility to a system built for it, rather than relying solely on a base64 string sitting in `etcd`.

The api-deployment's env wiring shows the deliberate split between bulk and individual injection:

```yaml
envFrom:
  - configMapRef:
      name: ecommerce-config
env:
  - name: Jwt__Key
    valueFrom:
      secretKeyRef:
        name: ecommerce-api-secret
        key: jwt-key
  - name: ConnectionStrings__DefaultConnection
    valueFrom:
      secretKeyRef:
        name: ecommerce-api-secret
        key: connection-string
```

`envFrom: configMapRef` bulk-injects every key in the ConfigMap as an environment variable — convenient, and safe here specifically because the ConfigMap is guaranteed to contain nothing sensitive. Secrets are deliberately *not* bulk-injected the same way; each one is pulled in individually via `secretKeyRef`, naming the exact key. This is intentional friction: it forces whoever adds a new secret value to explicitly wire it into the pod spec, so a secret can never leak into a running pod "by accident" the way an `envFrom: secretRef` might silently expose a newly-added key nobody meant to inject yet.

## StatefulSets vs. Deployments: the real `sql-statefulset.yaml`

`k8s/base/sql-statefulset.yaml` runs SQL Server as a **StatefulSet** rather than a Deployment, and the distinction matters specifically because a database is *stateful* in a way a web API is not. A Deployment's pods are interchangeable — any replica can serve any request, and if one dies and a fresh one starts elsewhere, nothing cares which specific pod it was. A database, by contrast, needs stable identity and stable, dedicated storage: pod `sqlserver-0` must always come back as `sqlserver-0`, reattached to the *same* disk it had before, not a fresh empty one, or you lose your data. A StatefulSet guarantees exactly this: it names pods predictably (`sqlserver-0`, `sqlserver-1`, ...), and its `volumeClaimTemplates` field stamps out a dedicated PersistentVolumeClaim *per pod ordinal* — when `sqlserver-0` is rescheduled, Kubernetes reattaches the same PVC it had before, rather than provisioning a new empty one, which is precisely what a Deployment's shared pod template does not guarantee. The StatefulSet is also paired with a **headless Service** (`clusterIP: None`), which changes what its DNS lookup returns: instead of one virtual load-balanced IP, DNS returns each pod's individual address directly (`sqlserver-0.sqlserver.ecommerce.svc.cluster.local`), because load-balancing across database replicas the way you'd load-balance stateless web pods would be actively wrong — clients need to reach a *specific* pod, not "whichever one happens to answer."

It's worth repeating the project's own explicit warning here: this in-cluster SQL Server exists purely so you can run the whole stack for free on a local `kind`/`minikube` cluster while learning. It has one replica, no backups, and no real high availability. Real production traffic in this project's architecture is intended to hit a managed **Azure SQL Database** reached over a private endpoint (provisioned by Terraform, doc 09) — not this StatefulSet at all; `values-prod.yaml` in the Helm chart even sets `sql.enabled: false` for exactly this reason.

## PersistentVolumeClaims and StorageClasses, briefly

A **PersistentVolumeClaim (PVC)** is a request for storage — "give me 5Gi of ReadWriteOnce storage" — decoupled from the details of *how* that storage is actually provisioned. A **StorageClass** is what answers that request: it defines which underlying storage provisioner satisfies PVCs (on AKS, an Azure Disk; on a local `kind` cluster, typically a simple local-path provisioner), and Kubernetes dynamically creates a matching PersistentVolume to bind to the claim. This project's StatefulSet requests `accessModes: ["ReadWriteOnce"]` (meaning only one node can mount this volume for read/write at a time — normal for block storage backing a single-writer database) and doesn't hardcode a specific StorageClass, relying on whatever the cluster's default StorageClass provides.

## Ingress and Ingress Controllers: a rule is not an implementation

`k8s/base/ingress.yaml` defines routing rules for external HTTP traffic — but it's essential to understand that an `Ingress` object, by itself, does *nothing*. It is purely a declarative routing specification; something else, called an **Ingress Controller**, must actually be running in the cluster to read Ingress objects and program a real reverse proxy (or cloud load balancer) to implement them. This project's Ingress explicitly targets `ingressClassName: nginx`, meaning it expects the **NGINX Ingress Controller** to be installed — the file's own comment gives the install command (`helm upgrade --install ingress-nginx ...`) as a prerequisite, precisely because forgetting this step is a very common source of "my Ingress does nothing" confusion. Once installed, the controller watches all Ingress objects, and for this one:

```yaml
spec:
  ingressClassName: nginx
  rules:
    - host: ecommerce.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ecommerce-web
                port:
                  number: 80
```

it routes any request for host `ecommerce.local` to the `ecommerce-web` Service. Note this Ingress only ever knows about the frontend — `/api/` routing is deliberately *not* handled here at all; that responsibility lives entirely inside the frontend's own `nginx.conf` `proxy_pass`, keeping API routing logic in exactly one place rather than duplicated across the Ingress and the frontend's nginx config.

## Probes, tied back to `/health` vs `/health/live`

`api-deployment.yaml`'s readiness and liveness probes are the Kubernetes-side consumer of the two endpoints explained in doc 02:

```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 10
livenessProbe:
  httpGet:
    path: /health/live
    port: 8080
  initialDelaySeconds: 15
  periodSeconds: 15
```

A failing **readiness** probe (`/health`, which includes the DB check) removes the pod's IP from the `ecommerce-api` Service's endpoint list — traffic simply stops being routed to it — without touching the pod's lifecycle at all; it stays running, and rejoins rotation automatically the moment the probe passes again. A failing **liveness** probe (`/health/live`, process-only) instead causes the kubelet to kill and restart the container. Getting these swapped — pointing liveness at a DB-dependent endpoint — would mean a transient database outage causes Kubernetes to kill and restart every API pod simultaneously, which fixes nothing and can create a reconnection storm the moment the database does recover. `initialDelaySeconds` gives the container time to actually finish starting before probes begin counting failures against it at all.

## Resource requests vs. limits: OOMKilled vs. throttled

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "256Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"
```

A **request** is what the scheduler reserves for this container when deciding which node has room for it — it's a guaranteed floor, and it's also the denominator the HorizontalPodAutoscaler's percentage target is computed against (more below). A **limit** is a hard ceiling enforced directly by the kernel via cgroups. What happens when you exceed each is fundamentally different because CPU and memory behave differently at the kernel level: CPU is a *compressible* resource — a process can simply be given less CPU time and slowed down (throttled) without anything crashing. Memory is not compressible — you cannot "slow down" a memory allocation; once a container's actual memory usage exceeds its limit, the kernel's out-of-memory killer terminates the process outright, which Kubernetes reports as the container being **OOMKilled**. This is why there's no such thing as a "memory throttle" and why memory limits deserve more careful sizing than CPU limits — a slightly-too-low CPU limit costs you latency; a slightly-too-low memory limit crashes your pod.

## HorizontalPodAutoscaler: requirements, not just configuration

`k8s/base/hpa.yaml` defines an HPA targeting the API Deployment, scaling between 2 and 6 replicas based on 70% average CPU utilization. The file's own comments flag two hard prerequisites that are easy to miss: first, a **metrics-server** must be running in the cluster — it's the component that actually collects and exposes per-pod CPU/memory usage via the `metrics.k8s.io` API the HPA controller queries; without it, `kubectl get hpa` shows `<unknown>` under targets forever, silently doing nothing. Second, and more subtly, the target container **must have `resources.requests.cpu` set**, because "70% utilization" is explicitly 70% of the *requested* CPU, not of the node's total capacity and not of the configured limit — an HPA target with no request defined has no denominator to compute a percentage against and simply cannot function, regardless of how correctly the HPA object itself is configured.

## PodDisruptionBudget: protecting availability during planned disruptions

`k8s/overlays/prod/pdb.yaml` introduces a concept that only makes sense once you have multiple replicas on a multi-node cluster: the distinction between **involuntary disruptions** (a node's hardware fails — nothing you can budget for) and **voluntary disruptions** (a cluster admin runs `kubectl drain`, or AKS's own node-image auto-upgrade process drains nodes one at a time, or the cluster autoscaler scales down an underused node). A **PodDisruptionBudget (PDB)** puts a floor under voluntary disruptions only: `minAvailable: 2` here means the Kubernetes eviction API will refuse to evict a pod if doing so would drop the number of healthy, available pods matching that selector below 2. With prod's 3 replicas, this means a node drain can safely evict one API pod at a time, wait for a replacement to become ready elsewhere, and only then proceed — turning what could otherwise be a brief, unlucky window of reduced (or zero) capacity during routine maintenance into a guaranteed-safe, just slightly slower, rolling drain. This is deliberately absent from `k8s/base` and from the dev overlay: on a single-node local cluster there's no multi-node draining scenario to protect against in the first place.

## Kustomize: the problem it solves, and how this project uses it

Every environment needs slightly different values layered onto the same underlying application definition — different replica counts, different resource sizing, a different image tag, an extra prod-only resource like the PDB. The naive approach — maintaining a full separate copy of every YAML file per environment — means any shared change (say, adding a new environment variable) has to be manually, consistently repeated across every copy, and copies inevitably drift out of sync over time. **Kustomize** solves this without introducing a templating language at all (no `{{ }}` syntax, unlike Helm) — instead, you define one **base** (`k8s/base/`, the common, environment-agnostic definition) and one **overlay** per environment (`k8s/overlays/dev/`, `k8s/overlays/prod/`) that references the base and applies *patches* on top of it.

`k8s/overlays/dev/kustomization.yaml` shows the pattern:

```yaml
resources:
  - ../../base

images:
  - name: youracr.azurecr.io/ecommerce-api
    newTag: dev
  - name: youracr.azurecr.io/ecommerce-web
    newTag: dev

patchesStrategicMerge:
  - patch-api-replicas-resources.yaml
  - patch-web-replicas-resources.yaml

patches:
  - path: patch-hpa-dev.yaml
    target:
      group: autoscaling
      version: v2
      kind: HorizontalPodAutoscaler
      name: ecommerce-api-hpa
```

`resources: [../../base]` pulls in every manifest from the base directory unmodified as a starting point. `images:` is a Kustomize built-in transformer that rewrites the image tag on any container matching that repository name, wherever it appears in the base — a clean way to handle "dev uses a floating `:dev` tag, prod uses a pinned `:1.0.0`" without editing the Deployment YAML itself. `patchesStrategicMerge` applies **strategic merge patches** — partial YAML documents that Kustomize merges field-by-field onto the matching base resource (matched by apiVersion+kind+name); `k8s/overlays/dev/patch-api-replicas-resources.yaml` only specifies `replicas: 1` and smaller resource values, and every other field (probes, env vars, image name) passes through from base untouched. The separate `patches:` block uses a **JSON6902 patch** instead (`k8s/overlays/dev/patch-hpa-dev.yaml`), a more surgical, explicit-path style (`{op: replace, path: /spec/minReplicas, value: 1}`) — this project's own comment explains why: strategic-merge's rules for handling *list* fields (like the HPA's `metrics` array) can behave unpredictably when you only want to replace a couple of scalar fields (`minReplicas`/`maxReplicas`) without restating the whole list, so an explicit path-based operation is clearer and safer for that specific case.

The prod overlay follows the identical mechanism but pulls in an extra resource entirely absent from base (`pdb.yaml`) and pins the image tag to an explicit semantic version rather than a floating tag — a deliberate choice so that a production rollout is always a reviewed, intentional change to a specific version string in a pull request, not something that silently drifts because someone rebuilt and repushed whatever `latest` happens to mean today.

## Real commands you'll actually use

```bash
# Apply the entire dev environment (base + dev overlay patches) in one command
kubectl apply -k k8s/overlays/dev

# See what's running in the dedicated namespace
kubectl get pods -n ecommerce

# Tail logs from a specific pod (or use a label selector across all API pods)
kubectl logs -n ecommerce -l app.kubernetes.io/name=ecommerce-api -f

# Forward a local port to a pod/service for direct debugging, bypassing Ingress entirely
kubectl port-forward -n ecommerce svc/ecommerce-api 5000:8080
```

`kubectl apply -k <dir>` tells `kubectl` to run Kustomize's build process against that directory (resolving `resources:`, applying all patches) and apply the resulting fully-rendered manifests — you never manually run a separate "kustomize build" step for normal use. `kubectl logs -l ...` uses a label selector rather than a specific pod name, which is useful because Deployment-managed pod names include a random suffix that changes on every rollout. `kubectl port-forward` opens a temporary, authenticated tunnel from your local machine directly to a Service or pod inside the cluster — invaluable for debugging the API directly without going through the Ingress/frontend path at all.

## Key terms

- **ReplicaSet**: the controller responsible for maintaining a specific count of pods matching a label selector; managed indirectly through a Deployment, which adds rolling-update behavior on top.
- **ClusterIP**: the default Kubernetes Service type, reachable only from inside the cluster.
- **CoreDNS**: the cluster's internal DNS server, which automatically creates a resolvable DNS name for every Service.
- **Headless Service**: a Service with `clusterIP: None`, used with StatefulSets to return individual pod DNS records instead of one load-balanced virtual IP.
- **Ingress Controller**: the actual software (e.g., NGINX Ingress) that reads Ingress objects and implements their routing rules; an Ingress object alone does nothing without one installed.
- **OOMKilled**: the state reported when a container is terminated by the kernel's out-of-memory killer for exceeding its memory limit — there is no equivalent "kill" for exceeding a CPU limit, only throttling.
- **PodDisruptionBudget (PDB)**: a policy that limits how many pods matching a selector can be voluntarily evicted at once, protecting availability during node drains and cluster upgrades.
- **Strategic merge patch vs. JSON6902**: two Kustomize patch styles — strategic merge intelligently merges partial YAML field-by-field onto a base resource; JSON6902 issues explicit, unambiguous operations against exact document paths, useful for precise edits to list-shaped fields.
