#!/usr/bin/env python3
"""bake_dataset_bundle.py — bake many upstream datasets into ONE mlbakery image.

Reads a manifest (see ../datasets/*.json) and, for each source, one at a time:
download -> add as its own image layer at /datasets/<dir>/ -> verify -> delete
the local copy. Peak disk is roughly the image size plus one source. The image
is pushed once at the end, with /datasets/manifest.json describing every source.

Source types:
  hf      HF dataset repo (snapshot_download, optional revision/allow_patterns)
  github  sparse checkout of paths at a pinned ref (commit, short sha or branch)
  url     plain file downloads
  api     authenticated live feeds — recorded in the manifest, never baked

Usage:
  python3 bake_dataset_bundle.py -m ../datasets/pyrit_remote_1.0.1.json [-t TAG] [-u GHCR_USER]
                                 [--only dir1,dir2] [--no-push]
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

BASE_DOCKERFILE = """FROM ubuntu:latest
RUN apt-get update && apt-get install -y g++
RUN apt-get install -y python3 python3-pip git htop
WORKDIR /datasets
"""


def log(msg: str) -> None:
    print(msg, flush=True)


def run(cmd: list, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, text=True, **kw)


# ── Fetchers ──────────────────────────────────────────────────────────────

def fetch_hf(src: dict, dest: Path) -> None:
    from huggingface_hub import snapshot_download
    log(f"  ⬇️  HF dataset {src['repo']}" + (f"@{src['revision']}" if src.get("revision") else ""))
    snapshot_download(
        src["repo"],
        repo_type="dataset",
        revision=src.get("revision"),
        local_dir=str(dest),
        allow_patterns=src.get("allow_patterns"),
        ignore_patterns=src.get("ignore_patterns"),
    )
    for junk in (".cache", ".huggingface"):
        shutil.rmtree(dest / junk, ignore_errors=True)


def fetch_github(src: dict, dest: Path, scratch: Path) -> None:
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    git = lambda *a: run(["git", *a], env=env, capture_output=True)
    url = f"https://github.com/{src['repo']}.git"
    for i, co in enumerate(src["checkouts"]):
        clone = scratch / f"clone{i}"
        shutil.rmtree(clone, ignore_errors=True)
        log(f"  ⬇️  GitHub {src['repo']}@{co['ref']}: {', '.join(co['paths'])}")
        git("clone", "--quiet", "--filter=blob:none", "--no-checkout", url, str(clone))
        git("-C", str(clone), "sparse-checkout", "set", "--no-cone", *["/" + p.lstrip("/") for p in co["paths"]])
        git("-C", str(clone), "checkout", "--quiet", co["ref"])
        for p in co["paths"]:
            s, d = clone / p, dest / p.rstrip("/")
            if not s.exists():
                raise FileNotFoundError(f"{p} not found in {src['repo']}@{co['ref']}")
            d.parent.mkdir(parents=True, exist_ok=True)
            if s.is_dir():
                shutil.copytree(s, d, dirs_exist_ok=True)
            else:
                shutil.copy2(s, d)
        shutil.rmtree(clone, ignore_errors=True)


def fetch_url(src: dict, dest: Path) -> None:
    for f in src["files"]:
        target = dest / f["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        log(f"  ⬇️  {f['url']}")
        for attempt in range(1, 4):
            try:
                req = urllib.request.Request(f["url"], headers={"User-Agent": "mlbakery"})
                with urllib.request.urlopen(req, timeout=300) as r, open(target, "wb") as out:
                    shutil.copyfileobj(r, out)
                break
            except Exception as exc:
                if attempt == 3:
                    raise
                log(f"  ⚠️ attempt {attempt} failed ({exc}); retrying in 5s")
                time.sleep(5)


def upstream_of(src: dict) -> str:
    if src["type"] == "hf":
        return f"https://huggingface.co/datasets/{src['repo']}"
    if src["type"] == "github":
        return f"https://github.com/{src['repo']}"
    return src.get("upstream", "")


# ── Image helpers ─────────────────────────────────────────────────────────

def file_list(root: Path, rel_to: Path) -> list:
    return sorted(str(p.relative_to(rel_to)) for p in root.rglob("*") if p.is_file())


def add_layer(image: str, ctx: Path, copy_from: str, copy_to: str) -> None:
    (ctx / "Dockerfile").write_text(f"FROM {image}\nCOPY [\"{copy_from}\", \"{copy_to}\"]\n")
    run(["docker", "build", "-q", "-t", image, str(ctx)], stdout=subprocess.DEVNULL)


def verify_layer(image: str, name: str, expected: list) -> str:
    out = run(["docker", "run", "--rm", image, "sh", "-c",
               f"cd /datasets && find '{name}' -type f; echo ===SEP===; du -sh '{name}' | cut -f1"],
              capture_output=True).stdout
    listing, _, size = out.partition("===SEP===")
    actual = sorted(l for l in listing.splitlines() if l)
    if actual != expected:
        missing = sorted(set(expected) - set(actual))[:10]
        extra = sorted(set(actual) - set(expected))[:10]
        raise RuntimeError(f"image contents mismatch (missing={missing} extra={extra})")
    return size.strip()


def push(image: str) -> bool:
    for attempt in range(1, 4):
        if subprocess.run(["docker", "push", image]).returncode == 0:
            return True
        log(f"  ⚠️ push attempt {attempt} failed; retrying in 5s")
        time.sleep(5)
    return False


# ── Main ──────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-m", "--manifest", required=True)
    ap.add_argument("-t", "--tag", help="image tag (default: manifest 'tag')")
    ap.add_argument("-u", "--ghcr-user", default="vamshikadumuri")
    ap.add_argument("--only", help="comma-separated source dirs to bake (for testing)")
    ap.add_argument("--no-push", action="store_true")
    ap.add_argument("--work-dir", default=None)
    args = ap.parse_args()

    manifest = json.loads(Path(args.manifest).read_text())
    tag = args.tag or manifest["tag"]
    image = f"ghcr.io/{args.ghcr_user}/mlbakery:{tag}"
    sources = manifest["sources"]
    if args.only:
        wanted = {s.strip() for s in args.only.split(",") if s.strip()}
        sources = [s for s in sources if s["dir"] in wanted]

    work = Path(args.work_dir or f"temp_bundle_{tag}").resolve()
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)

    if subprocess.run(["docker", "info"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
        log("❌ Docker not available")
        return 1

    log("━" * 56)
    log(f"  MLBakery — dataset bundle {manifest['name']}")
    log(f"  Image: {image}  |  Sources: {len(sources)}")
    log("━" * 56)

    base = work / "base"
    base.mkdir()
    (base / "Dockerfile").write_text(BASE_DOCKERFILE)
    run(["docker", "build", "-q", "-t", image, str(base)], stdout=subprocess.DEVNULL)
    shutil.rmtree(base)

    results = []
    for n, src in enumerate(sources, 1):
        name = src["dir"]
        entry = {"dir": name, "type": src["type"], "upstream": upstream_of(src),
                 "pyrit_datasets": src.get("pyrit_datasets", [])}
        for k in ("repo", "revision", "checkouts", "files", "allow_patterns", "note"):
            if k in src:
                entry[k] = src[k]
        log(f"\n📦 [{n}/{len(sources)}] {name}  ({', '.join(entry['pyrit_datasets'])})")

        if src["type"] == "api":
            entry["status"] = f"skipped: authenticated API ({src.get('requires_env', 'API key')})"
            log(f"  ⏭️  {entry['status']}")
            results.append(entry)
            continue

        ctx = work / "ctx"
        shutil.rmtree(ctx, ignore_errors=True)
        dest = ctx / name
        dest.mkdir(parents=True)
        try:
            if src["type"] == "hf":
                fetch_hf(src, dest)
            elif src["type"] == "github":
                fetch_github(src, dest, work)
            elif src["type"] == "url":
                fetch_url(src, dest)
            else:
                raise ValueError(f"unknown source type {src['type']!r}")
            expected = file_list(dest, ctx)
            if not expected:
                raise RuntimeError("no files downloaded")
            add_layer(image, ctx, name, f"/datasets/{name}/")
            size = verify_layer(image, name, expected)
            entry.update(status="ok", files=len(expected), size=size)
            log(f"  ✅ {len(expected)} files, {size} in /datasets/{name}/")
        except Exception as exc:
            lines = [l for l in str(getattr(exc, "stderr", None) or exc).splitlines() if l.strip()]
            key = [l for l in lines if "fatal:" in l or "Error" in l]
            entry["status"] = f"failed: {(key or lines or [type(exc).__name__])[0].strip()}"
            log(f"  ❌ {entry['status']}")
        finally:
            shutil.rmtree(ctx, ignore_errors=True)
        results.append(entry)

    ok = [r for r in results if r["status"] == "ok"]
    failed = [r for r in results if r["status"].startswith("failed")]
    skipped = [r for r in results if r["status"].startswith("skipped")]

    bundle = {k: manifest[k] for k in ("name", "description", "pyrit_version", "pyrit_loader_source", "excluded")
              if k in manifest}
    bundle.update(image=image, baked_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), sources=results)
    ctx = work / "ctx"
    ctx.mkdir(exist_ok=True)
    (ctx / "manifest.json").write_text(json.dumps(bundle, indent=2))
    add_layer(image, ctx, "manifest.json", "/datasets/manifest.json")
    shutil.rmtree(work, ignore_errors=True)

    log("\n" + "━" * 56)
    log(f"  Summary: {len(ok)} ok, {len(failed)} failed, {len(skipped)} skipped")
    for r in failed + skipped:
        log(f"   - {r['dir']}: {r['status']}")
    log("━" * 56)

    if not ok:
        log("❌ Nothing baked; not pushing")
        return 1
    if not args.no_push:
        log(f"🚀 Pushing {image}...")
        if not push(image):
            log("❌ Push FAILED after 3 attempts")
            return 1
        log(f"Pushed: {image}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
