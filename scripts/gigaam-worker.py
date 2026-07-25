#!/usr/bin/env python3
"""Постоянный воркер GigaAM-v3 (RNN-T, MLX) для MyDictate.

Протокол (JSON-строки): на stdin {"path": "/путь/к/файлу.wav"} — WAV 16 кГц
моно 16-бит; в ответ на stdout {"text": "..."} либо {"error": "..."}.
После загрузки модели воркер печатает {"ready": true}.

WAV читается напрямую (модуль wave) — ffmpeg, в отличие от CLI gigaam-mlx,
не требуется. Длинные записи режутся по тишине (split_audio из пакета).
"""

import json
import os
import sys
import wave

os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")  # xet-бэкенд HF иногда виснет

import numpy as np
import mlx.core as mx
from gigaam_mlx import load_model
from gigaam_mlx.audio import compute_mel, split_audio

SAMPLE_RATE = 16000
MIN_CHUNK_SAMPLES = SAMPLE_RATE // 5  # короче 0.2с не распознаём


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def read_wav(path):
    with wave.open(path, "rb") as w:
        if w.getframerate() != SAMPLE_RATE or w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise ValueError(
                f"ожидается WAV 16кГц моно 16-бит, получено "
                f"{w.getframerate()}Гц/{w.getnchannels()}ch/{w.getsampwidth()*8}бит"
            )
        data = w.readframes(w.getnframes())
    return np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0


def transcribe(model, tokenizer, audio):
    texts = []
    for chunk in split_audio(audio):
        seg = audio[chunk["start_sample"]:chunk["end_sample"]]
        if len(seg) < MIN_CHUNK_SAMPLES:
            continue
        mel = mx.array(compute_mel(seg)[np.newaxis])
        encoded, seq_len = model.encode(mel)
        mx.eval(encoded)
        text = tokenizer.decode(model.decode(encoded, seq_len)).strip()
        if text:
            texts.append(text)
    return " ".join(texts)


def resolve_model_dir():
    """Путь к модели в кэше HF без похода в сеть (анонимные запросы к HF
    рейт-лимитятся и могут висеть минутами). Нет кэша — вернём None, и
    load_model скачает модель онлайн."""
    try:
        from huggingface_hub import snapshot_download
        return snapshot_download("aystream/GigaAM-v3-e2e-rnnt-mlx", local_files_only=True)
    except Exception:
        return None


def main():
    model, tokenizer = load_model("rnnt", repo_id=resolve_model_dir())
    emit({"ready": True})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            emit({"text": transcribe(model, tokenizer, read_wav(req["path"]))})
        except Exception as e:  # noqa: BLE001 — любой сбой отдаём приложению
            emit({"error": str(e)})
        finally:
            # MLX держит освобождённые Metal-буферы в кэше вплоть до системного
            # memory limit. Для CLI это нормально (процесс сразу завершается),
            # но постоянный воркер иначе накапливает десятки ГБ между запросами.
            # Веса модели активны и clear_cache() их не выгружает.
            mx.clear_cache()


if __name__ == "__main__":
    main()
