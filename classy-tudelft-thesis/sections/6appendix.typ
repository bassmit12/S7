// Chapter 6 — Reflection and Future Work (Appendix)

= Reflection and Future Work

== What Went Well

*GitOps from the start.* Setting up ArgoCD early meant that every change to the cluster went through git. This made it easy to track what changed and when, and made it impossible to end up with an undocumented cluster state. When something broke, there was always a clear history of what had changed.

*Cloudflare Tunnel.* This turned out to be a much cleaner solution than expected. It handles TLS, proxying, and DNS all in one. Adding a new public endpoint is just a one-line change to the tunnel config in git and a DNS record in Cloudflare. No cert-manager, no ingress controller, no LoadBalancer service — the Fontys network constraints actually pushed toward a simpler architecture.

*Encore.go.* The framework did a lot of heavy lifting. Database migrations, inter-service calls, routing, and API generation are all handled automatically. For a project with seven backend services, this would have been weeks of boilerplate otherwise.

*Observability.* Getting Prometheus and Grafana running with real data showing for all pods took some work — especially the image mirroring — but it's genuinely useful. Being able to see CPU and memory trends for every pod makes debugging much faster.

== What Was Harder Than Expected

*The Fontys TLS proxy.* This wasn't mentioned anywhere in the documentation and took a while to diagnose. Every `ImagePullBackOff` error looked like a network issue, but the actual cause was the proxy intercepting the TLS connection to the image registry. Once the pattern was understood, the fix (mirror everything to GHCR) was straightforward, but it added friction to everything involving external images.

*ArgoCD multi-source applications.* The kube-prometheus-stack is installed from a Helm chart, but the values file lives in git. ArgoCD supports this as a multi-source Application but the configuration is not well documented and several attempts failed before finding the right format.

*CI infinite loop from manifest updates.* The `update-manifests` job commits back to `main` after every build. Without a guard, that commit triggers the workflow again — infinite loop. The fix is `paths-ignore: infra/k8s/**` on the workflow trigger, which is easy once you know it exists but took a few failed runs to diagnose.

*GitHub Actions authentication for GHCR.* The `GITHUB_TOKEN` that's built into GitHub Actions works for pushing to existing packages but fails with a 403 for new packages. This is a known limitation that's not prominently documented. The fix is a personal access token with `write:packages` scope stored as a secret (`GHCR_TOKEN`).

== What Changed from the Project Plan

The original project plan proposed an AI-powered monitoring system using Cilium and eBPF for anomaly detection in Kubernetes infrastructure. The shift to AbyssCore changed the focus from infrastructure research to application development and deployment.

The core skills are similar — Kubernetes, observability, GitOps — but the approach changed from studying existing tools to building and operating a real system. The result is more practical and more hands-on than the original plan, and covers more of the actual engineering challenges that come up when running real software on Kubernetes.

== Future Work

*Application metrics.* The backend and gateway don't expose `/metrics` endpoints yet. Adding Prometheus instrumentation to both would give visibility into request rates, latency, error rates, and game-specific counters. For Encore, this is a one-line config change.

*Custom Grafana dashboard.* A dashboard showing AbyssCore-specific data — active players, dungeons in progress, combat outcomes, queue depth — would make the observability much more meaningful.

*Alerting.* Alertmanager is deployed but not configured. Basic alerts for pod restarts, high memory usage, and service unavailability would make the setup more production-like.

*Log aggregation.* Loki would add log search and correlation with metrics. Currently logs are only available via `kubectl logs`, which has no retention and no search.

*HPA for backend and gateway.* As described in the scalability chapter, adding Horizontal Pod Autoscalers to both services is a natural next step and is straightforward to implement.

*Image Updater.* ArgoCD Image Updater can automatically update Deployment manifests when a new image is pushed to GHCR. This would close the loop on CI/CD — push code, image gets built and pushed, ArgoCD detects the new digest and rolls it out automatically.

= Appendix A — Kubernetes Manifest Overview <appendix-a>

All manifests live under `infra/k8s/` in the AbyssCore repository. The structure is flat — all core application manifests are in `infra/k8s/` and monitoring extras are in `infra/k8s/monitoring/`.

#table(
  columns: (auto, auto),
  [*File*], [*Contents*],
  [`backend.yaml`], [Deployment + Service for the Encore backend],
  [`frontend.yaml`], [Deployment + Service for the Next.js frontend],
  [`gateway.yaml`], [Deployment + Service for the GraphQL gateway],
  [`cloudflared.yaml`], [Deployment for Cloudflare Tunnel (2 replicas)],
  [`keycloak.yaml`], [Deployment + Service for Keycloak],
  [`rabbitmq.yaml`], [Deployment + Service for RabbitMQ],
  [`postgres.yaml`], [StatefulSet + Service for PostgreSQL],
  [`secrets.yaml`], [Kubernetes Secrets (GHCR pull secret, DB creds, etc.)],
  [`monitoring/kube-prometheus-values.yaml`], [Helm values for kube-prometheus-stack],
  [`monitoring/service-monitors.yaml`], [ServiceMonitors for backend, gateway, frontend],
)

= Appendix B — ArgoCD Application Definitions <appendix-b>

ArgoCD Applications are stored in `infra/argocd/`:

#table(
  columns: (auto, auto),
  [*File*], [*Manages*],
  [`abysscore-app.yaml`], [All game services from `infra/k8s/`],
  [`monitoring-app.yaml`], [kube-prometheus-stack Helm chart],
  [`monitoring-extras-app.yaml`], [ServiceMonitors from `infra/k8s/monitoring/`],
)

= Appendix C — CI/CD Pipeline Summary <appendix-c>

The GitHub Actions workflow (`.github/workflows/build-push.yml`) runs three parallel build jobs on every push to `main` (excluding changes to `infra/k8s/`):

#table(
  columns: (auto, auto, auto),
  [*Job*], [*Registry Target*], [*Build Tool*],
  [Build Backend], [`ghcr.io/bassmit12/abysscore-backend:<sha>`], [`encore build docker`],
  [Build Gateway], [`ghcr.io/bassmit12/abysscore-gateway:<sha>`], [Docker Buildx],
  [Build Frontend], [`ghcr.io/bassmit12/abysscore-frontend:<sha>`], [Docker Buildx],
)

All three images are also tagged `:latest`. After the build jobs, an `update-manifests` job patches the SHA tag in each `infra/k8s/*.yaml` and commits the change back to `main`. ArgoCD detects the updated manifest and rolls out the new images automatically.

The `paths-ignore: infra/k8s/**` filter on the workflow trigger prevents the manifest-update commit from triggering another build run.

Authentication uses the `GHCR_TOKEN` secret (PAT with `write:packages` scope). The `GITHUB_TOKEN` built into Actions fails with 403 for new packages.
