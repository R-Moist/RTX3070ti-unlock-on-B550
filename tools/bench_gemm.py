"""FP16/BF16 GEMM benchmark for the GPU-unlock experiment.

Method mirrors the upstream comparison so the numbers are directly comparable:
same shapes, FP16/BF16 as the target, TF32/FP32 and a memory copy as controls.
The controls must NOT move; only the FP16/BF16 issue rate is supposed to change.

Run:  python bench_gemm.py [--json out.json]
"""

from __future__ import annotations

import argparse
import json
import time

import torch


def bench_mm(dtype: torch.dtype, n: int, iters: int = 20, warmup: int = 5) -> dict:
    a = torch.randn(n, n, device="cuda", dtype=dtype)
    b = torch.randn(n, n, device="cuda", dtype=dtype)
    for _ in range(warmup):
        torch.mm(a, b)
    torch.cuda.synchronize()
    start = time.perf_counter()
    for _ in range(iters):
        torch.mm(a, b)
    torch.cuda.synchronize()
    elapsed = (time.perf_counter() - start) / iters
    del a, b
    torch.cuda.empty_cache()
    tflops = 2.0 * n**3 / elapsed / 1e12
    finite = bool(torch.isfinite(torch.tensor(tflops)))
    return {
        "shape": f"{n}x{n}x{n}",
        "ms": round(elapsed * 1e3, 3),
        "tflops": round(tflops, 2),
        "finite": finite,
    }


def bench_copy(gib: float = 1.0, iters: int = 10) -> dict:
    n = int(gib * 1024**3 // 2)
    src = torch.empty(n, device="cuda", dtype=torch.uint8)
    dst = torch.empty(n, device="cuda", dtype=torch.uint8)
    for _ in range(3):
        dst.copy_(src)
    torch.cuda.synchronize()
    start = time.perf_counter()
    for _ in range(iters):
        dst.copy_(src)
    torch.cuda.synchronize()
    elapsed = (time.perf_counter() - start) / iters
    del src, dst
    torch.cuda.empty_cache()
    gbps = 2.0 * n / elapsed / 1e9
    return {"size_gib": gib, "ms": round(elapsed * 1e3, 1), "gbps": round(gbps, 1)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", type=str, default=None)
    args = parser.parse_args()

    if not torch.cuda.is_available():
        print("CUDA is not available; this build cannot measure the GPU.", flush=True)
        return 2

    props = torch.cuda.get_device_properties(0)
    print(f"device      : {props.name}")
    print(f"cc          : {props.major}.{props.minor}")
    print(f"vram        : {props.total_memory / 1024**3:.1f} GiB")
    print(f"torch       : {torch.__version__}  cuda {torch.version.cuda}")
    drv = getattr(torch.cuda, "driver_version", None)
    print(f"driver      : {drv if drv else 'n/a'}")

    # Match the upstream methodology: no TF32 shortcut, no reduced-precision
    # reduction, so only the FP16/BF16 issue rate is under test.
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cuda.matmul.allow_fp16_reduced_precision_reduction = False

    results: dict[str, dict] = {}
    plan = [
        ("gemm_fp16_8192", torch.float16, 8192),
        ("gemm_bf16_8192", torch.bfloat16, 8192),
        ("gemm_fp16_4096", torch.float16, 4096),
        ("gemm_bf16_4096", torch.bfloat16, 4096),
        ("gemm_tf32_8192", torch.float32, 8192),
    ]
    for name, dtype, n in plan:
        try:
            results[name] = bench_mm(dtype, n)
        except Exception as exc:  # noqa: BLE001 - report, do not abort the sweep
            results[name] = {"error": str(exc)}
        print(f"{name:20s} {results[name]}", flush=True)

    # TF32 control needs the flag on; run it separately and restore the state.
    torch.backends.cuda.matmul.allow_tf32 = True
    try:
        results["gemm_tf32_8192"] = bench_mm(torch.float32, 8192)
    except Exception as exc:  # noqa: BLE001
        results["gemm_tf32_8192"] = {"error": str(exc)}
    torch.backends.cuda.matmul.allow_tf32 = False
    print(f"{'gemm_tf32_8192':20s} {results['gemm_tf32_8192']}", flush=True)

    results["mem_copy_1gib"] = bench_copy()
    print(f"{'mem_copy_1gib':20s} {results['mem_copy_1gib']}", flush=True)

    print()
    print("Reference: unleaked RTX 3070 Ti reports ~43-44 TFLOPS on FP16/BF16 GEMM;")
    print("a firmware-unlocked card reports roughly double that (~87-89).")
    print("TF32/FP32 and memory bandwidth must not change either way.")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump({"device": props.name, "torch": torch.__version__, "results": results},
                      handle, indent=2)
        print(f"\nwritten: {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
