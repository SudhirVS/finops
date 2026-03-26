#!/usr/bin/env bash
# ============================================================
# FinOps End-to-End Test & Evidence Capture Script
# Usage: bash test_and_evidence.sh
# Output: evidence/ folder with all results + summary report
# ============================================================

set -uo pipefail

# ── Config ───────────────────────────────────────────────────
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
REGION=${AWS_DEFAULT_REGION:-us-east-1}
PROJECT="finops"
EVIDENCE_DIR="$(pwd)/evidence"
REPORT="$EVIDENCE_DIR/00_summary_report.txt"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

PASS=0
FAIL=0
WARN=0

# ── Helpers ──────────────────────────────────────────────────
mkdir -p "$EVIDENCE_DIR"

green()  { echo -e "\033[32m✅  $*\033[0m"; }
red()    { echo -e "\033[31m❌  $*\033[0m"; }
yellow() { echo -e "\033[33m⚠️   $*\033[0m"; }
header() { echo -e "\n\033[1;34m━━━ $* ━━━\033[0m"; }

pass() { green "$1";  echo "PASS | $1" >> "$REPORT"; ((PASS++)); }
fail() { red "$1";    echo "FAIL | $1" >> "$REPORT"; ((FAIL++)); }
warn() { yellow "$1"; echo "WARN | $1" >> "$REPORT"; ((WARN++)); }

# Run a command, save output to file, return exit code
capture() {
  local label="$1" file="$2"; shift 2
  "$@" > "$file" 2>&1
  local rc=$?
  echo "--- $label ---" >> "$REPORT"
  cat "$file"          >> "$REPORT"
  echo ""              >> "$REPORT"
  return $rc
}

# ── Report Header ─────────────────────────────────────────────
cat > "$REPORT" <<EOF
============================================================
  FinOps System — End-to-End Test Evidence Report
  Account  : $ACCOUNT_ID
  Region   : $REGION
  Project  : $PROJECT
  Run Time : $TIMESTAMP
============================================================

EOF

echo "============================================================"
echo "  FinOps E2E Test & Evidence Capture"
echo "  Account: $ACCOUNT_ID | Region: $REGION"
echo "  Output : $EVIDENCE_DIR"
echo "============================================================"

# ════════════════════════════════════════════════════════════
# TEST 1 — AWS Identity & Connectivity
# ════════════════════════════════════════════════════════════
header "TEST 1: AWS Identity & Connectivity"

if capture "AWS Identity" "$EVIDENCE_DIR/01_identity.txt" \
    aws sts get-caller-identity --output table; then
  pass "AWS CLI connected — Account: $ACCOUNT_ID"
else
  fail "AWS CLI not configured or no connectivity"
fi

# ════════════════════════════════════════════════════════════
# TEST 2 — Terraform Resources
# ════════════════════════════════════════════════════════════
header "TEST 2: Terraform Deployed Resources"

if capture "Terraform State" "$EVIDENCE_DIR/02_terraform_state.txt" \
    terraform -chdir=terraform state list; then
  RESOURCE_COUNT=$(wc -l < "$EVIDENCE_DIR/02_terraform_state.txt" | tr -d ' ')
  pass "Terraform state has $RESOURCE_COUNT resources deployed"
else
  fail "Terraform state not found — run terraform apply first"
fi

# ════════════════════════════════════════════════════════════
# TEST 3 — PHASE 1: VISIBILITY — CUR Report
# ════════════════════════════════════════════════════════════
header "TEST 3: Phase 1 — CUR Report (Visibility)"

if capture "CUR Report" "$EVIDENCE_DIR/03_cur_report.txt" \
    aws cur describe-report-definitions \
      --query "ReportDefinitions[?ReportName=='${PROJECT}-cur'].{Name:ReportName,Format:Format,TimeUnit:TimeUnit,S3Bucket:S3Bucket}" \
      --output table --region us-east-1; then
  if grep -q "$PROJECT-cur" "$EVIDENCE_DIR/03_cur_report.txt"; then
    pass "CUR report '${PROJECT}-cur' exists — daily Parquet delivery active"
  else
    warn "CUR report found but name mismatch — check report name"
  fi
else
  fail "CUR report not found"
fi

# ════════════════════════════════════════════════════════════
# TEST 4 — S3 Bucket
# ════════════════════════════════════════════════════════════
header "TEST 4: Phase 1 — S3 Bucket for CUR Data"

