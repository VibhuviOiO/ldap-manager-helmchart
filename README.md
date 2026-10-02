# ldap-manager

A Helm chart for running [`vibhuvioio/ldap-manager`](https://hub.docker.com/r/vibhuvioio/ldap-manager)
on Kubernetes: one Deployment serving the React UI and the FastAPI backend on port 8000, with
`config.yml` from a ConfigMap, bind passwords from a Secret, and PersistentVolumeClaims for the
two directories the app cannot rebuild.

- `appVersion` is the LDAP Manager release (`1.0.0`); the chart version is independent (`0.1.0`).
- The app is stateless apart from `/app/.data` and `/app/.secrets`, so a restart is free.
- `config.yml` is mounted as a **directory** and read through `LDAP_MANAGER_CONFIG`, so editing
  the ConfigMap takes effect without a restart.
- Probes use `/api/auth/status`, the app-local endpoint — **not** `/health`, which returns 503
  whenever a managed LDAP cluster is unreachable. Readiness on `/health` would evict the only
  pod during an LDAP outage, exactly when you need the UI to diagnose it.

## What this chart deploys

| Object | Condition | Notes |
|---|---|---|
| `Deployment` | always | one container, port 8000, `maxSurge: 0` |
| `Service` | always | `ClusterIP` on port 8000 by default |
| `ConfigMap` | unless `config.existingConfigMap` | holds `config.yml` |
| `Secret` | only with `secrets.create` and no `secrets.existingSecret` | lab convenience |
| `PersistentVolumeClaim` ×2 | `persistence.data.enabled`, `persistence.secrets.enabled` | `/app/.data`, `/app/.secrets` — kept on uninstall |
| `PodDisruptionBudget` | `podDisruptionBudget.enabled` and `replicaCount > 1` | `maxUnavailable: 1` |
| `ServiceAccount` | `serviceAccount.create` | no API token projected |
| `Ingress` | `ingress.enabled` | networking.k8s.io/v1 |

`/app/.cache` is an `emptyDir` unless `persistence.cache.enabled` is set: the encrypted password
cache is rebuilt on demand.

## Requirements

| | |
|---|---|
| Kubernetes | >= 1.24 |
| Helm | 3 |
| Storage | a default StorageClass, or set `persistence.*.storageClass` |
| Image | `vibhuvioio/ldap-manager:1.0.0` from Docker Hub (public) |

## Install

```bash
helm repo add vibhuvioio-ldap-manager https://VibhuviOiO.github.io/ldap-manager-helmchart
helm repo update
```

The repository alias is local to your machine; `vibhuvioio` is already taken by the sibling
[openldap chart repository](https://VibhuviOiO.github.io/openldap-helmchart), so this one adds
under a distinct name.

Create the namespace and the Secret **first**. Every key becomes an environment variable in the
pod (`envFrom`), so a cluster whose `config.yml` says `credential: {source: env}` picks its
password up by name:

```bash
kubectl create namespace directory

kubectl -n directory create secret generic ldap-manager-secrets \
  --from-literal=LDAP_MANAGER_CLUSTER_EXAMPLE_CLUSTER_PASSWORD='change-me' \
  --from-literal=LDAP_MANAGER_CONFIG_EXAMPLE_CLUSTER_PASSWORD='change-me' \
  --from-literal=LDAP_MANAGER_SECRET_KEY="$(openssl rand -hex 32)"
```

Then add your directory to `config.yml` — see
[Before you install](#before-you-install-replace-the-placeholders) — and install:

```bash
helm install ldap-manager vibhuvioio-ldap-manager/ldap-manager \
  --namespace directory \
  --version 0.1.0 \
  --set secrets.existingSecret=ldap-manager-secrets \
  --set config.clusters[0].name=example-cluster \
  --set config.clusters[0].host=ldap.example.com \
  --set config.clusters[0].bind_dn=cn=admin,dc=example,dc=com \
  --set config.clusters[0].base_dn=dc=example,dc=com \
  --set config.clusters[0].credential.source=env
```

A values file is easier to read for anything beyond one cluster:

```yaml
# my-values.yaml
secrets:
  existingSecret: ldap-manager-secrets

config:
  auth:
    mode: none            # none | local | ldap
    defaultRole: readonly
  clusters:
    - name: example-cluster
      host: ldap.example.com        # replace
      port: 389
      bind_dn: cn=admin,dc=example,dc=com   # replace
      base_dn: dc=example,dc=com            # replace
      credential:
        source: env
```

```bash
helm install ldap-manager vibhuvioio-ldap-manager/ldap-manager \
  -n directory --version 0.1.0 -f my-values.yaml
```

Verify and reach it:

```bash
kubectl -n directory rollout status deploy/ldap-manager
kubectl -n directory port-forward svc/ldap-manager 8000:8000
# http://localhost:8000
```

**Use `kubectl rollout status`, not `helm install --wait`.** Helm computes
`expectedReady = replicas - maxUnavailable` for a Deployment; this chart runs one replica with
`maxUnavailable: 1` (see `deploymentStrategy` below), so that number is 0 and `--wait` — and
with it `--atomic` — returns as soon as the ReplicaSet exists, before any pod is Ready. The
same applies to `helm upgrade --wait`. Every workflow in this repository gates on
`kubectl rollout status` for that reason.

## Before you install: replace the placeholders

The chart ships **no real directory details**. Nothing below is filled in for you, and every one
of them is an example you must edit:

| Where | Placeholder | What to put there |
|---|---|---|
| `config.clusters[].host` or `.nodes[]` | `ldap.example.com` | Hostname/IP of an OpenLDAP server reachable **from the pod** |
| `config.clusters[].bind_dn` | `cn=admin,dc=example,dc=com` | A DN allowed to read (and, if not `readonly`, write) the directory |
| `config.clusters[].base_dn` | `dc=example,dc=com` | The suffix the UI should browse |
| `config.clusters[].name` | `example-cluster` | Any label; it decides the password env var name (see below) |
| Secret keys | `LDAP_MANAGER_CLUSTER_EXAMPLE_CLUSTER_PASSWORD` | The bind password, keyed by the cluster name upper-cased with every run of non-alphanumeric characters collapsed to one `_` |
| `allowedOrigins` | `""` | The public origin of the UI, e.g. `https://ldap.example.com`. Never `*` |
| `contextPath` | `""` | Only if you serve the app under a sub-path; must match the ingress |
| `ingress.hosts[].host` / `ingress.tls` | empty | Your hostname and TLS secret |

With `config.clusters: []` (the default) the chart installs and the UI runs, but it shows no
clusters to manage. That is a valid way to start: add clusters in the UI afterwards and they are
stored in `/app/.data`.

## Configure

`config.yml` is built from `config.auth`, `config.clusters` and `config.extra`. Cluster entries
are rendered verbatim, so their keys are the `config.yml` schema from the app's
[`config.example.yml`](https://github.com/VibhuviOiO/ldap-manager/blob/main/config.example.yml):
`name`, `host` or `nodes`, `port`, `bind_dn`, `base_dn`, `readonly`, `description`, `credential`,
`tls`, `config`, `user_creation_form`.

Credential sources, per cluster: `stored` (default — entered once in the UI and encrypted under
`/app/.secrets`), `env`, `file`, `prompt`, `config`. Use `env` or `file` in Kubernetes; `config`
writes the password into the ConfigMap in plaintext.

The image's built-in config location is `/app/config.yml`. This chart mounts the ConfigMap as a
directory at `config.mountPath` (default `/etc/ldap-manager`) and points `LDAP_MANAGER_CONFIG` at
the file inside it, rather than bind-mounting a single file with `subPath`: a `subPath` mount
never sees ConfigMap updates, while the app re-reads `config.yml` on every request. A directory
mount is what makes `kubectl edit configmap` take effect without a restart.

Authentication for the UI itself is `config.auth.mode`:

| Mode | Meaning |
|---|---|
| `none` | No login. Use when a reverse proxy or SSO already authenticates users. `defaultRole` decides what a visitor gets. |
| `local` | Built-in accounts created in a first-run wizard, hashed with scrypt and stored under `/app/.secrets`. |
| `ldap` | One of the clusters authenticates users; roles come from group membership. Set `config.auth.ldap`. |

`contextPath` must match the path your ingress serves. With `contextPath: /ldap-manager`, route
`/ldap-manager` and keep any rewrite rule consistent with it.

## State

| Path | Contents | Volume |
|---|---|---|
| `/app/.data` | clusters added or edited in the UI (`clusters.yml`) | `persistence.data` claim |
| `/app/.secrets` | Fernet key, encrypted bind-password cache, local users, session signing key | `persistence.secrets` claim |
| `/app/.cache` | encrypted password cache, rebuildable | `emptyDir` unless `persistence.cache.enabled` |

`config.yml` stays operator-owned: the app never writes to it.

## Health and probes

| Endpoint | Meaning |
|---|---|
| `/api/auth/status` | 200 whenever the process is serving. App-local. |
| `/health` | 200 only when `config.yml` parses *and* every checked cluster answers; 503 when a managed directory is down. |

All three probes default to `/api/auth/status` on purpose. With one replica, readiness on
`/health` removes the only pod from the Service during an LDAP outage — the moment you most want
the UI. Point `probes.readiness.path` at `/health` only when you run more than one replica and
want traffic gated on directory health.

**Caveat on the published `1.0.0` image.** The image behind `appVersion: 1.0.0` was built before
the auth API landed: it ships no `app/api/auth.py`, so `/api/auth/status` does not exist in it.
`/health` is registered after the SPA catch-all route (`/{full_path:path}`) in the same image, so
it is shadowed as well. Both therefore answer with `index.html` and HTTP 200 for any path, which
means the probes prove only that the HTTP server is up — they still pass, the pod becomes Ready,
and nothing else changes. Rebuild and republish the image from the repository's tag to get the
real endpoints; the chart probes the app-local path either way, so no chart change is needed when
that happens.

## More than one replica

The two state directories are `ReadWriteOnce` by default, and sessions are HMAC-signed with a key
in `/app/.secrets`. The chart **refuses to render** `replicaCount > 1` unless the state is
genuinely shared:

- `persistence.data.accessModes` and `persistence.secrets.accessModes` set to `ReadWriteMany`
  with a StorageClass that supports it, **or** `existingClaim` pointing at an RWX-backed claim, and
- `LDAP_MANAGER_SECRET_KEY` set (via `secrets.existingSecret` or `secrets.env`), or the shared
  `/app/.secrets` volume carrying the session key.

```bash
helm install ldap-manager vibhuvioio-ldap-manager/ldap-manager -n directory \
  --version 0.1.0 \
  --set replicaCount=3 \
  --set secrets.existingSecret=ldap-manager-secrets \
  --set persistence.data.accessModes[0]=ReadWriteMany \
  --set persistence.secrets.accessModes[0]=ReadWriteMany
```

## Upgrade

```bash
helm upgrade ldap-manager vibhuvioio-ldap-manager/ldap-manager \
  -n directory --version 0.1.0 -f my-values.yaml
kubectl -n directory rollout status deploy/ldap-manager
```

The Deployment rolls with `maxSurge: 0`, so the old pod releases its `ReadWriteOnce` volumes
before the new one starts. Bind passwords are never regenerated by the chart.

An upgrade that changes only the ConfigMap does not need a restart: the app re-reads `config.yml`
per request. A `checksum/config` pod annotation still rolls the pod when the rendered file
changes, so in-flight state is never stale.

## Uninstall

```bash
helm uninstall ldap-manager -n directory
```

The PersistentVolumeClaims **survive** the uninstall. Helm deletes every object it rendered,
and a claim that comes from a template is no exception — so the chart sets
`helm.sh/resource-policy: keep` on both claims. Without it, the uninstall would destroy
`/app/.secrets` and with it the Fernet key, the encrypted bind-password cache, any built-in
local accounts and the session signing key.

Keeping them also means the claims are yours to remove:

```bash
kubectl -n directory delete pvc ldap-manager-data ldap-manager-secrets
kubectl -n directory delete secret ldap-manager-secrets   # the Secret is not kept
```

Deleting the claim that holds `/app/.secrets` invalidates cached bind passwords and any built-in
local accounts.

**Reinstalling.** A reinstall under the *same release name and namespace* adopts the kept claims,
so `/app/.data` and `/app/.secrets` carry over. A release name whose rendered names collide with
them — the usual GitOps shape, a fixed `fullnameOverride` under a new release name — is refused
by Helm's ownership check (`... exists and cannot be imported into the current release: invalid
ownership metadata`). Either reuse the release name, or delete the claims first.

## Values

### Image and identity

| Key | Default | Description |
|---|---|---|
| `replicaCount` | `1` | Pods. See [More than one replica](#more-than-one-replica). |
| `image.repository` | `vibhuvioio/ldap-manager` | Docker Hub primary, `ghcr.io/vibhuvioio/ldap-manager` mirror. |
| `image.tag` | `""` | Empty means `.Chart.AppVersion`. |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy. |
| `imagePullSecrets` | `[]` | Pull secrets. |
| `nameOverride` | `""` | Override the chart name. |
| `fullnameOverride` | `""` | Override the generated resource names. |
| `serviceAccount.create` | `true` | Create a ServiceAccount (no API token is projected). |
| `serviceAccount.name` | `""` | Defaults to the fullname. |
| `serviceAccount.annotations` | `{}` | ServiceAccount annotations. |

### Application

| Key | Default | Description |
|---|---|---|
| `contextPath` | `""` | Sub-path the app is served under, e.g. `/ldap-manager`. |
| `allowedOrigins` | `""` | Comma-separated CORS origins. Set it in production; never `*`. |
| `logLevel` | `INFO` | `LOG_LEVEL`. |
| `jsonLogs` | `true` | `JSON_LOGS`. |
| `extraEnv` | `[]` | Extra env vars. |
| `extraEnvFrom` | `[]` | Extra `envFrom` sources. |

### config.yml

| Key | Default | Description |
|---|---|---|
| `config.existingConfigMap` | `""` | Use your own ConfigMap instead of a rendered one. |
| `config.key` | `config.yml` | Key inside the ConfigMap, and the file name in the mount. |
| `config.mountPath` | `/etc/ldap-manager` | Directory the ConfigMap is mounted at, read-only. |
| `config.content` | `""` | Verbatim `config.yml`, rendered through `tpl`. Overrides the structured values. |
| `config.auth.mode` | `none` | `none`, `local` or `ldap`. |
| `config.auth.defaultRole` | `readonly` | `readonly`, `readwrite` or `admin`. |
| `config.auth.sessionLifetimeHours` | `12` | Session lifetime. |
| `config.auth.ldap` | `{}` | Free-form `auth.ldap` block, used only for `mode: ldap`. |
| `config.clusters` | `[]` | Cluster entries, verbatim `config.yml` schema. |
| `config.extra` | `""` | Extra YAML appended to the rendered file. |

### Secrets

| Key | Default | Description |
|---|---|---|
| `secrets.existingSecret` | `""` | Existing Secret consumed with `envFrom`. Recommended. |
| `secrets.create` | `false` | Render a Secret from `secrets.env` when no existing one is set. |
| `secrets.env` | `{}` | Keys for the chart-managed Secret. |
| `secrets.mountPath` | `""` | Also mount the Secret read-only here, for `credential.source: file`. |

### Persistence

| Key | Default | Description |
|---|---|---|
| `persistence.data.enabled` | `true` | Claim for `/app/.data`; `false` uses an `emptyDir`. |
| `persistence.data.existingClaim` | `""` | Claim to reuse. |
| `persistence.data.size` | `1Gi` | Requested size. |
| `persistence.data.accessModes` | `["ReadWriteOnce"]` | Access modes. |
| `persistence.data.storageClass` | `""` | Empty uses the cluster default. |
| `persistence.data.annotations` | `{}` | Claim annotations. `helm.sh/resource-policy: keep` is added for you. |
| `persistence.secrets.*` | same shape as `data` | Claim for `/app/.secrets`. |
| `persistence.cache.enabled` | `false` | Persist `/app/.cache`; `false` uses an `emptyDir`. |
| `persistence.cache.*` | same shape as `data` | Claim for `/app/.cache`. |

Every claim the chart renders carries `helm.sh/resource-policy: keep`, so `helm uninstall` does
not delete it — see [Uninstall](#uninstall). Claims supplied through `existingClaim` are never
touched by the chart at all.

### Networking

| Key | Default | Description |
|---|---|---|
| `service.type` | `ClusterIP` | Service type. |
| `service.port` | `8000` | Service port. |
| `service.annotations` | `{}` | Service annotations. |
| `ingress.enabled` | `false` | Create an Ingress. |
| `ingress.className` | `""` | `ingressClassName`. |
| `ingress.annotations` | `{}` | Ingress annotations. |
| `ingress.hosts` | `[]` | `host` plus `paths` (`path`, `pathType`). |
| `ingress.tls` | `[]` | Standard Ingress TLS blocks. |

### Probes, rollout and security

| Key | Default | Description |
|---|---|---|
| `probes.startup.enabled` | `true` | Startup probe. |
| `probes.startup.path` | `/api/auth/status` | See [Health and probes](#health-and-probes). |
| `probes.startup.failureThreshold` / `periodSeconds` | `30` / `5` | 150s budget. |
| `probes.readiness.enabled` / `path` | `true` / `/api/auth/status` | Set the path to `/health` to gate traffic on directory health. |
| `probes.readiness.initialDelaySeconds` / `periodSeconds` / `timeoutSeconds` / `failureThreshold` | `5` / `10` / `5` / `3` | Readiness tuning. |
| `probes.liveness.enabled` / `path` | `true` / `/api/auth/status` | Liveness probe. |
| `probes.liveness.initialDelaySeconds` / `periodSeconds` / `timeoutSeconds` / `failureThreshold` | `20` / `30` / `5` / `3` | Liveness tuning. |
| `deploymentStrategy` | `RollingUpdate`, `maxSurge 0`, `maxUnavailable 1` | Keeps `ReadWriteOnce` volumes exclusive. Makes `helm --wait` unable to gate readiness — see [Install](#install). |
| `terminationGracePeriodSeconds` | `30` | Grace period. |
| `podSecurityContext` | `runAsNonRoot`, `runAsUser/Group 1000`, `fsGroup 1000`, `RuntimeDefault` | Must match the uid the image runs as. |
| `securityContext` | no privilege escalation, all capabilities dropped, `readOnlyRootFilesystem: false` | Container security. |
| `resources` | requests `250m`/`256Mi`, limits `1`/`1Gi` | Resources. |
| `extraVolumes` / `extraVolumeMounts` | `[]` | E.g. cluster CA certificates for `tls.ca_file`. |
| `podAnnotations` / `podLabels` | `{}` | Pod metadata. |
| `nodeSelector` / `tolerations` / `affinity` / `topologySpreadConstraints` | empty | Scheduling. |
| `podDisruptionBudget.enabled` | `true` | Created only when `replicaCount > 1`. |
| `podDisruptionBudget.maxUnavailable` | `1` | Disruption budget. |

## Artifact Hub and the chart repository

The chart is published to GitHub Pages from this repository, which is what
`helm repo add` consumes and what Artifact Hub indexes:

| | |
|---|---|
| Repository | `https://VibhuviOiO.github.io/ldap-manager-helmchart` |
| Chart | `ldap-manager` |
| Artifact Hub | `https://artifacthub.io/packages/helm/ldap-manager/ldap-manager` |

Artifact Hub repository names are globally unique, so the publisher slug is chosen when the
repository is added there; substitute it for `ldap-manager`. See
[`CONTRIBUTING.md`](CONTRIBUTING.md) for the maintainer-side setup (gh-pages, Pages, Artifact Hub
registration, `artifacthub-repo.yml`).

```bash
helm repo add vibhuvioio-ldap-manager https://VibhuviOiO.github.io/ldap-manager-helmchart
helm repo update
helm search repo vibhuvioio-ldap-manager/ldap-manager --versions
helm show values vibhuvioio-ldap-manager/ldap-manager --version 0.1.0
```

## Troubleshooting

```bash
kubectl -n directory logs deploy/ldap-manager
kubectl -n directory get events --sort-by=.lastTimestamp
```

| Symptom | Cause |
|---|---|
| Pod stuck `CreateContainerConfigError` | The Secret named by `secrets.existingSecret` does not exist in this namespace. |
| UI shows no clusters | `config.clusters` is empty, or the ConfigMap key is not `config.yml`. |
| "expects its password in $LDAP_MANAGER_…" in the logs | The Secret has no key for that cluster name. The name is upper-cased with every run of non-alphanumeric characters collapsed to one `_`. |
| `container has runAsNonRoot and image will run as root` | The image tag runs as a different uid; set `podSecurityContext.runAsUser`, `runAsGroup` and `fsGroup` together. |
| `Permission denied` writing `/app/.data` | `fsGroup` does not match the uid the process runs as. |
| Readiness flaps while an LDAP cluster is down | `probes.readiness.path` is `/health`; set it back to `/api/auth/status` (or run more than one replica). |
| Probes pass but the UI is broken | Expected with the published `1.0.0` image: the SPA answers 200 for every path, so a probe only proves the HTTP server is up. See [Health and probes](#health-and-probes). |
| `helm install --wait` returned and the pod is not Ready | Expected: one replica with `maxUnavailable: 1` makes Helm's `expectedReady` 0. Use `kubectl rollout status`. |
| `helm install` fails with `replicaCount=… mounts one ReadWriteOnce PVC into every pod` | The multi-replica guard. See [More than one replica](#more-than-one-replica). |
| `helm install` after `helm uninstall` fails with `… exists and cannot be imported into the current release: invalid ownership metadata` | The kept claim (or another rendered object) belongs to the old release. Reuse the release name, or `kubectl delete` the objects first. |
| `helm uninstall` left PVCs behind | By design: `helm.sh/resource-policy: keep`. `kubectl delete pvc` when you mean it. |
| A ConfigMap edit does not take effect | Something is mounting the key with `subPath`; this chart mounts the directory instead. Note the kubelet syncs the volume on its own schedule — up to a minute, and the pod is not restarted. |
| Login does not survive a second replica | Sessions are HMAC-signed. Set `LDAP_MANAGER_SECRET_KEY` or share `/app/.secrets` over RWX. |

## Links

- [Documentation](https://vibhuvioio.com/ldap-manager/)
- [Docker image](https://hub.docker.com/r/vibhuvioio/ldap-manager)
- [Application source](https://github.com/VibhuviOiO/ldap-manager)
- [Chart source and issues](https://github.com/VibhuviOiO/ldap-manager-helmchart)
- [OpenLDAP chart](https://artifacthub.io/packages/helm/vibhuvioio/openldap)
- [vibhuvioio.com](https://vibhuvioio.com)
