#!/usr/bin/env python3
"""Qwen3-ASR + ForcedAligner sidecar — bundled-with-cutti edition.

Differences from the standalone bench version:
- Picks an OS-assigned free port (when PORT=0 env), binds, writes the
  actual port to `port.txt` in the install dir before starting uvicorn.
  The Swift parent reads port.txt to know where to connect.
- Requires `Authorization: Bearer <AUTH_TOKEN>` on /transcribe to keep
  the localhost endpoint from being abused by other local processes.
- Honours HF_HOME / TRANSFORMERS_CACHE the way the HF libs do; cutti
  sets these to an app-local cache so uninstall can free the model.
- Single source of truth for behaviour: env vars passed by Swift.

Env (set by cutti when spawning):
    PORT                Bound port (0 = OS picks). Default 0.
    QWEN_AUTH_TOKEN     Required bearer token. If unset, server refuses to start.
    QWEN_INSTALL_DIR    Install dir. port.txt is written here. Required.
    HF_HOME             HuggingFace cache root. Defaults to ~/Library/Caches/cutti/qwen-asr/huggingface
                        (Swift sets this; sidecar inherits).
    QWEN_ASR_MODEL      Override ASR model id (default Qwen/Qwen3-ASR-1.7B)
    QWEN_ALIGNER_MODEL  Override aligner id ("" disables aligner; default Qwen/Qwen3-ForcedAligner-0.6B)
    QWEN_ASR_DEVICE     "mps" / "cpu" / "cuda:0" (default: mps)
    QWEN_ASR_DTYPE      "float16" / "bfloat16" / "float32" (default: float16)
    MAX_NEW_TOKENS      Per-chunk generation cap (default 1024)
"""
from __future__ import annotations

import json
import os
import secrets
import signal
import socket
import subprocess
import sys
import threading
import time
from contextlib import asynccontextmanager
from dataclasses import asdict, is_dataclass
from pathlib import Path
from typing import Any, Optional

import torch
import uvicorn
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
from qwen_asr import Qwen3ASRModel


ASR_MODEL = os.environ.get("QWEN_ASR_MODEL", "Qwen/Qwen3-ASR-1.7B")
ALIGNER_MODEL = os.environ.get("QWEN_ALIGNER_MODEL", "Qwen/Qwen3-ForcedAligner-0.6B")
DEVICE = os.environ.get("QWEN_ASR_DEVICE") or ("mps" if torch.backends.mps.is_available() else "cpu")
DTYPE_STR = os.environ.get("QWEN_ASR_DTYPE", "float16" if DEVICE == "mps" else "float32")
MAX_NEW_TOKENS = int(os.environ.get("MAX_NEW_TOKENS", "1024"))

AUTH_TOKEN = os.environ.get("QWEN_AUTH_TOKEN", "").strip()
INSTALL_DIR = Path(os.environ.get("QWEN_INSTALL_DIR", "")).expanduser()

ALIGNER_LANGUAGES = {
    "Chinese", "English", "Cantonese", "French", "German", "Italian",
    "Japanese", "Korean", "Portuguese", "Russian", "Spanish",
}

_DTYPE_MAP = {"float16": torch.float16, "bfloat16": torch.bfloat16, "float32": torch.float32}
_state: dict = {}


def _load() -> dict:
    if _state:
        return _state

    dtype = _DTYPE_MAP.get(DTYPE_STR)
    if dtype is None:
        raise RuntimeError(f"unknown QWEN_ASR_DTYPE={DTYPE_STR!r}; expected float16/bfloat16/float32")

    aligner_kwargs = None
    aligner_id = ALIGNER_MODEL.strip() or None
    if aligner_id:
        aligner_kwargs = dict(dtype=dtype, device_map=DEVICE)

    print(f"⏳ Loading {ASR_MODEL} on {DEVICE} ({DTYPE_STR})"
          + (f" + {aligner_id}" if aligner_id else " (no aligner)") + " ...", flush=True)
    t0 = time.time()
    model = Qwen3ASRModel.from_pretrained(
        ASR_MODEL,
        dtype=dtype,
        device_map=DEVICE,
        max_inference_batch_size=1,
        max_new_tokens=MAX_NEW_TOKENS,
        forced_aligner=aligner_id,
        forced_aligner_kwargs=aligner_kwargs,
    )
    elapsed = time.time() - t0
    _state.update(model=model, has_aligner=bool(aligner_id))
    print(f"✅ Loaded in {elapsed:.1f}s", flush=True)
    return _state


@asynccontextmanager
async def lifespan(app: FastAPI):
    _load()
    _install_progress_hooks()
    yield


