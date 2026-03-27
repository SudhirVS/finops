# FinOps System — AWS Cost Visibility, Optimization & Governance

## Prerequisites

### Required Tools

| Tool | Version | Install |
|------|---------|---------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | >= 1.5 | `choco install terraform` / [download](https://developer.hashicorp.com/terraform/install) |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) | v2 | `choco install awscli` / [download](https://awscli.amazonaws.com/AWSCLIV2.msi) |
| [Python](https://www.python.org/downloads/) | >= 3.12 | `choco install python` / [download](https://www.python.org/downloads/) |
| [Git](https://git-scm.com/downloads) | >= 2.x | `choco install git` / [download](https://git-scm.com/downloads) |
| [bash](https://git-scm.com/downloads) | any | Included with Git for Windows (Git Bash) |

> On Windows, run all commands in **Git Bash**, not PowerShell or CMD.

### Verify Installations

```bash
aws --version        # aws-cli/2.x.x
terraform --version  # Terraform v1.5+
python3 --version    # Python 3.12+
git --version        # git version 2.x
```

### AWS Account Requirements

| Requirement | Details |
|-------------|---------|
| AWS Account | Active account with billing enabled |
| IAM User | Permissions listed below |
| AWS Region | `us-east-1` recommended (CUR only supported here) |
| AWS Organizations | Management account required for Tag Policy + SCP |
| QuickSight | Enterprise edition (for Athena integration) — optional |

### IAM Permissions Required

The IAM user/role running Terraform needs the following:

```json
{
  "Effect": "Allow",
  "Action": [
    "s3:*",
    "athena:*",
    "glue:*",
    "cur:*",
    "budgets:*",
    "ce:*",
    "sns:*",
    "lambda:*",
    "iam:*",
    "kms:*",
    "events:*",
    "logs:*",
    "compute-optimizer:*",
    "organizations:*"
  ],
  "Resource": "*"
}
```

> For least-privilege, scope each action to specific resources after initial setup.

### AWS CLI Configuration

```bash
aws configure
# AWS Access Key ID     : <your-access-key>
# AWS Secret Access Key : <your-secret-key>
# Default region        : us-east-1
# Default output format : table

# Verify
aws sts get-caller-identity
```

### Clone & Configure

```bash
git clone https://github.com/SudhirVS/finops.git
cd finops

# Copy example vars and fill in your values
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
vim terraform/terraform.tfvars
```

---

## Architecture

```
AWS Resources (EC2, S3, RDS, EKS, Lambda)
        │
        ▼
Cost & Usage Report (CUR) ──► S3 Bucket
        │
        ▼
   AWS Athena  ◄──── SQL queries (cost by tag/service/env)
        │
        ▼
  QuickSight / Grafana  ◄──── Dashboards
        │
        ▼
CloudWatch Events ──► Lambda (nightly cleanup)
        │
        ▼
AWS Budgets + Cost Anomaly Detection
        │
        ▼
    SNS Topic ──► Email + Slack
```

---

## Phase 1 — Visibility

| What | How |
|------|-----|
| Raw cost data | CUR (daily, Parquet) → S3 |
| Query engine | Athena workgroup |
| Dashboards | QuickSight (6 panels below) |

### Dashboard Panels
1. **Total monthly cost** — KPI card, current vs last month
2. **Cost by service** — Bar chart (EC2, S3, RDS, EKS, Lambda)
3. **Cost by environment** — Pie chart (dev / stage / prod)
4. **Daily spend trend** — Line chart (last 30 days)
5. **Top 10 expensive resources** — Table sorted by cost DESC
6. **Cost by team/owner** — Bar chart using `Owner` tag

### Key Athena Queries

```sql
-- Daily cost by service
SELECT line_item_product_code AS service,
       DATE(line_item_usage_start_date) AS day,
       ROUND(SUM(line_item_unblended_cost), 2) AS cost
FROM cur
WHERE month(line_item_usage_start_date) = month(current_date)
GROUP BY 1, 2
ORDER BY 2 DESC, 3 DESC;

-- Cost by environment tag
SELECT resource_tags_user_environment AS env,
       ROUND(SUM(line_item_unblended_cost), 2) AS cost
FROM cur
WHERE year(line_item_usage_start_date) = year(current_date)
  AND month(line_item_usage_start_date) = month(current_date)
GROUP BY 1
ORDER BY 2 DESC;

-- Top 10 expensive resources
SELECT line_item_resource_id,
       line_item_product_code,
       resource_tags_user_owner AS owner,
       ROUND(SUM(line_item_unblended_cost), 2) AS cost
FROM cur
WHERE month(line_item_usage_start_date) = month(current_date)
GROUP BY 1, 2, 3
ORDER BY 4 DESC
LIMIT 10;
```

---

## Phase 2 — Optimization

### Automated Cleanup (Lambda — nightly 11 PM UTC)

| Action | Condition |
|--------|-----------|
| Stop EC2 | avg CPU < 5% over 7 days, non-prod |
| Delete EBS | status = `available` (unattached) |
| Delete Snapshots | older than 90 days, not linked to AMI |
| Delete Load Balancers | zero healthy targets |

Set `DRY_RUN=true` (default) to preview before enabling real deletion.

### Manual Optimization Checklist
- [ ] Run **AWS Compute Optimizer** → apply rightsizing recommendations
- [ ] Convert On-Demand to **Savings Plans** for steady-state workloads (1yr = ~30% savings)
- [ ] Use **Spot Instances** for batch/dev workloads (up to 90% savings)
- [ ] Enable **S3 Intelligent-Tiering** for buckets > 128KB objects
- [ ] Enable **RDS Aurora Serverless v2** for variable workloads

---

## Phase 3 — Governance

### Budget Alerts

| Budget | Limit | Alerts |
|--------|-------|--------|
| Monthly total | $1,000 | 50% (forecast), 80%, 100% |
| Dev environment | $200 | 80% |
| Stage environment | $300 | 80% |
| Prod environment | $500 | 80% |

### Cost Anomaly Detection
- Monitor type: per AWS service
- Alert threshold: anomaly impact > **$20**
- Frequency: daily digest

### SCP Controls (apply at OU level)
| Policy | Effect |
|--------|--------|
| Block GPU/bare-metal instances | Deny unless `Role=ml-approved` |
| Require tags on create | Deny EC2/RDS/Lambda without Environment+Project+Owner |
| Block large RDS in dev | Deny r5/r6/x1 class in dev |
| Block NAT Gateway in dev | Use VPC endpoints or shared NAT instead |
| Protect cost allocation tags | Deny deletion of tag definitions |

### Tag Policy (enforced via AWS Organizations)
Required tags on all billable resources:

```
Environment : dev | stage | prod
Project     : <service-name>
Owner       : <team-name>
CostCenter  : <cost-center-code>   (EC2, RDS, EKS only)
```

---

## Ownership Model

| Role | Responsibility |
|------|---------------|
| Dev Team | Tag resources correctly, rightsize application usage |
| DevOps | Deploy this system, maintain Lambda automation |
| FinOps / Finance | Review dashboards, approve budgets, run chargeback |
| Management | Approve budget increases, review monthly report |

> Each team owns its cost. Tagging maps spend to owner → enables chargeback/showback.

---

## Continuous Optimization Loop

```
Monitor (QuickSight/Budgets)
    → Analyze (Athena queries / Compute Optimizer)
        → Optimize (Lambda cleanup / Savings Plans)
            → Enforce (SCP / Tag Policy / Budgets)
                → Monitor again  ↺
```

---

## Deployment

```bash
# 1. Fill in your values
vim terraform/terraform.tfvars

# 2. Deploy infrastructure
cd terraform
terraform init
terraform plan
terraform apply

# 3. Set up QuickSight dashboard
export PROJECT=myapp
export QS_USER=admin
bash dashboards/quicksight_setup.sh

# 4. Apply Tag Policy (run once per AWS Organization)
aws organizations create-policy \
  --name "FinOps-Tag-Policy" \
  --type TAG_POLICY \
  --content file://tagging/tag_policy.json

# 5. Apply SCP to non-prod OU
aws organizations create-policy \
  --name "FinOps-Cost-Control-SCP" \
  --type SERVICE_CONTROL_POLICY \
  --content file://scp/cost_control_scp.json

# 6. Enable Lambda cleanup (set DRY_RUN=false when ready)
aws lambda update-function-configuration \
  --function-name myapp-cleanup \
  --environment "Variables={SNS_TOPIC_ARN=<arn>,DRY_RUN=false,IDLE_CPU_PERCENT=5}"
```

---

## File Structure

```
finops/
├── terraform/
│   ├── main.tf                   # CUR, Athena, KMS, Budgets, Anomaly Detection, Lambda
│   ├── terraform.tfvars          # Your config values (git-ignored)
│   └── terraform.tfvars.example  # Template — copy to terraform.tfvars
├── lambda/
│   ├── cleanup.py                # Nightly: stop idle EC2, delete unused EBS/snapshots/ELBs
│   ├── budget_alert.py           # SNS → Slack/email formatter
│   └── chargeback.py             # Monthly: per-team cost report via Athena → SNS
├── dashboards/
│   └── quicksight_setup.sh       # Create Athena datasource + dataset in QuickSight
├── tagging/
│   └── tag_policy.json           # AWS Organizations Tag Policy
├── scp/
│   └── cost_control_scp.json     # Service Control Policy (block expensive resources)
├── evidence/                     # E2E test outputs (git-ignored)
├── test_and_evidence.sh          # Automated E2E test + evidence capture script
└── .gitignore
```