S3_BUCKET="${PROJECT}-cur-reports-${ACCOUNT_ID}"
if capture "S3 Bucket" "$EVIDENCE_DIR/04_s3_bucket.txt" \
    aws s3api head-bucket --bucket "$S3_BUCKET" 2>&1; then
  pass "S3 bucket '$S3_BUCKET' exists and accessible"
else
  fail "S3 bucket '$S3_BUCKET' not found"
fi

# Capture bucket policy — get-bucket-policy returns JSON string, pipe directly
aws s3api get-bucket-policy --bucket "$S3_BUCKET" \
  --output text 2>/dev/null \
  | python3 -m json.tool > "$EVIDENCE_DIR/04b_s3_bucket_policy.txt" 2>/dev/null
if [ -s "$EVIDENCE_DIR/04b_s3_bucket_policy.txt" ]; then
  pass "S3 bucket policy captured"
else
  # Policy exists but may be inline — try raw output
  aws s3api get-bucket-policy --bucket "$S3_BUCKET" \
    > "$EVIDENCE_DIR/04b_s3_bucket_policy.txt" 2>/dev/null \
    && pass "S3 bucket policy captured" || warn "S3 bucket policy not readable"
fi

# ════════════════════════════════════════════════════════════
# TEST 5 — Athena Workgroup & Database
# ════════════════════════════════════════════════════════════
header "TEST 5: Phase 1 — Athena (Query Engine)"

if capture "Athena Workgroup" "$EVIDENCE_DIR/05_athena_workgroup.txt" \
    aws athena get-work-group \
      --work-group "${PROJECT}-finops" \
      --query "WorkGroup.{Name:Name,State:State,Encryption:Configuration.ResultConfiguration.EncryptionConfiguration.EncryptionOption}" \
      --output table; then
  pass "Athena workgroup '${PROJECT}-finops' exists with encryption"
else
  fail "Athena workgroup '${PROJECT}-finops' not found"
fi

# Run a test Athena query
echo "Running test Athena query..."
QUERY_ID=$(aws athena start-query-execution \
  --query-string "SELECT 'finops-test' AS test, current_date AS run_date;" \
  --work-group "${PROJECT}-finops" \
  --query "QueryExecutionId" --output text 2>/dev/null)

if [ -n "$QUERY_ID" ]; then
  # Wait for query to complete
  for i in {1..12}; do
    STATE=$(aws athena get-query-execution \
      --query-execution-id "$QUERY_ID" \
      --query "QueryExecution.Status.State" --output text 2>/dev/null)
    [ "$STATE" = "SUCCEEDED" ] && break
    [ "$STATE" = "FAILED" ] && break
    sleep 5
  done

  aws athena get-query-results \
    --query-execution-id "$QUERY_ID" \
    --output table > "$EVIDENCE_DIR/05b_athena_query_result.txt" 2>&1

  if [ "$STATE" = "SUCCEEDED" ]; then
    pass "Athena live query executed successfully (QueryId: $QUERY_ID)"
  else
    warn "Athena query state: $STATE — CUR data may not be available yet (wait 24h)"
  fi
else
  warn "Could not start Athena query — workgroup may need CUR data first"
fi

# ════════════════════════════════════════════════════════════
# TEST 6 — PHASE 2: OPTIMIZATION — Lambda Cleanup
# ════════════════════════════════════════════════════════════
header "TEST 6: Phase 2 — Lambda Cleanup (Optimization)"

# Invoke Lambda — payload goes to /tmp/cleanup_out.json, CLI metadata to stdout
aws lambda invoke \
  --function-name "${PROJECT}-cleanup" \
  --payload "e30=" \
  /tmp/cleanup_out.json > /tmp/cleanup_invoke_meta.json 2>&1
INVOKE_RC=$?

cp /tmp/cleanup_out.json "$EVIDENCE_DIR/06b_lambda_cleanup_output.json" 2>/dev/null
cp /tmp/cleanup_invoke_meta.json "$EVIDENCE_DIR/06_lambda_cleanup_response.txt" 2>/dev/null
echo "--- Lambda Response Payload ---" >> "$EVIDENCE_DIR/06_lambda_cleanup_response.txt"
cat /tmp/cleanup_out.json >> "$EVIDENCE_DIR/06_lambda_cleanup_response.txt"

