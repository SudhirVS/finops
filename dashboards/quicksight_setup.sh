#!/usr/bin/env bash
# QuickSight FinOps Dashboard Setup
# Prereq: CUR data in Athena, QuickSight Enterprise edition enabled

set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=${AWS_REGION:-us-east-1}
PROJECT=${PROJECT:-myapp}
QS_USER=${QS_USER:-"admin"}          # QuickSight username
ATHENA_WG="${PROJECT}-finops"
ATHENA_DB="${PROJECT//-/_}_finops"
DS_ID="${PROJECT}-cur-datasource"
DATASET_ID="${PROJECT}-cur-dataset"

echo "==> Creating QuickSight Athena data source..."
aws quicksight create-data-source \
  --aws-account-id "$ACCOUNT_ID" \
  --data-source-id "$DS_ID" \
  --name "CUR Athena - $PROJECT" \
  --type ATHENA \
  --data-source-parameters "{\"AthenaParameters\":{\"WorkGroup\":\"$ATHENA_WG\"}}" \
  --permissions "[{\"Principal\":\"arn:aws:quicksight:$REGION:$ACCOUNT_ID:user/default/$QS_USER\",\"Actions\":[\"quicksight:DescribeDataSource\",\"quicksight:PassDataSource\"]}]" \
  --region "$REGION"

echo "==> Creating QuickSight dataset (cost by service/env/team)..."
aws quicksight create-data-set \
  --aws-account-id "$ACCOUNT_ID" \
  --data-set-id "$DATASET_ID" \
  --name "FinOps CUR Dataset" \
  --import-mode SPICE \
  --physical-table-map "{
    \"cur_table\": {
      \"RelationalTable\": {
        \"DataSourceArn\": \"arn:aws:quicksight:$REGION:$ACCOUNT_ID:datasource/$DS_ID\",
        \"Catalog\": \"AWSDataCatalog\",
        \"Schema\": \"$ATHENA_DB\",
        \"Name\": \"cur\",
        \"InputColumns\": [
          {\"Name\": \"line_item_product_code\",    \"Type\": \"STRING\"},
          {\"Name\": \"line_item_unblended_cost\",  \"Type\": \"DECIMAL\"},
          {\"Name\": \"line_item_usage_start_date\",\"Type\": \"DATETIME\"},
          {\"Name\": \"resource_tags_user_environment\", \"Type\": \"STRING\"},
          {\"Name\": \"resource_tags_user_project\",     \"Type\": \"STRING\"},
          {\"Name\": \"resource_tags_user_owner\",       \"Type\": \"STRING\"},
          {\"Name\": \"line_item_resource_id\",     \"Type\": \"STRING\"}
        ]
      }
    }
  }" \
  --permissions "[{\"Principal\":\"arn:aws:quicksight:$REGION:$ACCOUNT_ID:user/default/$QS_USER\",\"Actions\":[\"quicksight:DescribeDataSet\",\"quicksight:PassDataSet\",\"quicksight:DescribeDataSetPermissions\",\"quicksight:ListIngestions\",\"quicksight:DescribeIngestion\"]}]" \
  --region "$REGION"

echo "==> Triggering SPICE ingestion..."
aws quicksight create-ingestion \
  --aws-account-id "$ACCOUNT_ID" \
  --data-set-id "$DATASET_ID" \
  --ingestion-id "initial-load" \
  --region "$REGION"

echo ""
echo "✅ QuickSight setup complete."
echo "   Next: Open QuickSight → New Analysis → Select dataset '$DATASET_ID'"
echo "   Recommended panels:"
echo "     1. Total monthly cost (KPI)"
echo "     2. Cost by service  (Bar chart: line_item_product_code vs SUM cost)"
echo "     3. Cost by environment (Pie: resource_tags_user_environment)"
echo "     4. Daily spend trend (Line: date vs SUM cost)"
echo "     5. Top 10 expensive resources (Table: resource_id, sorted DESC)"
echo "     6. Cost by team/owner (Bar: resource_tags_user_owner)"
