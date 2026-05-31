# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
"""Proves the derived backend image from the inside. Run by check-image.sh, in a container with no network.

Prints one PASS or FAIL line per check and exits non-zero on any FAIL. With --build-time, Dockerfile.backend
runs only the checks that need no Django, so a commercially headed file anywhere in the filesystem, or a wrong PyJWT,
stops the image build.
"""
import argparse
import ast
import collections
import hashlib
import importlib
import importlib.metadata
import json
import os
import re
import secrets
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path("/code")
OPT = Path("/opt/wayline")
# In two pieces, so that this file, which is in the image, does not hold it. checks/layer-check.py fails on any file that does.
COMMERCIAL = b"LicenseRef-Plane-" + b"Commercial"
EMAIL_PY = ROOT / "plane/utils/email.py"
BRAND = re.compile(r"Plane|plane\.so|plane\.sh|makeplane|planepowers|plane-marketing|mailinblue|imagekit")
CREDIT = "Built on Plane Community Edition"
failures = 0


def report(ok, label, detail=""):
    global failures
    failures += 0 if ok else 1
    print(f"{'PASS' if ok else 'FAIL'} {label}{(' ' + detail) if detail else ''}", flush=True)


def edited_files():
    return (OPT / "edited-files.txt").read_text().split()


def email_pin():
    lines = (OPT / "vendor/email.py.pin").read_text().splitlines()
    return dict(line.split("=", 1) for line in lines if "=" in line and not line.startswith("#"))


def check_licence(scan_root=ROOT):
    print(f"\n== Licence headers under {scan_root}")
    hits, count = [], 0
    for directory, subdirectories, names in os.walk(scan_root):
        if directory == "/":
            subdirectories[:] = [d for d in subdirectories if d not in ("proc", "sys", "dev")]
        for name in names:
            path = Path(directory, name)
            if path.is_file() and not path.is_symlink():
                count += 1
                if COMMERCIAL in path.read_bytes():
                    hits.append(str(path))
    report(not hits, f"no file under {scan_root} contains {COMMERCIAL.decode()}", str(hits) if hits else f"{count} files read")
    data = EMAIL_PY.read_bytes()
    report(b"# SPDX-License-Identifier: AGPL-3.0-only\n" in data, f"{EMAIL_PY} carries AGPL-3.0-only")
    pin, digest = email_pin(), hashlib.sha256(data).hexdigest()
    report(digest == pin["sha256"], f"{EMAIL_PY} is upstream's file at {pin['commit']}", f"sha256 {digest}")


def check_pyjwt_install():
    print("\n== PyJWT as installed")
    pinned = re.search(r"^PyJWT==(\S+)", (OPT / "pyjwt-requirements.txt").read_text(), re.M).group(1)
    version = importlib.metadata.version("PyJWT")
    report(version == pinned, f"PyJWT is {version}, and backend/pyjwt-requirements.txt pins {pinned}")
    copies = [d.version for d in importlib.metadata.distributions() if (d.metadata["Name"] or "").lower() == "pyjwt"]
    report(copies == [pinned], f"one copy installed: {copies}")
    result = subprocess.run([sys.executable, "-m", "pip", "check"], capture_output=True, text=True, check=False)
    report(result.returncode == 0, "pip check", (result.stdout or result.stderr).strip())


def check_pyjwt_use():
    import jwt
    from django.conf import settings
    from django.core.management.utils import get_random_secret_key

    print("\n== PyJWT as Plane uses it")
    importers = []
    for path in sorted((ROOT / "plane").rglob("*.py")):
        if "tests" not in path.parts and re.search(r"^\s*(import jwt\b|from jwt\b)", path.read_text(errors="replace"), re.M):
            importers.append(str(path.relative_to(ROOT)))
    report(importers == ["plane/app/views/project/invite.py", "plane/app/views/workspace/invite.py"], f"importers of jwt: {importers}")
    for rel in importers:
        calls = [
            node for node in ast.walk(ast.parse((ROOT / rel).read_text()))
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and getattr(node.func.value, "id", "") == "jwt"
        ]
        names = [call.func.attr for call in calls]
        algorithm = [kw.value.value for call in calls for kw in call.keywords if kw.arg == "algorithm"]
        report(names == ["encode"] and algorithm == ["HS256"], f"{rel} calls jwt.encode with HS256 and nothing else", str(names))
    # The same payload shape and call as both invite views. The keys: this image's setting, the format
    # scripts/secret-zero.sh generates (openssl rand -hex 24), and the format upstream's settings suggest.
    payload = {"email": {"email": "invitee@x.test", "role": 15}, "timestamp": 1762300000.25}
    keys = [("settings.SECRET_KEY", settings.SECRET_KEY), ("24 random bytes in hex", secrets.token_hex(24)), ("get_random_secret_key()", get_random_secret_key())]
    for label, key in keys:
        token = jwt.encode(payload, key, algorithm="HS256")
        report(isinstance(token, str) and jwt.decode(token, key, algorithms=["HS256"]) == payload, f"encode and decode, HS256, {label}", f"{len(token)} characters")


