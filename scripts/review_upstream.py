"""Read-only upstream review snapshots; no vendoring, installs or EDA."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.error
import urllib.request

REPOSITORIES = {
    "openTPU": {
        "repo": "FeSens/openTPU",
        "commit": "810632e2e1d4961575a3c6f8f194abc8fc3f8fd3",
        "files": [
            "LICENSE", "README.md", "pyproject.toml",
            "asic/nangate45/openlayout/skills/LICENSE",
            "docs/isa.md", "docs/quant.md", "docs/host.md",
            "docs/llama.md", "docs/board.md", "docs/scoreboard.md",
            "docs/litedram.md", "docs/mxu_systolic.md",
            "docs/bcu1525.md",
            "rtl/top/otpu_pkg.sv", "rtl/top/otpu_top.sv",
            "rtl/seq/otpu_seq.sv", "rtl/dma/otpu_dma.sv",
            "rtl/mem/otpu_dram.sv", "rtl/mem/otpu_actram.sv",
            "rtl/shell/otpu_ctrl.sv", "rtl/shell/otpu_mem_ch.sv",
            "rtl/vpu/otpu_quant.sv", "rtl/vpu/otpu_vpu.sv",
            "opentpu/isa.py", "opentpu/isasim.py",
            "opentpu/runtime.py", "opentpu/compiler.py",
            "opentpu/quant.py", "opentpu/kernels/attention.py",
            "opentpu/kernels/mlp.py", "opentpu/kernels/lib.py",
            "opentpu/llm/llama.py", "opentpu/host/regs.py",
            "tests/test_isa.py", "tests/test_quant_rtl.py",
            "tests/test_kernels.py"
        ],
    },
    "llama-fpga": {
        "repo": "adamgallas/llama-fpga",
        "commit": "bdd90206675594ab6b710a32d5319c68a58d9c36",
        "files": [
            "README.md", "scala/build.sbt", "python/model2bin.py",
            "au250/host_sdk.c", "au250/load_param.sh",
            "scala/src/main/scala/top/AxiLiteCtrl.scala",
            "scala/src/main/scala/top/StateGen.scala",
            "scala/src/main/scala/schedule/MemCmd.scala",
            "scala/src/main/scala/util/AXIDataMoverWrapper.scala",
            "scala/src/main/scala/util/XilinxFloatIPCollection.scala",
            "scala/src/main/scala/cfgGen/LLaMA2_7B_MMAP_Align.scala",
            "scala/src/main/scala/busdemux/KvCacheCase.scala",
            "scala/src/main/scala/attn/QKMul.scala",
            "scala/src/main/scala/attn/SerialSafeSoftmax.scala",
            "scala/src/main/scala/quant/GetScaleZero.scala",
            "scala/src/main/scala/quant/QuantWrapper.scala",
            "scala/src/main/scala/convert/Int4Int8FP16Conv.scala",
            "scala/src/main/scala/norm/RMSNormFp32.scala",
            "scala/src/main/scala/rope/SerialRoPE32.scala",
            "scala/src/main/scala/mlp/SiluFp32.scala"
        ],
    },
}
HEADERS = {"User-Agent": "fpga-project-upstream-review"}
def fetch(url):
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.read()
def collect_file(job):
    label, repo, commit, name, destination = job
    url = f"https://raw.githubusercontent.com/{repo}/{commit}/{name}"
    try:
        payload = fetch(url)
        if len(payload) > 2 * 1024 * 1024:
            raise ValueError("selected review file exceeds 2 MiB limit")
        target = destination / label / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(payload)
        return {"repository": label, "path": name, "url": url,
                "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
    except Exception as exc:
        return {"repository": label, "path": name, "url": url, "error": str(exc)}
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parents[1] / "build/upstream_review")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    manifest = {"scope": "Selected read-only review copies; not integrated into DUT",
                "repositories": {}, "files": []}
    jobs = []
    for label, config in REPOSITORIES.items():
        repo, commit = config["repo"], config["commit"]
        metadata = {"repo": repo, "commit": commit}
        repository = json.loads(fetch(f"https://api.github.com/repos/{repo}"))
        metadata["github_declared_license"] = repository.get("license")
        (args.out / f"{label}_repository.json").write_text(json.dumps(repository, indent=2), encoding="utf-8")
        try:
            license_value = json.loads(fetch(f"https://api.github.com/repos/{repo}/license?ref={commit}"))
            metadata["license_api_status"] = 200
            metadata["license_api_spdx"] = license_value.get("license", {}).get("spdx_id")
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
            license_value = {"http_status": 404, "error": "No license file returned for pinned reference", "ref": commit}
            metadata["license_api_status"] = 404
        (args.out / f"{label}_license.json").write_text(json.dumps(license_value, indent=2), encoding="utf-8")
        tree = json.loads(fetch(f"https://api.github.com/repos/{repo}/git/trees/{commit}?recursive=1"))
        (args.out / f"{label}_pinned_tree.json").write_text(json.dumps(tree, indent=2), encoding="utf-8")
        entries = [item for item in tree["tree"] if item["type"] == "blob"]
        metadata["tree_truncated"] = tree.get("truncated")
        metadata["file_count"] = len(entries)
        metadata["license_notice_paths"] = [
            item["path"] for item in entries
            if any(word in item["path"].lower() for word in ("license", "licence", "notice", "copying"))
        ]
        metadata["gitlinks"] = [item["path"] for item in tree["tree"] if item["type"] == "commit"]
        manifest["repositories"][label] = metadata
        jobs.extend((label, repo, commit, name, args.out) for name in config["files"])
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        manifest["files"] = list(executor.map(collect_file, jobs))
    manifest["pass"] = all("error" not in item for item in manifest["files"]) and all(
        not meta["tree_truncated"] for meta in manifest["repositories"].values())
    (args.out / "review_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps({"pass": manifest["pass"], "repositories": manifest["repositories"],
                      "selected_files": len(jobs), "downloaded_bytes": sum(item.get("bytes", 0) for item in manifest["files"]),
                      "errors": [item for item in manifest["files"] if "error" in item]}, indent=2))
    return 0 if manifest["pass"] else 1
if __name__ == "__main__":
    raise SystemExit(main())
