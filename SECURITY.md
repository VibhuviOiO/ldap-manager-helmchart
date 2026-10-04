# Security Policy

This repository publishes the `ldap-manager` Helm chart. For the application or image it
deploys, report against that project instead — see the links at the end.

## Reporting a vulnerability

**Please do not open a public issue.** Use GitHub's private reporting:

**→ [Report a vulnerability](https://github.com/VibhuviOiO/ldap-manager-helmchart/security/advisories/new)**

If you cannot use that, open a minimal public issue saying only that you have a security
report and asking for a private channel — never the details.

## What to expect

| Stage | Target |
| --- | --- |
| Acknowledgement | 3 business days |
| Initial assessment | 7 days |
| Fix or mitigation | 30 days for high and critical |

## Scope

**In scope**

- An **insecure default** in `values.yaml` — a rendered manifest that is weaker than the
  chart's own README claims
- A template that leaks a credential into a place it should not be: a container argument,
  a log line, an annotation, or a ConfigMap instead of a Secret
- `values.schema.json` permitting a combination the templates then handle unsafely
- Anything that lets one release reach another release's data

**Out of scope**

- OpenLDAP itself, and the LDAP Manager application — both have their own policies
- The published **image** contents; report those against `openldap-docker` or `ldap-manager`
- Findings that require an already-compromised cluster
- Missing hardening with no demonstrated impact, such as a probe path without authentication

## Design notes relevant to reports

A few properties are deliberate:

- **The chart refuses to render without credentials.** `fail` fires if neither a password nor
  `existingSecret` is set. A directory with a predictable admin password is worse than one
  that failed to start.
- **`podDisruptionBudget.maxUnavailable` defaults to 1.** Lowering it is a deliberate trade of
  rollout speed for availability, not an oversight.
- **Persistence carries `helm.sh/resource-policy: keep` where losing the volume would lose
  data** — for `ldap-manager`, that is `/app/.secrets`, which holds the session signing key.
- **The chart is signed.** Verify with `helm verify <chart>.tgz` before installing; the public
  key is in the repository.

## Related policies

- `openldap-docker` — the container image
- `ldap-manager` — the web UI and API
