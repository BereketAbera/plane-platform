# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
"""Proves what check_image.py cannot, against a real empty database. Run by checks/backend-db.sh, after migrate
and register_instance, in a container with no route out.

Prints one PASS or FAIL line per check and exits non-zero on any FAIL.
"""
import json
import os
import secrets
import sys
import urllib.request

sys.path.insert(0, "/code")
import django  # noqa: E402

django.setup()

import jwt  # noqa: E402
from django.conf import settings  # noqa: E402
from django.test import Client  # noqa: E402
from rest_framework.test import APIClient  # noqa: E402

from plane.bgtasks.workspace_invitation_task import workspace_invitation  # noqa: E402
from plane.db.models import Profile, Project, ProjectMember, ProjectMemberInvite, User, Workspace, WorkspaceMember, WorkspaceMemberInvite  # noqa: E402
from plane.license.bgtasks import telemetry_metrics  # noqa: E402
from plane.license.models import Instance, InstanceAdmin  # noqa: E402

failures = 0
INVITEE = "invitee@example.test"
MAILPIT = f"http://{os.environ['EMAIL_HOST']}:8025/api/v1"


def report(ok, label, detail=""):
    global failures
    failures += 0 if ok else 1
    print(f"{'PASS' if ok else 'FAIL'} {label}{(' ' + str(detail)) if detail != '' else ''}", flush=True)


def check_registration():
    print("\n== A newly registered instance")
    instance = Instance.objects.get()
    report(instance.is_telemetry_enabled is False, "telemetry is off", f"is_telemetry_enabled={instance.is_telemetry_enabled}")
    report(instance.instance_name == "Wayline", "it is named Wayline", repr(instance.instance_name))


def check_metrics_task():
    print("\n== The metrics task, which beat runs every 6 hours and registration queues once")
    built = []

    def no_exporter():
        built.append(True)
        raise RuntimeError("the check stops here, before anything is sent")

    def run_task():
        try:
            telemetry_metrics._collect_and_push_metrics()
        except RuntimeError:
            pass

    telemetry_metrics._create_otlp_metric_exporter = no_exporter
    Instance.objects.update(is_telemetry_enabled=False)
    run_task()
    report(not built, "with telemetry off, it returns before building an exporter")
    Instance.objects.update(is_telemetry_enabled=True)
    run_task()
    report(bool(built), "with telemetry on, it does build one, so the line above is not vacuous")
    Instance.objects.update(is_telemetry_enabled=False)


def setup(fields):
    """POST the god-mode setup endpoint, as a browser form does, and return the stored flag and the response."""
    email = f"admin-{secrets.token_hex(4)}@example.test"
    data = {"email": email, "first_name": "Admin", "password": secrets.token_urlsafe(24), "company_name": "Proof", **fields}
    response = Client().post("/api/instances/admins/sign-up/", data, HTTP_USER_AGENT="check_db.py")
    return Instance.objects.get(), response, email


def undo_setup(email):
    InstanceAdmin.objects.all().delete()
    User.objects.filter(email=email).delete()
    Instance.objects.update(is_setup_done=False, is_telemetry_enabled=False)


def check_setup_endpoint():
    print("\n== The setup endpoint")
    for fields, expected, label in [
        ({"is_telemetry_enabled": "True"}, True, "ticking the box still turns telemetry on"),
        ({"is_telemetry_enabled": "False"}, False, "the unticked form leaves it off"),
        ({}, False, "a request that leaves the field out leaves it off"),
    ]:
        instance, response, email = setup(fields)
        done = response.status_code == 302 and "error_code" not in response["Location"]
        report(done and instance.is_setup_done, f"setup with {fields or 'no field'} succeeds", f"{response.status_code} {response['Location']}")
        report(instance.is_telemetry_enabled is expected, label, f"is_telemetry_enabled={instance.is_telemetry_enabled}")
        if fields:
            undo_setup(email)
    admin = User.objects.get(email=email)
    profile = Profile.objects.get(user=admin)
    report(profile.has_marketing_email_consent is False, "the new user's profile assumes no marketing consent", f"has_marketing_email_consent={profile.has_marketing_email_consent}")
    return admin


