#!/usr/bin/env python3
"""Summarize a scan-images.sh run and apply its failure policy.

    scan-images-report.py <results directory>
    scan-images-report.py --selftest

Reads platform.txt, inventory.tsv, not-scanned.txt and images/*.json from the directory, and writes summary.tsv and
critical.tsv beside them. Exits 1 if an image we build has a CRITICAL finding with a fix available, if any image
was not scanned, or if any result is of a platform this scan was not for. See scan-images.sh for why the policy is
that and no wider.
"""
import csv
import json
import os
import re
import sys
import tempfile

OURS = re.compile(r"^(localhost:5001|ghcr\.io/[^/]+)/wayline/")
SEVERITIES = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]
NO_PLATFORM = "none"
SUMMARY_FIELDS = ["image", "sources", "ours", "scanned", "os", "os_end_of_life", "architecture", "platform"] + [
    f"{severity.lower()}{suffix}" for severity in SEVERITIES for suffix in ("", "_fixable")
] + ["why_not_scanned"]


def findings(report):
    for result in report.get("Results") or []:
        for vulnerability in result.get("Vulnerabilities") or []:
            yield result.get("Target", ""), vulnerability


def summarize(image, sources, report, why_not_scanned):
    row = {field: 0 for field in SUMMARY_FIELDS}
    row.update(image=image, sources=sources, ours="yes" if OURS.match(image) else "no")
    if report is None:
        row.update(scanned="no", os="", os_end_of_life="", architecture="", platform="", why_not_scanned=why_not_scanned or "no result")
        return row, []
    metadata = report.get("Metadata") or {}
    system = metadata.get("OS") or {}
    config = metadata.get("ImageConfig") or {}
    row.update(
        scanned="yes",
        os=f"{system.get('Family', '')} {system.get('Name', '')}".strip() or "none",
        os_end_of_life="yes" if system.get("EOSL") else "no",
        architecture=config.get("architecture", ""),
        # The lockfiles row is a directory, which has no platform. An image always has one.
        platform=NO_PLATFORM if report.get("ArtifactType") == "filesystem" else f"{config.get('os', '')}/{config.get('architecture', '')}",
        why_not_scanned="",
    )
    critical = []
    for target, vulnerability in findings(report):
        severity = vulnerability.get("Severity", "UNKNOWN").upper()
        if severity not in SEVERITIES:
            severity = "UNKNOWN"
        row[severity.lower()] += 1
        if vulnerability.get("FixedVersion"):
            row[f"{severity.lower()}_fixable"] += 1
        if severity == "CRITICAL":
            critical.append(
                {
                    "image": image,
                    "ours": row["ours"],
                    "id": vulnerability.get("VulnerabilityID", ""),
                    "package": vulnerability.get("PkgName", ""),
                    "installed": vulnerability.get("InstalledVersion", ""),
                    "fixed_in": vulnerability.get("FixedVersion", ""),
                    "target": target,
                }
            )
    return row, critical


def load_report(path):
    try:
        with open(path, encoding="utf-8") as handle:
            report = json.load(handle)
    except (OSError, ValueError):
        return None
    return report if report.get("ArtifactName") else None


def read_not_scanned(directory):
    reasons = {}
    path = os.path.join(directory, "not-scanned.txt")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                image, _, reason = line.rstrip("\n").partition("\t")
                reasons[image] = reason
    return reasons


def read_platforms(directory):
    """What scan-images.sh asked trivy for, then any other platform it lets a plain manifest be."""
    try:
        with open(os.path.join(directory, "platform.txt"), encoding="utf-8") as handle:
            return [line.strip() for line in handle if line.strip()]
    except OSError:
        return []


def analyze(directory):
    reasons = read_not_scanned(directory)
    rows, critical = [], []
    with open(os.path.join(directory, "inventory.tsv"), encoding="utf-8") as handle:
        for line in handle:
            image, sources, filename = line.rstrip("\n").split("\t")
            report = None if image in reasons else load_report(os.path.join(directory, "images", filename))
            row, found = summarize(image, sources, report, reasons.get(image))
            rows.append(row)
            critical.extend(found)
    return rows, critical


def policy_failures(rows, critical, platforms):
    failures = [f"{row['image']} was not scanned: {row['why_not_scanned']}" for row in rows if row["scanned"] == "no"]
    if not platforms:
        failures.append("platform.txt names no platform, so nothing says what this scan was meant to read")
    # trivy's --platform chooses a child of an index. On a plain manifest it does nothing: it exits 0 and scans whatever the
    # manifest is, so without this a scan for the wrong architecture would read as a clean one.
    failures += [
        f"{row['image']} is {row['platform']}, and this scan is for {' or '.join(platforms)}. A digest dev runs under emulation on purpose can be allowed on a full scan with SCAN_ALSO_PLATFORM"
        for row in rows
        if platforms and row["scanned"] == "yes" and row["platform"] not in (NO_PLATFORM, *platforms)
    ]
    failures += [
        f"{item['image']} is ours and has {item['id']} in {item['package']} {item['installed']}, fixed in {item['fixed_in']}"
        for item in critical
        if item["ours"] == "yes" and item["fixed_in"]
    ]
    return failures


