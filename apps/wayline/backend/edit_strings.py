# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
"""Scripted brand edits of upstream's backend files, run once at image build by Dockerfile.backend.

Every edit states how many times its text must match. Any mismatch stops the build before a single file
is written, so an upstream change fails loudly instead of leaving a string behind. This is the record of
what the derived image changes in upstream Python, JSON and admin templates.

Not edited, on purpose: functional identifiers (the plane module, X-Plane-* headers, the edition enum),
every copyright and SPDX line, tests, and the "New at Plane" TextChoices label in db/models/workspace.py,
because changing a field's choices would call for a migration.
"""
import argparse
import json
import re
import sys
from pathlib import Path

WORD = r"(?<![A-Za-z])Plane(?![A-Za-z])"
SEED_IMAGE = r'<image-component src=\\"https://media\.docs\.plane\.so/seed_assets/\d+\.png\\"[^>]*></image-component>'
REPO = "https://github.com/BereketAbera/plane-platform"
DEFAULT_FROM = "Wayline <noreply@wayline.invalid>"

# (path relative to root, text to find, replacement, exact number of matches)
LITERAL = [
    # Email subjects
    ("plane/bgtasks/forgot_password_task.py",
     '"A new password to your Plane account has been requested"',
     '"A new password to your Wayline account has been requested"', 1),
    ("plane/bgtasks/magic_link_code_task.py",
     'f"Your unique Plane login code is {token}"', 'f"Your unique Wayline login code is {token}"', 1),
    ("plane/bgtasks/project_add_user_email_task.py",
     '"You have been invited to a Plane project"', '"You have been invited to a Wayline project"', 1),
    ("plane/bgtasks/project_invitation_task.py",
     'invited you to join {project.name} on Plane"', 'invited you to join {project.name} on Wayline"', 1),
    ("plane/bgtasks/user_activation_email_task.py",
     'has been activated on Plane"', 'has been activated on Wayline"', 1),
    ("plane/bgtasks/user_deactivation_email_task.py",
     'has been deactivated on Plane"', 'has been deactivated on Wayline"', 1),
    ("plane/bgtasks/user_email_update_task.py",
     '"Plane email address successfully updated"', '"Wayline email address successfully updated"', 1),
    ("plane/bgtasks/workspace_invitation_task.py",
     'in {workspace.name} on Plane"', 'in {workspace.name} on Wayline"', 1),
    ("plane/db/management/commands/test_email.py",
     '"Test email from Plane"', '"Test email from Wayline"', 1),
    ("plane/license/api/views/configuration.py",
     '"Email Notification from Plane"', '"Email Notification from Wayline"', 1),
    ("plane/license/api/views/configuration.py",
     '"This is a sample email notification sent from Plane application."',
     '"This is a sample email notification sent from Wayline application."', 1),
    # Bot name and its fallback mail domain. WEB_URL normally supplies the domain.
    ("plane/bgtasks/workspace_seed_task.py", 'display_name="Plane",', 'display_name="Wayline",', 1),
    ("plane/bgtasks/workspace_seed_task.py", 'first_name="Plane",', 'first_name="Wayline",', 1),
    ("plane/bgtasks/workspace_seed_task.py",
     "urlparse(settings.WEB_URL or 'https://plane.so').hostname or 'plane.so'",
     "urlparse(settings.WEB_URL or 'https://wayline.invalid').hostname or 'wayline.invalid'", 1),
    # Activity strings, persisted in the database when written
    ("plane/bgtasks/issue_activities_task.py",
     '"Plane has archived the issue"', '"Wayline has archived the issue"', 1),
    ("plane/bgtasks/issue_activities_task.py",
     '"Plane updated the state to "', '"Wayline updated the state to "', 1),
    # Default instance name, and telemetry off at registration. The model default stays, so no migration.
    ("plane/license/management/commands/register_instance.py",
     'instance_name="Plane Community Edition",\n',
     'instance_name="Wayline",\n                is_telemetry_enabled=False,\n', 1),
    # Default sender. The EMAIL_FROM environment variable still takes precedence.
    ("plane/license/utils/instance_value.py",
     '"Team Plane <team@mailer.plane.so>"', f'"{DEFAULT_FROM}"', 1),
    # API error text
    ("plane/api/views/issue.py",
     '"PQL and structured filters are not supported on this Plane edition. "',
     '"PQL and structured filters are not supported on this edition. "', 1),
    ("plane/api/views/issue.py",
     '"a Plane edition that supports work item query filtering."',
     '"an edition that supports work item query filtering."', 1),
    # OpenAPI metadata
    ("plane/settings/openapi.py", '"TITLE": "The Plane REST API",', '"TITLE": "The Wayline REST API",', 1),
    ("plane/settings/openapi.py",
     '''"The Plane REST API\\n\\n"
        "Visit our quick start guide and full API documentation at "
        "[developers.plane.so](https://developers.plane.so/api-reference/introduction)."''',
     f'''"The Wayline REST API\\n\\n"
        "Built on Plane Community Edition, licensed under AGPL-3.0. "
        "Source code: [{REPO}]({REPO})."''', 1),
    ("plane/settings/openapi.py",
     '''"name": "Plane",
        "url": "https://plane.so",
        "email": "support@plane.so",''',
     f'''"name": "Wayline",
        "url": "{REPO}",''', 1),
    ("plane/settings/openapi.py",
     '"url": "https://github.com/makeplane/plane/blob/preview/LICENSE.txt",',
     '"url": "https://www.gnu.org/licenses/agpl-3.0.html",', 1),
    ("plane/settings/openapi.py", '        {"url": "https://api.plane.so", "description": "Production"},\n', "", 1),
    # A top-level path the web image answers itself (the AGPL offer), as with spaces and god-mode.
    ("plane/utils/constants.py", '    "accounts",\n', '    "accounts",\n    "source",\n', 1),
    # Django admin
    ("templates/admin/base_site.html", "{% trans  'plane Admin' %}", "{% trans 'Wayline Admin' %}", 1),
    ("templates/admin/base_site.html", "{% trans 'Plane Django Admin'  %}", "{% trans 'Wayline Django Admin' %}", 1),
    ("templates/admin/base_site.html", "#24292e", "#0F1B2D", 1),
    ("templates/base.html", "<title>Hello plane!</title>", "<title>Wayline</title>", 1),
]

