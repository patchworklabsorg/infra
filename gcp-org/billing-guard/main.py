"""Billing kill switch.

Triggered by Cloud Billing budget notifications on Pub/Sub. When actual
spend reaches the budget, unlinks billing from every project under the
target folders. Projects elsewhere (Common, Operations) are never touched.
"""

import base64
import json
import os

import functions_framework
from google.cloud import billing_v1, resourcemanager_v3

TARGET_FOLDERS = [f.strip() for f in os.environ["TARGET_FOLDERS"].split(",") if f.strip()]
TRIP_RATIO = float(os.environ.get("TRIP_RATIO", "1.0"))
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"

billing = billing_v1.CloudBillingClient()
projects = resourcemanager_v3.ProjectsClient()
folders = resourcemanager_v3.FoldersClient()


def walk(parent):
    """Yield project IDs under a folder, recursively."""
    for p in projects.list_projects(parent=parent):
        if p.state == resourcemanager_v3.Project.State.ACTIVE:
            yield p.project_id
    for f in folders.list_folders(parent=parent):
        yield from walk(f.name)


@functions_framework.cloud_event
def guard(cloud_event):
    payload = json.loads(base64.b64decode(cloud_event.data["message"]["data"]))
    cost = float(payload.get("costAmount", 0))
    budget = float(payload.get("budgetAmount", 0))
    name = payload.get("budgetDisplayName", "unknown budget")

    if budget <= 0 or cost < budget * TRIP_RATIO:
        print(f"{name}: cost {cost} under trip point {budget * TRIP_RATIO}, nothing to do")
        return

    print(f"{name}: cost {cost} reached trip point {budget * TRIP_RATIO}, disabling billing")
    for folder in TARGET_FOLDERS:
        for project_id in walk(folder):
            resource = f"projects/{project_id}"
            info = billing.get_project_billing_info(name=resource)
            if not info.billing_enabled:
                continue
            if DRY_RUN:
                print(f"DRY RUN: would disable billing on {project_id}")
                continue
            billing.update_project_billing_info(
                name=resource,
                project_billing_info=billing_v1.ProjectBillingInfo(billing_account_name=""),
            )
            print(f"Disabled billing on {project_id}")