app = FastAPI(title="qwen-asr-sidecar", lifespan=lifespan)


# Tracks the most recent /transcribe call's stage so a parallel
# /progress poller (Swift parent) can read it without depending on
# stderr scraping. Keyed by request id (we only run one at a time
# given max_inference_batch_size=1, but a key keeps state cleanable).
_progress_state: dict = {
    "stage": "idle",
    "chunk_index": 0,
    "chunk_total": 0,
    "started_at": 0.0,
}


def _set_stage(stage: str, *, chunk_index: int = 0, chunk_total: int = 0) -> None:
    """Update the shared progress snapshot AND mirror it to stderr so
    the parent process sees it in real time (parent pipes our stderr
    into its own log)."""
    _progress_state["stage"] = stage
    _progress_state["chunk_index"] = chunk_index
    _progress_state["chunk_total"] = chunk_total
    suffix = f" ({chunk_index}/{chunk_total})" if chunk_total > 0 else ""
    print(f"🎤 [asr.stage] {stage}{suffix}", file=sys.stderr, flush=True)


def _install_progress_hooks() -> None:
    """Monkey-patch the model's chunk-level inference + aligner so we
    can emit per-chunk progress. The library exposes a single
    `transcribe` entry point that processes 30s chunks one at a time
    (because we set `max_inference_batch_size=1`) but has no built-in
    callback — without this hook, a 24-minute audio clip = 1 silent
    10-minute call from the parent's perspective."""
    state = _state
    model = state.get("model")
    if model is None:
        return

    # ASR chunk inference: each call processes one 30s chunk on
    # transformers backend because batch_size=1.
    if hasattr(model, "_infer_asr_transformers"):
        original_infer = model._infer_asr_transformers
        def logging_infer(contexts, wavs, languages):  # type: ignore[no-redef]
            n = len(wavs)
            _set_stage("asr.inference", chunk_index=0, chunk_total=n)
            outs: list = []
            for i in range(n):
                t0 = time.time()
                out = original_infer([contexts[i]], [wavs[i]], [languages[i]])
                elapsed = time.time() - t0
                _set_stage("asr.inference", chunk_index=i + 1, chunk_total=n)
                print(
                    f"🎤 [asr.chunk] {i + 1}/{n} done in {elapsed:.1f}s",
                    file=sys.stderr, flush=True,
                )
                outs.extend(out)
            return outs
        model._infer_asr_transformers = logging_infer

    # Forced aligner: same idea, one call per chunk under
    # max_inference_batch_size=1.
    aligner = getattr(model, "forced_aligner", None)
    if aligner is not None and hasattr(aligner, "align"):
        original_align = aligner.align
        def logging_align(audio, text, language):  # type: ignore[no-redef]
            n = len(audio)
            _set_stage("align.inference", chunk_index=0, chunk_total=n)
            results: list = []
            for i in range(n):
                t0 = time.time()
                r = original_align(
                    audio=[audio[i]], text=[text[i]], language=[language[i]],
                )
                elapsed = time.time() - t0
                _set_stage("align.inference", chunk_index=i + 1, chunk_total=n)
                print(
                    f"🎤 [align.chunk] {i + 1}/{n} done in {elapsed:.1f}s",
                    file=sys.stderr, flush=True,
                )
                results.extend(r)
            return results
        aligner.align = logging_align


class TranscribeReq(BaseModel):
    path: str
    language: Optional[str] = None
    return_time_stamps: Optional[bool] = True
    context: Optional[str] = ""


def _check_auth(authorization: Optional[str]) -> None:
    if not AUTH_TOKEN:
        # Server refused to start without a token; this is unreachable.
        raise HTTPException(status_code=500, detail="server misconfigured")
    expected = f"Bearer {AUTH_TOKEN}"
    if not authorization or not secrets.compare_digest(authorization, expected):
        raise HTTPException(status_code=401, detail="unauthorized")


def _probe_duration(path: str) -> Optional[float]:
    try:
        out = subprocess.check_output(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "json", str(Path(path).expanduser())]
        )
        return float(json.loads(out)["format"]["duration"])
    except (subprocess.CalledProcessError, ValueError, KeyError, FileNotFoundError):
        return None


def _serialize_timestamps(time_stamps: Any) -> list[dict]:
    if time_stamps is None:
        return []
    items = getattr(time_stamps, "items", None) or time_stamps
    out: list[dict] = []
    for it in items:
        if is_dataclass(it):
            d = asdict(it)
        elif isinstance(it, dict):
            d = it
        else:
            d = {"text": getattr(it, "text", ""),
                 "start_time": getattr(it, "start_time", None),
                 "end_time": getattr(it, "end_time", None)}
        out.append({
            "text": d.get("text", ""),
            "start_sec": round(float(d["start_time"]), 3) if d.get("start_time") is not None else None,
            "end_sec": round(float(d["end_time"]), 3) if d.get("end_time") is not None else None,
        })
    return out


