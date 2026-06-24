#!/usr/bin/env bash
# Создаёт самоподписанный сертификат для подписи кода и импортирует его в login-keychain.
# Нужен, чтобы цифровая подпись MyDictate не менялась при пересборках —
# тогда выданный «Универсальный доступ» (Accessibility) не слетает.
set -euo pipefail

CN="MyDictate Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Уже есть?
if security find-certificate -c "$CN" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Сертификат «$CN» уже существует — пропускаю создание."
  exit 0
fi

echo "==> Генерирую самоподписанный сертификат с EKU=codeSigning"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -subj "/CN=$CN" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

P12PASS="mydictate"
# Legacy-алгоритмы (SHA1/3DES) — иначе Keychain на macOS не читает PKCS12 от OpenSSL 3.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout "pass:$P12PASS" -name "$CN" \
  -legacy -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES

echo "==> Импортирую в login-keychain (разрешаю использовать codesign)"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12PASS" \
  -T /usr/bin/codesign -A

echo "==> Помечаю сертификат как доверенный для подписи кода"
# Может появиться окно с запросом пароля — это нормально, введите пароль от учётки.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null \
  || echo "  (не удалось задать доверие автоматически — это не критично для локальной подписи)"

echo
echo "Готово. Проверка:"
security find-identity -p codesigning "$KEYCHAIN" | grep "$CN" || true
echo
echo "Если при первой подписи появится окно «codesign хочет использовать ключ» —"
echo "нажмите «Всегда разрешать» (Always Allow)."
