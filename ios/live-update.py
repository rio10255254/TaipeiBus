"""Validate, publish and roll back downloaded app content. Standard library only."""
import argparse
import base64
import copy
import json
import math
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENDPOINT = "repos/rio10255254/TaipeiBus/contents/runtime/settings.json"


def load_json(text):
    return json.loads(text, parse_constant=lambda value: (_ for _ in ()).throw(ValueError("Non-finite number: " + value)))


def validate(document, app_version=None):
    schema = load_json((ROOT / "runtime/settings.schema.json").read_text(encoding="utf-8-sig"))

    def require(valid, path):
        if not valid:
            raise ValueError("Invalid live setting: " + path)

    def visit(value, rule, path):
        if "const" in rule:
            require(type(value) is int and value == rule["const"], path)
        kind = rule.get("type")
        if kind == "object":
            require(type(value) is dict, path)
            require(len(value) <= rule.get("maxProperties", 10000), path)
            require(all(key in value for key in rule.get("required", [])), path)
            properties = rule.get("properties", {})
            for key, item in value.items():
                if "propertyNames" in rule:
                    visit(key, rule["propertyNames"], path + ".key")
                child = properties.get(key, rule.get("additionalProperties"))
                require(type(child) is dict, path + "." + key)
                visit(item, child, path + "." + key)
        elif kind == "array":
            require(type(value) is list and rule.get("minItems", 0) <= len(value) <= rule.get("maxItems", 10000), path)
            if rule.get("uniqueItems"):
                require(len({json.dumps(x, sort_keys=True) for x in value}) == len(value), path)
            for index, item in enumerate(value):
                visit(item, rule["items"], f"{path}[{index}]")
        elif kind == "string":
            require(type(value) is str and rule.get("minLength", 0) <= len(value) <= rule.get("maxLength", 10000), path)
            require(not any(ord(letter) < 32 and letter != "\n" for letter in value), path)
            if "pattern" in rule:
                require(re.fullmatch(rule["pattern"], value) is not None, path)
        elif kind in ("number", "integer"):
            require(type(value) in ((int,) if kind == "integer" else (int, float)), path)
            require(math.isfinite(value) and rule.get("minimum", -math.inf) <= value <= rule.get("maximum", math.inf), path)
        elif kind == "boolean":
            require(type(value) is bool, path)
    visit(document, schema, "settings")
    planning = document.get("planning", {})
    require(planning.get("expandedWalkMeters", 1200) >= planning.get("firstWalkMeters", 800), "walking distances")
    if app_version:
        require(tuple(map(int, document["minimumAppVersion"].split("."))) <= tuple(map(int, app_version.split("."))), "minimumAppVersion")
    require(len(json.dumps(document, ensure_ascii=False).encode("utf-8")) <= 131072, "file size")
    return document


def gh(*arguments, payload=None):
    command = ["gh", "api", *arguments]
    if payload is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(payload, ensure_ascii=False) if payload is not None else None,
                            capture_output=True, text=True, encoding="utf-8", check=True)
    return load_json(result.stdout)


def merge(base, patch):
    result = copy.deepcopy(base)
    for key, value in patch.items():
        result[key] = merge(result[key], value) if isinstance(value, dict) and isinstance(result.get(key), dict) else value
    return result


def publish(patch, rollback_revision=None):
    remote = gh(ENDPOINT + "?ref=main")
    current = load_json(base64.b64decode(remote["content"]).decode("utf-8"))
    if rollback_revision is not None:
        commits = gh("repos/rio10255254/TaipeiBus/commits?path=runtime/settings.json&sha=main&per_page=100")
        candidate = None
        for commit in commits:
            old = gh(ENDPOINT + "?ref=" + commit["sha"])
            contents = load_json(base64.b64decode(old["content"]).decode("utf-8"))
            if contents["revision"] == rollback_revision:
                candidate = contents
                break
        if candidate is None:
            raise ValueError("The requested content revision was not found.")
    else:
        full = all(key in patch for key in ("schemaVersion", "revision", "minimumAppVersion"))
        candidate = copy.deepcopy(patch) if full else merge(current, patch)
    candidate["revision"] = current["revision"] + 1
    app_version = load_json((ROOT / "ios/release/testflight.json").read_text(encoding="utf-8"))["version"]
    validate(candidate, app_version)
    encoded = (json.dumps(candidate, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    answer = gh("--method", "PUT", ENDPOINT, payload={
        "message": f"Update app content to revision {candidate['revision']}",
        "content": base64.b64encode(encoded).decode("ascii"), "sha": remote["sha"], "branch": "main"})
    print(f"Published app content revision {candidate['revision']}. No app rebuild was started.")
    print(answer["commit"]["html_url"])
    return candidate


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="operation", required=True)
    check = sub.add_parser("validate")
    check.add_argument("path", nargs="?", default="runtime/settings.json")
    send = sub.add_parser("publish")
    send.add_argument("--document-env", default="BUS_LIVE_DOCUMENT")
    rollback = sub.add_parser("rollback")
    rollback.add_argument("revision", type=int)
    args = parser.parse_args()
    if args.operation == "validate":
        data = Path(args.path).read_bytes()
        if len(data) > 131072:
            raise ValueError("Live content exceeds the size limit.")
        document = load_json(data.decode("utf-8-sig"))
        app_version = load_json((ROOT / "ios/release/testflight.json").read_text(encoding="utf-8"))["version"]
        validate(document, app_version)
        print(f"Live content revision {document['revision']} validated for App {app_version}.")
    elif args.operation == "publish":
        document = os.environ.get(args.document_env, "").strip()
        if not document:
            raise ValueError("Provide the JSON content or a partial update.")
        publish(load_json(document))
    else:
        publish({}, rollback_revision=args.revision)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Live update failed: {error}")
