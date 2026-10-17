# 0003: Single-account hardening instead of multi-account

Status: accepted (Phase 1, Day 4). Date: 2026-10-15. Amended 2026-10-15: shared account services.

> **Update 2026-10-17:** this ADR first spoke of a "daily destroy". That was the habit of tearing
> `terraform-aws/` down at the end of a working day; nothing does it on a schedule, only a manual
> `infra` run with `action = destroy`. The decision does not depend on how often it happens, only
> on `terraform-aws/` being destroyed at all (Object Lock, tag conditions), so it is unchanged.

## Context

The platform runs in one AWS account: the shared VPC and EKS cluster, the dev and prod data
stores, the Terraform state and the GitHub Actions roles. `terraform-aws/` is destroyed and
re-applied often, by hand (`infra` with `action = destroy`), to save money. The deploy role had AdministratorAccess with no
ceiling, and the project had no audit trail of its own. The project has one maintainer and a
one-week schedule for this phase.

The account also hosts **another project**, which already runs GuardDuty, the AWS Config recorder
(with its delivery channel) and Security Hub with the AWS Foundational Security Best Practices
(FSBP) standard. AWS allows each of these only once per account and region, so this project
cannot create its own, and they are not its to import, re-tag or change.

## Options considered

1. **AWS Organizations with separate accounts** (security/log archive, dev, prod, CI), SCPs and
   IAM Identity Center.
   - Strongest isolation: a compromised dev or CI identity cannot reach prod or the logs, and this
     project would own its own detector, recorder and hub.
   - Several accounts to bootstrap, cross-account roles in every workflow, every destroy split
     across accounts, more fixed cost. Too much for one person in one week (DESIGN D-07).
2. **One account, hardened inside it**: an audit trail the CI cannot erase, permission boundaries
   and tag conditions on the CI roles, and the account's security services as they are.
   - Fits the schedule and the frequent destroy and apply; one bootstrap run.
   - Isolation is by policy, not by account; the detector, recorder and hub are someone else's.

## Decision

Option 2. What this project owns is created by `terraform-bootstrap/` (never destroyed, tagged
`Project = week3-boutique`, `ManagedBy = terraform-bootstrap`), not `terraform-aws/` (destroyed
by every `infra` destroy: Object Lock files cannot be deleted, so a destroy of the audit bucket would fail):

- **CloudTrail (owned)**: this project's own multi-region trail, log file validation, KMS key with
  rotation; S3 bucket with Object Lock in **GOVERNANCE** mode (30-day default retention), public
  access blocked, HTTPS only, files deleted after 90 days. GOVERNANCE rather than COMPLIANCE so an
  admin can still remove files in an emergency or when the project ends; the CI roles cannot.
- **AWS Config rules (owned)**: six managed rules named `week3-boutique-*` (S3 public access, S3
  encryption, RDS encrypted, RDS public, root access key, CloudTrail enabled), evaluated by the
  shared recorder.
- **Permission boundaries** on `week3-gha-plan` (read-only on the services terraform-aws uses, no
  secret values) and `week3-gha-deploy` (the services terraform-aws and the workflows use; denies
  on the security services, ours and the shared ones, the audit bucket, the CI identities, IAM
  users and keys, admin managed policies). The lists were built from every AWS call in
  `terraform-aws/` and the workflows.
- **Tag-based access** (`aws:ResourceTag/Project`, `aws:ResourceTag/ManagedBy`,
  `aws:RequestTag/Project`) where the APIs support it: the deploy role cannot change resources
  tagged with another `Project` (such as the other project's) or anything the bootstrap made, and
  every role it creates must carry the project tag.

**Shared, relied on, not owned:** GuardDuty, the AWS Config recorder and delivery channel, and
Security Hub with FSBP. The bootstrap never imports, tags or changes them. This project only reads
GuardDuty's findings: severity >= 7 goes to Slack (`terraform-aws/security-alerts.tf`).

## Consequences

- A leaked or misused CI token cannot stop the trail, change the detectors, delete audit files or
  widen its own rights; every API call in the account is recorded in this project's own bucket,
  verifiable and kept 30 days at least.
- The settings of GuardDuty (protection plans), the recorder (recorded types, delivery) and
  Security Hub (standards), and whether they stay on at all, are decided by the other project.
- A new AWS service in `terraform-aws` now needs a boundary change and a bootstrap run first; a
  missing action shows up as "explicit deny in a permissions boundary" (RUNBOOK section 1).
- The bootstrap is no longer a one-time step: it is re-run after every change to
  `terraform-bootstrap/`.
- Cost of what this project adds (estimate, to confirm with Cost Explorer after a month): about
  USD 8 to 22 a month. The other project already has a trail, so this one is a second copy of the
  management events, billed at about USD 2 per 100,000 events (about USD 6 to 20 for this account);
  KMS and S3 about USD 2; the six Config rules under USD 1. GuardDuty, the recorder and Security
  Hub are billed to the same account whoever owns them, and this project's destroy and apply
  cycles add to what they record and check.
- Still open: the deploy role can create a role without a boundary and give it inline rights;
  requiring a boundary on every role terraform-aws creates is the next step (SECURITY.md
  section 7).

## Revisit when

- The project needs control over its detector, recorder or hub, gets a second maintainer or real
  customer data: move to its own AWS account (AWS Organizations with a log-archive account; the
  trail and bucket move there, the boundaries become SCPs).
- The second trail costs more than it is worth: drop it if the other project's trail is trusted,
  or move to a separate account.
