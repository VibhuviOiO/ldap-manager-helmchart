# Contributing

Maintainer notes for this repository. User-facing documentation is in
[`README.md`](README.md), which is the file Artifact Hub renders.

## Why this is a separate repository

The application repo builds and tests a container; this repository owns deploying it. The two
release cadences are independent and neither should pull the other's tooling in.

| | [ldap-manager](https://github.com/VibhuviOiO/ldap-manager) | this repository |
|---|---|---|
| Versioning | image tag = `frontend/package.json` version | chart `version`, independent of `appVersion` |
| Consumers | `docker run`, `docker compose`, the plain manifests under `manifests/` | `helm install` |
| CI | image build, backend tests, frontend tests | `helm lint`, `helm template`, `kubeconform`, `ct`, k3s e2e |

The chart used to live at `helm/ldap-manager/` inside the application repo. A chart that is not
the root of its own repository cannot be published cleanly to a public chart repository, which is
why it moved here. When the move is complete the application repo's copy should be deleted, so
there is exactly one chart to release.

## Releasing

Chart `version` is independent semver; `appVersion` is the LDAP Manager release the chart
installs, and `image.tag` defaults to it. The git tag is `v<chart version>`.

```bash
# Chart.yaml: version: 0.1.0
git tag v0.1.0 && git push origin v0.1.0
```

`release.yml` refuses to publish unless the tag equals `Chart.yaml` `version` **and**
`vibhuvioio/ldap-manager:<appVersion>` exists on Docker Hub. It then packages the chart, rebuilds
`index.yaml` on `gh-pages`, copies `artifacthub-repo.yml` (only once its placeholders are filled
in) and the landing page, and creates a GitHub Release with the `.tgz` attached. The last step
polls the published repository until *that version* is installable, so a stale Pages cache cannot
pass for a successful release.

Changing only `.github/`, `hack/` or `README.md` still needs a version bump if you want it
released — the tag is the release. Merging to `main` does not publish: it runs `lint`, `ct` and
`e2e`. Only a tag releases.

**An image release alone needs no chart change.** `appVersion` is what `image.tag` defaults to, so
bumping `appVersion` in a chart version is only for saying "this chart was tested against that
image". If you bump it, the new tag must exist on Docker Hub or the release fails — which is the
point.

**Chart versions are not prereleases.** `0.1.0-1` is a prerelease to Helm: it is hidden from
`helm search`, `helm install` without `--version` resolves to the older version, and Artifact Hub
keeps headlining the base version. Bump the patch instead.

### One-time setup

`gh-pages` must exist and Pages must be enabled before the first tag:

```bash
git checkout --orphan gh-pages
git rm -rf . >/dev/null 2>&1
git commit --allow-empty -m "chore: init gh-pages"
git push origin gh-pages
git checkout main
```

Settings → Pages → *Deploy from a branch*, branch `gh-pages`, folder `/`.
Settings → Actions → General → Workflow permissions must be *Read and write*.

`hack/gh-pages-index.html` is copied to `index.html` on every release, because a Helm repository
has `index.yaml`, not `index.html`, and the Pages root 404s without it.

### Registering with Artifact Hub

| field | value |
|---|---|
| Kind | Helm charts |
| URL | `https://VibhuviOiO.github.io/ldap-manager-helmchart` |
| Name | any globally unique slug — Artifact Hub repository names are unique across all publishers, so pick one at registration and use it consistently |

Add the repository in the Artifact Hub control panel, point it at the Pages URL, and Artifact Hub
indexes `index.yaml` on its own. Then, from the repository's Settings tab, fill in
`artifacthub-repo.yml`:

```yaml
repositoryID: <the repository's UUID>      # was REPLACE-WITH-ARTIFACTHUB-REPOSITORY-ID
owners:
  - name: Jinna Baalu
    email: <your Artifact Hub account email>   # was REPLACE-WITH-ARTIFACTHUB-ACCOUNT-EMAIL
```

That file is optional for a Helm repository served over HTTP — it enables the ownership claim
and the verified publisher badge. It must sit next to `index.yaml`, which is why `release.yml`
copies it to `gh-pages` and skips it while the placeholders are still present. Verified publisher
status is granted by proving ownership of `vibhuvioio.com` in the control panel, which
`release.yml` never touches.

What makes the chart findable is `Chart.yaml`, not the repository name:

| field | value | why it matters for search |
|---|---|---|
| `name` | `ldap-manager` | what a search for `ldap-manager` matches |
| `keywords` | `ldap`, `openldap`, `ldap-manager`, … | secondary match |
| `artifacthub.io/category` | `security` | the shelf Artifact Hub browses by |
| `icon` | a square SVG or PNG | shown in results |
| `artifacthub.io/recommendations` | the `openldap` chart | cross-links the server this UI manages |

## Testing

Three layers, cheapest first.

**1. `helm lint --strict` / `helm template`** — `lint.yml`. It renders every values permutation,
validates each against the Kubernetes schemas with `kubeconform -strict`, checks the rendered
invariants that a template diff cannot show (no `subPath`, `LDAP_MANAGER_CONFIG` matching the
mount, probes on the app-local path, `fsGroup` matching `runAsUser`, `maxSurge: 0`, the claim
names), asserts that the multi-replica guard still rejects both unsafe shapes, parses every
`artifacthub.io/*` annotation as YAML, and confirms that `appVersion` names a tag that exists on
Docker Hub.

Run the whole workflow locally, step for step:

```bash
helm lint . --strict
helm template t . | docker run --rm -i ghcr.io/yannh/kubeconform:v0.6.7 \
  -strict -summary -kubernetes-version 1.30.0
```

**2. chart-testing** — `ct.yml`. `ct lint` needs no cluster; `ct install` runs on a kind cluster
the workflow starts. Set the repository variable `CT_INSTALL_ENABLED=false` to run lint only.

Three things about this configuration are deliberate, each verified against chart-testing 3.14.0
(the version `helm/chart-testing-action@v2` installs by default):

- ⚠️ **`--charts .`, never `--all`.** chart-testing finds charts by walking the *subdirectories* of
  each `chart-dirs` entry, so a chart sitting at the chart-dir root is invisible to it: with
  `chart-dirs: [.]`, `ct lint --all` prints `No chart changes detected.` and exits **0 without
  linting anything**. `--charts .` takes the path directly. A green ct job that lints nothing is
  worse than no job; if you ever move the chart into `charts/ldap-manager`, switch back to `--all`.
- **`--skip-clean-up`**, not `--skip-cleanup`, leaves the release installed for the readiness step.
- **`validate-maintainers: false`** in `ct.yaml`, because that check does an HTTP HEAD on
  `https://github.com/<maintainer name>` and `Chart.yaml` names a person (`Jinna Baalu` → 404).
  Switch maintainers to account names (`JinnaBaalu` and `VibhuviOiO` both resolve) and the opt-out
  can go.

`ct install` uses `helm install --wait`, which for this chart returns before the pod is Ready
(see "Design decisions" below), so the workflow asserts readiness against the API server
afterwards. Do not remove that step: without it a crash-looping pod passes.

**3. k3s e2e** — `e2e.yml` runs `hack/e2e-local.sh`, and nothing else. The script starts k3s in
Docker when no cluster is reachable, then asserts, on the live cluster, that the pod becomes
Ready, both claims bind, `config.yml` is a *directory* mount, the probes are app-local, the
Secret's keys arrive as environment variables, a ConfigMap edit reaches the pod with **no
restart**, an upgrade keeps `/app/.data`, an uninstall keeps the claims, a reinstall under the
same release name adopts them, and a foreign release cannot.

```bash
# The same run CI does, on your machine.
bash hack/e2e-local.sh
# Reuse a cluster you already have:
KUBECONFIG=~/.kube/config bash hack/e2e-local.sh
# Keep the namespace and the k3s container for poking at afterwards:
bash hack/e2e-local.sh --keep
```

Everything asserted in CI lives in the script, so a red build is reproducible with one command
instead of by reading a workflow.

## Design decisions worth keeping

**`config.yml` is mounted as a directory, never a `subPath`.** The app re-reads the file on
every request, but a `subPath` mount never sees ConfigMap updates: editing the ConfigMap would
need a restart. The chart mounts `config.mountPath` and points `LDAP_MANAGER_CONFIG` at the file
inside it. `lint.yml` fails if any volumeMount grows a `subPath`. The kubelet still syncs the
volume on its own schedule (measured at 15–35s on k3s; a one-minute sync period is the
documented worst case), so "no restart" is not the same as "instantly".

**Probes use `/api/auth/status`, not `/health`.** `/health` returns 503 whenever a managed
cluster is unreachable, and with one replica readiness on it would evict the only pod during an
LDAP outage — the moment the UI is most needed. The endpoint also has to exist in the image: the
published `1.0.0` tag predates the auth API and the SPA catch-all answers 200 for every path
including `/health`. Probes still pass; they simply prove less. The README says so plainly.

**Both claims carry `helm.sh/resource-policy: keep`.** Helm deletes every object it rendered on
`helm uninstall`, and a claim that comes from a template is no exception — immediately after the
uninstall `kubectl get pvc` shows it Terminating and the PV goes with it. That would destroy
`/app/.secrets` (Fernet key, encrypted bind-password cache, local accounts, session signing key)
on every uninstall, which is exactly what the chart promises not to do. The annotation is what
makes the promise true; `hack/e2e-local.sh` proves the claim's UID survives the uninstall and
that a reinstall adopts it. A consequence worth knowing: a *different* release name whose
rendered names collide is refused by Helm's ownership check, so reinstall under the same release
name or delete the claims first.

**`maxSurge: 0` and `maxUnavailable: 1`, and what that costs.** The state volumes are
ReadWriteOnce, so a surge pod would fight the old one for the same claim. Helm computes
`expectedReady = replicas - maxUnavailable` for a Deployment, so with one replica that is 0 and
`helm install --wait`, `helm upgrade --wait` and `--atomic` all return as soon as the ReplicaSet
exists. **`--wait` is not a readiness gate for this chart.** Use `kubectl rollout status`; CI
does.

**The chart refuses `replicaCount > 1` against unshared state.** Two ReadWriteOnce claims plus
one release is a deadlock, not a warning; and sessions are HMAC-signed with a key in
`/app/.secrets`, so replicas without `LDAP_MANAGER_SECRET_KEY` reject each other's sessions. The
guard in `templates/_helpers.tpl` fails the render instead, with the fix in the message. Both
unsafe shapes are exercised in `lint.yml`.

**`automountServiceAccountToken: false` and `enableServiceLinks: false`.** The app never calls the
API server, and Kubernetes injects `<SERVICE>_PORT` for every Service in the namespace, which
would collide with the app's own environment.

**`runAsUser`/`runAsGroup`/`fsGroup` are all 1000, and they must move together.** The app writes
0600 files inside the volumes. Verified outside Kubernetes: `vibhuvioio/ldap-manager:1.0.0`
starts, serves `/api/auth/status`, `/health` and `/` with HTTP 200 as uid 1000, reading
`config.yml` through `LDAP_MANAGER_CONFIG`.

## Layout

```
├── Chart.yaml                      # the chart IS the repository root
├── values.yaml
├── README.md                       # user-facing; rendered by Artifact Hub
├── CONTRIBUTING.md                 # this file
├── LICENSE
├── artifacthub-repo.yml            # ownership claim; copied to gh-pages on release
├── ct.yaml                         # chart-testing config
├── hack/
│   ├── e2e-local.sh                # every e2e assertion, runnable locally
│   ├── gh-pages-index.html         # landing page copied into gh-pages
│   └── prune-versions.sh           # remove a published version from gh-pages
├── templates/
│   ├── _helpers.tpl
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── configmap.yaml
│   ├── secret.yaml
│   ├── pvc.yaml
│   ├── serviceaccount.yaml
│   ├── ingress.yaml
│   ├── poddisruptionbudget.yaml
│   └── NOTES.txt
└── .github/workflows/
    ├── lint.yml                    # helm lint --strict + kubeconform + invariants + metadata
    ├── ct.yml                      # ct lint, ct install on kind
    ├── e2e.yml                     # k3s: hack/e2e-local.sh
    └── release.yml                 # tag -> gh-pages + GitHub Release
```

## Removing a published version

A broken version keeps winning: Helm and Artifact Hub resolve the highest one.

```bash
hack/prune-versions.sh --dry-run 0.1.0
hack/prune-versions.sh 0.1.0
```
