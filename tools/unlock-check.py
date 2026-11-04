#!/usr/bin/env python3
"""unlock-check.py - decide whether the GA104 SS0 unlock is active in THIS boot.

The unlock is volatile: it is replayed by UNLOCK.EFI on every boot and lives only
until the next power cycle. So this tool must run in the Windows session that was
started by the unlock EFI, with no reboot in between.

Signal used: FP16/BF16 tensor-core GEMM throughput, the same measurement the
project README reports (86.1 / 85.8 TFLOPS unlocked vs the published ~43-44
TFLOPS locked ceiling on GA104). TF32 and a DRAM copy run as controls: if those
are also slow the card is power/clock limited and the verdict is inconclusive
rather than "locked".

Runs on plain CPython - no PyTorch, no CUDA toolkit, no compiler. It locates
cudart64_*.dll + cublas64_*.dll on PATH / CUDA_PATH / a PyTorch install / the
default toolkit path, and calls cublasGemmEx through ctypes.

Exit codes: 0 unlocked, 1 locked, 2 inconclusive, 3 cannot run.
"""

import argparse
import ctypes as C
import glob
import json
import os
import re
import statistics
import struct
import subprocess
import sys
import time

# ---- CUDA / cuBLAS constants (stable across 11.x - 13.x) ------------------
CUDA_R_32F, CUDA_R_16F, CUDA_R_16BF = 0, 2, 14
CUBLAS_OP_N = 0
CUBLAS_COMPUTE_32F = 68
CUBLAS_COMPUTE_32F_FAST_TF32 = 77
CUBLAS_GEMM_DEFAULT_TENSOR_OP = 99
CUDA_MEMCPY_HOST_TO_DEVICE = 1
CUDA_DEVATTR_SM_COUNT = 16
CUDA_DEVATTR_CC_MAJOR = 75
CUDA_DEVATTR_CC_MINOR = 76

FP16_ONE = b"\x00\x3c"   # __half 1.0, little endian
BF16_ONE = b"\x80\x3f"   # __nv_bfloat16 1.0

_DLL_DIRS = []  # keep add_dll_directory handles alive


def _log(msg=""):
    print(msg, flush=True)


def find_cuda_dir(explicit=None):
    """Return a directory holding both cudart64_*.dll and cublas64_*.dll."""
    cands = []
    if explicit:
        cands.append(explicit)
    for p in os.environ.get("PATH", "").split(os.pathsep):
        if p and os.path.isdir(p):
            cands.append(p)
    for var in ("CUDA_PATH", "CUDA_HOME", "CUDA_BIN_PATH"):
        v = os.environ.get(var)
        if v:
            cands += [v, os.path.join(v, "bin")]
    try:
        import pathlib
        import torch  # noqa: F401  (only used to find its bundled CUDA libs)
        cands.append(str(pathlib.Path(torch.__file__).parent / "lib"))
    except Exception:
        pass
    cands += sorted(glob.glob(r"C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v*\bin"), reverse=True)
    cands += sorted(glob.glob(r"C:\Program Files\NVIDIA Corporation\CUDA\v*\bin"), reverse=True)

    seen = set()
    for d in cands:
        key = os.path.normcase(os.path.abspath(d))
        if key in seen or not os.path.isdir(d):
            continue
        seen.add(key)
        try:
            names = os.listdir(d)
        except OSError:
            continue
        if (any(re.fullmatch(r"cudart64_\d+\.dll", n, re.I) for n in names)
                and any(re.fullmatch(r"cublas64_\d+\.dll", n, re.I) for n in names)):
            return d
    return None


def _pick(directory, pattern):
    for n in sorted(os.listdir(directory), reverse=True):
        if re.fullmatch(pattern, n, re.I):
            return n
    return None