def check_email():
    from plane.utils import email as email_utils
    from plane.utils.email import generate_plain_text_from_html as plain

    print("\n== plane.utils.email: every caller fits, and the cases upstream tests at the pinned commit")
    names = collections.Counter()
    bad_calls = []
    callers = []
    for path in sorted((ROOT / "plane").rglob("*.py")):
        if "tests" in path.parts:
            continue
        tree = ast.parse(path.read_text(errors="replace"))
        imported = [a.name for n in ast.walk(tree) if isinstance(n, ast.ImportFrom) and n.module == "plane.utils.email" for a in n.names]
        if not imported:
            continue
        callers.append(str(path.relative_to(ROOT)))
        names.update(imported)
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and getattr(node.func, "id", "") == "generate_plain_text_from_html" and (len(node.args) != 1 or node.keywords):
                bad_calls.append(f"{path.relative_to(ROOT)}:{node.lineno}")
    report(bool(callers) and set(names) == {"generate_plain_text_from_html"} and hasattr(email_utils, "generate_plain_text_from_html"),
           f"{len(callers)} modules import only generate_plain_text_from_html", str(callers))
    report(not bad_calls, "every call passes one positional argument", str(bad_calls) if bad_calls else "")

    url = "https://example.com/workspace-invitations/?invitation_id=abc&slug=acme&token=xyz"
    text = plain(f'<p>copy this:</p><a href="{url.replace("&", "&amp;")}"><span>{url.replace("&", "&amp;")}</span></a>')
    report(url in text and "&amp;" not in text, "an escaped invitation URL reaches the text part whole")
    text = plain("<p>Ren&eacute;&#39;s workspace &lt;tag&gt; &amp; more</p>")
    report("René's workspace <tag> & more" in text, "named and numeric character references are decoded")
    text = plain("<style>p { color: red; }</style>\n<p>Hello <strong>world</strong></p>")
    report("color: red" not in text and "<p>" not in text and "Hello world" in text, "style blocks and tags are stripped")
    text = plain("<p>First</p>\n\n\n\n<p>Second</p>")
    report("\n\n\n" not in text.strip() and text.startswith("\n\n") and text.endswith("\n\n"), "blank lines collapse and the output is padded")
    for html in ("<STYLE type='text/css'>\na{}\n</Style><p>Hi</p><style>b{}</style>tail", "<style>a{}</style><style>unclosed <p>Hi</p>", "<style</style>x</style>", "<p>Hi</p>" + "<style" * 50):
        expected = re.sub(r"<style[^>]*>.*?</style>", "", html, flags=re.DOTALL | re.IGNORECASE)
        report(email_utils._remove_style_blocks(html) == expected, f"style removal matches the old regex on {html[:24]!r}")
    start = time.perf_counter()
    text = plain("<p>" + "<style-x>" * 11000 + "</p>")
    elapsed = time.perf_counter() - start
    report(elapsed < 1 and text == "\n\n\n\n", "11000 unclosed style-like tags take under a second", f"{elapsed:.3f} s")