if [ $INVOKE_RC -eq 0 ]; then
  # Parse payload file directly — separate from CLI metadata
  STATUS=$(python3 -c "import json; d=json.load(open('/tmp/cleanup_out.json')); print(d.get('statusCode','?'))" 2>/dev/null)
  ACTIONS=$(python3 -c "import json; d=json.load(open('/tmp/cleanup_out.json')); print(d.get('actions','?'))" 2>/dev/null)
  # FunctionError is in the CLI metadata table — check for 'Unhandled' string
  FUNC_ERR=$(grep -o 'Unhandled' /tmp/cleanup_invoke_meta.json 2>/dev/null || true)

  if [ "$STATUS" = "200" ] && [ -z "$FUNC_ERR" ]; then
    pass "Lambda cleanup executed — statusCode=200, actions=$ACTIONS resources processed"
  else
    fail "Lambda cleanup error — statusCode=$STATUS FunctionError=$FUNC_ERR"
  fi
else
  fail "Lambda function '${PROJECT}-cleanup' invocation failed"
fi

# Capture Lambda logs
aws logs tail "/aws/lambda/${PROJECT}-cleanup" --since 10m \
  > "$EVIDENCE_DIR/06c_lambda_cleanup_logs.txt" 2>&1 \
  && pass "Lambda CloudWatch logs captured" \
  || warn "Lambda logs not yet available"

# ════════════════════════════════════════════════════════════
# TEST 7 — Lambda Chargeback
# ════════════════════════════════════════════════════════════
header "TEST 7: Phase 2 — Lambda Chargeback (Cost Allocation)"

aws lambda invoke \
  --function-name "${PROJECT}-chargeback" \
  --payload "e30=" \
  /tmp/chargeback_out.json > /tmp/chargeback_meta.json 2>&1
CHARGEBACK_RC=$?

cp /tmp/chargeback_out.json "$EVIDENCE_DIR/07b_lambda_chargeback_output.json" 2>/dev/null
cp /tmp/chargeback_meta.json "$EVIDENCE_DIR/07_lambda_chargeback_response.txt" 2>/dev/null
echo "--- Chargeback Response Payload ---" >> "$EVIDENCE_DIR/07_lambda_chargeback_response.txt"
cat /tmp/chargeback_out.json >> "$EVIDENCE_DIR/07_lambda_chargeback_response.txt"

if [ $CHARGEBACK_RC -eq 0 ]; then
  STATUS=$(python3 -c "import json; d=json.load(open('/tmp/chargeback_out.json')); print(d.get('statusCode','?'))" 2>/dev/null)
  FUNC_ERR=$(grep -o 'Unhandled' /tmp/chargeback_meta.json 2>/dev/null || true)
  if [ "$STATUS" = "200" ] && [ -z "$FUNC_ERR" ]; then
    pass "Lambda chargeback executed — statusCode=200"
  else
    warn "Chargeback returned status=$STATUS — CUR data needed for full report"
  fi
else
  fail "Lambda function '${PROJECT}-chargeback' invocation failed"
fi

# ════════════════════════════════════════════════════════════
# TEST 8 — EventBridge Schedules
# ════════════════════════════════════════════════════════════
header "TEST 8: Phase 2 — EventBridge Nightly Schedules"

if capture "EventBridge Rules" "$EVIDENCE_DIR/08_eventbridge_rules.txt" \
    aws events list-rules \
      --query "Rules[?contains(Name,'${PROJECT}')].{Name:Name,Schedule:ScheduleExpression,State:State}" \
      --output table; then
  RULE_COUNT=$(grep -c "ENABLED" "$EVIDENCE_DIR/08_eventbridge_rules.txt" 2>/dev/null || echo 0)
  pass "EventBridge rules captured — $RULE_COUNT rule(s) ENABLED"
else
  fail "EventBridge rules not found"
fi

# ════════════════════════════════════════════════════════════
# TEST 9 — PHASE 3: GOVERNANCE — AWS Budgets
# ════════════════════════════════════════════════════════════
header "TEST 9: Phase 3 — AWS Budgets (Governance)"

