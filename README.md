# Finzla Platform — Cloud & Platform Engineer Technical Assessment

A small, secure, production-shaped AWS deployment platform for a Finzla backend
service, built with **Python (FastAPI)**, **Docker**, **Terraform**, **AWS ECS
Fargate**, and **GitHub Actions with OIDC**.

The repository contains everything required to build, ship, and operate the
service: application source, Dockerfile, Terraform (modular, dev + prod),
GitHub Actions workflows, and this README.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Why ECS Fargate (and why not EKS/App Runner)](#2-why-ecs-fargate-and-why-not-eksapp-runner)
3. [Repo Layout](#3-repo-layout)
4. [Local Run](#4-local-run)
5. [Terraform](#5-terraform)
6. [CI/CD](#6-cicd)
7. [Security](#7-security)
8. [Monitoring](#8-monitoring)
9. [Incident Investigation](#9-incident-investigation)
10. [Engineering Judgement](#10-engineering-judgement)
11. [Evidence](#11-evidence)
12. [Cleanup](#12-cleanup)

---

## 1. Overview

This repository deploys a small FastAPI HTTP service to AWS. It provides two
contract endpoints and runs as a non-root container on ECS Fargate behind an
Application Load Balancer.

**Request path — Internet → AWS → Application:**

```
Internet
   │
   ▼
Route 53 (DNS)
   │
   ▼
AWS WAF (rate-limit, OWASP)         [recommended, optional in this repo]
   │
   ▼
Application Load Balancer  ── public subnets, HTTPS:443, ACM cert
   │                          HTTP:80 → 301 redirect to HTTPS
   ▼
Target Group  ── HTTP:8080, health check GET /health (matcher 200)
   │
   ▼
ECS Fargate Task  ── private subnets, no public IP
   │
   ▼
Container  ── uvicorn on 0.0.0.0:8080
   │
   ├── outbound via NAT Gateway
   ├── logs → CloudWatch Logs (/ecs/finzla-<env>)
   └── metrics → CloudWatch / Container Insights
```

**Key security properties:**

- The ALB is the only public-facing component.
- The task SG allows ingress on 8080 **only from the ALB SG** — never from a CIDR.
- Tasks live in **private subnets** with `assign_public_ip = false`.
- TLS 1.3 policy `ELBSecurityPolicy-TLS13-1-2-2021-06` on the HTTPS listener.
- No long-lived AWS credentials anywhere — GitHub authenticates via OIDC.

**Architecture diagram:** see `docs/architecture.png`.

---

## 2. Why ECS Fargate (and why not EKS/App Runner)

**Chosen: ECS on Fargate behind an Application Load Balancer.**

| Requirement | Why ECS Fargate wins |
|---|---|
| Small service, no dedicated K8s ops team | No control plane to manage; EKS adds ~$73/mo plus operational overhead |
| Least privilege | Task-level IAM roles; no node-level IAM complexity |
| Speed to production | Native ALB, CloudWatch, Secrets Manager integration |
| Cost control | Per-task billing; no idle worker nodes |
| Security | No SSH, no EC2 patching, immutable tasks, task-level SGs |

**Rejected — EKS:** for a single small service, EKS adds unnecessary cost, a
control-plane attack surface, and significant operational burden with no
benefit. **Rejected — App Runner:** it hides the network and IAM design that
this assessment exists to demonstrate.

---

## 3. Repo Layout

```
finzla-platform/
├── app/
│   ├── main.py
│   ├── requirements.txt
│   ├── Dockerfile
│   └── tests/test_main.py
├── terraform/
│   ├── bootstrap/                  # S3 + DynamoDB for remote state
│   ├── modules/
│   │   ├── network/                # VPC, subnets, NAT, routing
│   │   ├── ecr/                    # Image repo + lifecycle + scan-on-push
│   │   ├── alb/                    # ALB, listeners, target group
│   │   ├── iam/                    # ECS task-execution & task roles
│   │   ├── ecs/                    # Cluster, task def, service, logs
│   │   └── observability/          # CloudWatch alarms + SNS
│   └── environments/
│       ├── dev/                    # backend.tf, main.tf, variables.tf, tfvars, outputs.tf
│       └── prod/                   # same shape, prod sizing / retention
├── .github/workflows/
│   ├── pr.yml                      # PR validation
│   ├── deploy-dev.yml              # push to main → dev
│   └── deploy-prod.yml             # tag / manual → prod (approval gate)
├── docs/
│   └── architecture.png
├── .gitignore
├── .dockerignore
└── README.md
```

Each Terraform module and environment has its own `main.tf`, `variables.tf`,
`outputs.tf` (and `versions.tf` where relevant). **All variables are separated
per file as required.**

---

## 4. Local Run

```bash
# Build
docker build -t finzla-app:local ./app

# Run
docker run --rm -p 8080:8080 \
  -e APP_ENV=local \
  -e APP_VERSION=dev \
  finzla-app:local

# Verify
curl -i http://localhost:8080/health
curl -i http://localhost:8080/version
```

Run tests:

```bash
pip install -r app/requirements.txt pytest httpx
pytest app/tests -q
```

The container:

- listens on `0.0.0.0:8080`,
- reads `APP_ENV`, `APP_VERSION`, `GIT_SHA`, `LOG_LEVEL` from the environment,
- writes **structured JSON to stdout/stderr** (no files),
- runs as non-root user `appuser` (UID 10001),
- declares a `HEALTHCHECK` calling `/health`,
- contains **no credentials or secrets** in source.

---

## 5. Terraform

### 5.1 Bootstrap (one-time, per AWS account)

`terraform/bootstrap/` creates:

- S3 bucket `finzla-tfstate-<ACCOUNT_ID>` — versioned, SSE-AES256, public access blocked.
- DynamoDB table `finzla-tflock` — `LockID` hash key, pay-per-request.

Apply once with a break-glass admin role, then do not use that role for
day-to-day work.

### 5.2 Modules

| Module | Responsibility |
|---|---|
| `network` | VPC, public/private subnets, IGW, NAT (per-AZ in prod, single in dev), route tables |
| `ecr` | Immutable image repo, scan-on-push, lifecycle policy keeping 10 images |
| `alb` | Internet-facing ALB, HTTPS listener + HTTP→HTTPS redirect, target group with `/health` check |
| `iam` | ECS task-execution role (one secret + one log group) and task role (logs only) |
| `ecs` | ECS cluster (Container Insights on), task definition, service with **deployment circuit breaker + rollback**, CloudWatch log group, task SG |
| `observability` | CloudWatch alarms for 5xx, unhealthy hosts, CPU; SNS topic |

### 5.3 Environments

- `terraform/environments/dev/` — single NAT, 1 task, 14-day log retention, deletion protection off.
- `terraform/environments/prod/` — multi-AZ NAT, 3 tasks, 365-day log retention, deletion protection on.

Both share modules; differences live in `terraform.tfvars` and small
`main.tf` overrides. **No secrets are stored in tfvars** — only ARNs and
non-sensitive values.

### 5.4 Commands

```bash
# Format & validate (repo-wide)
terraform fmt -check -recursive terraform
(cd terraform/environments/dev && terraform init -backend=false && terraform validate)
(cd terraform/environments/prod && terraform init -backend=false && terraform validate)

# Plan / apply (dev example)
cd terraform/environments/dev
terraform init
terraform plan  -lock-timeout=5m -out=tfplan
terraform apply -lock-timeout=5m tfplan
```

### 5.5 Remote State & Locking without AdministratorAccess

**Remote state:**

- Stored in S3 (`finzla-tfstate-<ACCOUNT_ID>`), SSE-AES256, versioned, public access blocked.
- Per-environment keys: `dev/terraform.tfstate`, `prod/terraform.tfstate`.
- CI assumes a role scoped to only `s3:GetObject/PutObject/ListBucket` on that prefix.

**Locking & concurrency:**

- DynamoDB table `finzla-tflock` holds a `LockID` item per state file.
- Terraform acquires the lock on plan/apply; `-lock-timeout=5m` avoids transient conflicts.
- Prod applies run **only** through the protected `prod` GitHub Environment, so two concurrent prod applies cannot happen.
- PR plans use a read-only role with no state-write permissions.

**Environment separation:**

| Aspect | Dev | Prod |
|---|---|---|
| State key | `dev/terraform.tfstate` | `prod/terraform.tfstate` |
| CI role | `gha-finzla-dev` | `gha-finzla-prod` (env-protected) |
| NAT | single | one per AZ |
| Tasks | 1 | 3 |
| Log retention | 14 days | 365 days |
| Deletion protection | off | on |
| Approval | none | 2 required reviewers |

Promotion is by re-running the **same immutable image tag** against the prod
environment — never by copying state.

---

## 6. CI/CD

### 6.1 Pull Request — `.github/workflows/pr.yml`

On every PR to `main`, the pipeline runs:

- **Terraform formatting:** `terraform fmt -check -recursive`.
- **Terraform validation:** `terraform validate` for `dev` and `prod`.
- **Terraform plan:** `terraform plan` for `dev` and `prod` (read-only plan role via OIDC).
- **Application build/test:** `docker build` + `pytest` unit tests.
- **Security check:** Trivy image scan fails the PR on HIGH/CRITICAL vulnerabilities.

All checks are required before merge.

### 6.2 Dev deployment — `.github/workflows/deploy-dev.yml`

Triggered on push to `main`:

1. Build Docker image, tagged with the git SHA.
2. Push to ECR `finzla-dev` (immutable tag).
3. `terraform apply -var="image_tag=<sha>"` in `environments/dev`.
4. `aws ecs wait services-stable`.
5. Poll `https://<alb>/health` until HTTP 200 (fail otherwise).
6. On failure, roll back to the previous task definition.

No approval required — this is the fast feedback loop.

### 6.3 Prod deployment — `.github/workflows/deploy-prod.yml`

Triggered by a `v*` tag or manual `workflow_dispatch`, and gated by the GitHub
**Environment `prod`** (2 required reviewers, deployment branches restricted to
`main` and tags).

Same flow as dev, against `environments/prod`, using the `gha-finzla-prod`
OIDC role.

### 6.4 Authentication — GitHub Actions to AWS via OIDC

**No permanent AWS access keys are stored in GitHub.** Workflows request a
short-lived OIDC token from GitHub and exchange it for temporary AWS
credentials via `sts:AssumeRoleWithWebIdentity`.

**AWS OIDC trust policy (created once, out of band):**

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": [
          "repo:Finzla/finzla-platform:ref:refs/heads/main",
          "repo:Finzla/finzla-platform:environment:prod"
        ]
      }
    }
  }]
}
```

Two IAM roles are created:

- **`gha-finzla-dev`** — build & deploy dev, no approval needed.
- **`gha-finzla-prod`** — deploy prod, gated by GitHub Environment `prod` with required reviewers.

### 6.5 Deployment pipeline summary

```
Pull Request
  → app build + unit tests
  → Trivy image scan
  → terraform fmt -check
  → terraform validate (dev & prod)
  → terraform plan (dev & prod)
  → Review & Merge

main push
  → build image, tag = git SHA
  → push to ECR (immutable tag)
  → terraform apply (dev)
  → aws ecs wait services-stable
  → HTTPS GET /health until 200
  → on failure: rollback ECS to previous task definition

Tag push (v*) or workflow_dispatch
  → GitHub Environment: prod (2 required reviewers)
  → same build/push/apply/verify/rollback flow against prod
```

### 6.6 Handling unhealthy deployments

- **ECS deployment circuit breaker** (`enable = true, rollback = true`) detects
  unhealthy rollouts and automatically rolls back to the previous task definition.
- The GitHub Actions workflow additionally performs an explicit rollback step
  (`aws ecs update-service --task-definition <previous>`) if the post-deploy
  health check fails.
- The ALB keeps serving from healthy tasks during the rollout.

### 6.7 What prevents another repo, a compromised workflow, or an individual developer from freely deploying into production?

1. **OIDC trust `sub` is pinned** to `repo:Finzla/finzla-platform:environment:prod`. A fork or another repository cannot obtain a token for that subject.
2. **GitHub Environment `prod`** requires **2 reviewers** and restricts deployment to `main` and `v*` tags. No workflow run can obtain prod credentials without approval.
3. **Branch protection on `main`** requires PRs, reviews, and passing checks; direct pushes are blocked.
4. **Least-privilege IAM** — the prod role can update only the specific ECS service/task definition, push only to the prod ECR repo, and read only the prod state prefix. It cannot modify IAM, delete the cluster, or touch dev.
5. **Immutable image tags + Trivy scanning** prevent silent overwrites and known-CVE images.
6. **CloudTrail + GuardDuty** alert on anomalous `AssumeRoleWithWebIdentity`, `ecr:PutImage`, and `ecs:UpdateService` activity.

---

## 7. Security

### 7.1 Least-privilege summary

- No `AdministratorAccess` on any CI, ECS, or application role.
- ECS **task execution role** — pulls only its own image, writes only to its own log group, reads one specific secret ARN, decrypts with one KMS CMK.
- ECS **task role** — logs only; the app has no other AWS permissions.
- GitHub OIDC roles — scoped per environment, repository, and subject.
- S3 state bucket — public access blocked, SSE enabled, versioned.
- Secrets — Secrets Manager + KMS CMK; injected into the task definition by ARN.
- Networking — HTTPS-only ALB, HTTP→HTTPS redirect, private subnets, SG-to-SG ingress.

### 7.2 Most security-sensitive IAM role — `gha-finzla-prod`

1. **What it can do:** Assume via OIDC only from the `prod` GitHub Environment; push to the prod ECR repo; register task definitions and update the prod ECS service; read/write the prod Terraform state prefix.
2. **Why these permissions are required:** without them, CI cannot build the artifact, apply Terraform, or roll the ECS service. Every permission maps directly to a pipeline step.
3. **What could happen if compromised:** an attacker could push a malicious image and deploy it to production, gaining the app's task role and network position inside the VPC.
4. **What limits its blast radius:**
   - Trust policy pins `sub` to a single repo + `environment:prod`.
   - Prod GitHub Environment requires 2 approvers — no silent deploy.
   - Cannot delete the cluster, modify IAM, read other secrets, or touch dev.
   - ECS deployment circuit breaker auto-rolls back unhealthy releases.
   - Image scanning + branch protection + required reviews gate `main`.
   - CloudTrail + GuardDuty detect anomalous use.

### 7.3 Other security controls

- **HTTPS/TLS:** ACM certificate on the ALB, TLS 1.3 policy, HTTP redirected to HTTPS.
- **Encryption in transit:** all external traffic over TLS.
- **Encryption at rest:** S3 SSE-AES256, CloudWatch Logs KMS CMK, Secrets Manager KMS CMK.
- **Secure secrets management:** AWS Secrets Manager; values never in source, tfvars, or env files.
- **Secure GitHub→AWS authentication:** OIDC short-lived credentials only.
- **Environment separation:** separate state, IAM roles, SGs, clusters, secrets; multi-account recommended.

### 7.4 Security group design

- **ALB SG:** ingress 443 (and 80 for redirect) from `0.0.0.0/0`; egress to task SG on 8080.
- **Task SG:** ingress 8080 **from the ALB SG only**; egress 0.0.0.0/0 for NAT-routed outbound (ECR, Secrets Manager, Logs via VPC endpoints where possible).

---

## 8. Monitoring

### 8.1 Metrics (≥3)

| Metric | Source | Why it matters |
|---|---|---|
| `HTTPCode_Target_5XX_Count` | ALB | Direct signal of user-facing errors |
| `TargetResponseTime` (p99) | ALB | Latency regression before users complain |
| `UnHealthyHostCount` | ALB Target Group | Immediate fleet health |
| `CpuUtilized` / `MemoryUtilized` | ECS Container Insights | Capacity and leak detection |
| `RunningTaskCount` vs `DesiredCount` | ECS | Crash-loop / deployment detection |

### 8.2 Alerts (≥2)

**Alert 1 — ALB 5xx rate**

- **Trigger:** `HTTPCode_Target_5XX_Count > 5` for 2 consecutive 1-minute periods.
- **Why it matters:** users are receiving errors — primary SLO breach.
- **Who receives it:** on-call engineer (SNS → PagerDuty); CC `#finzla-alerts`.
- **First investigation step:** CloudWatch Logs Insights on ALB access logs filtered for `status >= 500`; identify the failing path and the deployed task definition revision.

**Alert 2 — Unhealthy targets**

- **Trigger:** `UnHealthyHostCount > 0` for 1 minute.
- **Why it matters:** if all tasks become unhealthy, users see 503s.
- **Who receives it:** on-call engineer; escalate to service owner after 10 minutes.
- **First investigation step:** `aws ecs describe-services` for service events, then `aws logs tail /ecs/finzla-<env>` for the failing task's stderr; manually `curl /health` from a bastion/VPN.

**Alert 3 — ECS CPU high**

- **Trigger:** `CpuUtilized > 80%` average for 3 minutes.
- **Why it matters:** early warning for latency/5xx under load.
- **Who receives it:** on-call engineer (warning channel, not page).
- **First investigation step:** compare request rate to capacity; consider scaling `desired_count` or raising task CPU.

### 8.3 Logs

- **Location:** CloudWatch Logs group `/ecs/finzla-<env>`, stream prefix `app`, one stream per task.
- **Format:** structured JSON written to stdout/stderr by the container.
- **Retention:** dev = 14 days; prod = **365 days**, KMS-encrypted. Long-term archival to S3 via subscription filter if required for audit.
- **Access:** read-only IAM policy (`logs:FilterLogEvents`, `logs:GetLogEvents`) scoped to the group; no delete permission.

---

## 9. Incident Investigation

**Scenario:** A new release was just deployed. GitHub Actions reports
*Deployment successful*. ECS reports *Expected tasks running*. Customers are
receiving **HTTP 503**, and the ALB reports **unhealthy targets**.

### 9.1 What to investigate first

The gap between "tasks running" and "targets unhealthy" almost always means the
container is up but **failing the ALB health check**.

1. `aws elbv2 describe-target-health --target-group-arn <tg>` → confirm state and `Reason`.
2. ALB access logs for `/health` → see what status the ALB actually received.
3. ECS service events + task logs → look for app startup errors.

### 9.2 AWS services, logs, and metrics to inspect

- **ELBv2:** `describe-target-health`, target group attributes, ALB access logs.
- **ECS:** `describe-services` events, `describe-tasks` (`lastStatus`, `stoppedReason`), current task definition revision.
- **CloudWatch Logs:** `/ecs/finzla-<env>` for startup errors and health-check hits.
- **CloudWatch Metrics:** `UnHealthyHostCount`, `HTTPCode_Target_5XX_Count`, `TargetResponseTime`.
- **Container Insights:** task CPU/memory (OOM kill shows as task stopped, not unhealthy).
- **Security Groups:** verify the task SG still allows ingress from the ALB SG.
- **Secrets Manager / KMS:** verify the secret ARN exists and the task execution role can decrypt it.
- **ECS deployment state:** was the circuit breaker tripped?

### 9.3 Three possible causes — proof & elimination

**Cause A — App listening on the wrong port or host.**

- *Proof:* Task logs show uvicorn on `:8000`, but the target group expects `:8080`; ALB access logs show connection refused.
- *Eliminate:* run the image locally with `-p 8080:8080` and `curl /health`; check `CMD`, `PORT` env, and `containerPort` in the task definition against the target group port.

**Cause B — Health-check path or matcher mismatch.**

- *Proof:* ALB access logs show `/health` returning 404 or 204 while the matcher expects 200.
- *Eliminate:* `curl -i https://<alb>/health` from outside; compare target group `health_check.path`/`matcher` with FastAPI routes. Restore the route or update the matcher.

**Cause C — App crashes on startup due to missing/invalid config or secret.**

- *Proof:* Task logs show a traceback at boot (e.g., `KeyError`, KMS `AccessDenied`); tasks restart repeatedly; ALB marks them unhealthy.
- *Eliminate:* inspect `describe-tasks` `stoppedReason` and the log stream; verify the task execution role can read the secret ARN and decrypt with KMS; verify the secret value exists.

**Cause D (bonus) — Security group regression.**

- *Proof:* Task SG no longer allows ingress from the ALB SG; health checks time out.
- *Eliminate:* `aws ec2 describe-security-groups` on both SGs; test connectivity from an EC2 in the same SG. Nightly Terraform drift detection would catch this.

### 9.4 Safest immediate recovery

Roll back the ECS service to the previous task definition revision:

```bash
aws ecs update-service \
  --cluster finzla-prod-cluster \
  --service finzla-prod-svc \
  --task-definition finzla-prod-task:<PREVIOUS_REVISION> \
  --force-new-deployment

aws ecs wait services-stable \
  --cluster finzla-prod-cluster \
  --services finzla-prod-svc
```

The ECS deployment circuit breaker should already have done this automatically;
the manual step is a belt-and-braces confirmation. If the previous revision is
also unhealthy, scale the service to 0 and serve a fixed-response maintenance
page at the ALB while root-causing.

### 9.5 Preventing recurrence

- **Pre-deploy smoke tests in CI** — the workflow already hits `/health` and `/version` and fails on non-200.
- **ECS deployment circuit breaker** always on.
- **Canary / blue-green** via CodeDeploy for prod (linear 10% → 50% → 100%, auto-rollback on 5xx).
- **Contract test** in the PR pipeline that the image exposes `/health` on the expected port.
- **Nightly Terraform drift detection** (`terraform plan -detailed-exitcode`).
- **CloudWatch Synthetics canary** hitting `/health` every minute, alerting before customers notice.
- **Runbook + game day** rehearsing this exact scenario quarterly.

---

## 10. Engineering Judgement

### 10.1 Architecture

- **Chosen:** ECS Fargate behind an ALB — smallest operational surface for a single small service, native ALB/CloudWatch/Secrets integration, per-task least privilege, no nodes to patch, immutable tasks for auditability.
- **Rejected alternative:** **EKS** — overkill at this scale; adds cost, control-plane, and attack surface. **App Runner** — hides the network/IAM design this assessment exists to demonstrate.

### 10.2 Reliability

- **If a new deployment fails health checks:** the ECS deployment circuit breaker detects it, stops the rollout, and automatically rolls back to the last known-good task definition. The ALB keeps serving from healthy old tasks during the rollout. CI additionally fails on the post-deploy health check and executes a rollback step.
- **How to roll back:** (1) automatic circuit breaker, (2) CI rollback step calling `aws ecs update-service --task-definition <previous>`, (3) manual command from the runbook. Immutable SHA tags mean the previous artifact is always in ECR.

### 10.3 Cost

- **Two largest likely drivers:**
  1. **NAT Gateway** — hourly + data processing (one per AZ in prod for HA).
  2. **ALB** — hourly + LCU (plus Fargate vCPU/GB-hours as a close third).
- **Controls:** single NAT in dev; VPC endpoints for ECR/S3/Secrets Manager/Logs to avoid NAT data charges; Fargate Spot in dev; right-size task CPU/memory from Container Insights; ALB only in prod; ECR lifecycle keeping 10 images; tuned log retention per env; AWS Budgets alerts.

### 10.4 Production readiness — top 3 improvements for a fintech platform

1. **Multi-account isolation** via AWS Organizations + Control Tower: separate accounts for dev, staging, prod, and a dedicated log-archive/security account; SCPs prevent cross-account changes.
2. **WAF + Shield Advanced + strict TLS/mTLS** in front of the ALB; **secrets rotation** with Secrets Manager rotation Lambdas; **KMS CMKs** per environment with tight key policies; **GuardDuty, Security Hub, CloudTrail org trail, AWS Config rules**.
3. **Blue-green / canary deployments with SLO-based alerts**, synthetic canaries, on-call rotation, tested runbooks, and chaos/game-day drills — fintech requires provable resilience and audit trails.

Near-term extras: SOC 2 / PCI evidence collection, image signing (cosign + ECR), SBOM generation, and dependency scanning in CI.

---

## 11. Evidence

The repository contains (or this README documents how to reproduce):

- `docker build` output, plus `docker run` and `curl /health` returning 200.
- `terraform fmt -check -recursive` → clean.
- `terraform validate` for `dev` and `prod` → success.
- `terraform plan` output saved under `docs/evidence/`.
- PR workflow logs (pytest + Trivy + fmt + validate + plan) passing.
- Dev deploy workflow logs: build → push → `terraform apply` → `aws ecs wait services-stable` → `/health` 200.
- `aws elbv2 describe-target-health` output showing `healthy`.
- `docs/architecture.png` diagram.

If you choose **not** to perform a live AWS deployment, the Terraform and
workflows are complete enough for another engineer to deploy as-is.

**No AWS credentials, passwords, access tokens, private keys, or other secrets
are ever committed.** `.gitignore` excludes `*.tfstate*`, `.env`, `*.pem`,
`tfplan`, and `.terraform/`.

---

## 12. Cleanup

```bash
# Dev
cd terraform/environments/dev
terraform destroy

# Prod — deletion protection must be disabled first
cd terraform/environments/prod
# 1) set enable_deletion_protection = false and apply once
# 2) then:
terraform destroy
```

Remember to also remove ECR images and any Secrets Manager entries that were
created outside Terraform during testing.

---

*A smaller, secure, and well-understood solution scores higher than an
unnecessarily complex architecture. This repository intentionally keeps the
service simple, the infrastructure minimal, and the security posture strong.*