def check_python():
    print("\n== Compile every edited Python file")
    for rel in edited_files():
        if rel.endswith(".py"):
            source = (ROOT / rel).read_text(encoding="utf-8")
            try:
                compile(source, rel, "exec", dont_inherit=True)
                report(True, f"compile {rel}")
            except SyntaxError as err:
                report(False, f"compile {rel}", str(err))

    print("\n== Parse every edited seed file")
    for rel in edited_files():
        if rel.endswith(".json"):
            data = (ROOT / rel).read_text(encoding="utf-8")
            json.loads(data)
            report(not re.search(r"Plane|media\.docs\.plane\.so", data), f"json {rel}", "valid, no brand or hotlink")

    print("\n== Telemetry default at registration (static: reads the create() call)")
    tree = ast.parse((ROOT / "plane/license/management/commands/register_instance.py").read_text())
    kwargs = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and getattr(node.func, "attr", "") == "create":
            kwargs = {k.arg: k.value for k in node.keywords}
    value = kwargs.get("is_telemetry_enabled")
    report(isinstance(value, ast.Constant) and value.value is False, "Instance.objects.create(is_telemetry_enabled=False)")
    name = kwargs.get("instance_name")
    report(isinstance(name, ast.Constant) and name.value == "Wayline", "Instance.objects.create(instance_name='Wayline')")
    fallback = [
        node.args[1] for node in ast.walk(ast.parse((ROOT / "plane/license/api/views/admin.py").read_text()))
        if isinstance(node, ast.Call) and getattr(node.func, "attr", "") == "get" and len(node.args) == 2
        and isinstance(node.args[0], ast.Constant) and node.args[0].value == "is_telemetry_enabled"
    ]
    report(len(fallback) == 1 and isinstance(fallback[0], ast.Constant) and fallback[0].value is False, "the setup endpoint falls back to False when the field is missing")
    model = (ROOT / "plane/license/models/instance.py").read_text()
    report("is_telemetry_enabled = models.BooleanField(default=True)" in model, "the model default is unchanged, so there is no migration")
    migrations = sorted((ROOT / "plane/license/migrations").glob("*.py")) + sorted((ROOT / "plane/db/migrations").glob("*.py"))
    report(not [p for p in migrations if b"Wayline" in p.read_bytes()], "no migration mentions Wayline", f"{len(migrations)} files read")


def actor(first, avatar=""):
    return {"first_name": first, "last_name": first + "-last", "avatar_url": avatar}


def issue_context(actors, data, comments):
    return {
        "entity_type": "issue",
        "issue": {"issue_identifier": "WAY-42", "name": "ISSUE-NAME"},
        "workspace": "WORKSPACE-SLUG",
        "project": "PROJECT-NAME",
        "project_url": "https://x.test/project",
        "issue_url": "https://x.test/issue",
        "summary": "SUMMARY-TEXT",
        "actors_involved": actors,
        "data": data,
        "comments": comments,
        "receiver": {"email": "receiver@x.test"},
        "user_preference": "https://x.test/preferences",
    }


UPDATE_ALL = {
    "actor_detail": actor("ACTOR-A"),
    "activity_time": "ACTIVITY-TIME",
    "changes": {
        "name": {"new_value": ["n"]},
        "target_date": {"new_value": ["DATE-NEW"], "old_value": ["DATE-OLD"]},
        "duplicate": {"new_value": ["DUP-N1", "DUP-N2", "DUP-N3"], "old_value": ["DUP-O1", "DUP-O2", "DUP-O3"]},
        "assignees": {"new_value": ["ASG-N1", "ASG-N2"], "old_value": ["ASG-O1", "ASG-O2"]},
        "labels": {"new_value": ["LBL-N1", "LBL-N2"], "old_value": ["LBL-O1", "LBL-O2"]},
        "state": {"old_value": ["Backlog"], "new_value": ["In Progress", "STATE-NEW"]},
        "link": {"new_value": ["https://x.test/LINK-NEW"], "old_value": ["https://x.test/old"]},
        "priority": {"old_value": ["PRI-OLD"], "new_value": ["low", "PRI-NEW"]},
        "blocking": {"new_value": ["BLK-N1", "BLK-N2", "BLK-N3"], "old_value": ["BLK-O1", "BLK-O2", "BLK-O3"]},
    },
}
UPDATE_ELSE = {
    "actor_detail": actor("ACTOR-B", "https://x.test/AVATAR-B.png"),
    "activity_time": "ACTIVITY-TIME-B",
    "changes": {"target_date": {"new_value": [""], "old_value": ["DATE-CLEARED"]}},
}
COMMENT = {
    "actor_detail": actor("COMMENTER", "https://x.test/AVATAR-C.png"),
    "actor_comments": {"new_value": ["<p>COMMENT-BODY</p>"]},
}
COMMENT_NO_AVATAR = {"actor_detail": actor("ZED"), "actor_comments": {"new_value": ["<p>COMMENT-TWO</p>"]}}