@app.get("/")
def root():
    # No auth on /, used as health probe by Swift.
    return {
        "status": "ok",
        "asr_model": ASR_MODEL,
        "aligner_model": ALIGNER_MODEL or None,
        "device": DEVICE,
        "dtype": DTYPE_STR,
        "max_new_tokens": MAX_NEW_TOKENS,
        "supported_aligner_languages": sorted(ALIGNER_LANGUAGES),
        "version": _read_version(),
    }


@app.get("/progress")
def progress(authorization: Optional[str] = Header(default=None)):
    """Return the current /transcribe call's stage snapshot.

    Polled by the Swift parent while the long-running /transcribe
    call is in flight so the chat panel can show a live status
    ("ASR chunk 7/41 — 4m 12s elapsed") instead of a frozen spinner.
    Auth is required to keep the localhost endpoint from leaking
    stage info to other local processes.
    """
    _check_auth(authorization)
    started_at = _progress_state.get("started_at") or 0.0
    elapsed = max(0.0, time.time() - started_at) if started_at else 0.0
    return {
        "stage": _progress_state.get("stage", "idle"),
        "chunk_index": _progress_state.get("chunk_index", 0),
        "chunk_total": _progress_state.get("chunk_total", 0),
        "elapsed_sec": round(elapsed, 1),
    }


def _read_version() -> str:
    try:
        return (Path(__file__).parent / "VERSION").read_text().strip()
    except Exception:
        return "unknown"


@app.post("/transcribe")
def transcribe(req: TranscribeReq, authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)

    src = Path(req.path).expanduser()
    if not src.exists():
        raise HTTPException(status_code=404, detail=f"file not found: {src}")

    state = _load()
    model = state["model"]
    has_aligner = state["has_aligner"]

    want_ts = bool(req.return_time_stamps) and has_aligner
    if want_ts and req.language and req.language not in ALIGNER_LANGUAGES:
        want_ts = False

    duration = _probe_duration(str(src))

    _progress_state["started_at"] = time.time()
    _set_stage("load_audio")
    print(
        f"🎤 [transcribe.req] path={src.name} duration={duration:.1f}s want_ts={want_ts}"
        if duration else
        f"🎤 [transcribe.req] path={src.name} duration=? want_ts={want_ts}",
        file=sys.stderr, flush=True,
    )

    t0 = time.time()
    try:
        # The two heavy stages (`asr.inference` and `align.inference`)
        # are reported per-chunk by the monkey-patched callbacks
        # installed in `_install_progress_hooks`. We only need to
        # mark the wrapping book-end stages here.
        results = model.transcribe(
            audio=str(src),
            language=req.language,
            context=req.context or "",
            return_time_stamps=want_ts,
        )
        _set_stage("serializing")
    except Exception as e:
        _set_stage("failed")
        raise HTTPException(status_code=500, detail=f"transcription failed: {type(e).__name__}: {e}")
    elapsed = time.time() - t0
    print(f"🎤 [transcribe.done] {elapsed:.1f}s", file=sys.stderr, flush=True)

    if not results:
        _set_stage("failed")
        raise HTTPException(status_code=500, detail="empty transcription result")
    r = results[0]

    items = _serialize_timestamps(r.time_stamps) if want_ts else []
    _set_stage("idle")

    return {
        "text": r.text,
        "language": r.language,
        "items": items,
        "elapsed_sec": round(elapsed, 2),
        "audio_duration_sec": round(duration, 2) if duration else None,
        "real_time_factor": round(elapsed / duration, 3) if duration and duration > 0 else None,
        "asr_model": ASR_MODEL,
        "aligner_model": ALIGNER_MODEL if want_ts else None,
        "device": DEVICE,
        "dtype": DTYPE_STR,
    }