# (path, regular expression, replacement, exact number of matches). Demo content seeded into new workspaces.
REGEX = [
    ("plane/seeds/data/projects.json", WORD, "Wayline", 5),
    ("plane/seeds/data/cycles.json", WORD, "Wayline", 1),
    ("plane/seeds/data/pages.json", WORD, "Wayline", 3),
    ("plane/seeds/data/issues.json", WORD, "Wayline", 15),
    # Screenshots of upstream's UI, hotlinked from upstream's CDN.
    ("plane/seeds/data/issues.json", SEED_IMAGE, "", 7),
]

# Run after the edits and the template copy. A new upstream email template fails here until it is rebranded.
FORBIDDEN = re.compile(r"Plane|plane\.so|plane\.sh|makeplane|planepowers|plane-marketing|mailinblue|imagekit")
ALLOWED_LINE = re.compile(r"\{# Copyright \(c\) 2023-present Plane Software, Inc\. and contributors #\}|Built on Plane Community Edition")


def apply_edits(root):
    """Return {relative path: new text}, or exit listing every mismatch. Writes nothing."""
    texts = {}
    failures = []

    def load(rel):
        if rel not in texts:
            path = root / rel
            if not path.is_file():
                failures.append(f"{rel}: file not found")
                return None
            texts[rel] = path.read_text(encoding="utf-8")
        return texts[rel]

    for rel, old, new, expected in LITERAL:
        text = load(rel)
        if text is None:
            continue
        found = text.count(old)
        if found != expected:
            failures.append(f"{rel}: expected {expected} of {old!r}, found {found}")
            continue
        texts[rel] = text.replace(old, new)

    for rel, pattern, new, expected in REGEX:
        text = load(rel)
        if text is None:
            continue
        texts[rel], found = re.subn(pattern, new, text)
        if found != expected:
            failures.append(f"{rel}: expected {expected} of /{pattern}/, found {found}")

    if failures:
        sys.exit("edit_strings: upstream changed, nothing was written:\n  " + "\n  ".join(failures))
    return texts


def validate(texts):
    failures = []
    for rel, text in texts.items():
        try:
            if rel.endswith(".py"):
                compile(text, rel, "exec", dont_inherit=True)
            elif rel.endswith(".json"):
                json.loads(text)
        except (SyntaxError, ValueError) as err:
            failures.append(f"{rel}: {err}")
    if failures:
        sys.exit("edit_strings: an edit produced invalid output, nothing was written:\n  " + "\n  ".join(failures))


def scan_templates(root):
    failures = []
    for path in sorted((root / "templates").rglob("*.html")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if FORBIDDEN.search(ALLOWED_LINE.sub("", line)):
                failures.append(f"{path.relative_to(root)}:{number}: {line.strip()[:120]}")
    if failures:
        sys.exit("edit_strings: upstream brand left in templates:\n  " + "\n  ".join(failures))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True, help="where to list the edited files")
    args = parser.parse_args()

    texts = apply_edits(args.root)
    validate(texts)
    for rel, text in texts.items():
        (args.root / rel).write_text(text, encoding="utf-8")
    scan_templates(args.root)
    args.manifest.write_text("".join(f"{rel}\n" for rel in sorted(texts)), encoding="utf-8")
    print(f"edit_strings: {len(LITERAL) + len(REGEX)} edits applied to {len(texts)} files")


if __name__ == "__main__":
    main()
