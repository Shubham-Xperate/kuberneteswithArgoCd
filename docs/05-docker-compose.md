# 05 — Docker Compose

## The problem Compose solves

A single `docker run` command with all the flags a real service needs — port mappings, environment variables, a named network, a healthcheck, a restart policy — gets long and unwieldy fast, and this project needs *three* such containers (SQL Server, the API, the web frontend) started together, on a shared network, in a specific order, every single time you want to test the app locally. Retyping (or even remembering) three long `docker run` commands, in the right sequence, every session, is exactly the kind of manual, error-prone process this whole project is trying to eliminate at every layer. **Docker Compose** solves this by letting you describe an entire multi-container application — its services, networks, volumes, and how they relate — in one declarative YAML file, then bring the whole thing up or down with a single command: `docker compose up` / `docker compose down`.

## Reading the real `docker-compose.yml`

The project root's `docker-compose.yml` defines exactly three services, and its own comments explain the intent clearly:

```yaml
version: "3.9"

services:
  sqlserver:
    image: mcr.microsoft.com/mssql/server:2022-latest
    container_name: ecommerce-sqlserver
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: "${SA_PASSWORD:?set SA_PASSWORD in .env}"
      MSSQL_PID: "Developer"
    ports:
      - "1433:1433"
    volumes:
      - sqlserver-data:/var/opt/mssql
    healthcheck:
      test: ["CMD-SHELL", "/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P \"$$MSSQL_SA_PASSWORD\" -Q 'SELECT 1' || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    networks:
      - ecommerce-net

  ecommerce-api:
    build:
      context: ./backend
      dockerfile: Dockerfile
    container_name: ecommerce-api
    depends_on:
      sqlserver:
        condition: service_healthy
    environment:
      ASPNETCORE_ENVIRONMENT: "Development"
      ConnectionStrings__DefaultConnection: "Server=sqlserver,1433;Database=ECommerceDb;User Id=sa;Password=${SA_PASSWORD};TrustServerCertificate=True;"
      Jwt__Key: "${JWT_KEY:?set JWT_KEY in .env (min 32 chars)}"
      Jwt__Issuer: "ecommerce-local"
      Jwt__Audience: "ecommerce-local-clients"
      Cors__AllowedOrigin: "http://localhost:4200"
    ports:
      - "5000:8080"
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:8080/health/live"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s
    networks:
      - ecommerce-net

  ecommerce-web:
    build:
      context: ./frontend
      dockerfile: Dockerfile
    container_name: ecommerce-web
    depends_on:
      - ecommerce-api
    environment:
      API_URL: "/api"
    ports:
      - "4200:80"
    networks:
      - ecommerce-net

networks:
  ecommerce-net:
    driver: bridge

volumes:
  sqlserver-data:
```

`services:` is the top-level list of containers Compose manages; each key (`sqlserver`, `ecommerce-api`, `ecommerce-web`) is a service name. `build: { context: ./backend, dockerfile: Dockerfile }` tells Compose to build the image from that Dockerfile rather than pull a pre-built one (the SQL Server service instead uses a plain prebuilt `image:` reference, since there's no need to build a custom SQL Server image).

## Networks, and why service names matter

`networks: { ecommerce-net: { driver: bridge } }` creates a private **bridge network** — an isolated virtual network that only the containers attached to it can communicate over. Every service in this file lists `networks: [ecommerce-net]`, which does two things: it isolates this stack from other unrelated containers that might be running on your machine, and — the more important part — it gives every attached container automatic **DNS resolution by service name**. Inside this network, the string `sqlserver` resolves to the SQL Server container's IP address, and `ecommerce-api` resolves to the API container's IP address, entirely automatically, with no manual `/etc/hosts` editing or hardcoded IPs anywhere. This is exactly how the API's connection string can simply say `Server=sqlserver,1433;...` and have it work.

This project's `docker-compose.yml` is explicit about *why* the API service is named `ecommerce-api` rather than something shorter like `api`:

> Service names on the `ecommerce-net` network double as internal DNS names. The frontend's `nginx.conf` already hardcodes `"http://ecommerce-api:8080"` as its proxy target (that's the Kubernetes Service name it will use in-cluster) so the API service here is deliberately named `"ecommerce-api"` — this lets the exact same `nginx.conf` / image work unmodified in both Compose and K8s.

