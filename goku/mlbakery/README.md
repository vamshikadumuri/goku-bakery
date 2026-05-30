# MLBakery
![MLBakery](assets/mlbakery.webp)
MLBakery is a subproject under [goku](../../README.md) that is aimed at creating lightweight base images with AI/ML artefacts, especially small language models and embedding models, for easier portability. Some of the pre-built images are released as packages that can be found in the parent project's ghcr. Ideally, though, you will use the scripts to build your own images :)

## Example Usage

**Build a GGUF model image:**
```
bash build_gguf.sh microsoft/Phi-3-mini-4k-instruct-gguf Phi-3-mini-4k-instruct-fp16.gguf
```

**Build the PyRIT safety datasets image:**
```
# Requires: echo $GITHUB_TOKEN | docker login ghcr.io -u vamshikadumuri --password-stdin
bash datasets/build_datasets.sh vamshikadumuri
```

Individual datasets can also be fetched at runtime:
```
docker run --rm ghcr.io/vamshikadumuri/mlbakery:pyrit-datasets \
    python /download_datasets.py harmbench xstest
```

## Available Images

| Image                                | Model Source             | Image Size |
|---------------------------------------|--------------------------|------------|
| [mlbakery:Phi-3-mini-4k-instruct-q4.gguf](https://github.com/aishwaryaprabhat/goku/pkgs/container/mlbakery/215241701?tag=Phi-3-mini-4k-instruct-q4.gguf)   | [Source](https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/tree/main)              | 2.83GB     |
| [mlbakery:Phi-3-mini-4k-instruct-fp16.gguf](https://github.com/aishwaryaprabhat/goku/pkgs/container/mlbakery/215238297?tag=Phi-3-mini-4k-instruct-fp16.gguf)   | [Source](https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/tree/main)              | 8.08GB   |
| [mlbakery:gemma-2b-it-q4_k_m.gguf](https://github.com/aishwaryaprabhat/goku/pkgs/container/mlbakery/215226227?tag=gemma-2b-it-q4_k_m.gguf)     | [Source](https://huggingface.co/lmstudio-ai/gemma-2b-it-GGUF/tree/main)         | 1.93GB     |
| [mlbakery:gemma-2b-it-q8_0gguf](https://github.com/aishwaryaprabhat/goku/pkgs/container/mlbakery/215224594?tag=gemma-2b-it-q8_0.gguf)     | [Source](https://huggingface.co/lmstudio-ai/gemma-2b-it-GGUF/tree/main)         | 3.1GB     |
| `mlbakery:pyrit-datasets`    | 18 safety/red-teaming datasets (HarmBench, XSTest, BeaverTails, …) | ~5–10GB |

### Datasets image contents (`mlbakery:pyrit-datasets`)

| Dataset | Source |
|---------|--------|
| `harmbench` | [GitHub: centerforaisafety/HarmBench](https://github.com/centerforaisafety/HarmBench) |
| `xstest` | [GitHub: paul-rottger/exaggerated-safety](https://github.com/paul-rottger/exaggerated-safety) |
| `medsafetybench` | [GitHub: AI4LIFE-GROUP/med-safety-bench](https://github.com/AI4LIFE-GROUP/med-safety-bench) |
| `mlcommons_ailuminate` | [GitHub: mlcommons/ailuminate](https://github.com/mlcommons/ailuminate) |
| `multilingual_vulnerability` | [GitHub: CarsonDon/Multilingual-Vuln-LLMs](https://github.com/CarsonDon/Multilingual-Vuln-LLMs) |
| `visual_leak_bench` | [GitHub: YoutingWang/MM-SafetyBench](https://github.com/YoutingWang/MM-SafetyBench) |
| `aya_redteaming` | [HF: CohereForAI/aya_redteaming](https://huggingface.co/datasets/CohereForAI/aya_redteaming) |
| `jbb_behaviors` | [HF: JailbreakBench/JBB-Behaviors](https://huggingface.co/datasets/JailbreakBench/JBB-Behaviors) |
| `forbidden_questions` | [HF: TrustAIRLab/forbidden_question_set](https://huggingface.co/datasets/TrustAIRLab/forbidden_question_set) |
| `harmbench_hf` | [HF: centerforaisafety/HarmBench](https://huggingface.co/datasets/centerforaisafety/HarmBench) (standard + contextual) |
| `beaver_tails` | [HF: PKU-Alignment/BeaverTails](https://huggingface.co/datasets/PKU-Alignment/BeaverTails) |
| `salad_bench` | [HF: walledai/SaladBench](https://huggingface.co/datasets/walledai/SaladBench) |
| `simple_safety_tests` | [HF: Bertievidgen/SimpleSafetyTests](https://huggingface.co/datasets/Bertievidgen/SimpleSafetyTests) |
| `sorry_bench` | [HF: sorry-bench/sorry-bench-202503](https://huggingface.co/datasets/sorry-bench/sorry-bench-202503) |
| `toxic_chat` | [HF: lmsys/toxic-chat](https://huggingface.co/datasets/lmsys/toxic-chat) (0124 + 1123) |
| `pku_safe_rlhf` | [HF: PKU-Alignment/PKU-SafeRLHF](https://huggingface.co/datasets/PKU-Alignment/PKU-SafeRLHF) |
| `transphobia_awareness` | [Zenodo record 15482694](https://zenodo.org/records/15482694) |
| `promptintel` | [api.promptintel.novahunting.ai](https://api.promptintel.novahunting.ai) — requires `PROMPTINTEL_API_KEY` |