class Cuda:
    def __init__(self, dll_dir):
        self.dir = dll_dir
        _DLL_DIRS.append(os.add_dll_directory(dll_dir))
        rt_name = _pick(dll_dir, r"cudart64_\d+\.dll")
        bl_name = _pick(dll_dir, r"cublas64_\d+\.dll")
        self.rt_name, self.bl_name = rt_name, bl_name
        self.rt = C.WinDLL(os.path.join(dll_dir, rt_name))
        self.bl = C.WinDLL(os.path.join(dll_dir, bl_name))
        self._declare()

    def _declare(self):
        rt, bl = self.rt, self.bl
        rt.cudaGetErrorString.argtypes = [C.c_int]
        rt.cudaGetErrorString.restype = C.c_char_p
        rt.cudaGetDeviceCount.argtypes = [C.POINTER(C.c_int)]
        rt.cudaGetDeviceCount.restype = C.c_int
        rt.cudaDeviceGetAttribute.argtypes = [C.POINTER(C.c_int), C.c_int, C.c_int]
        rt.cudaDeviceGetAttribute.restype = C.c_int
        rt.cudaMalloc.argtypes = [C.POINTER(C.c_void_p), C.c_size_t]
        rt.cudaMalloc.restype = C.c_int
        rt.cudaFree.argtypes = [C.c_void_p]
        rt.cudaFree.restype = C.c_int
        rt.cudaMemcpy.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t, C.c_int]
        rt.cudaMemcpy.restype = C.c_int
        rt.cudaDeviceSynchronize.argtypes = []
        rt.cudaDeviceSynchronize.restype = C.c_int
        rt.cudaEventCreate.argtypes = [C.POINTER(C.c_void_p)]
        rt.cudaEventCreate.restype = C.c_int
        rt.cudaEventRecord.argtypes = [C.c_void_p, C.c_void_p]
        rt.cudaEventRecord.restype = C.c_int
        rt.cudaEventSynchronize.argtypes = [C.c_void_p]
        rt.cudaEventSynchronize.restype = C.c_int
        rt.cudaEventElapsedTime.argtypes = [C.POINTER(C.c_float), C.c_void_p, C.c_void_p]
        rt.cudaEventElapsedTime.restype = C.c_int
        rt.cudaEventDestroy.argtypes = [C.c_void_p]
        rt.cudaEventDestroy.restype = C.c_int

        bl.cublasCreate_v2.argtypes = [C.POINTER(C.c_void_p)]
        bl.cublasCreate_v2.restype = C.c_int
        bl.cublasDestroy_v2.argtypes = [C.c_void_p]
        bl.cublasDestroy_v2.restype = C.c_int
        bl.cublasGetVersion_v2.argtypes = [C.c_void_p, C.POINTER(C.c_int)]
        bl.cublasGetVersion_v2.restype = C.c_int
        bl.cublasGemmEx.argtypes = [
            C.c_void_p, C.c_int, C.c_int, C.c_int, C.c_int, C.c_int,
            C.c_void_p, C.c_void_p, C.c_int, C.c_int,
            C.c_void_p, C.c_int, C.c_int,
            C.c_void_p, C.c_void_p, C.c_int, C.c_int,
            C.c_int, C.c_int,
        ]
        bl.cublasGemmEx.restype = C.c_int

    def _rt(self, status, what):
        if status != 0:
            err = self.rt.cudaGetErrorString(status)
            raise RuntimeError("%s failed: %s (%d)" % (what, err.decode("ascii", "replace"), status))

    def _bl(self, status, what):
        if status != 0:
            raise RuntimeError("%s failed: cuBLAS status %d" % (what, status))

    def info(self):
        count = C.c_int(0)
        self._rt(self.rt.cudaGetDeviceCount(C.byref(count)), "cudaGetDeviceCount")
        if count.value < 1:
            raise RuntimeError("no CUDA device visible")
        out = {"devices": count.value}
        for name, attr in (("cc_major", CUDA_DEVATTR_CC_MAJOR),
                           ("cc_minor", CUDA_DEVATTR_CC_MINOR),
                           ("sm_count", CUDA_DEVATTR_SM_COUNT)):
            v = C.c_int(0)
            self._rt(self.rt.cudaDeviceGetAttribute(C.byref(v), attr, 0), "cudaDeviceGetAttribute")
            out[name] = v.value
        return out

    def cublas_version(self):
        h = C.c_void_p()
        self._bl(self.bl.cublasCreate_v2(C.byref(h)), "cublasCreate_v2")
        try:
            v = C.c_int(0)
            self._bl(self.bl.cublasGetVersion_v2(h, C.byref(v)), "cublasGetVersion_v2")
            return v.value
        finally:
            self.bl.cublasDestroy_v2(h)

    def gemm(self, kind, n, reps, warm_seconds):
        """Return (median_ms, tflops) for one n x n x n GEMM flavour."""
        if kind == "fp16":
            atype, ctype, elem, one = CUDA_R_16F, CUBLAS_COMPUTE_32F, 2, FP16_ONE
        elif kind == "bf16":
            atype, ctype, elem, one = CUDA_R_16BF, CUBLAS_COMPUTE_32F, 2, BF16_ONE
        else:  # tf32 control, fp32 in / fp32 accumulate with TF32 tensor cores
            atype, ctype, elem, one = CUDA_R_32F, CUBLAS_COMPUTE_32F_FAST_TF32, 4, None

        count = n * n
        ab_bytes = count * elem
        c_bytes = count * 4
        a = C.c_void_p()
        b = C.c_void_p()
        c = C.c_void_p()
        handle = C.c_void_p()
        ev0 = C.c_void_p()
        ev1 = C.c_void_p()
        try:
            self._rt(self.rt.cudaMalloc(C.byref(a), ab_bytes), "cudaMalloc(A)")
            self._rt(self.rt.cudaMalloc(C.byref(b), ab_bytes), "cudaMalloc(B)")
            self._rt(self.rt.cudaMalloc(C.byref(c), c_bytes), "cudaMalloc(C)")
            # Fill A and B with 1.0 (GEMM throughput is value independent, but a
            # non-zero input rules out any zero-skipping fast path).
            raw = one if one is not None else struct.pack("<f", 1.0)
            host = C.create_string_buffer(raw * count, ab_bytes)
            for name, dst in (("A", a), ("B", b)):
                self._rt(self.rt.cudaMemcpy(dst, C.cast(host, C.c_void_p), ab_bytes,
                                            CUDA_MEMCPY_HOST_TO_DEVICE), "cudaMemcpy(%s)" % name)

            self._bl(self.bl.cublasCreate_v2(C.byref(handle)), "cublasCreate_v2")
            alpha = C.c_float(1.0)
            beta = C.c_float(0.0)

            def call():
                st = self.bl.cublasGemmEx(
                    handle, CUBLAS_OP_N, CUBLAS_OP_N, n, n, n,
                    C.byref(alpha), a, atype, n, b, atype, n,
                    C.byref(beta), c, CUDA_R_32F, n,
                    ctype, CUBLAS_GEMM_DEFAULT_TENSOR_OP)
                self._bl(st, "cublasGemmEx")

            t0 = time.perf_counter()
            while True:
                call()
                self._rt(self.rt.cudaDeviceSynchronize(), "cudaDeviceSynchronize")
                if time.perf_counter() - t0 >= warm_seconds:
                    break

            self._rt(self.rt.cudaEventCreate(C.byref(ev0)), "cudaEventCreate")
            self._rt(self.rt.cudaEventCreate(C.byref(ev1)), "cudaEventCreate")
            samples = []
            for _ in range(reps):
                self._rt(self.rt.cudaEventRecord(ev0, None), "cudaEventRecord")
                call()
                self._rt(self.rt.cudaEventRecord(ev1, None), "cudaEventRecord")
                self._rt(self.rt.cudaEventSynchronize(ev1), "cudaEventSynchronize")
                ms = C.c_float(0.0)
                self._rt(self.rt.cudaEventElapsedTime(C.byref(ms), ev0, ev1), "cudaEventElapsedTime")
                samples.append(ms.value)
            median_ms = statistics.median(samples)
            flops = 2.0 * (n ** 3)
            return median_ms, flops / (median_ms * 1e-3) / 1e12
        finally:
            for ev in (ev0, ev1):
                if ev:
                    self.rt.cudaEventDestroy(ev)
            if handle:
                self.bl.cublasDestroy_v2(handle)
            for p in (a, b, c):
                if p:
                    self.rt.cudaFree(p)


