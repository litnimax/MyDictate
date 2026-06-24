#!/usr/bin/env bash
# Скачивает ggml-модель whisper в ~/Library/Application Support/MyDictate/models
# Использование: ./scripts/download-model.sh [tiny|base|small|medium|large-v3]
set -euo pipefail

MODEL="${1:-base}"
DEST="$HOME/Library/Application Support/MyDictate/models"
FILE="ggml-${MODEL}.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${FILE}"

mkdir -p "$DEST"

if [[ -f "$DEST/$FILE" ]]; then
  echo "Модель уже на месте: $DEST/$FILE"
  exit 0
fi

echo "Скачиваю $FILE …"
echo "  из: $URL"
echo "  в:  $DEST/$FILE"
curl -L --fail --progress-bar -o "$DEST/$FILE.part" "$URL"
mv "$DEST/$FILE.part" "$DEST/$FILE"
echo "Готово. Размер: $(du -h "$DEST/$FILE" | cut -f1)"

# Сохраняем выбор модели в настройках приложения
defaults write com.mydictate.app modelFileName "$FILE" 2>/dev/null || true
echo "Для русского рекомендуется small или medium (точнее, но медленнее)."
