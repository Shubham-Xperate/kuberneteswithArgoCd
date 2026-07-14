# 15 — End-to-End Runbook

This doc ties every previous one together into a single, ordered, hands-on sequence. It's written to actually be followed, not just read — each phase builds on the previous one, and the first three phases cost nothing and touch nothing outside your own laptop. Phase 4 is the first point where anything real/paid happens, and it's clearly marked. Every command below references the concepts and files explained in detail in docs 01–14; this doc deliberately doesn't re-explain *why* each piece works, only *what to run and in what order*.

## Phase 1 — Run locally with Docker Compose

The goal here is the same one `docker-compose.yml`'s own header comment states directly: confirm the app works in containers at all, using the same images that will eventually run in Kubernetes, before any orchestration layer is involved. Full detail on this file is in doc 05.

1. From the project root, create a `.env` file (or export the variable directly) providing a SQL Server `sa` password, since `docker-compose.yml` requires it and refuses to start without one:
   ```bash
   echo "SA_PASSWORD=Str0ngP@ssw0rd!" > .env
   ```
2. Build and start the whole stack:
   ```bash
   docker compose up --build
   ```
3. Wait for the SQL Server healthcheck to pass (Compose won't start the API until it does — see the `depends_on: condition: service_healthy` wiring in `docker-compose.yml`, covered in doc 05).
4. Open the app in a browser at `http://localhost` (or whatever port the web service maps to in the real file) and confirm the frontend loads and can reach the API.
5. Tear down when finished:
   ```bash
   docker compose down          # keeps the named SQL volume
   docker compose down -v       # also deletes the SQL volume (fresh DB next time)
   ```

## Phase 2 — Practice Kubernetes locally with kind

This phase exercises everything in docs 06 and 07 — real Kubernetes objects, a real Helm install — without needing any cloud account at all. **kind** ("Kubernetes IN Docker") runs an actual, real Kubernetes cluster with each "node" as a Docker container on your own machine — genuinely real Kubernetes, not a simulation, just packaged to run entirely locally.

1. Install kind and `kubectl` if you don't already have them (via your OS package manager, or kind's own install docs), then create a cluster:
   ```bash
   kind create cluster --name ecommerce-lab
   ```
2. Install the NGINX Ingress Controller — required because, per `helm/ecommerce-chart/templates/NOTES.txt`, it is deliberately **not** part of this project's own Helm chart (the chart only creates an `Ingress` resource; something else has to actually implement ingress routing):
   ```bash
   helm upgrade --install ingress-nginx ingress-nginx \
     --repo https://kubernetes.github.io/ingress-nginx \
     --namespace ingress-nginx --create-namespace
   ```
3. Install `metrics-server` — required for the HPA (doc 06/07) to have any real CPU data to scale on; without it, `kubectl get hpa` shows `<unknown>` under `TARGETS` forever, per the chart's own NOTES.txt warning:
   ```bash
   helm upgrade --install metrics-server metrics-server \
     --repo https://kubernetes-sigs.github.io/metrics-server \
     --namespace kube-system \
     --set args={--kubelet-insecure-tls}   # kind's self-signed kubelet certs need this flag locally
   ```
4. Build the API and web images locally, then load them directly into kind's nodes — kind clusters can't pull from your local Docker daemon's image cache the way a normal `docker run` would, so images have to be explicitly loaded in:
   ```bash
   docker build -t ecommerce-api:local ./backend
   docker build -t ecommerce-web:local ./frontend
   kind load docker-image ecommerce-api:local --name ecommerce-lab
   kind load docker-image ecommerce-web:local --name ecommerce-lab
   ```
5. Deploy using either path covered in docs 06/07 — Kustomize's dev overlay:
   ```bash
   kubectl apply -k k8s/overlays/dev
   ```
   or the Helm chart (pick one, not both, to avoid two competing sets of resources in the same namespace):
   ```bash
   helm install ecommerce ./helm/ecommerce-chart \
     -f helm/ecommerce-chart/values.yaml \
     -f helm/ecommerce-chart/values-dev.yaml \
     --set api.image.repository=ecommerce-api --set api.image.tag=local \
     --set web.image.repository=ecommerce-web --set web.image.tag=local \
     -n ecommerce --create-namespace
   ```