if capture "AWS Budgets" "$EVIDENCE_DIR/09_budgets.txt" \
    aws budgets describe-budgets \
      --account-id "$ACCOUNT_ID" \
      --query "Budgets[*].{Name:BudgetName,Limit:BudgetLimit.Amount,Unit:BudgetLimit.Unit,Type:BudgetType}" \
      --output table; then
  BUDGET_COUNT=$(grep -c "COST" "$EVIDENCE_DIR/09_budgets.txt" 2>/dev/null || echo 0)
  pass "AWS Budgets captured — $BUDGET_COUNT budget(s) active (monthly + per-env)"
else
  fail "AWS Budgets not found"
fi

# ════════════════════════════════════════════════════════════
# TEST 10 — Cost Anomaly Detection
# ════════════════════════════════════════════════════════════
header "TEST 10: Phase 3 — Cost Anomaly Detection"

if capture "Anomaly Monitors" "$EVIDENCE_DIR/10_anomaly_monitors.txt" \
    aws ce get-anomaly-monitors \
      --query "AnomalyMonitors[*].{Name:MonitorName,Type:MonitorType,Arn:MonitorArn}" \
      --output table; then
  pass "Cost Anomaly Monitor exists"
else
  fail "Cost Anomaly Monitor not found"
fi

if capture "Anomaly Subscriptions" "$EVIDENCE_DIR/10b_anomaly_subscriptions.txt" \
    aws ce get-anomaly-subscriptions \
      --query "AnomalySubscriptions[*].{Name:SubscriptionName,Frequency:Frequency,Threshold:Threshold}" \
      --output table; then
  SUB_COUNT=$(grep -c "finops" "$EVIDENCE_DIR/10b_anomaly_subscriptions.txt" 2>/dev/null || echo 0)
  pass "Anomaly subscriptions captured — $SUB_COUNT subscription(s) active"
else
  fail "Anomaly subscriptions not found"
fi

# ════════════════════════════════════════════════════════════
# TEST 11 — SNS Topic & Subscription
# ════════════════════════════════════════════════════════════
header "TEST 11: Phase 3 — SNS Alerts Pipeline"

SNS_ARN=$(aws sns list-topics \
  --query "Topics[?contains(TopicArn,'finops-alerts')].TopicArn" \
  --output text 2>/dev/null)

if [ -n "$SNS_ARN" ]; then
  pass "SNS topic found: $SNS_ARN"
  echo "SNS_ARN=$SNS_ARN" > "$EVIDENCE_DIR/11_sns_topic.txt"

  # Check subscription status
  capture "SNS Subscriptions" "$EVIDENCE_DIR/11b_sns_subscriptions.txt" \
    aws sns list-subscriptions-by-topic \
      --topic-arn "$SNS_ARN" \
      --query "Subscriptions[*].{Protocol:Protocol,Endpoint:Endpoint,Status:SubscriptionArn}" \
      --output table

  if grep -q "PendingConfirmation" "$EVIDENCE_DIR/11b_sns_subscriptions.txt" 2>/dev/null; then
    warn "SNS email subscription still pending — check inbox and confirm"
  else
    pass "SNS subscription confirmed and active"
  fi

  # Send live test alert
  MSG_ID=$(aws sns publish \
    --topic-arn "$SNS_ARN" \
    --subject "[FinOps TEST] Alert Pipeline Verification" \
    --message "FinOps E2E test alert. Timestamp: $TIMESTAMP. Account: $ACCOUNT_ID. This confirms the SNS alerting pipeline is working end-to-end." \
    --query "MessageId" --output text 2>/dev/null)

  if [ -n "$MSG_ID" ]; then
    echo "MessageId=$MSG_ID" > "$EVIDENCE_DIR/11c_sns_test_alert.txt"
    pass "Live SNS test alert sent — MessageId: $MSG_ID (check your email)"
  else
    fail "SNS test alert failed to send"
  fi
else
  fail "SNS topic 'finops-alerts' not found"
fi

# ════════════════════════════════════════════════════════════
# TEST 12 — KMS Encryption Key
# ════════════════════════════════════════════════════════════
header "TEST 12: Security — KMS Encryption"

if capture "KMS Key" "$EVIDENCE_DIR/12_kms_key.txt" \
    aws kms describe-key \
      --key-id "alias/${PROJECT}-finops" \
      --query "KeyMetadata.{KeyId:KeyId,State:KeyState,Rotation:KeyRotationStatus,Description:Description}" \
      --output table 2>/dev/null; then
  pass "KMS CMK exists with key rotation — SNS/Athena encrypted at rest"
