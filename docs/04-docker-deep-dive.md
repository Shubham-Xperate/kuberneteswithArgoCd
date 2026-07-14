# 04 — Docker Deep Dive

## What a container actually is

A container is not a lightweight virtual machine, even though it's often explained that way for convenience. A **virtual machine** virtualizes hardware: a hypervisor emulates an entire computer, including its own kernel, booting an entire independent operating system on top of the host's. A **container**, by contrast, runs as an ordinary process on the *host machine's own kernel*, made to look isolated using two Linux kernel features: **namespaces**, which give a process its own private view of things like the filesystem, process list, network interfaces, and hostname (so a process inside a container sees itself as PID 1 with its own `/`, even though the host sees it as just another PID with a mapped root), and **cgroups** (control groups), which let the kernel cap and account for how much CPU, memory, and I/O that process (and its children) is allowed to consume. The practical upshot: containers start in milliseconds (no OS boot), share the host kernel (no duplicated OS overhead), and are far denser per machine than VMs — but they also cannot run a different kernel than the host, which is why, for example, you cannot run a Windows container on a Linux kernel without a compatibility layer.

## Images, containers, and layers

A **Docker image** is a read-only template: a stack of filesystem **layers**, each one representing the filesystem changes introduced by a single instruction in a Dockerfile (roughly — modern BuildKit can combine some steps, but conceptually each `RUN`, `COPY`, etc. produces a layer). A **container** is a running (or stopped) *instance* of an image, with one additional writable layer stacked on top where any runtime changes go — the underlying image layers themselves are never modified, which is what lets many containers share the same underlying image layers on disk without duplicating that data. This layering is also the basis of Docker's build cache: if an instruction and everything preceding it in the Dockerfile are unchanged since the last build, Docker reuses the previously-built layer instead of re-executing that instruction.

## Multi-stage builds: the real backend Dockerfile

`backend/Dockerfile` in this project is a clean example of a **multi-stage build** — a Dockerfile containing more than one `FROM` instruction, where later stages can selectively copy artifacts out of earlier ones, and only the *final* stage's layers end up in the image you actually ship:

```dockerfile
# syntax=docker/dockerfile:1

# ---- Stage 1: build/publish using the full SDK image ----
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

COPY src/ECommerce.Api/ECommerce.Api.csproj src/ECommerce.Api/
RUN dotnet restore src/ECommerce.Api/ECommerce.Api.csproj

COPY src/ECommerce.Api/ src/ECommerce.Api/
RUN dotnet publish src/ECommerce.Api/ECommerce.Api.csproj \
    -c Release -o /app/publish --no-restore

# ---- Stage 2: runtime image — only the ASP.NET Core runtime ----
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
WORKDIR /app

RUN groupadd -r appgroup && useradd -r -g appgroup appuser
COPY --from=build /app/publish .

EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080

RUN chown -R appuser:appgroup /app
USER appuser

ENTRYPOINT ["dotnet", "ECommerce.Api.dll"]
```

Stage 1 (`AS build`) starts from `mcr.microsoft.com/dotnet/sdk:8.0` — the full .NET SDK image, which bundles the compiler (Roslyn), the NuGet package manager, MSBuild, and every tool needed to *build* a .NET project. That image is large (several hundred MB) precisely because a compiler and build toolchain need to be there. Stage 2 (`AS final`) starts fresh from `mcr.microsoft.com/dotnet/aspnet:8.0`, the much smaller ASP.NET Core *runtime-only* image — it can execute an already-compiled `.dll`, but it has no compiler, no MSBuild, none of the SDK's tooling. The line `COPY --from=build /app/publish .` is the entire point of the pattern: it reaches into the first stage's filesystem and copies out only the compiled output (`/app/publish`, produced by `dotnet publish`), while every other file and layer from the `build` stage — the SDK itself, restored NuGet packages, intermediate object files — is discarded and never becomes part of the final image at all.

The reason this matters in production is twofold. First, size: a smaller final image pulls faster onto every new Kubernetes node and every pod restart, which directly affects how quickly you can scale out or recover from a failure. Second, and more importantly, attack surface: shipping a full SDK (a compiler, in particular) into a running production container is a real security liability — if an attacker ever achieves code execution inside that container, having a compiler and build tools available makes it dramatically easier for them to build and run additional malicious tooling on the spot. The runtime-only image simply doesn't have those tools to abuse.

## Layer caching, and why `COPY *.csproj` happens before `COPY . .`

Look again at the ordering inside the build stage:

```dockerfile
COPY src/ECommerce.Api/ECommerce.Api.csproj src/ECommerce.Api/
RUN dotnet restore src/ECommerce.Api/ECommerce.Api.csproj

COPY src/ECommerce.Api/ src/ECommerce.Api/
RUN dotnet publish src/ECommerce.Api/ECommerce.Api.csproj -c Release -o /app/publish --no-restore
```

The frontend Dockerfile follows the identical principle: `COPY package*.json ./` then `RUN npm ci`, only afterward `COPY . .`. Docker's build cache works layer-by-layer, top to bottom: it hashes each instruction (and, for `COPY`, the actual contents of the files being copied) and reuses the cached result of a previous build *as long as nothing has changed up to and including that instruction*. The moment one instruction's inputs change, that layer is invalidated, and — critically — every layer after it is invalidated too, even if their own inputs didn't change, because Docker can't know that without re-running them.

`dotnet restore` (or `npm ci`) is usually the slowest step in the whole build — it downloads every dependency from the internet. If the Dockerfile copied the entire source tree first and *then* ran restore, then editing even a single line in a controller file (which touches nothing dependency-related) would invalidate the "copy everything" layer, which would invalidate the restore layer right after it, forcing a full dependency re-download on every single build — even though the actual dependency list (`.csproj`/`package.json`) never changed. By copying *only* the manifest file (`.csproj` or `package*.json`) first, that layer's cache key is based solely on the dependency manifest's contents. As long as you haven't added or upgraded a package, that `COPY` and the following `restore`/`npm ci` layer stay cached and are skipped entirely on subsequent builds, no matter how much application source code changes — only the later `COPY . .` (source code) layer and everything after it gets rebuilt. This ordering is a deliberate, load-bearing pattern, not an arbitrary style choice, and it's the single biggest lever for keeping iterative Docker builds fast.

## Running as non-root: `USER appuser`

Both Dockerfiles take care to ensure the container process does not run as the root user. In `backend/Dockerfile`:

```dockerfile
RUN groupadd -r appgroup && useradd -r -g appgroup appuser
COPY --from=build /app/publish .
...
RUN chown -R appuser:appgroup /app
USER appuser
```

By default, a container process runs as UID 0 (root) *inside the container's namespace* unless told otherwise. That sounds contained, but it's a meaningfully weaker security boundary than it appears: several known container-escape techniques, misconfigurations, and kernel vulnerabilities are specifically easier to exploit from a root process inside a container than from an unprivileged one, because root inside a namespace still carries capabilities that can, under the right conditions, be leveraged against the host. Creating a dedicated `appuser`/`appgroup`, copying application files in as root but then `chown`-ing them and switching to that unprivileged user via `USER appuser` before the container actually runs the app, means that even a fully compromised application process is confined to whatever a normal unprivileged user could do — a meaningfully smaller blast radius. This local choice is also what makes it *possible* for the Kubernetes manifests later (doc 06) to enforce `securityContext: { runAsNonRoot: true }` at the pod level; that Kubernetes setting causes the kubelet to flatly refuse to start any container whose image tries to run as root, so the image and the cluster policy have to agree — this Dockerfile is what makes that agreement true.

## Base image selection: alpine vs. full images

The frontend build uses `node:20-alpine` for its build stage and `nginx:1.27-alpine` for the final runtime stage. **Alpine Linux** is a minimal Linux distribution built around `musl libc` and BusyBox instead of the glibc/GNU userland most distros use, producing base images that are often 5–10x smaller than their "full" (Debian/Ubuntu-based) equivalents. The tradeoff is real, not free: Alpine's `musl` libc has subtly different behavior from glibc in some edge cases (rare, but occasionally trips up native Node addons compiled against glibc assumptions), and Alpine's minimalism means common debugging tools (`bash`, `curl`, various diagnostic utilities) often aren't present by default, which can make interactively debugging inside a running Alpine container more awkward than a full Debian-based image. For this project's use cases — building a static Angular bundle with well-established, pure-JS tooling, and serving static files with nginx — those risks are minimal, and the size/attack-surface benefit (fewer packages installed means fewer potential CVEs to track and patch) is a clear win, which is why both frontend stages choose the `-alpine` variants deliberately. The backend Dockerfile, by contrast, uses the full (non-Alpine) `mcr.microsoft.com/dotnet/sdk:8.0` and `mcr.microsoft.com/dotnet/aspnet:8.0` images rather than their `-alpine` variants — .NET's own Alpine images exist and do work, but the full Debian-based Microsoft images are the more battle-tested, broadly-compatible default for .NET workloads, and this project's inline comments prioritize the multi-stage split (SDK vs. runtime) as the primary size/security lever for the backend rather than also switching distros.

## `.dockerignore`: keeping the build context small and clean