def check_invitations(admin):
    print("\n== PyJWT through the two views that use it")
    workspace = Workspace.objects.create(name="Proof", slug="proof", owner=admin)
    WorkspaceMember.objects.create(workspace=workspace, member=admin, role=20)
    project = Project.objects.create(name="Proof", identifier="PROOF", workspace=workspace, created_by=admin)
    ProjectMember.objects.create(project=project, workspace=workspace, member=admin, role=20)
    api = APIClient()
    api.force_authenticate(user=admin)
    body = {"emails": [{"email": INVITEE, "role": 15}]}

    response = api.post("/api/workspaces/proof/invitations/", body, format="json")
    report(response.status_code == 200, "POST workspace invitations", f"{response.status_code} {response.content[:120]!r}")
    invite = WorkspaceMemberInvite.objects.get(email=INVITEE, workspace=workspace)
    claims = jwt.decode(invite.token, settings.SECRET_KEY, algorithms=["HS256"])
    report(jwt.get_unverified_header(invite.token)["alg"] == "HS256" and claims["email"]["email"] == INVITEE, "its stored token is HS256 and decodes with SECRET_KEY", sorted(claims))

    # Upstream's view reads .role off a queryset before it reaches jwt.encode, so at v1.4.3 this answers 500 on the
    # base image too, and no request reaches that call. Not ours to fix here, and not a failure of this check.
    response = api.post(f"/api/workspaces/proof/projects/{project.id}/invitations/", body, format="json")
    if response.status_code == 500:
        print("NOTE POST project invitations answers 500, upstream's bug at v1.4.3, so its jwt.encode is not reached. check_image.py runs the same call directly")
    else:
        report(response.status_code == 200, "POST project invitations", f"{response.status_code} {response.content[:120]!r}")
        project_invite = ProjectMemberInvite.objects.get(email=INVITEE, project=project)
        claims = jwt.decode(project_invite.token, settings.SECRET_KEY, algorithms=["HS256"])
        report(claims["email"]["email"] == INVITEE, "its stored token decodes with SECRET_KEY", sorted(claims))

    print("\n== email.py through a real mail: the invitation task, rendered, sent over SMTP, and read back from the server")
    urllib.request.urlopen(urllib.request.Request(f"{MAILPIT}/messages", method="DELETE"), timeout=10).close()
    workspace_invitation(INVITEE, workspace.id, invite.token, "https://x.test", admin.email)
    with urllib.request.urlopen(f"{MAILPIT}/messages", timeout=10) as reply:
        messages = json.load(reply)["messages"]
    report(len(messages) == 1, "one message reached the mail server", len(messages))
    if not messages:
        return
    with urllib.request.urlopen(f"{MAILPIT}/message/{messages[0]['ID']}", timeout=10) as reply:
        message = json.load(reply)
    link = f"https://x.test/workspace-invitations/?invitation_id={invite.id}&slug=proof&token={invite.token}"
    text, html = message["Text"], message["HTML"]
    report("on Wayline" in message["Subject"], "subject", message["Subject"])
    report(message["From"]["Address"] == "noreply@wayline.invalid", "default sender", message["From"]["Address"])
    report(link in text and "&amp;" not in text, "the text part holds the invitation link whole")
    report("<" not in text.replace("<" + INVITEE + ">", ""), "the text part holds no markup")
    report("Wayline" in text and "Proof" in text, "the text part holds the template's words")
    report(link.replace("&", "&amp;") in html, "the HTML part holds the link, escaped for HTML")


check_registration()
check_metrics_task()
check_invitations(check_setup_endpoint())
print(f"\nRESULT {'FAIL' if failures else 'PASS'}: {failures} failed")
sys.exit(1 if failures else 0)
