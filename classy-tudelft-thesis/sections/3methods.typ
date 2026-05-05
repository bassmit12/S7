// Chapter 3 — Infrastructure and Deployment

= Infrastructure and Deployment

== The Cluster

AbyssCore runs on a Kubernetes cluster managed by Fontys. This means no access to the control plane, no ability to install cluster-wide components without working around restrictions, and — most importantly — a TLS-intercepting proxy that intercepts all outbound HTTPS traffic.

That last point caused the most friction. Kubernetes pulls container images over HTTPS. When the proxy intercepts those connections, it replaces the TLS certificate with its own. Docker Hub, GitHub Container Registry, and Quay all use certificate pinning or expect specific certificates — so every image pull from an external registry fails with a TLS error.

The fix: mirror every image to GitHub Container Registry under the `bassmit12` organisation, and configure Kubernetes to pull from there using a `ghcr-secret` image pull secret. Any new image used in the cluster needs to be mirrored first. It's extra work, but it's a one-time cost per image and after that it's reliable.

== GitOps with ArgoCD

All Kubernetes manifests live in the AbyssCore GitHub repository under `infra/`. ArgoCD watches the repository and automatically applies changes when new commits land on `main`. There's no manual `kubectl apply` in the normal workflow — you push to git and ArgoCD handles the rest.

Three ArgoCD Applications manage the full stack:

- *abysscore* — the game itself: frontend, backend, gateway, Keycloak, RabbitMQ, PostgreSQL, Cloudflare Tunnel. Watches `infra/k8s/`.
- *monitoring* — the kube-prometheus-stack Helm chart. Deploys Prometheus, Alertmanager, Grafana, node-exporter, and kube-state-metrics. Sourced directly from the prometheus-community Helm repo.
- *monitoring-extras* — ServiceMonitors and other monitoring add-ons that live in git. Watches `infra/k8s/monitoring/`.

ArgoCD runs in its own namespace and is exposed publicly at `argocd.bassmit.dev` via Cloudflare Tunnel. It runs in insecure mode (no internal TLS) because the Cloudflare Tunnel handles TLS termination at the edge.

=== Self-Healing

One of the big benefits of GitOps is that the cluster will always converge back to what's in git. If someone manually edits a Deployment, ArgoCD will overwrite it on the next sync. This makes accidental drift impossible to sustain — the git repository is always the source of truth.

== Image Mirroring and CI/CD

=== The Problem

As described above, the Fontys proxy blocks external image pulls. But there's a second constraint: building and pushing images in CI also needs registry access. The solution is to use GitHub Actions to build images and push them to GHCR, then have Kubernetes pull from GHCR using a secret.

=== GitHub Actions Pipeline

The CI pipeline runs on every push to `main`. It has three parallel jobs:

- *Build Backend* — runs `encore build docker` to compile the Encore application and push it to `ghcr.io/bassmit12/abysscore-backend:latest`
- *Build Gateway* — builds the Go gateway with Docker Buildx and pushes to `ghcr.io/bassmit12/abysscore-gateway:latest`
- *Build Frontend* — builds the Next.js app with Docker Buildx and pushes to `ghcr.io/bassmit12/abysscore-frontend:latest`

Authentication uses a `GHCR_TOKEN` secret stored in GitHub Actions. The `GITHUB_TOKEN` built into Actions can't push to new packages, so a personal access token with `write:packages` scope is needed.

After images are pushed, ArgoCD picks up the change on the next sync cycle (every 3 minutes by default). There's no automatic image tag update in place yet — all Deployments use `latest`, so ArgoCD detects the change through the image digest rather than a tag change.

=== Environment Variables

The frontend needs to know the public URLs for the GraphQL gateway and Keycloak at build time, since Next.js bakes `NEXT_PUBLIC_*` variables into the static bundle. These are passed as build arguments in the GitHub Actions workflow and come from repository secrets:

- `NEXT_PUBLIC_GRAPHQL_URL` — `https://abysscore-api.bassmit.dev/graphql`
- `NEXT_PUBLIC_KEYCLOAK_URL` — `https://abysscore-auth.bassmit.dev`
- `NEXT_PUBLIC_KEYCLOAK_REALM` — `abysscore`
- `NEXT_PUBLIC_KEYCLOAK_CLIENT_ID` — `abysscore-frontend`

== Public Access via Cloudflare Tunnel

