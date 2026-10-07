"""Write a MeshLLM native runtime manifest.json for a staged runtime bundle.

Mirrors the manifest produced by skippy/scripts/package-native-runtime.sh.
The host verifies every listed checksum when it loads the bundle, so this
must run after the last modification of any bundled file.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def skippy_abi_version(ffi_lib_rs):
    values = {}
    with open(ffi_lib_rs, encoding="utf-8") as handle:
        for line in handle:
            match = re.match(
                r"pub const ABI_VERSION_(MAJOR|MINOR|PATCH): u32 = ([0-9]+);",
                line.strip(),
            )
            if match:
                values[match.group(1)] = match.group(2)
    return "{}.{}.{}".format(values["MAJOR"], values["MINOR"], values["PATCH"])


def glibc_requirement(version):
    if version == "GLIBC_ABI_DT_RELR":
        return (2, 36)
    major, minor = version.removeprefix("GLIBC_").split(".")
    return (int(major), int(minor))


def packaged_glibc_requirement(root, paths):
    requirements = []
    env = dict(os.environ, LC_ALL="C")
    for relative_path in paths:
        path = os.path.join(root, relative_path)
        with open(path, "rb") as handle:
            if handle.read(4) != b"\x7fELF":
                continue
        output = subprocess.run(
            ["readelf", "-V", path], check=True, capture_output=True, text=True, env=env
        ).stdout
        _, heading, needs = output.partition("Version needs section")
        if heading:
            requirements.extend(
                glibc_requirement(version)
                for version in re.findall(r"GLIBC_(?:\d+\.\d+|ABI_DT_RELR)", needs)
            )
    if not requirements:
        return None
    major, minor = max(requirements)
    return f"{major}.{minor}"


def split_arches(raw):
    values = []
    for part in raw.replace(",", ";").split(";"):
        if part.strip():
            values.append(part.strip())
    return values


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--release-version", required=True)
    parser.add_argument("--ffi-lib-rs", required=True)
    parser.add_argument("--os", required=True)
    parser.add_argument("--arch", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--backend", required=True)
    parser.add_argument("--cuda-major", default="")
    parser.add_argument("--cuda-arches", default="")
    parser.add_argument("--primary-library", required=True)
    parser.add_argument("--library", action="append", default=[])
    parser.add_argument("--tool", action="append", default=[])
    parser.add_argument("--llama-upstream-sha", default="")
    parser.add_argument("--llama-patch-digest", default="")
    args = parser.parse_args()

    files = {path: file_sha256(os.path.join(args.root, path)) for path in args.library}
    tools = {path: file_sha256(os.path.join(args.root, path)) for path in args.tool}

    backend = {"kind": args.backend}
    if args.backend == "cuda":
        backend["cuda"] = {
            "toolkit_major": int(args.cuda_major),
            "gpu_arches": split_arches(args.cuda_arches),
        }
    elif args.backend == "vulkan":
        backend["vulkan"] = {}

    min_glibc = None
    if args.os == "linux":
        min_glibc = packaged_glibc_requirement(args.root, [*args.library, *args.tool])

    manifest = {
        "schema_version": 2,
        "runtime": {
            "id": args.id,
            "release_version": args.release_version,
            "skippy_abi": skippy_abi_version(args.ffi_lib_rs),
            "platform": {
                "os": args.os,
                "arch": args.arch,
                "target": args.target,
                "min_glibc": min_glibc,
            },
            "backend": backend,
            "rank": 0,
            "libraries": args.library,
            "files": files,
            "tools": tools,
            "url": None,
            "sha256": None,
            "signature": None,
        },
        "build": {
            "platform": args.platform,
            "backend": args.backend,
            "primary_library": args.primary_library,
            "relocatable_libraries": args.library if args.os == "linux" else [],
            "library_sha256": files[args.primary_library],
            "llama_upstream_sha": args.llama_upstream_sha or None,
            "llama_patched_sha": None,
            "llama_patch_digest": args.llama_patch_digest or None,
        },
    }
    with open(os.path.join(args.root, "manifest.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")


if __name__ == "__main__":
    main()
