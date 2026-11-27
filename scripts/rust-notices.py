#!/usr/bin/env python3
"""Collect the license texts of the locked Cargo graph for a packaged target."""
import json
from pathlib import Path
import shutil
import subprocess
import sys

target, output = sys.argv[1:]
metadata = json.loads(subprocess.check_output([
    "cargo", "metadata", "--format-version", "1", "--locked",
    "--manifest-path", "Core/Cargo.toml", "--filter-platform", target,
]))
with Path(output).open("w", encoding="utf-8") as out:
    for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
        if package["source"] is None:
            continue
        root = Path(package["manifest_path"]).parent
        print(package["name"], package["version"], package["license"], file=out)
        for path in sorted(root.iterdir()):
            if path.is_file() and path.name.upper().startswith(("LICENSE", "COPYING", "COPYRIGHT", "NOTICE")):
                print(path.name, path.read_text(), sep="\n", file=out)
        print(file=out)


sysroot = Path(subprocess.check_output(["rustc", "--print", "sysroot"], text=True).strip())
library_notice = sysroot / "share/doc/rust/COPYRIGHT-library.html"
if library_notice.is_file():
    shutil.copyfile(library_notice, Path(output).with_name("Rust-library.html"))
