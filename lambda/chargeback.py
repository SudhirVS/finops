import boto3, os, time

athena = boto3.client("athena")
sns    = boto3.client("sns")

SNS_TOPIC  = os.environ["SNS_TOPIC_ARN"]
ATHENA_DB  = os.environ["ATHENA_DB"]
ATHENA_WG  = os.environ["ATHENA_WG"]
S3_BUCKET  = os.environ["S3_BUCKET"]

CHARGEBACK_QUERY = """
SELECT
    resource_tags_user_owner       AS team,
    resource_tags_user_environment AS environment,
    resource_tags_user_project     AS project,
    line_item_product_code         AS service,
    ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd
FROM cur
WHERE year(line_item_usage_start_date)  = year(current_date - interval '1' month)
  AND month(line_item_usage_start_date) = month(current_date - interval '1' month)
  AND line_item_unblended_cost > 0
GROUP BY 1, 2, 3, 4
ORDER BY 5 DESC
"""

def _run_query(sql: str) -> list[dict]:
    resp = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": ATHENA_DB},
        WorkGroup=ATHENA_WG,
        ResultConfiguration={"OutputLocation": f"s3://{S3_BUCKET}/chargeback-results/"}
    )
    qid = resp["QueryExecutionId"]

    for _ in range(30):
        state = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"]["State"]
        if state == "SUCCEEDED":
            break
        if state in ("FAILED", "CANCELLED"):
            raise RuntimeError(f"Athena query {state}")
        time.sleep(5)

    results = athena.get_query_results(QueryExecutionId=qid)
    headers = [c["VarCharValue"] for c in results["ResultSet"]["Rows"][0]["Data"]]
    return [
        {headers[i]: col.get("VarCharValue", "") for i, col in enumerate(row["Data"])}
        for row in results["ResultSet"]["Rows"][1:]
    ]

def _format_report(rows: list[dict]) -> str:
    if not rows:
        return "No cost data found for last month."

    # Aggregate by team
    by_team: dict[str, float] = {}
    for r in rows:
        team = r.get("team") or "untagged"
        by_team[team] = by_team.get(team, 0) + float(r.get("cost_usd") or 0)

    total = sum(by_team.values())
    lines = ["=== Monthly Chargeback Report ===", f"Total: ${total:,.2f}\n", "By Team:"]
    for team, cost in sorted(by_team.items(), key=lambda x: -x[1]):
        pct = (cost / total * 100) if total else 0
        lines.append(f"  {team:<25} ${cost:>10,.2f}  ({pct:.1f}%)")

    lines += ["\nTop 10 Resources by Cost:", "-" * 60]
    for r in rows[:10]:
        lines.append(
            f"  {r.get('team','?'):<15} {r.get('service','?'):<20} "
            f"{r.get('environment','?'):<8} ${float(r.get('cost_usd') or 0):>8,.2f}"
        )
    return "\n".join(lines)

def handler(event, context):
    rows   = _run_query(CHARGEBACK_QUERY)
    report = _format_report(rows)
    sns.publish(
        TopicArn=SNS_TOPIC,
        Subject="[FinOps] Monthly Chargeback Report",
        Message=report
    )
    return {"statusCode": 200, "teams": len(set(r.get("team") for r in rows))}