# (label, template, context, strings the output must contain)
CASES = [
    ("forgot_password", "emails/auth/forgot_password.html",
     {"first_name": "F", "forgot_password_url": "https://x.test/reset", "email": "e@x.test"},
     ["https://x.test/reset", "e@x.test", "Reset your Wayline password"]),
    ("magic_signin", "emails/auth/magic_signin.html",
     {"code": "CODE-1234", "email": "e@x.test"}, ["CODE-1234", "e@x.test", "Your login code for Wayline"]),
    ("analytics", "emails/exports/analytics.html", {}, ["Your Wayline Analytics export is ready"]),
    ("project_invitation", "emails/invitations/project_invitation.html",
     {"email": "e@x.test", "first_name": "FIRST", "project_name": "PROJECT", "invitation_url": "https://x.test/invite",
      "current_site": "https://x.test", "mirror": "https://x.test/mirror", "unsubscribe": "https://x.test/unsub"},
     ["FIRST", "PROJECT", "https://x.test/invite", "https://x.test/mirror", "https://x.test/unsub"]),
    ("workspace_invitation", "emails/invitations/workspace_invitation.html",
     {"email": "e@x.test", "first_name": "FIRST", "workspace_name": "WORKSPACE", "abs_url": "https://x.test/join"},
     ["FIRST", "WORKSPACE", "https://x.test/join", "e@x.test"]),
    ("issue-updates: one actor, every property", "emails/notifications/issue-updates.html",
     issue_context(1, [UPDATE_ALL], [COMMENT]),
     ["WAY-42", "ISSUE-NAME", "WORKSPACE-SLUG", "PROJECT-NAME", "SUMMARY-TEXT", "ACTOR-A", "ACTIVITY-TIME", "title has been updated",
      "DATE-NEW", "DUP-N1", "DUP-N2", "+1 more", "DUP-O1", "ASG-N1", "ASG-O1", "LBL-N1", "LBL-O1", "Backlog", "STATE-NEW",
      "LINK-NEW", "2 Links were removed", "PRI-OLD", "PRI-NEW", "BLK-N1", "BLK-O1", "COMMENTER", "<p>COMMENT-BODY</p>",
      "AVATAR-C.png", "receiver@x.test", "https://x.test/preferences", "View issue"]),
    ("issue-updates: several actors, else branches", "emails/notifications/issue-updates.html",
     issue_context(2, [UPDATE_ELSE], [COMMENT_NO_AVATAR]),
     ["and others", "ACTOR-B", "AVATAR-B.png", "DATE-CLEARED", "ZED", "<p>COMMENT-TWO</p>"]),
    ("issue-updates: comments only", "emails/notifications/issue-updates.html",
     issue_context(1, [], [COMMENT]), ["COMMENTER-last", "<p>COMMENT-BODY</p>"]),
    ("issue-updates: priority colours", "emails/notifications/issue-updates.html",
     issue_context(1, [
         {"actor_detail": actor("P1"), "activity_time": "t",
          "changes": {"priority": {"old_value": ["urgent"], "new_value": ["none", "high"]}}},
         {"actor_detail": actor("P2"), "activity_time": "t",
          "changes": {"priority": {"old_value": ["medium"], "new_value": ["none", "low"]}}},
     ], []),
     ["color:#9E1C20", "color:#8F3209", "color:#755600", "color:#1F6B32"]),
    ("project_addition", "emails/notifications/project_addition.html",
     {"inviter_first_name": "INVITER", "project_name": "PROJECT", "workspace_name": "WORKSPACE",
      "project_url": "https://x.test/project", "email": "e@x.test"},
     ["INVITER", "PROJECT", "WORKSPACE", "https://x.test/project", "e@x.test"]),
    ("webhook-deactivate", "emails/notifications/webhook-deactivate.html",
     {"email": "e@x.test", "message": "MESSAGE-TEXT", "webhook_url": "https://x.test/webhook"},
     ["MESSAGE-TEXT", "https://x.test/webhook", "e@x.test"]),
    ("test_email", "emails/test_email.html", None, ["your Wayline instance", "Team Wayline"]),
    ("email_updated", "emails/user/email_updated.html", {"email": "e@x.test"}, ["e@x.test", "Wayline email address"]),
    ("user_activation", "emails/user/user_activation.html",
     {"email": "e@x.test", "profile_url": "https://x.test/profile"}, ["https://x.test/profile", "Go to Wayline", "e@x.test"]),
    ("user_deactivation", "emails/user/user_deactivation.html",
     {"email": "e@x.test", "login_url": "https://x.test/login"}, ["https://x.test/login", "Reactivate account", "e@x.test"]),
]