In other words, the naming isn't arbitrary or just for readability — it's chosen specifically so this project's *actual production Kubernetes Service* (documented in doc 06) has the identical name, meaning the exact same frontend Docker image, with its `nginx.conf` baked in unmodified, works correctly whether it's running under Compose locally or inside Kubernetes — DNS resolution "just works" identically in both environments because both environments happen to name the backend the same thing.

## `depends_on` with `condition: service_healthy`, and the race condition it prevents

Look closely at how `ecommerce-api` depends on `sqlserver`:

```yaml
depends_on:
  sqlserver:
    condition: service_healthy
```

Plain `depends_on: [sqlserver]` (without a condition) only controls **start order** — Compose would start the `sqlserver` container process first, then immediately start `ecommerce-api` right after, with no further waiting. That's a trap: a container being *started* is not the same as the service inside it being *ready to accept connections*. SQL Server, in particular, takes real time internally after its process launches — mounting data files, running startup checks — before it will actually accept a login. If the API container started immediately after the SQL Server *container* started (rather than after SQL Server was *actually ready*), the API's first connection attempt during `Program.cs`'s startup migration logic would very likely fail with a connection refused/timeout error, even though from Compose's point of view "everything started fine." This is a classic, extremely common race condition in multi-container local setups, and it often manifests as "works if I restart the API container a second time" — a strong hint that a plain `depends_on` without a health condition is the culprit.

`condition: service_healthy` fixes this properly: Compose will not start `ecommerce-api` until the `sqlserver` service's own `healthcheck` reports a healthy status, not merely until its process has launched. Notice the API service also defines its own `healthcheck`, and the web service's `depends_on: [ecommerce-api]` uses the plain (unconditioned) form — reasonable here since nginx doesn't have a similarly slow startup sequence and a moment's initial connection retry from the browser is harmless, whereas the database's slow-start problem is real and worth guarding against explicitly.

## Healthchecks explained

A `healthcheck:` block tells Docker how to determine whether a running container is actually working correctly, as opposed to merely "not crashed." The SQL Server healthcheck:

```yaml
healthcheck:
  test: ["CMD-SHELL", "/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P \"$$MSSQL_SA_PASSWORD\" -Q 'SELECT 1' || exit 1"]
  interval: 10s
  timeout: 5s
  retries: 10
  start_period: 30s
```

`test` is the actual command Docker runs *inside* the container on a schedule; here it attempts a real SQL login and a trivial `SELECT 1` query — the only way to know with certainty that SQL Server is truly accepting connections, since the process itself can be running for a while before its TDS listener is actually ready. `interval: 10s` means run this check every 10 seconds; `timeout: 5s` is how long a single check attempt is allowed to take before being considered failed; `retries: 10` is how many consecutive failures are tolerated before the container is marked `unhealthy`; `start_period: 30s` is a grace window immediately after container start during which failures don't count against the retry budget at all, acknowledging that a freshly-started SQL Server is *expected* to fail this check for a while before it's ready. The API's healthcheck (`wget --spider -q http://localhost:8080/health/live`) deliberately targets `/health/live`, not `/health` — the liveness endpoint from doc 02, since Compose's healthcheck here is really asking "is the API process itself up," matching the same readiness-vs-liveness reasoning covered there.

## Named volumes vs. bind mounts: `sqlserver-data`

```yaml
volumes:
  - sqlserver-data:/var/opt/mssql
...
volumes:
  sqlserver-data:
```