def _install_signal_logger() -> None:
    """Print a noisy log line on every catchable termination signal.

    Why: when the sidecar shuts down "for no reason" the standard
    uvicorn ``INFO: Shutting down`` line tells us a clean shutdown
    happened but not WHO triggered it. By logging the actual signal
    number we can tell whether it was the Swift parent calling
    ``proc.terminate()`` (SIGTERM), an interactive Ctrl+C (SIGINT),
    a sleep/hangup transition (SIGHUP), etc.

    The trick: uvicorn installs its OWN SIGTERM/SIGINT handlers
    inside ``server.run``. If we just call ``signal.signal`` from
    here, our handler gets clobbered by uvicorn. So we monkey-patch
    ``signal.signal`` itself: every subsequent install wraps the
    target handler in a logger. That way uvicorn's graceful-shutdown
    handler still runs, and we just get a print line before it.
    """
    _real_signal_signal = signal.signal
    _watched = {signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT}

    def _wrap(target):  # type: ignore[no-untyped-def]
        def _log_and_call(signum: int, frame) -> None:  # type: ignore[no-untyped-def]
            try:
                name = signal.Signals(signum).name
            except ValueError:
                name = f"sig{signum}"
            ppid = -1
            try:
                ppid = os.getppid()
            except OSError:
                pass
            print(
                f"🎤 [sidecar.signal] received {name} ({signum}); ppid={ppid}",
                file=sys.stderr,
                flush=True,
            )
            if callable(target):
                target(signum, frame)
            elif target == signal.SIG_DFL:
                _real_signal_signal(signum, signal.SIG_DFL)
                os.kill(os.getpid(), signum)
            # SIG_IGN → swallow.

        return _log_and_call

    def _patched_signal(signum, handler):  # type: ignore[no-untyped-def]
        if signum in _watched and (callable(handler) or handler == signal.SIG_DFL):
            return _real_signal_signal(signum, _wrap(handler))
        return _real_signal_signal(signum, handler)

    signal.signal = _patched_signal  # type: ignore[assignment]

    # Install initial wrappers so a signal received before uvicorn
    # gets to ``run`` is also logged.
    for s in _watched:
        try:
            prev = signal.getsignal(s)
            _patched_signal(s, prev if callable(prev) else signal.SIG_DFL)
        except (OSError, ValueError):
            pass


def _bind_free_port() -> tuple[socket.socket, int]:
    """Bind to PORT (or OS-assigned 0) and return (socket, port).

    The socket is handed to uvicorn via fd inheritance so there's no
    TOCTOU window between bind and accept.
    """
    port = int(os.environ.get("PORT", "0"))
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(128)
    return s, s.getsockname()[1]


def _start_parent_death_watchdog() -> None:
    """Exit if the parent process (cutti) goes away.

    Cutti spawns us as a child and signals SIGTERM on a graceful
    quit. A crash, force-quit, or `kill -9` on cutti.app, however,
    leaves us orphaned and reparented to launchd / pid 1. Without
    this watchdog the sidecar can keep ~5GB of model weights pinned
    in RAM across cutti restarts.

    macOS doesn't have Linux's PR_SET_PDEATHSIG, so we poll
    os.getppid(): a non-original parent means the original parent
    exited. The 2s cadence is plenty given that the sidecar is
    intended to be ephemeral on quit.
    """
    initial_ppid = os.getppid()
    if initial_ppid == 1:
        # We were started orphaned (e.g. detached test harness); no
        # parent to watch. Skip rather than spin forever.
        return

    def _watch() -> None:
        while True:
            try:
                current = os.getppid()
            except OSError:
                current = 1
            if current != initial_ppid or current == 1:
                # Parent gone — flush stderr and hard-exit. We don't
                # try a graceful shutdown because the parent is
                # already dead and there's no client to drain.
                print(
                    f"⚠️  parent pid {initial_ppid} exited (now {current}); shutting down.",
                    file=sys.stderr,
                    flush=True,
                )
                os._exit(0)
            time.sleep(2.0)

    t = threading.Thread(target=_watch, name="parent-death-watchdog", daemon=True)
    t.start()


def main() -> int:
    if not AUTH_TOKEN:
        print("ERROR: QWEN_AUTH_TOKEN must be set; refusing to start.", file=sys.stderr, flush=True)
        return 64
    if not INSTALL_DIR or not INSTALL_DIR.exists():
        print(f"ERROR: QWEN_INSTALL_DIR must be set to a writable dir (got {INSTALL_DIR!r}).",
              file=sys.stderr, flush=True)
        return 65

    _install_signal_logger()
    _start_parent_death_watchdog()

    sock, port = _bind_free_port()
    port_file = INSTALL_DIR / "port.txt"
    port_file.write_text(str(port) + "\n")
    print(f"📌 Bound 127.0.0.1:{port}, wrote {port_file}", flush=True)

    config = uvicorn.Config(
        app,
        host="127.0.0.1",
        port=port,
        log_level="info",
        access_log=False,
    )
    server = uvicorn.Server(config)
    # Hand the already-bound socket to uvicorn.
    try:
        server.run(sockets=[sock])
    finally:
        try:
            port_file.unlink()
        except FileNotFoundError:
            pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
