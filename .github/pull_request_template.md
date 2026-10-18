## What and why

<!-- One or two sentences: what this change does and why it is needed. -->

## Type

- [ ] Feature (`feature/...`)
- [ ] Fix (`fix/...`)
- [ ] Infrastructure / Terraform (`infra/...`)
- [ ] Pipeline / docs (`chore/...`, `docs/...`)

## Checks before merging

- [ ] `ci-ok` is green (unit tests, Helm render, image builds)
- [ ] Infrastructure changes: the Terraform plan in the `infra` check was read, nothing unexpected is destroyed
- [ ] No secrets, keys or passwords in the code
- [ ] Restarts Prometheus (`prometheus.prometheusSpec` in `monitoring/kube-prometheus-stack.values.yaml`: flags, resources, version): merged while cluster-status shows no Rollout progressing in `boutique-dev` or `boutique-prod` and no prod approval pending (RUNBOOK section 12, "Changes that restart Prometheus")

## After merging

Merging to `main` deploys to dev automatically, then waits for approval before prod.