def check_render(out_dir):
    from django.template.loader import render_to_string
    from plane.utils.email import generate_plain_text_from_html

    print("\n== Render every email template with Django's engine, under plane's own settings")
    seen = set()
    for index, (label, template, context, expected) in enumerate(CASES):
        seen.add(template)
        html = render_to_string(template, context)
        missing = [s for s in expected if s not in html]
        leftovers = "{{" in html or "{%" in html
        brand = [m for m in BRAND.findall(html.replace(CREDIT, ""))]
        hotlinks = [src for src in re.findall(r'<img[^>]*src="([^"]*)"', html) if "x.test" not in src]
        text = generate_plain_text_from_html(html)
        problems = []
        if missing:
            problems.append(f"missing={missing}")
        if leftovers:
            problems.append("unrendered template syntax")
        if brand:
            problems.append(f"brand={brand}")
        if hotlinks:
            problems.append(f"images={hotlinks}")
        if "Wayline" not in text or "<" in re.sub(r"<p>COMMENT", "", text).replace("<p>", ""):
            problems.append("plain text alternative is wrong")
        digest = hashlib.sha256(html.encode()).hexdigest()[:12]
        report(not problems, f"render {label}", "; ".join(problems) or f"{len(html)} bytes, {len(text)} bytes text, sha256 {digest}")
        if out_dir:
            (out_dir / f"{index:02d}-{re.sub(r'[^a-z0-9]+', '-', label.lower())}.html").write_text(html, encoding="utf-8")

    on_disk = {str(p.relative_to(ROOT / "templates")) for p in (ROOT / "templates/emails").rglob("*.html")}
    on_disk.discard("emails/_wayline_base.html")
    report(on_disk == seen, f"every email template was rendered ({len(on_disk)} templates)", str(sorted(on_disk ^ seen)) if on_disk != seen else "")

    print("\n== Other edited templates")
    html = render_to_string("base.html")
    report("<title>Wayline</title>" in html and not BRAND.search(html), "render base.html")

    # plane's settings do not install django.contrib.admin, so its URLs and base template do not exist in
    # this deployment. The edited template is rendered against a stub parent holding only its three blocks.
    from django.apps import apps
    from django.template import Context, Engine

    installed = apps.is_installed("django.contrib.admin")
    print(f"     django.contrib.admin installed under plane's settings: {installed}")
    stub = "{% block title %}{% endblock %}{% block branding %}{% endblock %}{% block nav-global %}{% endblock %}"
    engine = Engine(
        dirs=[str(ROOT / "templates")],
        libraries={"i18n": "django.templatetags.i18n"},
        loaders=[
            ("django.template.loaders.locmem.Loader", {"admin/base.html": stub}),
            "django.template.loaders.filesystem.Loader",
        ],
    )
    html = engine.get_template("admin/base_site.html").render(Context({"title": "T"}))
    report("Wayline Django Admin" in html and "Wayline Admin" in html and not BRAND.search(html), "render admin/base_site.html", "against a stub parent")


def tokens(text):
    found = re.findall(r"\{%.*?%\}|\{\{.*?\}\}", text, re.S)
    normal = [re.sub(r"\s+", " ", t[2:-2].strip()) for t in found]
    tags = [n for t, n in zip(found, normal) if t.startswith("{%") and not re.match(r"(extends|block|endblock)\b", n)]
    variables = [n for t, n in zip(found, normal) if t.startswith("{{")]
    return tags, collections.Counter(variables)