Both `backend/.dockerignore` and `frontend/.dockerignore` exist to exclude files from the **build context** — the set of files Docker actually sends to the daemon when you run `docker build`. The backend's:

```
**/bin/
**/obj/
**/.vs/
**/.vscode/
**/.git/
**/.gitignore
**/*.user
**/*.suo
**/Migrations/*.db
**/node_modules/
**/*.md
**/.dockerignore
**/Dockerfile
```

and the frontend's excludes `node_modules`, `dist`, `.git`, and similar. Without this file, `COPY . .` would happily copy your entire local `.git` history, IDE settings, and — worst of all — locally compiled `bin`/`obj` folders or a local `node_modules` directory straight into the image, which is both wasteful (bloats the build context and the image) and actively dangerous: a locally-built `bin`/`obj` folder built on your machine's OS/architecture could silently get copied over top of what `dotnet publish` produces inside the container, or a `node_modules` built for your host OS could conflict with one `npm ci` installs for Linux inside the container. `.dockerignore` uses the same glob syntax as `.gitignore` and is evaluated before the build context is even sent to the Docker daemon, so excluded files never enter the image-building process at all.

## The container port contract: `EXPOSE` is documentation, not enforcement

Both Dockerfiles declare a port: `EXPOSE 8080` for the API, `EXPOSE 80` for the web frontend (implicit via the base nginx image, which already declares this). It's important to understand precisely what `EXPOSE` does and does not do: it does **not** open, publish, or forward any network port by itself — a container's `EXPOSE`d ports are not reachable from outside the container unless you separately publish them (`docker run -p host:container`) or, in Kubernetes, define a Service pointing at that `containerPort`. `EXPOSE` is purely metadata/documentation embedded in the image, readable via `docker inspect`, telling anyone running the image which port the application inside actually listens on. The *actual* contract that matters is whatever port the application process itself binds to — for the API, that's set explicitly via `ENV ASPNETCORE_URLS=http://+:8080` in the Dockerfile, which is what makes ASP.NET Core actually bind to `0.0.0.0:8080` inside the container. This project treats 8080 (API) and 80 (web/nginx default) as a hard contract precisely because other files depend on it externally: the frontend's `nginx.conf` hardcodes `proxy_pass http://ecommerce-api:8080`, and the Kubernetes Service/Deployment manifests in `k8s/base/` set `containerPort: 8080` / `targetPort: 8080` to match — if the application inside the container ever bound to a different port than what `EXPOSE` claims and the Service/proxy config expects, everything downstream would silently fail to connect, since nothing enforces that these numbers actually agree except careful, consistent authoring.

## Building and running these images directly

To build and run the API image standalone, from the `backend/` directory:

```bash
docker build -t ecommerce-api:local .
docker run -d --name ecommerce-api \
  -p 5000:8080 \
  -e ASPNETCORE_ENVIRONMENT=Development \
  -e ConnectionStrings__DefaultConnection="Server=host.docker.internal,1433;Database=ECommerceDb;User Id=sa;Password=YourStrong!Passw0rd;TrustServerCertificate=True;" \
  -e Jwt__Key="a-local-testing-secret-key-32-characters-min" \
  ecommerce-api:local
```

`-p 5000:8080` publishes the container's internal port 8080 to port 5000 on your host machine — this is the piece `EXPOSE` alone never does. `-e` flags inject environment variables, using the same double-underscore configuration binding convention explained in doc 02. For the frontend, from `frontend/`:

```bash
docker build -t ecommerce-web:local .
docker run -d --name ecommerce-web -p 4200:80 -e API_URL=http://localhost:5000 ecommerce-web:local
```

Here `API_URL` drives the runtime-config mechanism from doc 03 — `docker-entrypoint.sh` rewrites `assets/env.js` with this value before nginx starts serving.

## Key terms

- **Namespace (Linux kernel)**: a mechanism giving a process its own isolated view of a resource (filesystem, network, process list), the core primitive containers use for isolation.
- **cgroup (control group)**: a Linux kernel mechanism for limiting and accounting for a process's resource usage (CPU, memory, I/O).
- **Multi-stage build**: a Dockerfile with multiple `FROM` instructions, where later stages selectively copy artifacts from earlier ones, discarding everything else — used to keep build tooling out of the final shipped image.
- **Build context**: the set of files sent to the Docker daemon when a build starts; `.dockerignore` excludes files from it.
- **Layer cache invalidation**: once one Dockerfile instruction's cache is invalidated (its inputs changed), every subsequent instruction's layer is rebuilt too, regardless of whether their own inputs changed.
- **`EXPOSE`**: Dockerfile metadata documenting which port a container's application listens on; it does not itself publish or open that port to any network.
