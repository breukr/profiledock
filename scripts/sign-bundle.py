#!/usr/bin/env python3
"""Thin bundled Mach-O files to arm64, then sign nested code from the inside out."""
import os
import subprocess
import sys
from pathlib import Path

bundle = Path(sys.argv[1])
identity = os.environ.get("SIGNING_IDENTITY", "-")
options = ["--options", "runtime", "--timestamp"] if identity != "-" else []
machos = []
for path in bundle.rglob("*"):
    if path.is_symlink() or not path.is_file():
        continue
    with path.open("rb") as source:
        magic = source.read(4)
    if magic not in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
        continue
    architectures = subprocess.check_output(["lipo", "-archs", str(path)], text=True).split()
    if "arm64" not in architectures:
        raise SystemExit(f"Missing Apple Silicon code: {path.name}")
    if architectures != ["arm64"]:
        temporary = path.with_name(path.name + ".arm64")
        subprocess.run(["lipo", str(path), "-thin", "arm64", "-output", str(temporary)], check=True)
        temporary.chmod(path.stat().st_mode)
        temporary.replace(path)
    machos.append(path)

nested = [p for p in bundle.rglob("*") if p.is_dir() and not p.is_symlink() and p.suffix in (".framework", ".app", ".xpc")]
for path in sorted(set(machos + nested), key=lambda p: len(p.parts), reverse=True) + [bundle]:
    entitlements = ["--entitlements", str(Path(__file__).resolve().parent.parent / "Resources/ProfileDock.entitlements")] if path == bundle else ["--preserve-metadata=entitlements"]
    subprocess.run(["codesign", "--force", *entitlements, *options, "--sign", identity, str(path)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