def write_tsv(path, fields, rows):
    with open(path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fields, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def short(image):
    return re.sub(r"@sha256:([a-f0-9]{12})[a-f0-9]*$", r"@\1", image)


def table(rows):
    lines = [f"{'image':<84} {'CRITICAL':>12} {'HIGH':>12} {'MEDIUM':>12} {'LOW':>6}  os"]
    for row in sorted(rows, key=lambda r: (r["ours"] == "no", -r["critical"], -r["high"], r["image"])):
        if row["scanned"] == "no":
            lines.append(f"{short(row['image']):<84} NOT SCANNED: {row['why_not_scanned']}")
            continue
        counts = [f"{row[s]} ({row[s + '_fixable']} fix)" for s in ("critical", "high", "medium")]
        end_of_life = ", end of life" if row["os_end_of_life"] == "yes" else ""
        lines.append(f"{short(row['image']):<84} {counts[0]:>12} {counts[1]:>12} {counts[2]:>12} {row['low']:>6}  {row['os']}{end_of_life}")
    return lines


def report_lines(rows, critical, failures, platforms):
    scanned = [row for row in rows if row["scanned"] == "yes"]
    total = {severity: sum(row[severity.lower()] for row in scanned) for severity in SEVERITIES}
    ours = [row for row in scanned if row["ours"] == "yes"]
    lines = table(rows)
    lines.append("")
    lines.append(f"{len(scanned)} of {len(rows)} targets scanned, {len(ours)} of the scanned ones built here.")
    if platforms:
        also = f", and {' and '.join(platforms[1:])} allowed for a plain manifest" if platforms[1:] else ""
        lines.append(f"Scanned for {platforms[0]}{also}.")
    lines.append("Findings across all images: " + ", ".join(f"{total[s]} {s}" for s in SEVERITIES) + ".")
    fixable_upstream = sorted({short(item["image"]) for item in critical if item["ours"] == "no" and item["fixed_in"]})
    if fixable_upstream:
        lines.append(f"Reported, not failing: {len(fixable_upstream)} upstream target(s) have a CRITICAL finding with a fix, so a newer version may help:")
        lines += [f"  {image}" for image in fixable_upstream]
    end_of_life = sorted(short(row["image"]) for row in scanned if row["os_end_of_life"] == "yes")
    if end_of_life:
        lines.append(f"Reported, not failing: {len(end_of_life)} image(s) on an end-of-life OS, where trivy's OS findings may be incomplete:")
        lines += [f"  {image}" for image in end_of_life]
    if not ours:
        lines.append("No image built here was scanned, so this run says nothing about Wayline's own images.")
    if failures:
        lines.append(f"FAIL: {len(failures)} policy failure(s):")
        lines += [f"  {failure}" for failure in failures]
    else:
        lines.append("PASS: every image was scanned, and no image built here has a CRITICAL finding with a fix.")
    return lines


def main(directory):
    rows, critical = analyze(directory)
    write_tsv(os.path.join(directory, "summary.tsv"), SUMMARY_FIELDS, rows)
    write_tsv(os.path.join(directory, "critical.tsv"), ["image", "ours", "id", "package", "installed", "fixed_in", "target"], critical)
    platforms = read_platforms(directory)
    failures = policy_failures(rows, critical, platforms)
    lines = report_lines(rows, critical, failures, platforms)
    print("\n".join(lines))
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        with open(summary_file, "a", encoding="utf-8") as handle:
            handle.write("### Image scan\n\n```\n" + "\n".join(lines) + "\n```\n")
    return 1 if failures else 0


def selftest():
    critical_fixed = {"VulnerabilityID": "CVE-1", "PkgName": "a", "InstalledVersion": "1", "FixedVersion": "2", "Severity": "CRITICAL"}
    critical_unfixed = {"VulnerabilityID": "CVE-2", "PkgName": "b", "InstalledVersion": "1", "Severity": "CRITICAL"}
    high_fixed = {"VulnerabilityID": "CVE-3", "PkgName": "c", "InstalledVersion": "1", "FixedVersion": "2", "Severity": "HIGH"}
    ours = "localhost:5001/wayline/web@sha256:" + "a" * 64
    ours_ghcr = "ghcr.io/owner/wayline/web@sha256:" + "b" * 64
    upstream = "docker.io/makeplane/plane-frontend:v1@sha256:" + "c" * 64

    def run(images, not_scanned=(), asked=("linux/arm64",), read_as=("linux", "arm64"), artifact_type="container_image"):
        """images: {image: [vulnerabilities]}. asked goes in platform.txt, and read_as is what each result says it read. Returns (exit code, summary rows)."""
        with tempfile.TemporaryDirectory() as directory:
            os.mkdir(os.path.join(directory, "images"))
            if asked is not None:
                with open(os.path.join(directory, "platform.txt"), "w", encoding="utf-8") as handle:
                    handle.write("".join(f"{platform}\n" for platform in asked))
            with open(os.path.join(directory, "inventory.tsv"), "w", encoding="utf-8") as inventory:
                for number, (image, vulnerabilities) in enumerate(images.items()):
                    filename = f"{number}.json"
                    inventory.write(f"{image}\ttest\t{filename}\n")
                    if vulnerabilities is not None:
                        with open(os.path.join(directory, "images", filename), "w", encoding="utf-8") as handle:
                            json.dump(
                                {
                                    "ArtifactName": image,
                                    "ArtifactType": artifact_type,
                                    "Metadata": {"OS": {"Family": "alpine", "Name": "3", "EOSL": True}, "ImageConfig": dict(zip(("os", "architecture"), read_as))},
                                    "Results": [{"Target": "t", "Vulnerabilities": vulnerabilities}],
                                },
                                handle,
                            )
            with open(os.path.join(directory, "not-scanned.txt"), "w", encoding="utf-8") as handle:
                for image in not_scanned:
                    handle.write(f"{image}\ttrivy failed twice\n")
            stdout = sys.stdout
            sys.stdout = open(os.devnull, "w", encoding="utf-8")
            try:
                code = main(directory)
            finally:
                sys.stdout.close()
                sys.stdout = stdout
            return code, analyze(directory)[0]

    assert run({ours: [critical_fixed]})[0] == 1, "a fixable CRITICAL in our image must fail"
    assert run({ours_ghcr: [critical_fixed]})[0] == 1, "the same image in GHCR must fail"
    assert run({ours: [critical_unfixed]})[0] == 0, "no fix means nothing to do yet"
    assert run({ours: [high_fixed]})[0] == 0, "a fixable HIGH is reported only"
    code, rows = run({upstream: [critical_fixed, high_fixed, critical_unfixed]})
    assert code == 0, "upstream findings must not fail"
    assert rows[0]["critical"] == 2 and rows[0]["critical_fixable"] == 1 and rows[0]["high"] == 1, "upstream findings must still be counted"
    assert rows[0]["os_end_of_life"] == "yes", "an end-of-life OS must be reported"
    assert run({upstream: []})[0] == 0, "a clean image passes"
    assert run({upstream: None})[0] == 1, "a missing result must fail"
    assert run({upstream: []}, not_scanned=[upstream])[0] == 1, "a stopped scan must fail"
    assert run({upstream: [], ours: [critical_fixed]})[0] == 1, "one bad image among good ones must fail"
    # trivy exits 0 and reads what a plain manifest is, whatever --platform said. Measured on trivy 0.76.1.
    amd64 = ("linux", "amd64")
    assert run({ours: []}, read_as=amd64)[0] == 1, "a plain amd64 manifest in an arm64 scan must fail"
    assert run({ours_ghcr: []}, asked=("linux/amd64",))[0] == 1, "a plain arm64 manifest in an amd64 scan must fail"
    assert run({upstream: []}, read_as=amd64)[0] == 1, "another architecture must fail upstream too: the child read was not the one asked for"
    code, rows = run({ours_ghcr: []}, asked=("linux/amd64",), read_as=amd64)
    assert code == 0 and rows[0]["platform"] == "linux/amd64" and rows[0]["architecture"] == "amd64", "the architecture asked for passes"
    assert run({ours: []}, asked=("linux/arm64", "linux/amd64"), read_as=amd64)[0] == 0, "a platform allowed on a full scan passes"
    assert run({ours: []}, asked=("linux/arm64", "linux/amd64"), read_as=("linux", "riscv64"))[0] == 1, "a platform nobody allowed still fails"
    assert run({ours: []}, read_as=("linux", ""))[0] == 1, "a result that names no architecture must fail"
    assert run({ours: []}, read_as=("windows", "arm64"))[0] == 1, "another OS must fail"
    assert run({ours: []}, asked=None)[0] == 1, "with nothing saying what was asked for, it must fail"
    assert run({ours: []}, asked=())[0] == 1, "an empty platform.txt must fail"
    assert run({"wayline-source-lockfiles": []}, read_as=("", ""), artifact_type="filesystem")[0] == 0, "a directory has no platform"
    assert run({ours: []}, read_as=("", ""), artifact_type="container_image")[0] == 1, "an image with no platform is not a directory"
    print("selftest ok")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(selftest() if sys.argv[1] == "--selftest" else main(sys.argv[1]))
