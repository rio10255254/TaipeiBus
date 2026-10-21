"""Package an isolated Windows reader, without changing the host Python."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request
import zipfile

RUNTIME_URL = "https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip"
# The digest published in Python.org's Sigstore bundle for this exact file.
RUNTIME_SHA256 = base64.b64decode("SsvtbdHHRLA3bjsc9XzpBvncnpXmiCRYTICZpjAlo8M=").hex()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--site-packages", type=Path)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    runtime = root / "runtime"
    runtime.mkdir()
    with urllib.request.urlopen(RUNTIME_URL, timeout=60) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != RUNTIME_SHA256:
        raise RuntimeError("Official Python runtime hash does not match")
    import io
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        if not all((runtime / name).resolve().is_relative_to(runtime) for name in archive.namelist()):
            raise RuntimeError("Unsafe runtime archive")
        archive.extractall(runtime)
    site = runtime / "Lib" / "site-packages"
    if args.site_packages:
        shutil.copytree(args.site_packages, site, ignore=shutil.ignore_patterns("__pycache__", "pip", "pip-*.dist-info"))
    else:
        subprocess.run([sys.executable, "-m", "pip", "install", "--disable-pip-version-check",
            "--only-binary=:all:", "--target", str(site), "pymobiledevice3==11.40.2"], check=True)
    (runtime / "python312._pth").write_text("python312.zip\n.\nLib/site-packages\n..\nimport site\n", encoding="ascii")
    source = Path(__file__).resolve().parent
    for name in ("capture.py", "Start.cmd", "README.txt"):
        shutil.copyfile(source / name, root / name)
    # Retain per-wheel licenses and provenance. No credentials, pairing records,
    # developer machine paths or captured device reports are added to the bundle.
    manifest = {"python_url": RUNTIME_URL, "python_sha256": RUNTIME_SHA256,
                "pymobiledevice3": "11.40.2", "files": {}}
    for file in sorted(root.rglob("*")):
        if file.is_file():
            manifest["files"][file.relative_to(root).as_posix()] = hashlib.sha256(file.read_bytes()).hexdigest()
    (root / "package-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print("Portable reader ready:", root)


if __name__ == "__main__":
    main()