This is a **named volume** — Docker creates and manages a storage location (outside any specific container's writable layer, on the host, but in a location Docker itself controls) and mounts it at `/var/opt/mssql` inside the container, which is where SQL Server keeps its actual database files. Because the volume is a distinct object from the container, running `docker compose down` (which stops and removes the containers) leaves the volume — and therefore all your product/order/user data — intact; the next `docker compose up` reattaches the same volume and your data is exactly as you left it. Only `docker compose down -v` explicitly destroys volumes too. This is contrasted with a **bind mount**, which instead maps a specific path on your host filesystem directly into the container (e.g., `./local-folder:/var/opt/mssql`) — useful when you want to directly inspect or edit files from your host, but less appropriate here since you don't need to browse SQL Server's raw data files directly, and a named volume is more portable (it doesn't depend on a specific host directory structure) and is the pattern Docker itself recommends for "a service just needs somewhere persistent to write."

## Environment variables and the `.env` file

None of the sensitive values in `docker-compose.yml` are hardcoded. Instead, they're referenced as `${SA_PASSWORD}` and `${JWT_KEY}`, which Compose substitutes from a `.env` file sitting alongside `docker-compose.yml` (Compose loads this file automatically; you never need to `source` it manually). This project ships `.env.example` as a template:

```
SA_PASSWORD=YourStrong!Passw0rd
JWT_KEY=this-is-a-local-dev-only-secret-key-32-chars-min
```

with an explicit note that you copy it to `.env` (which is git-ignored) and fill in real local values — the actual `.env` file is never committed, so real secrets never enter source control even accidentally. Notice the syntax `${SA_PASSWORD:?set SA_PASSWORD in .env}` in the compose file itself: the `:?` operator makes Compose *fail loudly* with that exact error message if `SA_PASSWORD` isn't set at all, rather than silently starting SQL Server with an empty or undefined password — a deliberate guard against a confusing, hard-to-diagnose failure later.

It's worth being explicit about the limits of this pattern, because production does it differently (foreshadowing docs 06/07/13): a `.env` file is a fine, low-friction way to keep secrets out of a git-committed YAML file *for local development on a single trusted machine*, but it's still a plaintext file sitting on disk, with no access control, no audit log of who read it, and no rotation mechanism. In Kubernetes, secrets instead live as `Secret` objects (base64-encoded, access-controlled via RBAC, and in this project's real production path, ultimately backed by Azure Key Vault via the Secrets Store CSI Driver rather than ever being typed into a file by a human at all) — a categorically more auditable and rotatable mechanism than "a `.env` file on someone's laptop," which is the right tradeoff for a passing local dev convenience versus a hard production requirement.

## Running this project end to end, locally

From the project root:

```bash
cp .env.example .env
# then edit .env and set real local values for SA_PASSWORD and JWT_KEY

docker compose up --build
```

`--build` forces Compose to (re)build the `ecommerce-api` and `ecommerce-web` images from their Dockerfiles rather than trying to reuse a stale cached image — worth using any time you've changed backend or frontend source since the last run. Compose will start `sqlserver` first, wait for its healthcheck to pass, then start `ecommerce-api`, then `ecommerce-web`. Once everything is healthy, open a browser to `http://localhost:4200` for the Angular app (which, via nginx, proxies `/api/*` calls to the API container internally), or `http://localhost:5000/swagger` to hit the API's Swagger UI directly. To tear everything down: `docker compose down` (keeps the `sqlserver-data` volume, so your data survives) or `docker compose down -v` (also deletes the volume, for a completely fresh start).

## Key terms

- **Bridge network**: an isolated virtual network Docker creates for a set of containers, providing both network isolation from unrelated containers and automatic DNS resolution by container/service name.
- **Healthcheck**: a command Docker runs on a schedule inside a container to determine if the service inside is actually functioning, distinct from merely "the process hasn't crashed."
- **`depends_on: condition: service_healthy`**: a Compose directive that delays starting a dependent service until another service's healthcheck passes, preventing race conditions where a dependency's container has started but isn't yet ready to serve requests.
- **Named volume**: Docker-managed persistent storage, decoupled from any single container's lifecycle, so data survives container removal until the volume itself is explicitly deleted.
- **Bind mount**: a direct mapping of a host filesystem path into a container, as opposed to Docker-managed volume storage.
- **`.env` file**: a local, git-ignored file Compose automatically loads to substitute `${VAR}` references in `docker-compose.yml`, keeping secrets out of the committed YAML for local development.