# Icons served from upstream's bucket, chosen by state name. The name itself is still printed.
STATE_ICON = re.compile(
    r"\{% if update\.changes\.state\.(?:old_value\.0|new_value\|last) == 'Backlog' or .*?</td>\s*\{% endif %\}", re.S
)
# Only ever used to build the URLs of upstream's social icons, which are gone with the links.
DROPPED_VARIABLES = {"emails/invitations/project_invitation.html": {"current_site"}}


def check_logic(upstream):
    print("\n== Template logic against upstream's copy from the pinned base image")
    for path in sorted(upstream.rglob("*.html")):
        rel = "emails/" + str(path.relative_to(upstream))
        theirs = path.read_text(encoding="utf-8")
        if rel.endswith("issue-updates.html"):
            theirs, removed = STATE_ICON.subn("", theirs)
            report(removed == 2, f"state icon blocks removed from comparison ({removed})")
        ours_tags, ours_vars = tokens((ROOT / "templates" / rel).read_text(encoding="utf-8"))
        their_tags, their_vars = tokens(theirs)
        dropped = DROPPED_VARIABLES.get(rel, set())
        their_names = {k for k in their_vars if k.split(".")[0].split("|")[0] not in dropped}
        same_tags = ours_tags == their_tags
        same_set = set(ours_vars) == their_names
        detail = f"{len(ours_tags)} tags in the same order, {len(set(ours_vars))} distinct variables"
        if not same_tags:
            first = next((i for i, (a, b) in enumerate(zip(ours_tags, their_tags)) if a != b), min(len(ours_tags), len(their_tags)))
            detail = f"tags differ at {first}: ours={ours_tags[first:first + 2]} theirs={their_tags[first:first + 2]}"
        elif not same_set:
            detail = f"variables differ: {sorted(set(ours_vars) ^ their_names)}"
        report(same_tags and same_set, f"logic {rel}", detail)


# What may still contain the brand in the backend's own code, each with its reason.
KNOWN_REMAINDER = [
    (r"Copyright \(c\) 2023-present Plane Software", "required notice"),
    (r"X-Plane-", "functional webhook header"),
    (r"^plane/settings/openapi\.py:.*Built on Plane Community Edition", "the permitted credit"),
    (r"^plane/db/models/workspace\.py:.*New at Plane", "TextChoices label: changing it would call for a migration"),
    (r"^plane/settings/production\.py:.*SCOUT_NAME", "APM app name, off unless SCOUT_MONITOR is set"),
    (r"^plane/license/bgtasks/telemetry_metrics\.py:", "metric description, sent only if telemetry is enabled"),
    (r"^plane/license/management/commands/register_instance\.py:.*api\.github\.com/repos/makeplane/plane", "upstream's release check"),
    (r"^plane/utils/otlp_endpoints\.py:", "telemetry endpoint default, used only if telemetry is enabled"),
    (r"^plane/settings/common\.py:.*plane\.so", "code comment"),
    (r"^plane/app/serializers/webhook\.py:.*# ", "code comment"),
    (r"^plane/utils/core/__init__\.py:", "module docstring"),
    (r"^plane/utils/ip_address\.py:.*# ", "code comment"),
    (r"^plane/seeds/data/issues\.json:.*https://docs\.plane\.so/", "upstream's manual: same policy as leak-allowlist.txt"),
    (r"^templates/.*(Copyright \(c\) 2023-present Plane Software|Built on Plane Community Edition)", "required notice and the permitted credit"),
]


def check_remainder():
    print("\n== Brand left in the backend's code, each with its reason (tests excluded)")
    counts = collections.Counter()
    for path in sorted([*(ROOT / "plane").rglob("*"), *(ROOT / "templates").rglob("*")]):
        if path.suffix not in {".py", ".json", ".html"} or "tests" in path.parts or "static-assets" in path.parts or not path.is_file():
            continue
        rel = path.relative_to(ROOT)
        for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if not re.search(r"Plane|plane\.so|makeplane|planepowers", line):
                continue
            entry = f"{rel}:{line.strip()}"
            for pattern, reason in KNOWN_REMAINDER:
                if re.search(pattern, entry):
                    counts[reason] += 1
                    break
            else:
                report(False, f"unexplained brand at {rel}:{number}", line.strip()[:140])
    for reason, count in sorted(counts.items()):
        print(f"     {count:5d}  {reason}")
    report(True, "brand scan finished", f"{sum(counts.values())} explained lines")


