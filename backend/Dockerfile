# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage 1: build/publish using the full SDK image (contains compilers, NuGet,
# etc.) - this stage is much larger than the final image but never ships.
# ---------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

# Copy only the csproj first so Docker can cache the `dotnet restore` layer
# and skip re-downloading NuGet packages when only source code changes.
COPY src/ECommerce.Api/ECommerce.Api.csproj src/ECommerce.Api/
RUN dotnet restore src/ECommerce.Api/ECommerce.Api.csproj

# Now copy the rest of the source and publish a Release build.
COPY src/ECommerce.Api/ src/ECommerce.Api/
RUN dotnet publish src/ECommerce.Api/ECommerce.Api.csproj \
    -c Release \
    -o /app/publish \
    --no-restore

# ---------------------------------------------------------------------------
# Stage 2: runtime image - only the ASP.NET Core runtime, not the full SDK.
# Smaller image = smaller attack surface and faster pulls in Kubernetes.
# ---------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
WORKDIR /app

# Create a dedicated non-root user/group to run the app. Running as root
# inside a container is unnecessary privilege: if the process is compromised,
# a non-root user limits what it can do on the host/node, and it lets the
# Kubernetes Deployment enforce a restrictive securityContext
# (runAsNonRoot: true, allowPrivilegeEscalation: false, etc.).
#
# Explicit numeric --gid/--uid (rather than letting useradd pick the next
# free system UID) matters because Kubernetes' runAsNonRoot check has to
# verify the image's user is non-root WITHOUT running the container -- it
# can only do that by reading a numeric UID directly off the image's
# metadata. A named user (USER appuser with no fixed UID) can't be verified
# that way and kubelet refuses to start the container at all.
RUN groupadd -r appgroup --gid=999 && useradd -r -g appgroup --uid=999 appuser

COPY --from=build /app/publish .

# Container port contract: the app listens on 8080 (not 80/443). This must
# match the Service/Deployment definitions in the Helm chart.
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080

# Ensure the non-root user owns the app files, then switch to it.
RUN chown -R appuser:appgroup /app
USER appuser

ENTRYPOINT ["dotnet", "ECommerce.Api.dll"]
