#!/usr/bin/env bash
# Устанавливает движок GigaAM-v3 RNNT (MLX, Python) для MyDictate:
# venv + пакет gigaam-mlx + воркер в ~/Library/Application Support/MyDictate/gigaam-mlx,
# затем предзагружает модель aystream/GigaAM-v3-e2e-rnnt-mlx (~0.9 ГБ, кэш HF).
# Требует uv (brew install uv). ffmpeg НЕ нужен — аудио готовит само приложение.
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="$HOME/Library/Application Support/MyDictate/gigaam-mlx"
VENV_PY="$DEST/venv/bin/python3"

command -v uv >/dev/null || { echo "ОШИБКА: нужен uv (brew install uv)"; exit 1; }
mkdir -p "$DEST"

echo "==> venv (python 3.12) + gigaam-mlx"
[ -x "$VENV_PY" ] || uv venv --python 3.12 "$DEST/venv"
# numba>=0.60 — иначе резолвер откатывается на numba 0.53/llvmlite 0.36,
# которые не собираются под Python 3.12.
"$VENV_PY" -c "import gigaam_mlx" 2>/dev/null || \
  uv pip install --python "$VENV_PY" "numba>=0.60" \
    "gigaam-mlx @ git+https://github.com/aystream/gigaam-mlx.git"

echo "==> воркер"
cp scripts/gigaam-worker.py "$DEST/worker.py"

echo "==> предзагрузка модели RNNT (~0.9 ГБ при первом запуске)"
HF_HUB_DISABLE_XET=1 HF_HUB_DISABLE_TELEMETRY=1 "$VENV_PY" - <<'PY'
from gigaam_mlx import load_model
load_model("rnnt")
print("модель загружена и готова")
PY

echo "Готово. Выберите «GigaAM-v3 rnnt» в Настройках MyDictate."
