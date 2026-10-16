# Connect GitHub to AWS (bootstrap)

Everything in AWS is created by GitHub Actions, except **one login role** that has to exist first. Otherwise GitHub would have no way in. This guide is that one-time setup: about 15 minutes of clicks, then two workflow runs.

```
You (once, in the console):  GitHub OIDC provider + week3-bootstrap role
        ↓
bootstrap workflow (Terraform):  state bucket + week3-gha-plan + week3-gha-deploy (with permission boundaries)
                                 + audit baseline: own CloudTrail trail (Object Lock bucket, KMS key), AWS Config rules
        ↓
infra / deploy workflows:  everything else, with the plan or deploy role
```

| Role | Created by | Used by | Rights |
|---|---|---|---|
| `week3-bootstrap` | You, by hand | `bootstrap` workflow, only in the protected `prod` environment | Admin (it creates IAM roles) |
| `week3-gha-plan` | bootstrap workflow | Pull-request plans | Read-only, plus the Terraform state lock; boundary: reads of the services terraform-aws uses only |
| `week3-gha-deploy` | bootstrap workflow | `main` branch, `dev` / `prod` environments | Admin (applies Terraform, deploys), capped by a permission boundary (SECURITY.md section 2a) |

So a pull request from any branch can only **read**. Changes need a merge to `main` or an approved environment.

## 1. GitHub: create the environments

Repo > **Settings > Environments > New environment**:

1. Create **`dev`** with no rules.
2. Create **`prod`**. Tick **Required reviewers** and add yourself.

On a **private** repo with a free GitHub plan, required reviewers aren't available. Either make the repo public (it contains no secrets) or skip the reviewer; everything else still works.

## 2. AWS console: GitHub login provider

Region **us-east-1**. **IAM > Identity providers > Add provider**:

1. **Provider type:** OpenID Connect.
2. **Provider URL:** `https://token.actions.githubusercontent.com`
3. **Audience:** `sts.amazonaws.com`. Click **Add provider**.

If it already exists, skip this step: only one is allowed per account.

## 3. AWS console: the bootstrap role

1. **IAM > Roles > Create role > Custom trust policy**.
2. Paste this, replacing `<ACCOUNT_ID>` (12 digits, top-right menu), `<OWNER>` (your GitHub username) and `<REPO>` (repo name, same upper/lower case as on GitHub):

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": {
           "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
           "token.actions.githubusercontent.com:sub": "repo:<OWNER>@<OWNER_ID>/<REPO>@<REPO_ID>:environment:prod"
         }
       }
     }]
   }
   ```

   The `environment:prod` part means only jobs running in the protected `prod` environment can use this role.

   **The `sub` format.** Repositories created after 15 July 2026 identify themselves with immutable IDs: `repo:ngems1@330211773/Sec-GitOps-platform@<REPO_ID>:environment:prod` for this repo (the repository ID changed when the project moved to Sec-GitOps-platform). Older repositories use `repo:<OWNER>/<REPO>:environment:prod`. The step "Show the identity GitHub presents to AWS" in the bootstrap run prints the exact value: copy it **whole**, including `:environment:prod`.

3. **Next**, then tick **AdministratorAccess**, then **Next**.
4. **Name:** `week3-bootstrap`. Click **Create role**, then copy its **ARN**.
5. Back in GitHub: **Settings > Environments > prod > Environment variables > Add variable**:
   - `AWS_BOOTSTRAP_ROLE_ARN` = the ARN you copied

## 4. GitHub: repository variables

**Settings > Secrets and variables > Actions > Variables > New repository variable**:

| Variable | Value |
|---|---|
| `AWS_REGION` | `us-east-1` |
| `ADMIN_PRINCIPAL_ARN` | Your IAM user's ARN (**IAM > Users > you**), for `kubectl` access to the cluster. Not the root user. |

## 5. Run the bootstrap workflow

1. **Actions > bootstrap > Run workflow**, with **apply unchecked**. If `prod` has a reviewer, approve the run. Open the run's **Summary** and read the plan: it should create the bucket and 2 roles.
2. **Run workflow** again, with **apply checked**. Approve the run.
3. The run's **Summary** ends with a table. Add each line as a **repository variable**:
   `AWS_PLAN_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`, `TF_STATE_BUCKET`, `BUDGET_ALERTS_TOPIC_ARN` (the Bedrock daily budget topic: once set, the next `infra` apply sends its alerts to Slack). `AWS_REGION` is already set.

Then continue with SETUP.md step 5 (`infra` > `apply`).

## If something goes wrong

| Error | Fix |
|---|---|
| "Set the AWS_BOOTSTRAP_ROLE_ARN variable" | The variable must be on the **prod environment**, not the repository (step 3.5) |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Compare the `sub` printed in the step "Show the identity GitHub presents to AWS" with the trust policy (step 3.2). Case and spelling must match exactly. |
| `No OpenIDConnect provider found` | Step 2 is missing, or was done in another AWS account |
| A run failed half-way | Run it again: resources that already exist are imported, not duplicated |
| The plan lists GuardDuty, a Config recorder or Security Hub | It must not: those are shared account services of another project, never managed here (SECURITY.md section 2a). Stop and check `terraform-bootstrap/` for a resource that was added back |

## Re-running after a change in `terraform-bootstrap/`

The bootstrap is not only one-time: the CI roles' permission boundaries and this project's audit
baseline (its CloudTrail trail, Object Lock bucket, KMS key and AWS Config rules) live here too, because `terraform-aws` is
destroyed every day. After a merge that changes `terraform-bootstrap/`, run **bootstrap** with
**apply unchecked**, read the plan, then run it again with **apply checked**. A new AWS service in
`terraform-aws` needs its line in `terraform-bootstrap/boundaries.tf` and this run **before** the
infra apply that uses it.

## Security notes (for the demo)

- **No keys anywhere:** GitHub gets credentials valid for at most 2 hours, through OIDC.
- **Least privilege:** pull requests can't change anything (`week3-gha-plan` is read-only).
- **Admin rights are gated:** the admin roles only work from `main` or a protected environment.
- **Permission boundaries:** `week3-gha-deploy` still has AdministratorAccess, but its boundary limits it to the services Terraform and the workflows use, and denies touching the audit trail, the security services, the CI roles and resources of other projects (`terraform-bootstrap/boundaries.tf`, ADR 0003).
- You can delete `week3-bootstrap` after a bootstrap run and recreate it only when `terraform-bootstrap/` changes.

## Shared account services (not managed here)

This AWS account also hosts another project, which already runs **GuardDuty**, the **AWS Config
recorder** (with its delivery channel) and **Security Hub** with the Foundational Security Best
Practices standard. AWS allows each of them only once per account and region, so this project uses
them as they are: the bootstrap never imports, tags or changes them, and a bootstrap plan must show
**no** change to them. This project adds only its own trail, bucket, key and Config rules (the rules
are evaluated by the shared recorder). Owning these services needs a separate AWS account (future
work, ADR 0003).
