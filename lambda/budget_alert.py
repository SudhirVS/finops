import json, os, re, boto3
from urllib.parse import urlparse

SLACK_WEBHOOK = os.environ.get("SLACK_WEBHOOK_URL", "")
_sns = boto3.client("sns")

def _sanitize(text: str) -> str:
    """Strip non-printable and HTML-unsafe characters from alert text."""
    text = re.sub(r"[<>&\"']", "", text)   # remove HTML special chars
    text = re.sub(r"[^\x20-\x7E\n]", "", text)  # keep printable ASCII + newlines
    return text[:2000]  # hard cap to prevent oversized payloads

def _post_slack(text: str):
    topic_arn = os.environ.get("SNS_TOPIC_ARN", "")
    if not topic_arn:
        print(f"ALERT: {_sanitize(text)}")
        return
    _sns.publish(
        TopicArn=topic_arn,
        Message=_sanitize(text),
        Subject="FinOps Alert"
    )

def _format_budget(msg: dict) -> str:
    return (
        f":money_with_wings: *Budget Alert* — `{msg.get('budgetName')}`\n"
        f"> Threshold *{msg.get('thresholdExceeded')}%* exceeded\n"
        f"> Actual: *${msg.get('actualSpend', {}).get('amount')}* / "
        f"Budget: *${msg.get('budgetLimit', {}).get('amount')}*"
    )

def _format_anomaly(msg: dict) -> str:
    detail = msg.get("anomalyDetails", {})
    return (
        f":rotating_light: *Cost Anomaly Detected*\n"
        f"> Service: `{detail.get('rootCauses', [{}])[0].get('service', 'N/A')}`\n"
        f"> Impact: *${detail.get('totalImpact', {}).get('totalActualSpend', 'N/A')}* "
        f"(expected: ${detail.get('totalImpact', {}).get('totalExpectedSpend', 'N/A')})"
    )

def handler(event, context):
    for record in event.get("Records", []):
        raw     = record["Sns"]["Message"]
        subject = record["Sns"].get("Subject", "")

        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            _post_slack(f":bell: *AWS Cost Alert*\n{raw}")
            continue

        if "budgetName" in msg:
            _post_slack(_format_budget(msg))
        elif "anomalyId" in msg:
            _post_slack(_format_anomaly(msg))
        else:
            _post_slack(f":bell: *AWS Cost Alert*\n```{json.dumps(msg, indent=2)[:1500]}```")

    return {"statusCode": 200}
