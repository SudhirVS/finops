import boto3, os, json
from datetime import datetime, timezone, timedelta

ec2     = boto3.client("ec2")
elb     = boto3.client("elbv2")
sns     = boto3.client("sns")
cw      = boto3.client("cloudwatch")

SNS_TOPIC    = os.environ["SNS_TOPIC_ARN"]
DRY_RUN      = os.environ.get("DRY_RUN", "true").lower() == "true"
IDLE_CPU_PCT = float(os.environ.get("IDLE_CPU_PERCENT", "5"))

report = []

def notify(subject, body):
    sns.publish(TopicArn=SNS_TOPIC, Subject=subject, Message=body)

def get_cpu_avg(instance_id, days=7):
    resp = cw.get_metric_statistics(
        Namespace="AWS/EC2",
        MetricName="CPUUtilization",
        Dimensions=[{"Name": "InstanceId", "Value": instance_id}],
        StartTime=datetime.now(timezone.utc) - timedelta(days=days),
        EndTime=datetime.now(timezone.utc),
        Period=86400 * days,
        Statistics=["Average"],
    )
    points = resp.get("Datapoints", [])
    return points[0]["Average"] if points else 0.0

def stop_idle_ec2():
    """Stop running EC2 instances with avg CPU < threshold (excludes prod)."""
    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate(Filters=[{"Name": "instance-state-name", "Values": ["running"]}]):
        for r in page["Reservations"]:
            for i in r["Instances"]:
                iid   = i["InstanceId"]
                tags  = {t["Key"]: t["Value"] for t in i.get("Tags", [])}
                env   = tags.get("Environment", "unknown").lower()

                if env == "prod":
                    continue  # never touch prod automatically

                cpu = get_cpu_avg(iid)
                if cpu < IDLE_CPU_PCT:
                    report.append(f"[EC2-IDLE] {iid} env={env} cpu={cpu:.1f}%")
                    if not DRY_RUN:
                        ec2.stop_instances(InstanceIds=[iid])

def delete_unattached_ebs():
    """Delete EBS volumes in 'available' state (not attached to any instance)."""
    paginator = ec2.get_paginator("describe_volumes")
    for page in paginator.paginate(Filters=[{"Name": "status", "Values": ["available"]}]):
        for vol in page["Volumes"]:
            vid  = vol["VolumeId"]
            size = vol["Size"]
            report.append(f"[EBS-UNUSED] {vid} {size}GB")
            if not DRY_RUN:
                ec2.delete_volume(VolumeId=vid)

def delete_old_snapshots(days=90):
    """Delete snapshots older than N days that are not linked to an AMI."""
    account_id = boto3.client("sts").get_caller_identity()["Account"]
    amis = {
        img["BlockDeviceMappings"][0]["Ebs"]["SnapshotId"]
        for img in ec2.describe_images(Owners=["self"])["Images"]
        if img.get("BlockDeviceMappings") and "Ebs" in img["BlockDeviceMappings"][0]
    }
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    paginator = ec2.get_paginator("describe_snapshots")
    for page in paginator.paginate(OwnerIds=[account_id]):
        for snap in page["Snapshots"]:
            if snap["StartTime"] < cutoff and snap["SnapshotId"] not in amis:
                report.append(f"[SNAP-OLD] {snap['SnapshotId']} age>{days}d")
                if not DRY_RUN:
                    ec2.delete_snapshot(SnapshotId=snap["SnapshotId"])

def delete_idle_load_balancers():
    """Delete ALBs/NLBs with zero healthy targets for 7+ days."""
    lbs = elb.describe_load_balancers()["LoadBalancers"]
    for lb in lbs:
        tgs = elb.describe_target_groups(LoadBalancerArn=lb["LoadBalancerArn"])["TargetGroups"]
        all_empty = all(
            sum(
                1 for t in elb.describe_target_health(TargetGroupArn=tg["TargetGroupArn"])["TargetHealthDescriptions"]
                if t["TargetHealth"]["State"] == "healthy"
            ) == 0
            for tg in tgs
        )
        if all_empty and tgs:
            report.append(f"[ELB-IDLE] {lb['LoadBalancerName']} {lb['LoadBalancerArn']}")
            if not DRY_RUN:
                elb.delete_load_balancer(LoadBalancerArn=lb["LoadBalancerArn"])

def handler(event, context):
    stop_idle_ec2()
    delete_unattached_ebs()
    delete_old_snapshots()
    delete_idle_load_balancers()

    if report:
        mode = "DRY-RUN" if DRY_RUN else "EXECUTED"
        notify(
            subject=f"[FinOps Cleanup] {len(report)} resources found ({mode})",
            body="\n".join(report)
        )

    return {"statusCode": 200, "actions": len(report), "dry_run": DRY_RUN}