def check_settings():
    print("\n== Edited modules import under plane's own settings")
    for rel in edited_files():
        if rel.endswith(".py"):
            module = rel[:-3].replace("/", ".")
            try:
                importlib.import_module(module)
                report(True, f"import {module}")
            except Exception as err:  # noqa: BLE001 - the point is to report any failure
                report(False, f"import {module}", repr(err))

    print("\n== Every task module loads, as a worker's start does")
    from plane.celery import app

    app.loader.import_default_modules()
    tasks = [name for name in app.tasks if name.startswith("plane.")]
    report("plane.bgtasks.workspace_invitation_task.workspace_invitation" in tasks and "plane.license.bgtasks.telemetry_metrics.push_instance_metrics" in tasks, f"{len(tasks)} tasks registered")

    print("\n== Values that reach users")
    from django.conf import settings
    from plane.settings.openapi import SPECTACULAR_SETTINGS as api

    report(api["TITLE"] == "The Wayline REST API", f"openapi TITLE = {api['TITLE']!r}")
    report(api["CONTACT"]["name"] == "Wayline" and "email" not in api["CONTACT"], f"openapi CONTACT = {api['CONTACT']}")
    report(api["LICENSE"]["name"] == "GNU AGPLv3" and "makeplane" not in api["LICENSE"]["url"], f"openapi LICENSE = {api['LICENSE']}")
    report(len(api["SERVERS"]) == 1, f"openapi SERVERS = {api['SERVERS']}")
    report(settings.INSTANCE_CHANGELOG_URL == "", f"INSTANCE_CHANGELOG_URL = {settings.INSTANCE_CHANGELOG_URL!r}")


def check_layout():
    print("\n== Image layout")
    report(os.getcwd() == str(ROOT), f"working directory {os.getcwd()}")
    report(os.getuid() == 1000, f"uid {os.getuid()}")
    for name in ("api", "worker", "beat", "migrator"):
        path = ROOT / "bin" / f"docker-entrypoint-{name}.sh"
        report(path.is_file() and os.access(path, os.X_OK), f"entrypoint {path}")
    logo, master = ROOT / "plane/static/logos/Logo.png", Path("/opt/wayline/Logo.png")
    report(logo.read_bytes() == master.read_bytes(), f"{logo} is Wayline's", f"sha256 {hashlib.sha256(logo.read_bytes()).hexdigest()[:12]}")
    stale = [str(p) for p in (ROOT / "plane").rglob("*.pyc")]
    report(not stale, "no stale bytecode under /code/plane")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, help="upstream's templates/emails, from the base image")
    parser.add_argument("--render-dir", type=Path, help="write the rendered HTML here")
    parser.add_argument("--build-time", action="store_true", help="only the checks that need no Django")
    args = parser.parse_args()

    # At build time this runs as root in the stage whose whole filesystem is copied into the published image, so it
    # reads all of it, and a file holding that identifier anywhere stops the image before anything is pushed.
    if args.build_time:
        check_licence(Path("/"))
        check_pyjwt_install()
        print(f"\nRESULT {'FAIL' if failures else 'PASS'}: {failures} failed")
        sys.exit(1 if failures else 0)

    check_layout()
    check_licence()
    check_pyjwt_install()
    check_python()

    sys.path.insert(0, str(ROOT))
    import django

    django.setup()
    from django.conf import settings

    print(f"\nDJANGO_SETTINGS_MODULE={settings.SETTINGS_MODULE} django={django.get_version()} TEMPLATES.DIRS={settings.TEMPLATES[0]['DIRS']}")
    check_render(args.render_dir)
    check_email()
    check_pyjwt_use()
    if args.upstream:
        check_logic(args.upstream)
    check_settings()
    check_remainder()

    print(f"\nRESULT {'FAIL' if failures else 'PASS'}: {failures} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
