# ---------------------------------------------------------------------------
# Stage 1: build the Angular application
# ---------------------------------------------------------------------------
FROM node:20-alpine AS build

WORKDIR /app

# Copy only the manifest files first so Docker can cache the npm ci layer
# and skip re-downloading dependencies when only source files change.
COPY package*.json ./
RUN npm ci

# Now copy the rest of the source and build for production.
COPY . .
RUN npx ng build --configuration production

# NOTE: Angular 17's "application" builder (used in angular.json) emits
# output nested under dist/<project-name>/browser/, not directly under
# dist/<project-name>/. The outputPath in angular.json is "dist/ecommerce-web",
# so the actual static files land in /app/dist/ecommerce-web/browser.
# This MUST match the COPY --from=build path below.

# ---------------------------------------------------------------------------
# Stage 2: serve the compiled app with nginx
# ---------------------------------------------------------------------------
# nginx-unprivileged, not plain nginx: the official nginx image's master
# process starts as root (needed to bind port 80), then drops to a non-root
# worker -- incompatible with Kubernetes' runAsNonRoot: true, which refuses
# to even start a container whose image runs as root at all. This variant
# is pre-configured to run entirely as a non-root user on port 8080, so no
# privileged bind ever happens in the first place.
FROM nginxinc/nginx-unprivileged:1.27-alpine

# Remove the default nginx site config and replace it with ours, which
# adds SPA fallback routing and reverse-proxies /api/ to the backend.
RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy the compiled Angular app (browser output of the application builder).
# Explicit --chown to the image's built-in non-root "nginx" user: without
# this, COPY defaults to root ownership, and docker-entrypoint.sh (which
# runs as the non-root user at container start) would fail to write
# assets/env.js at startup.
COPY --from=build --chown=nginx:nginx /app/dist/ecommerce-web/browser /usr/share/nginx/html

# The entrypoint script regenerates assets/env.js from the API_URL env var
# at container startup, before nginx starts, implementing the runtime-config
# pattern (see docker-entrypoint.sh for details).
COPY --chown=nginx:nginx docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]