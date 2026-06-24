#!/usr/bin/env bash
# Собирает MyDictate.app из SPM-сборки. Xcode не требуется — только Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${1:-release}"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/MyDictate.app"

echo "==> Собираю бандл $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/MyDictate" "$APP/Contents/MacOS/MyDictate"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Копируем resource-бандлы зависимостей (локализации KeyboardShortcuts и т.п.)
shopt -s nullglob
for b in "$BIN_DIR"/*.bundle; do
  cp -R "$b" "$APP/Contents/Resources/"
done
shopt -u nullglob

CERT_CN="MyDictate Self-Signed"
# Подписываем сначала вложенные бандлы (если появятся), затем сам .app — без --deep.
sign() {
  local id="$1"
  find "$APP/Contents" -name "*.bundle" -o -name "*.framework" 2>/dev/null | while read -r nested; do
    codesign --force --sign "$id" "$nested"
  done
  codesign --force --sign "$id" "$APP/Contents/MacOS/MyDictate"
  codesign --force --sign "$id" "$APP"
}

if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
  echo "==> Подпись стабильным сертификатом: $CERT_CN"
  echo "    (если появится окно «codesign хочет использовать ключ» — нажмите «Всегда разрешать»)"
  sign "$CERT_CN"
else
  echo "==> Стабильный сертификат не найден — ad-hoc подпись (права будут слетать!)"
  echo "    Для стабильной подписи запустите: ./scripts/create-cert.sh"
  sign -
fi

echo "==> Проверка подписи"
codesign -dvvv "$APP" 2>&1 | grep -iE "Authority|Identifier=" | head -3
codesign --verify --strict "$APP" 2>&1 && echo "подпись валидна" || echo "ВНИМАНИЕ: подпись не прошла проверку"

echo "Готово: $APP"
echo "Запуск: open \"$APP\"  (или перетащите в /Applications)"
