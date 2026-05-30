#!/usr/bin/env python3
"""
PyRIT Safety Datasets Downloader
Downloads red-teaming and safety evaluation datasets into /datasets/.
Datasets may be passed as positional CLI args to download selectively;
with no args all datasets are attempted.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import requests

DATASETS_DIR = Path(os.environ.get("DATASETS_DIR", "/datasets"))
DATASETS_DIR.mkdir(parents=True, exist_ok=True)


# ─── Logging ──────────────────────────────────────────────────────────────────

def _log(level: str, msg: str) -> None:
    print(f"[{level}] {msg}", flush=True)

def info(msg): _log("INFO", msg)
def warn(msg): _log("WARN", msg)
def error(msg): _log("ERROR", msg)


# ─── Helpers ──────────────────────────────────────────────────────────────────

def download_file(url: str, dest: Path, headers: dict = None) -> bool:
    dest.parent.mkdir(parents=True, exist_ok=True)
    info(f"GET {url}")
    try:
        r = requests.get(url, timeout=300, stream=True, headers=headers or {})
        r.raise_for_status()
        with open(dest, "wb") as f:
            for chunk in r.iter_content(chunk_size=65536):
                f.write(chunk)
        info(f"  -> {dest} ({dest.stat().st_size:,} bytes)")
        return True
    except Exception as exc:
        error(f"  {exc}")
        return False


def sparse_clone(repo_url: str, dest: Path, data_paths: list) -> bool:
    if dest.exists() and any(dest.iterdir()):
        info(f"Already exists: {dest}")
        return True
    dest.mkdir(parents=True, exist_ok=True)
    info(f"Sparse-cloning {repo_url}")
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    try:
        subprocess.run(
            ["git", "clone", "--depth=1", "--filter=blob:none", "--sparse",
             repo_url, str(dest)],
            check=True, env=env, capture_output=True, text=True,
        )
        subprocess.run(
            ["git", "-C", str(dest), "sparse-checkout", "set", "--cone"]
            + data_paths,
            check=True, env=env, capture_output=True, text=True,
        )
        info(f"  -> {dest}")
        return True
    except subprocess.CalledProcessError as exc:
        error(f"  git: {exc.stderr.strip()}")
        return False


def load_hf_dataset(repo_id: str, dest: Path, configs: list = None) -> bool:
    from datasets import load_dataset  # type: ignore
    import huggingface_hub  # type: ignore

    hf_token = os.environ.get("HF_TOKEN", "")
    if hf_token:
        huggingface_hub.login(token=hf_token, add_to_git_credential=False)

    dest.mkdir(parents=True, exist_ok=True)
    configs = configs or [None]
    ok = True
    for cfg in configs:
        label = cfg if cfg else "default"
        out = dest / label
        if out.exists():
            info(f"Already exists: {out}")
            continue
        info(f"Loading HF {repo_id}" + (f" [{cfg}]" if cfg else ""))
        try:
            kwargs: dict = {"path": repo_id, "trust_remote_code": False}
            if cfg:
                kwargs["name"] = cfg
            if hf_token:
                kwargs["token"] = hf_token
            ds = load_dataset(**kwargs)
            out.mkdir(parents=True, exist_ok=True)
            ds.save_to_disk(str(out))
            sizes = {k: len(v) for k, v in ds.items()}
            info(f"  -> {out} {sizes}")
        except Exception as exc:
            error(f"  {repo_id} [{label}]: {exc}")
            ok = False
    return ok


def fetch_zenodo(record_id: str, dest: Path) -> bool:
    dest.mkdir(parents=True, exist_ok=True)
    meta_path = dest / "metadata.json"
    if meta_path.exists():
        info(f"Already exists: {dest}")
        return True
    info(f"Fetching Zenodo record {record_id}")
    try:
        r = requests.get(
            f"https://zenodo.org/api/records/{record_id}", timeout=60
        )
        r.raise_for_status()
        record = r.json()
        meta_path.write_text(json.dumps(record, indent=2))
        for f in record.get("files", []):
            url = f["links"]["self"]
            fname = f["key"]
            download_file(url, dest / fname)
        return True
    except Exception as exc:
        error(f"  Zenodo {record_id}: {exc}")
        return False


# ─── GitHub-hosted datasets ────────────────────────────────────────────────

def fetch_harmbench():
    """HarmBench behavior datasets (text) from GitHub."""
    sparse_clone(
        "https://github.com/centerforaisafety/HarmBench",
        DATASETS_DIR / "harmbench",
        ["data/behavior_datasets"],
    )


def fetch_xstest():
    """XSTest exaggerated-safety prompts from GitHub."""
    sparse_clone(
        "https://github.com/paul-rottger/exaggerated-safety",
        DATASETS_DIR / "xstest",
        ["data"],
    )


def fetch_medsafetybench():
    """MedSafetyBench medical safety prompts from GitHub."""
    sparse_clone(
        "https://github.com/AI4LIFE-GROUP/med-safety-bench",
        DATASETS_DIR / "medsafetybench",
        ["data"],
    )


def fetch_mlcommons_ailuminate():
    """MLCommons AILuminate safety benchmark from GitHub."""
    sparse_clone(
        "https://github.com/mlcommons/ailuminate",
        DATASETS_DIR / "mlcommons_ailuminate",
        ["data", "src"],
    )


def fetch_multilingual_vulnerability():
    """Multilingual LLM vulnerability dataset from GitHub."""
    sparse_clone(
        "https://github.com/CarsonDon/Multilingual-Vuln-LLMs",
        DATASETS_DIR / "multilingual_vulnerability",
        ["data", "datasets"],
    )


def fetch_visual_leak_bench():
    """MM-SafetyBench text components from GitHub."""
    sparse_clone(
        "https://github.com/YoutingWang/MM-SafetyBench",
        DATASETS_DIR / "visual_leak_bench",
        ["MSSBench-Evaluation", "data"],
    )


# ─── HuggingFace datasets ──────────────────────────────────────────────────

def fetch_aya_redteaming():
    """Aya red-teaming dataset (CohereForAI)."""
    load_hf_dataset(
        "CohereForAI/aya_redteaming",
        DATASETS_DIR / "aya_redteaming",
    )


def fetch_jbb_behaviors():
    """JailbreakBench behaviors."""
    load_hf_dataset(
        "JailbreakBench/JBB-Behaviors",
        DATASETS_DIR / "jbb_behaviors",
    )


def fetch_forbidden_questions():
    """TrustAIRLab forbidden question set."""
    load_hf_dataset(
        "TrustAIRLab/forbidden_question_set",
        DATASETS_DIR / "forbidden_questions",
    )


def fetch_harmbench_hf():
    """HarmBench via HuggingFace (standard + contextual configs)."""
    load_hf_dataset(
        "centerforaisafety/HarmBench",
        DATASETS_DIR / "harmbench_hf",
        configs=["standard", "contextual"],
    )


def fetch_beaver_tails():
    """BeaverTails safety preference dataset (PKU-Alignment)."""
    load_hf_dataset(
        "PKU-Alignment/BeaverTails",
        DATASETS_DIR / "beaver_tails",
    )


def fetch_salad_bench():
    """SaladBench safety benchmark (walledai)."""
    load_hf_dataset(
        "walledai/SaladBench",
        DATASETS_DIR / "salad_bench",
    )


def fetch_simple_safety_tests():
    """SimpleSafetyTests (Bertievidgen)."""
    load_hf_dataset(
        "Bertievidgen/SimpleSafetyTests",
        DATASETS_DIR / "simple_safety_tests",
    )


def fetch_sorry_bench():
    """Sorry-Bench refusal evaluation dataset."""
    load_hf_dataset(
        "sorry-bench/sorry-bench-202503",
        DATASETS_DIR / "sorry_bench",
    )


def fetch_toxic_chat():
    """ToxicChat conversations (lmsys, both monthly configs)."""
    load_hf_dataset(
        "lmsys/toxic-chat",
        DATASETS_DIR / "toxic_chat",
        configs=["toxicchat0124", "toxicchat1123"],
    )


def fetch_pku_safe_rlhf():
    """PKU-SafeRLHF safety alignment dataset."""
    load_hf_dataset(
        "PKU-Alignment/PKU-SafeRLHF",
        DATASETS_DIR / "pku_safe_rlhf",
    )


# ─── Zenodo datasets ───────────────────────────────────────────────────────

def fetch_transphobia_awareness():
    """Transphobia awareness dataset from Zenodo (record 15482694)."""
    fetch_zenodo("15482694", DATASETS_DIR / "transphobia_awareness")


# ─── API-based datasets ────────────────────────────────────────────────────

def fetch_promptintel():
    """PromptIntel dataset — requires PROMPTINTEL_API_KEY at runtime."""
    dest = DATASETS_DIR / "promptintel"
    dest.mkdir(parents=True, exist_ok=True)
    api_key = os.environ.get("PROMPTINTEL_API_KEY", "")
    if not api_key:
        warn("PROMPTINTEL_API_KEY not set — skipping promptintel download")
        (dest / "README.txt").write_text(
            "Set PROMPTINTEL_API_KEY and re-run:\n"
            "  python /download_datasets.py promptintel\n"
            "API: https://api.promptintel.novahunting.ai\n"
        )
        return
    # Endpoint structure is provider-specific; update when API docs are confirmed.
    warn("PromptIntel API download not yet implemented.")


# ─── Registry + entrypoint ────────────────────────────────────────────────

FETCHERS: dict = {
    "harmbench": fetch_harmbench,
    "xstest": fetch_xstest,
    "medsafetybench": fetch_medsafetybench,
    "mlcommons_ailuminate": fetch_mlcommons_ailuminate,
    "multilingual_vulnerability": fetch_multilingual_vulnerability,
    "visual_leak_bench": fetch_visual_leak_bench,
    "aya_redteaming": fetch_aya_redteaming,
    "jbb_behaviors": fetch_jbb_behaviors,
    "forbidden_questions": fetch_forbidden_questions,
    "harmbench_hf": fetch_harmbench_hf,
    "beaver_tails": fetch_beaver_tails,
    "salad_bench": fetch_salad_bench,
    "simple_safety_tests": fetch_simple_safety_tests,
    "sorry_bench": fetch_sorry_bench,
    "toxic_chat": fetch_toxic_chat,
    "pku_safe_rlhf": fetch_pku_safe_rlhf,
    "transphobia_awareness": fetch_transphobia_awareness,
    "promptintel": fetch_promptintel,
}


if __name__ == "__main__":
    targets = sys.argv[1:] if sys.argv[1:] else list(FETCHERS.keys())
    unknown = [t for t in targets if t not in FETCHERS]
    if unknown:
        error(f"Unknown datasets: {unknown}")
        error(f"Available: {list(FETCHERS.keys())}")
        sys.exit(1)

    results: dict = {}
    for name in targets:
        info(f"\n{'=' * 60}\n  {name}\n{'=' * 60}")
        try:
            FETCHERS[name]()
            results[name] = "ok"
        except Exception as exc:
            error(f"Unhandled error in {name}: {exc}")
            results[name] = str(exc)

    manifest_path = DATASETS_DIR / "manifest.json"
    manifest_path.write_text(
        json.dumps({"version": "1.0", "datasets": targets, "results": results}, indent=2)
    )
    info(f"\nManifest -> {manifest_path}")

    failed = [k for k, v in results.items() if v != "ok"]
    if failed:
        warn(f"Failed datasets: {failed}")
    info(f"Done. {len(results) - len(failed)}/{len(results)} datasets OK.")
