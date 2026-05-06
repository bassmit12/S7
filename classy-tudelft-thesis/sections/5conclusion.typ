// Chapter 5 — Scalability

= Scalability

== Current State

Right now, every service in AbyssCore runs as a single replica. There's one backend pod, one gateway pod, one frontend pod. If any of those goes down, that service is unavailable until Kubernetes restarts it. At current traffic levels this is fine — it's a personal project, not a production service — but it's worth understanding what "scaling" would actually look like here and what's available.

The one exception is `cloudflared`, which runs two replicas. That's intentional — if the single tunnel process crashes, all external traffic drops. Two replicas means there's always a fallback while Kubernetes restarts the failed one.

== Load Balancing

Kubernetes does basic load balancing automatically. Every Service in Kubernetes is backed by `kube-proxy`, which distributes incoming connections across all healthy pods behind that Service using round-robin. If you scale a Deployment to three replicas, `kube-proxy` splits traffic roughly evenly across all three.

This means load balancing is essentially free — you just increase the replica count and Kubernetes handles distribution. There's no additional configuration needed. What you don't get out of the box is anything smarter than round-robin: no session affinity based on game state, no weighted routing, no circuit breaking. For those, you'd need a service mesh like Istio or Linkerd.

== Horizontal Pod Autoscaler (HPA)

HPA is the standard Kubernetes mechanism for automatically scaling pod count based on resource utilisation. You define a target — say, "keep CPU usage below 70%" — and the HPA controller adds or removes pods to hit that target.

For AbyssCore, the services most likely to benefit from HPA are the backend and the gateway. They handle all the actual work: processing requests, running game logic, querying the database. The frontend is mostly static content and unlikely to become a bottleneck.

A reasonable HPA configuration for the backend would look like this:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: abysscore-backend
  namespace: abysscore
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: abysscore-backend
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

This keeps at least one replica running, scales up to five if CPU hits 70%, and scales back down when load drops. Kubernetes applies a cooldown period between scale events to prevent flapping.

One important requirement: resource requests must be defined on the Deployment for HPA to work. HPA calculates utilisation as `actual_cpu / requested_cpu`. If there are no requests defined, the calculation fails and HPA can't do anything. AbyssCore already has resource requests defined on all Deployments, so HPA can be added without any other changes.

== Vertical Pod Autoscaler (VPA)

VPA adjusts the CPU and memory requests and limits on a pod automatically, based on observed usage. Instead of adding more pods (like HPA), it makes each pod bigger or smaller.

VPA is useful when you don't know the right resource requests upfront, or when workload patterns change over time. In practice, it's less commonly used than HPA because it requires pod restarts to apply new values — VPA can't resize a running pod in place.

For AbyssCore, VPA could be useful for tuning the Keycloak memory allocation. At ~1.14 GiB observed usage, the current limit is set generously. VPA would help find the right number automatically over time rather than guessing upfront.

VPA is not installed on the cluster currently. It would need to be deployed separately — it's not part of the standard Kubernetes distribution.

== Cluster Autoscaler

The Cluster Autoscaler adds and removes nodes automatically based on whether pods can be scheduled. If all nodes are full and a pod is stuck in `Pending` state, the Cluster Autoscaler spins up a new node. When nodes are underutilised, it drains and removes them to save cost.

This is only relevant for cloud providers or infrastructure that supports dynamic node provisioning. The Fontys-managed cluster has a fixed set of nodes — `10.1.1.158` is the node AbyssCore runs on. There's no mechanism to add more nodes dynamically. The Cluster Autoscaler doesn't apply here.

== Scaling Recommendations for Production

If AbyssCore were being prepared for real production traffic, here's what should change:

*Add HPA for backend and gateway.* These are the services that will see load under real usage. Setting a CPU target of 60--70% gives enough headroom to handle traffic spikes before things get slow.

*Increase minimum replicas to 2.* Running single replicas means any pod restart causes a brief outage. Two replicas eliminates this — Kubernetes can terminate and restart one pod while the other keeps serving traffic. This should apply to frontend, backend, and gateway at minimum.

*Deploy VPA for Keycloak.* Keycloak's memory usage is variable and hard to predict. VPA would tune the allocation automatically.

*Separate PostgreSQL per service.* Currently one Postgres instance handles all seven databases. Under load, this becomes a bottleneck and a single point of failure. The proper fix is a dedicated database instance per service, possibly with a connection pooler like PgBouncer in front.

*Consider a service mesh for smart routing.* For things like circuit breaking, retries with backoff, and traffic splitting during deployments, a lightweight service mesh would add significant value without much operational overhead.

None of this is urgent for the current state of the project, but it's the natural next step if AbyssCore were to grow beyond a personal project.

== Planned: Authentication for All Services

Currently Keycloak only protects the frontend entry point. The gateway validates the JWT on every inbound request, but the individual backend services themselves don't verify the caller's identity — they trust that the gateway has already done it. That's fine as long as the gateway is the only path in, but it's a weak assumption. Any service reachable directly inside the cluster could be called without authentication.

The plan is to enforce authentication at every layer:

*Gateway token validation.* Already in place. Every request to the gateway must carry a valid JWT issued by the `abysscore` Keycloak realm. Requests without a token are rejected at the gateway before reaching any backend service.

*Service-to-service auth.* Each backend service should validate the JWT independently, rather than trusting the gateway implicitly. This can be done by passing the token through the gateway headers and having each Encore service verify the signature against the Keycloak JWKS endpoint. If a service is ever called directly — by mistake or by a misconfigured client — it will still reject the request.

*Dedicated player login.* Right now the only user is a single test account (`testplayer`). The plan is to open registration so anyone can create an account. Keycloak supports self-registration out of the box — enabling it in the realm settings is enough to get a working sign-up flow. Players would register with a username and password, Keycloak issues a JWT, and the existing NextAuth/Apollo flow handles the rest without any code changes.

*Role-based access.* Keycloak supports realm roles and client roles. Adding a `player` role to all registered users and an `admin` role for management operations would let the gateway enforce role-based access at the route level — `/admin/*` requires `admin`, all game endpoints require `player`. This keeps authorization logic out of the individual services and centralised at the gateway.

Together these changes would make the authentication boundary complete: Keycloak as the single source of truth for identity, the gateway as the enforcement point, and each service independently verifiable as a fallback.