6. Verify everything came up:
   ```bash
   kubectl get pods -n ecommerce -w
   kubectl get svc -n ecommerce
   kubectl get ingress -n ecommerce
   ```
7. Add the Ingress host to your machine's hosts file (per NOTES.txt: `127.0.0.1` for most kind setups) so the hostname the Ingress rule expects actually resolves:
   ```
   127.0.0.1  ecommerce.local
   ```
   (`C:\Windows\System32\drivers\etc\hosts` on Windows, `/etc/hosts` on Linux/Mac.)
8. Browse to `http://ecommerce.local` and confirm the full path — Ingress, Service, Pod — actually works end to end.

## Phase 3 — Install ArgoCD locally in the same kind cluster

This phase makes doc 08's concepts concrete without needing real AKS or a real Git remote (you can point ArgoCD's `repoURL` fields at a local Git server, a GitHub fork of this project, or leave the manifests applied manually to see ArgoCD's status reporting even without live sync working end to end).

1. Install ArgoCD into its own namespace, using its published install manifests:
   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```
2. Wait for ArgoCD's own pods to become ready:
   ```bash
   kubectl get pods -n argocd -w
   ```
3. Apply this project's `AppProject` and root Application — the one-time bootstrap step described in doc 08 (first update the placeholder `repoURL` values in `argocd/project.yaml`, `argocd/root-app.yaml`, and the two files under `argocd/apps/` to point at your own fork's real URL, or this step will fail to actually fetch anything):
   ```bash
   kubectl apply -f argocd/project.yaml
   kubectl apply -f argocd/root-app.yaml
   ```
4. Confirm the app-of-apps pattern worked — the root Application should have created the two child Applications automatically:
   ```bash
   kubectl get applications -n argocd
   ```
5. Reach the ArgoCD UI (and API) by port-forwarding its server Service, since it has no external IP by default:
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   ```
   then open `https://localhost:8080` in a browser (accept the self-signed cert warning). Retrieve the initial admin password:
   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
   ```
6. Log in (`admin` / the password above) and confirm `ecommerce-dev` and `ecommerce-prod` both appear, with sync/health status visible — this is `argocd app get` territory from doc 08, viewable either via UI or CLI.

## Phase 4 — Real Azure (this phase costs real money)

Everything before this point runs entirely on your own machine at no cost. This phase is the first one that provisions billable Azure resources — read doc 09 in full before running any of it, and remember to tear resources down (`terraform destroy`) when you're done experimenting if cost matters to you.

1. Authenticate the Azure CLI, which Terraform's `azurerm` provider reuses automatically:
   ```bash
   az login
   az account set --subscription "<your-subscription-id>"
   ```
2. Starting with **dev** (never prod first): copy the example tfvars and fill in real values.
   ```bash
   cd terraform/environments/dev
   cp terraform.tfvars.example terraform.tfvars
   # edit terraform.tfvars: project, location, node pool sizes, etc.
   ```
3. Initialize, plan, and apply — reading the plan output carefully before confirming, per doc 09's discipline:
   ```bash
   terraform init
   terraform plan -var-file=terraform.tfvars
   terraform apply -var-file=terraform.tfvars
   ```
4. Fetch cluster credentials so `kubectl`/`helm`/`argocd` can reach the real AKS cluster:
   ```bash
   az aks get-credentials --resource-group rg-ecom-dev --name aks-ecom-dev
   ```
5. In Azure DevOps: create the ACR service connection and, if you split `gitops/` into a genuinely separate repository (per `gitops/README.md`), set up whatever Git-type service connection or PAT that requires — both covered in `.azuredevops/README.md` and doc 13. Also create the `production` Environment with an Approvals check under Pipelines > Environments, since this can't be done from YAML.
6. Push this project (with real `repoURL` values filled into the ArgoCD manifests) to your Azure DevOps/GitHub repo, and run the pipeline — either by pushing to `main` or triggering it manually the first time.
7. Repeat the ArgoCD install from Phase 3 against this real AKS cluster instead of kind, pointing `argocd/root-app.yaml` and the child Applications at your real repo URL, and confirm `ecommerce-dev` syncs successfully end to end — image built and pushed to real ACR, tag bumped in real `gitops/apps/ecommerce-dev/values.yaml`, ArgoCD syncing the real cluster.
8. Repeat steps 2–4 for the `prod` environment directory once dev is validated, using prod's own `terraform.tfvars.example` as the starting point.

## Phase 5 — Promote to production

With both environments provisioned and the pipeline wired up, promoting a specific build to prod follows the flow doc 08 and doc 13 describe in full: after a change has merged to `main`, built, and already auto-deployed to dev, an authorized approver goes to the pipeline run in Azure DevOps and approves the `production` Environment gate on the `Update_GitOps_Prod` stage. That approval lets the stage bump `gitops/apps/ecommerce-prod/values.yaml` and commit — but, because `argocd/apps/ecommerce-prod-app.yaml` has no `automated` sync policy, the cluster itself doesn't move yet. The final, separate, deliberate step is either:
```bash
argocd app sync ecommerce-prod
```
from the CLI (authenticated against the real ArgoCD instance, same port-forward approach as Phase 3), or clicking "Sync" on `ecommerce-prod` in the ArgoCD UI. Only after this second action does the new build actually roll out to production.

## Troubleshooting

| Symptom | Likely cause | Where to check |
|---|---|---|
| Pods stuck in `ImagePullBackOff` / `ErrImagePull` | AKS's kubelet identity lacks `AcrPull` on the registry, or the image repository/tag in `values.yaml` is wrong | `kubectl describe pod <pod> -n ecommerce` for the exact error; verify the `azurerm_role_assignment.aks_acr_pull` in `terraform/modules/aks/main.tf` was actually applied (doc 11) |
| Pods stuck in `Pending` | Requested CPU/memory in `resources.requests` exceeds what any node has free; cluster autoscaler hasn't added a node yet, or is already at `max_count` | `kubectl describe pod <pod> -n ecommerce` (look for a scheduling failure event); `kubectl top nodes`; check `max_count` on the relevant node pool (doc 12) |
| ArgoCD Application shows `OutOfSync` forever, never resolves | `syncPolicy.automated` missing (expected/correct for prod — needs a manual `argocd app sync`), or ArgoCD's Git polling interval/webhook isn't actually detecting new commits | `argocd app get <app-name>` for the diff; confirm which commit ArgoCD last saw vs. the real HEAD of the watched path (doc 08) |
| Ingress returns `502 Bad Gateway` | The Ingress's backend Service selector doesn't match any Pod's labels, so there are zero healthy endpoints behind it | `kubectl get endpoints <service-name> -n ecommerce` (empty means no matching pods); compare the Service's `selector` against the Pod template's `labels` (doc 06) |
| `helm install`/`upgrade` succeeds but HPA shows `<unknown>` under `TARGETS` | `metrics-server` isn't installed in the cluster, so the HPA has no CPU data to act on | `kubectl get pods -n kube-system \| grep metrics-server`; install per Phase 2 step 3 (doc 06/12) |
| Application Gateway shows an unhealthy/failed provisioning state | Missing `GatewayManager`/`AzureLoadBalancer` NSG allow rules on `snet-appgw` | Check the `nsg-*-appgw` NSG's rules against `terraform/modules/networking/main.tf` (doc 10) |
| AKS node can't pull from ACR even though role assignment looks correct | DNS isn't resolving `<registry>.azurecr.io` to the private endpoint's IP — Private DNS Zone not linked to the VNet, or a role-assignment propagation delay | `nslookup <registry>.azurecr.io` from inside a pod; confirm `azurerm_private_dns_zone_virtual_network_link` exists and links the right VNet (doc 10/11) |