All five public endpoints route through a single `cloudflared` Deployment running two replicas. The tunnel is configured with a `config.yaml` that maps hostnames to internal Kubernetes services:

#table(
  columns: (auto, auto),
  [*Hostname*], [*Internal Service*],
  [`abysscore.bassmit.dev`], [`frontend:3000`],
  [`abysscore-api.bassmit.dev`], [`gateway:4001`],
  [`abysscore-auth.bassmit.dev`], [`keycloak:8080`],
  [`argocd.bassmit.dev`], [`argocd-server:80`],
  [`grafana.bassmit.dev`], [`kube-prometheus-stack-grafana:80`],
)

Cloudflare handles TLS for all public traffic. Inside the cluster, everything runs over plain HTTP — there's no internal certificate management to deal with.

== Resource Management

Every Deployment has resource requests and limits defined. This serves two purposes: it lets Kubernetes schedule pods onto nodes correctly, and it makes Grafana's resource utilisation dashboards actually work (without requests, the "% of limit" panels show no data).

Observed resource usage from Grafana:

#table(
  columns: (auto, auto, auto),
  [*Service*], [*CPU (typical)*], [*Memory (typical)*],
  [Keycloak], [variable], [~1.14 GiB],
  [RabbitMQ], [low], [~142 MiB],
  [PostgreSQL], [low], [~98 MiB],
  [Cloudflared], [low], [~22--27 MiB],
  [Frontend], [low], [~53 MiB],
  [Backend], [low], [~9--11 MiB],
  [Gateway], [low], [~8 MiB],
)

Keycloak dominates memory usage. At current traffic levels, everything else is well within its limits.

== Test and Production Environments

The current deployment runs a single environment on `main`. The logical next step is to split this into a proper test environment and a production environment, so that changes can be validated before they reach real users.

=== The Plan

The split follows a standard GitOps pattern: two branches, two namespaces, two sets of Cloudflare hostnames.

#table(
  columns: (auto, auto, auto),
  [*Environment*], [*Branch*], [*Namespace*],
  [Test], [`develop`], [`abysscore-test`],
  [Production], [`main`], [`abysscore`],
)

The `develop` branch is where all active work happens. Pull requests merge into `develop` first. Once a feature is tested and stable, it gets merged into `main` and goes live on production.

=== Image Tagging

GitHub Actions builds different image tags per environment:

- Push to `develop` → images tagged `:dev-<short-sha>` (e.g. `abysscore-backend:dev-a3f9c1`)
- Push to `main` → images tagged `:latest` and `:<sha>`

Using a unique tag per commit on `develop` means ArgoCD can detect new images reliably without relying on digest polling. Production keeps `:latest` for simplicity.

=== Kustomize Overlays

Rather than duplicating all manifests, the infra directory is restructured with Kustomize:

```
infra/k8s/
  base/          — shared manifests (Deployments, Services, ConfigMaps)
  overlays/
    test/         — patches: namespace, image tags, test hostnames
    prod/         — patches: namespace, prod hostnames, replicas
```

Each overlay patches only what differs between environments — the namespace, the image tag, and the Cloudflare hostnames. Everything else is inherited from `base/`.

=== ArgoCD Applications

Two ArgoCD Applications point at the two overlays:

- `abysscore-test` — watches the `develop` branch, applies `overlays/test/`, syncs to `abysscore-test` namespace
- `abysscore` — watches `main`, applies `overlays/prod/`, syncs to `abysscore` namespace (unchanged from current setup)

=== Cloudflare Hostnames

The test environment gets its own public URLs:

#table(
  columns: (auto, auto),
  [*Hostname*], [*Service*],
  [`test.abysscore.bassmit.dev`], [`frontend (test)`],
  [`test-api.abysscore.bassmit.dev`], [`gateway (test)`],
  [`test-auth.abysscore.bassmit.dev`], [`keycloak (test)`],
)

The tunnel config is extended to include these routes, all pointing at services in `abysscore-test`. Production hostnames remain unchanged.

=== Outcome

With this in place, the full workflow becomes:

+ Write code, push to `develop`
+ CI builds a `:dev-<sha>` image and pushes to GHCR
+ ArgoCD deploys it to the test environment automatically
+ Test at `test.abysscore.bassmit.dev`
+ Merge `develop` → `main` when ready
+ CI builds `:latest`, ArgoCD deploys to production

No manual steps, no risk of accidentally pushing broken code to prod.
