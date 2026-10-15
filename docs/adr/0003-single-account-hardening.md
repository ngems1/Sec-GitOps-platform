# 0003: Single-account hardening instead of multi-account

Status: accepted (Phase 1, Day 4). Date: 2026-10-15.

## Context

The platform runs in one AWS account: the shared VPC and EKS cluster, the dev and prod data
stores, the Terraform state and the GitHub Actions roles. `terraform-aws/` is destroyed and
re-applied almost every day to save money. The deploy role had AdministratorAccess with no
ceiling, and the account had no audit trail, no threat detection and no configuration history.
The project has one maintainer and a one-week schedule for this phase.

## Options considered

1. **AWS Organizations with separate accounts** (security/log archive, dev, prod, CI), SCPs and
   IAM Identity Center.
   - Strongest isolation: a compromised dev or CI identity cannot reach prod or the logs.
   - Several accounts to bootstrap, cross-account roles in every workflow, the daily destroy split
     across accounts, more fixed cost (one trail, detector and recorder per account). Too much for
     one person in one week (DESIGN D-07).
2. **One account, hardened inside it**: an audit trail the CI cannot erase, threat detection,
   posture checks, and permission boundaries plus tag conditions on the CI roles.
   - Fits the schedule and the daily destroy; one bootstrap run.
   - Isolation is by policy, not by account: an admin principal in the account can still change
     everything, and a policy mistake has a larger blast radius.

## Decision

Option 2, applied by `terraform-bootstrap/` (never destroyed), not `terraform-aws/` (destroyed
daily: Object Lock files cannot be deleted, so a destroy of the audit bucket would fail):

- **CloudTrail**: one multi-region trail, log file validation, KMS key with rotation; S3 bucket with
  Object Lock in **GOVERNANCE** mode (30-day default retention), public access blocked, HTTPS
  only, files deleted after 90 days. GOVERNANCE rather than COMPLIANCE so an admin can still
  remove files in an emergency or when the project ends; the CI roles cannot.
- **GuardDuty**: detector on, foundational detection only; the paid protection plans are turned
  off. Findings with severity >= 7 go to Slack (`terraform-aws/security-alerts.tf`).
- **Security Hub**: only the AWS Foundational Security Best Practices standard.
- **AWS Config**: records the resource types the project uses (IAM, S3, VPC/EC2 without network
  interfaces and volumes, EKS, RDS, KMS), six managed rules (S3 public access, S3 encryption, RDS
  encrypted, RDS public, root access key, CloudTrail enabled).
- **Permission boundaries** on `week3-gha-plan` (read-only on the services terraform-aws uses, no
  secret values) and `week3-gha-deploy` (the services terraform-aws and the workflows use; denies
  on the security services, the audit bucket, the CI identities, IAM users and keys, admin managed
  policies). The lists were built from every AWS call in `terraform-aws/` and the workflows.
- **Tag-based access** (`aws:ResourceTag/Project`, `aws:ResourceTag/ManagedBy`,
  `aws:RequestTag/Project`) where the APIs support it: the deploy role cannot change resources
  of another project or anything the bootstrap made, and every role it creates must carry the
  project tag.

## Consequences

- A leaked or misused CI token cannot stop the trail, disable the detectors, delete audit files or
  widen its own rights; every API call in the account is recorded, verifiable and kept 30 days
  at least.
- A new AWS service in `terraform-aws` now needs a boundary change and a bootstrap run first; a
  missing action shows up as "explicit deny in a permissions boundary" (RUNBOOK section 1).
- The bootstrap is no longer a one-time step: it is re-run after every change to
  `terraform-bootstrap/`.
- Cost (estimate, to confirm with Cost Explorer after a month): about USD 25 to 60 a month after
  the 30-day GuardDuty and Security Hub trials. Fixed part about USD 2 (KMS key and requests, S3;
  the first trail's management events are free). The rest scales with the daily destroy/apply:
  AWS Config about USD 20 to 35 (USD 0.003 per recorded change; about 60 recorded resources are
  created and deleted each day, plus relationship updates), Security Hub checks and the Config
  rules it runs about USD 5 to 15, GuardDuty foundational about USD 3 to 8. The first lever if it
  is too much: record fewer EC2 types in `terraform-bootstrap/security.tf`.
- Still open: the deploy role can create a role without a boundary and give it inline rights;
  requiring a boundary on every role terraform-aws creates is the next step (SECURITY.md
  section 7). The security services cover `us-east-1` only.

## Revisit when

- The project gets a second maintainer or real customer data: move to AWS Organizations with a
  log-archive account (the trail and bucket move there; the boundaries become SCPs).
- The baseline costs more than about USD 60 a month (then record fewer EC2 types first).
