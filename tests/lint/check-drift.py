#!/usr/bin/env python3
"""Fail when the docs and the code disagree (CI lint job, `make lint`).

Each check prints one line per problem; exit 1 if any. Stdlib only.
See docs/testing.md ("Drift checks") for what each rule protects.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
problems: list[str] = []


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def problem(check: str, msg: str) -> None:
    problems.append(f"[{check}] {msg}")


def md_files() -> list[Path]:
    skip = ("docs/research/", "tests/lab/artifacts/", ".omo/", ".claude/", ".serena/", "node_modules/")
    return [
        p for p in ROOT.rglob("*.md")
        if not any(str(p.relative_to(ROOT)).startswith(s) for s in skip)
    ]


def all_docs_text() -> str:
    return "\n".join(p.read_text(encoding="utf-8") for p in md_files())


# 1. Every alert rule has a row in the runbook's alert catalogue.
def check_alerts() -> None:
    runbook = read("docs/runbook-incident-response.md")
    for rules in sorted((ROOT / "config/prometheus/rules").glob("*.yml")):
        for name in re.findall(r"^\s*-\s*alert:\s*(\S+)", rules.read_text(), re.M):
            if f"| `{name}` |" not in runbook:
                problem("alerts", f"{name} ({rules.name}) has no row in docs/runbook-incident-response.md")


# 2. .env.example declares every variable the stack reads, and nothing else.
# Declared on purpose although nothing reads them by default:
DORMANT_VARS = {
    "ALERTMANAGER_WEBHOOK_URL",  # read once webhook_configs is uncommented in the template
}


def check_env() -> None:
    declared = set(re.findall(r"^([A-Z][A-Z0-9_]*)=", read(".env.example"), re.M))
    consumers = ["docker-compose.yml", "docker-compose.pegaprox.yml", "config/alertmanager/alertmanager.yml.tmpl"]
    used: set[str] = set()
    for rel in consumers:
        code = "\n".join(line for line in read(rel).splitlines() if not line.lstrip().startswith("#"))
        used |= set(re.findall(r"\$\{([A-Z][A-Z0-9_]*)", code))
    for var in sorted(used - declared):
        problem("env", f"${{{var}}} is used by the stack but missing from .env.example")
    scripts_text = "\n".join(p.read_text() for p in (ROOT / "scripts").rglob("*.sh"))
    for var in sorted(declared - used - DORMANT_VARS):
        if not re.search(rf"\b{var}\b", scripts_text):
            problem("env", f"{var} is in .env.example but nothing reads it")


# 3. Tags repeated outside the compose files match the compose files.
def check_tags() -> None:
    compose = read("docker-compose.yml")
    elsewhere = [".github/workflows/validate-and-test.yml", "tests/README.md", "Makefile"]
    for image in ("prom/prometheus", "prom/alertmanager"):
        m = re.search(rf"image:\s*{re.escape(image)}:(\S+)", compose)
        if not m:
            problem("tags", f"{image} not found in docker-compose.yml")
            continue
        for rel in elsewhere:
            for tag in re.findall(rf"{re.escape(image)}:(\S+)", read(rel)):
                if tag != m.group(1):
                    problem("tags", f"{rel} uses {image}:{tag}, docker-compose.yml pins {m.group(1)}")
    for name in ("cv4pve-diag", "cv4pve-metrics-exporter"):
        arg = re.search(r"^ARG CV4PVE_VERSION=(\S+)", read(f"docker/{name}/Dockerfile"), re.M)
        ref = re.search(rf"image:\s*proxmox-biome/{name}:(\S+)", compose)
        if arg and ref and arg.group(1) != ref.group(1):
            problem("tags", f"docker/{name}/Dockerfile builds {arg.group(1)}, compose tags it {ref.group(1)}")
        for rel in [".github/workflows/security-scan.yml"]:
            for tag in re.findall(rf"proxmox-biome/{name}:(\S+)", read(rel)):
                if arg and tag != arg.group(1):
                    problem("tags", f"{rel} scans {name}:{tag}, Dockerfile builds {arg.group(1)}")


# 4. Every script and every e2e phase is documented somewhere.
def check_documented() -> None:
    docs = all_docs_text()
    for p in sorted((ROOT / "scripts").rglob("*")):
        if p.is_file() and p.name not in docs:
            problem("docs", f"{p.relative_to(ROOT)} is not mentioned in any Markdown file")
    testing = read("docs/testing.md")
    for p in sorted((ROOT / "tests/e2e").glob("t*.sh")):
        if p.name not in testing:
            problem("docs", f"tests/e2e/{p.name} has no entry in docs/testing.md")
    for p in sorted((ROOT / ".github/workflows").glob("*.yml")):
        if p.name not in testing:
            problem("docs", f".github/workflows/{p.name} has no entry in docs/testing.md")


# 5. Relative Markdown links point at files that exist.
LINK = re.compile(r"\]\(([^)\s]+)\)")


def check_links() -> None:
    for md in md_files():
        text = re.sub(r"```.*?```", "", md.read_text(encoding="utf-8"), flags=re.S)
        for target in LINK.findall(text):
            if re.match(r"^[a-z]+:", target) or target.startswith("#"):
                continue
            path = target.split("#", 1)[0]
            if path and not (md.parent / path).exists():
                problem("links", f"{md.relative_to(ROOT)} -> {target} does not exist")


for check in (check_alerts, check_env, check_tags, check_documented, check_links):
    check()

for line in problems:
    print(line)
print(f"drift check: {len(problems)} problem(s)")
sys.exit(1 if problems else 0)
