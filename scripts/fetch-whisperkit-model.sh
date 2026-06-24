#!/usr/bin/env bash
# Прямая загрузка Core ML-модели WhisperKit с Hugging Face (надёжнее встроенного
# загрузчика, который иногда виснет на xet-бэкенде).
# Использование: ./scripts/fetch-whisperkit-model.sh [variant]
set -euo pipefail

REPO="argmaxinc/whisperkit-coreml"
VAR="${1:-openai_whisper-large-v3-v20240930_turbo}"
DEST="$HOME/Documents/huggingface/models/$REPO"

echo "Скачиваю $VAR в $DEST"
FILES=$(curl -s --max-time 30 "https://huggingface.co/api/models/$REPO/tree/main/$VAR?recursive=true" \
  | /usr/bin/python3 -c "import sys,json;[print(x['path']) for x in json.load(sys.stdin) if x['type']=='file']")

for path in $FILES; do
  out="$DEST/$path"
  mkdir -p "$(dirname "$out")"
  # пропускаем, если уже есть и непустой (грубая проверка)
  if [[ -s "$out" ]]; then
    echo "  есть: $path"
    continue
  fi
  echo "  качаю: $path"
  curl -L --fail --retry 3 --retry-delay 2 -s \
    -o "$out.part" "https://huggingface.co/$REPO/resolve/main/$path"
  mv "$out.part" "$out"
done

echo "Готово: $(du -sh "$DEST/$VAR" | cut -f1)"