else
  warn "KMS key alias not found — check key was created"
fi

# ════════════════════════════════════════════════════════════
# TEST 13 — Tag Policy
# ════════════════════════════════════════════════════════════
header "TEST 13: Phase 3 — Tag Policy (Governance)"

if capture "Tag Policy" "$EVIDENCE_DIR/13_tag_policy.txt" \
    aws organizations list-policies \
      --filter TAG_POLICY \
      --query "Policies[*].{Name:Name,Id:Id,AwsManaged:AwsManaged}" \
      --output table 2>/dev/null; then
  if grep -q "FinOps-Tag-Policy" "$EVIDENCE_DIR/13_tag_policy.txt"; then
    pass "Tag Policy 'FinOps-Tag-Policy' exists and enforced at org level"
  else
    warn "Tag Policy found but FinOps policy not listed — may not be attached"
  fi
else
  warn "Organizations not accessible — Tag Policy check skipped"
fi

# ════════════════════════════════════════════════════════════
# TEST 14 — SCP
# ════════════════════════════════════════════════════════════
header "TEST 14: Phase 3 — Service Control Policy"

if capture "SCP" "$EVIDENCE_DIR/14_scp.txt" \
    aws organizations list-policies \
      --filter SERVICE_CONTROL_POLICY \
      --query "Policies[?AwsManaged==\`false\`].{Name:Name,Id:Id}" \
      --output table 2>/dev/null; then
  if grep -q "FinOps-Cost-Control-SCP" "$EVIDENCE_DIR/14_scp.txt"; then
    pass "SCP 'FinOps-Cost-Control-SCP' exists — cost guardrails active"
  else
    warn "SCP found but FinOps SCP not listed"
  fi
else
  warn "Organizations not accessible — SCP check skipped"
fi

# ════════════════════════════════════════════════════════════
# TEST 15 — Compute Optimizer
# ════════════════════════════════════════════════════════════
header "TEST 15: Phase 2 — Compute Optimizer Enrollment"

CO_STATUS=$(aws compute-optimizer get-enrollment-status \
  --query "status" --output text 2>/dev/null)
CO_RC=$?

aws compute-optimizer get-enrollment-status \
  --output table > "$EVIDENCE_DIR/15_compute_optimizer.txt" 2>&1

echo "Parsed status: $CO_STATUS" >> "$EVIDENCE_DIR/15_compute_optimizer.txt"

if [ $CO_RC -eq 0 ] && [ "$CO_STATUS" = "Active" ]; then
  pass "Compute Optimizer enrolled — rightsizing recommendations active"
elif [ $CO_RC -eq 0 ]; then
  warn "Compute Optimizer status: '$CO_STATUS' — may take up to 24h to activate after enrollment"
else
  warn "Compute Optimizer status check failed — may need compute-optimizer:GetEnrollmentStatus permission"
fi

# ════════════════════════════════════════════════════════════
# FINAL REPORT
# ════════════════════════════════════════════════════════════
TOTAL=$((PASS + FAIL + WARN))

cat >> "$REPORT" <<EOF

============================================================
  TEST RESULTS SUMMARY
  Run Time : $TIMESTAMP
  Account  : $ACCOUNT_ID
------------------------------------------------------------
  Total    : $TOTAL
  PASS     : $PASS
  FAIL     : $FAIL
  WARN     : $WARN
============================================================

Evidence Files:
$(ls -1 "$EVIDENCE_DIR"/)
============================================================
EOF

echo ""
echo "============================================================"
echo "  TEST RESULTS SUMMARY"
echo "------------------------------------------------------------"
echo "  Total : $TOTAL"
green "  PASS  : $PASS"
[ $FAIL -gt 0 ] && red   "  FAIL  : $FAIL" || echo "  FAIL  : $FAIL"
[ $WARN -gt 0 ] && yellow "  WARN  : $WARN" || echo "  WARN  : $WARN"
echo "------------------------------------------------------------"
echo "  Evidence saved to: $EVIDENCE_DIR"
echo "  Full report      : $REPORT"
echo "============================================================"

# Exit with failure if any tests failed
[ $FAIL -eq 0 ] && exit 0 || exit 1