def smi(query):
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=" + query, "--format=csv,noheader"],
            capture_output=True, text=True, timeout=20)
        if out.returncode != 0:
            return None
        return [line.strip() for line in out.stdout.strip().splitlines() if line.strip()]
    except Exception:
        return None


def main(argv=None):
    ap = argparse.ArgumentParser(description="Test whether the GA104 unlock is active in this boot.")
    ap.add_argument("--size", type=int, default=4096, help="square GEMM size (default 4096)")
    ap.add_argument("--reps", type=int, default=20, help="measured repetitions per mode (default 20)")
    ap.add_argument("--warmup", type=float, default=2.0, help="warmup seconds per mode (default 2.0)")
    ap.add_argument("--cuda-dir", help="directory holding cudart64_*.dll and cublas64_*.dll")
    ap.add_argument("--json", metavar="PATH", help="also write the full result as JSON")
    args = ap.parse_args(argv)

    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    _log("unlock-check: GA104 SS0 unlock probe (same boot only)")
    _log("=" * 64)

    smi_name = smi("name,driver_version,pcie.link.gen.current,pcie.link.width.current,clocks.max.sm,power.limit")
    if smi_name:
        _log("nvidia-smi     : " + smi_name[0])
    else:
        _log("nvidia-smi     : unavailable")

    dll_dir = find_cuda_dir(args.cuda_dir)
    if not dll_dir:
        _log("")
        _log("FAILED: no cudart64_*.dll + cublas64_*.dll found.")
        _log("Point the tool at one of these and retry:")
        _log("  * a CUDA toolkit bin directory        -> --cuda-dir \"C:\\Program Files\\NVIDIA GPU Computing Toolkit\\CUDA\\v12.x\\bin\"")
        _log("  * the directory of a CUDA PyTorch     -> --cuda-dir \"<venv>\\Lib\\site-packages\\torch\\lib\"")
        _log("  * a llama.cpp CUDA build folder (has cublas64_*.dll)")
        return 3

    try:
        cuda = Cuda(dll_dir)
        info = cuda.info()
        cb_ver = cuda.cublas_version()
    except Exception as exc:
        _log("")
        _log("FAILED: CUDA/cuBLAS could not be initialised: %s" % exc)
        return 3

    _log("cuda libs      : %s" % dll_dir)
    _log("runtime        : %s / %s (cuBLAS %d)" % (cuda.rt_name, cuda.bl_name, cb_ver))
    _log("device         : compute %d.%d, %d SMs" % (info["cc_major"], info["cc_minor"], info["sm_count"]))
    if info["cc_major"] < 8:
        _log("WARNING        : BF16 needs compute 8.0+; skipping the BF16 run.")
    _log("workload       : %d^3 GEMM, %d reps after %.1fs warmup" % (args.size, args.reps, args.warmup))
    _log("")

    results = {}
    modes = ["fp16"] + (["bf16"] if info["cc_major"] >= 8 else []) + ["tf32"]
    for kind in modes:
        ms, tflops = cuda.gemm(kind, args.size, args.reps, args.warmup)
        results[kind] = {"median_ms": round(ms, 4), "tflops": round(tflops, 2)}
        _log("%-6s : %8.2f ms   %7.2f TFLOPS" % (kind.upper(), ms, tflops))

    _log("")
    fp16 = results["fp16"]["tflops"]
    bf16 = results.get("bf16", {}).get("tflops")
    tf32 = results["tf32"]["tflops"]
    peak = max([v for v in (fp16, bf16) if v] or [0.0])
    ratio = (peak / tf32) if tf32 > 0 else 0.0

    # Two independent signals, both calibrated on GA104 (RTX 3070 Ti):
    #   absolute : locked ~43-44 TFLOPS, unlocked ~86
    #   ratio    : FP16/TF32 is ~1.9 locked and ~3.7-4.0 unlocked, and unlike the
    #              absolute number it survives clock/power drift, because SSE/SS0
    #              leaves the TF32 path untouched.
    # Agreement is required; anything in between is reported as inconclusive
    # rather than guessed.
    abs_unlocked = peak >= 60.0
    abs_locked = peak <= 55.0
    ratio_unlocked = ratio >= 3.0
    ratio_locked = 0.0 < ratio <= 2.6

    if abs_unlocked and ratio_unlocked:
        verdict, code = "UNLOCKED", 0
        why = "absolute and ratio signals agree"
    elif abs_locked and ratio_locked:
        verdict, code = "LOCKED", 1
        why = "absolute and ratio signals agree"
    else:
        verdict, code = "INCONCLUSIVE", 2
        why = "signals disagree or fall between the two bands"

    if tf32 < 15.0:
        verdict, code = "INCONCLUSIVE", 2
        why = "TF32 control is only %.1f TFLOPS - the card looks clock/power limited" % tf32

    _log("peak tensor-core FP16/BF16 : %.2f TFLOPS" % peak)
    _log("FP16/TF32 ratio            : %.2fx  (locked ~1.9, unlocked ~3.7)" % ratio)
    _log("verdict                    : %s" % verdict)
    _log("                             %s" % why)
    if verdict == "UNLOCKED":
        _log("                             %.2fx the published locked ceiling (43.5 TFLOPS)" % (peak / 43.5))
    _log("")
    _log("Reminder: SS0 is volatile. A reboot of any kind clears it - run this")
    _log("          in the Windows session that the unlock EFI handed off to.")

    gpu_name = smi_name[0].split(",")[0].strip() if smi_name else ""
    if gpu_name and "3070 Ti" not in gpu_name:
        _log("")
        _log("NOTE: thresholds are calibrated on RTX 3070 Ti (GA104). This device")
        _log("      reports '%s'; treat the verdict as indicative only." % gpu_name)

    if args.json:
        payload = {
            "verdict": verdict,
            "reason": why,
            "exit_code": code,
            "peak_tflops": round(peak, 2),
            "fp16_tf32_ratio": round(ratio, 3),
            "modes": results,
            "gpu": (smi_name[0] if smi_name else None),
            "cuda_dir": dll_dir,
            "runtime": cuda.rt_name,
            "cublas": cuda.bl_name,
            "cublas_version": cb_ver,
            "compute": "%d.%d" % (info["cc_major"], info["cc_minor"]),
            "sm_count": info["sm_count"],
            "size": args.size,
            "reps": args.reps,
            "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2)
        _log("JSON written to %s" % args.json)

    return code


if __name__ == "__main__":
    sys.exit(main())
