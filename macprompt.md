# Промпт: собрать MyDictate-Lite (macOS, чистое распознавание, podlodka, без LLM)

Скопируй всё, что ниже разделителя, в Claude Code на Mac (Apple Silicon). Промпт
самодостаточный: по нему приложение собирается с нуля. Это УРЕЗАННАЯ версия —
только локальная диктовка и распознавание на модели **bond005/whisper-podlodka-turbo**.
БЕЗ LLM, БЕЗ AI-чистки, БЕЗ перевода и языковой кнопки.

---

Ты — инженер, делаешь нативное macOS-приложение для голосового ввода «MyDictate»
(Apple Silicon, macOS 13+). Назначение: нажал глобальную клавишу → говоришь (виден
индикатор записи) → нажал ещё раз → речь распознаётся ЛОКАЛЬНО на GPU/Neural Engine
и вставляется в активное текстовое поле. ТОЛЬКО распознавание. НИКАКИХ LLM, сетевых
вызовов (кроме разовой загрузки токенайзера), перевода.

## Среда сборки (важно)
- Только **Command Line Tools**, без полного Xcode. Сборка через **Swift Package
  Manager** (`swift build`) + ручная упаковка в `.app`. `xcodebuild`/`coremlcompiler`
  недоступны — учитывай это (см. конвертацию модели).
- Стек: **AppKit + SwiftUI**, исполняемый SPM-таргет, accessory-приложение
  (`LSUIElement`, без иконки в Dock, живёт в меню-баре).
- Зависимость одна: **WhisperKit** (`argmaxinc/WhisperKit`, from 1.0.0) — Core ML,
  GPU + Apple Neural Engine. Тянет транзитивно только swift-argument-parser.

## Функционал (ядро)
1. **Триггер** — глобальная клавиша **правый ⌥ (Option)**: 1-е нажатие старт, 2-е
   стоп. Это «голый» модификатор, поэтому лови его НЕ хоткеем, а глобальным
   монитором `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` (+ local),
   различая правый Option по `event.keyCode == kVK_RightOption (61)` и наличию
   флага `.option`. Требует разрешения «Универсальный доступ».
2. **Иконка в меню-баре** (`NSStatusItem`, SF Symbol `mic`/`mic.fill`) с меню:
   Начать/Остановить запись, История…, Транскрибировать файл…, Настройки…, Выход.
   Иконка красная во время записи, оранжевая на паузе. Дай текстовый фолбэк «🎙»,
   если символ не отрисуется.
3. **Индикатор записи** — плавающее окошко (HUD) внизу экрана: `NSPanel`
   `[.borderless, .nonactivatingPanel]`, уровень `.statusBar`, прозрачный фон,
   `ignoresMouseEvents=false`, `becomesKeyOnlyIfNeeded=true` (кликабельно, но НЕ
   забирает фокус у активного поля). Контент — SwiftUI через `NSHostingView`:
   пульсирующая точка, эквалайзер уровня звука, кнопки **Пауза/Продолжить** и
   **Отмена (✕)**. (Языковой кнопки НЕТ — перевода нет.)
4. **Захват аудио** — `AVAudioEngine.inputNode` tap → `AVAudioConverter` в **16 кГц
   mono Float32** (формат Whisper), накопление сэмплов под `NSLock`, RMS-уровень в
   индикатор; пауза отбрасывает сэмплы, не разрывая поток.
5. **Распознавание** — WhisperKit, модель **podlodka-turbo** (локальная, см. ниже),
   `transcribe(audioArray:[Float])` и `transcribe(audioPath:)`. `DecodingOptions(
   task:.transcribe, language: <код>|nil, detectLanguage: lang=="auto",
   skipSpecialTokens:true, withoutTimestamps:true, chunkingStrategy:.vad)`.
   ВАЖНО: podlodka сама ставит русскую пунктуацию и заглавные — постобработка не
   нужна.
6. **Автовставка** — сохранить текущий буфер обмена → положить распознанный текст →
   эмулировать ⌘V через `CGEvent` (`kVK_ANSI_V`, `.maskCommand`,
   `.cgAnnotatedSessionEventTap`) → через ~0.4с восстановить прежний буфер. В конец
   текста добавлять один пробел, если его нет. Требует «Универсального доступа».
7. **Словарь замен терминов** (детерминированный, БЕЗ LLM) — правила «что => на_что»
   по строке. **Морфологическая** замена: матчит корень + русское падежное окончание
   (правило `Клод => Claude` ловит Клод/Клода/Клоду/Клодом/Клоде), регистронезависимо,
   по границам слова через unicode-классы `(?<![\p{L}\p{N}])<corpus>[а-яёА-ЯЁ]{0,3}
   (?![\p{L}\p{N}])`. Применяется к тексту распознавания перед вставкой. Длинные
   правила — первыми. Редактируется в Настройках.
8. **История** последних 10 распознаваний (персист в UserDefaults JSON): итоговый
   текст (после словаря) + оригинал Whisper (до словаря) для сравнения, время,
   источник (диктовка/файл). Кнопки «Скопировать»/«Вставить». Если автовставка
   невозможна (нет прав) — окно истории открывается само.
9. **Сохранение записи + «Распознать заново»** — каждую диктовку писать в WAV
   (16-бит PCM моно 16 кГц) в `~/Library/Application Support/MyDictate/recordings/`,
   путь в истории; в окне истории — кнопка «Распознать заново» (перегнать ту же
   запись). Аудио чистить при вытеснении из истории (>10); оригиналы выбранных
   пользователем файлов не удалять.
10. **Транскрибация файла** — `NSOpenPanel` (m4a/wav/mp3/aiff…), результат в окне
    истории.

ЯВНО НЕ ДЕЛАЕМ: LM Studio / любую LLM, AI-чистку текста, перевод, языковую кнопку
в индикаторе, «частые слова/имена», любые сетевые вызовы кроме загрузки токенайзера
WhisperKit.

## Модель распознавания: bond005/whisper-podlodka-turbo (Core ML)
Это файнтюн **Whisper large-v3-turbo** на русский с родной пунктуацией (Apache 2.0,
ранг 2 на бенчмарке русского ASR, лучший CER, turbo-скорость). Это НЕ официальная
модель WhisperKit, поэтому её надо конвертировать в Core ML самому (Python 3.11 +
uv, **без полного Xcode**). Сделай скрипт `scripts/convert-podlodka.sh`:

1. `uv venv --python 3.11 .venv` ; `uv pip install "whisperkit @ git+https://github.com/argmaxinc/whisperkittools.git"`
2. **Три патча в установленном пакете** (иначе не соберётся без Xcode / не сохранит модель):
   - `argmaxtools/test_utils.py` `_compile_coreml_model`: заменить
     `os.system("xcrun coremlcompiler compile …")` + `shutil.move` на
     `compiled = ct.models.utils.compile_model(mlpackage_path)` → `shutil.move(compiled, target_path)`
     (компиляция через системный CoreML, без Xcode).
   - `argmaxtools/test_utils.py` `_print_compute_plan`: добавить `return` в начало
     (тяжёлый/хрупкий, чисто информационный).
   - `tests/test_text_decoder.py`: `TEST_PSNR_THR = 35` → `25` (у файнтюна PSNR
     декодера ~31, что нормально для ASR; иначе декодер не сохраняется).
3. Конвертация: `whisperkit-generate-model --model-version bond005/whisper-podlodka-turbo
   --output-dir out` (БЕЗ `--disable-default-tests` — сохранение моделей происходит
   ВНУТРИ correctness-теста; БЕЗ `--generate-decoder-context-prefill-data` — он даёт
   падающий prefill-тест, а prefill-данные опциональны для WhisperKit). Скачает ~3 ГБ,
   идёт ~10–15 мин.
4. Скопировать из `out/bond005_whisper-podlodka-turbo/` три файла **MelSpectrogram.mlmodelc,
   AudioEncoder.mlmodelc, TextDecoder.mlmodelc** в
   `~/Library/Application Support/MyDictate/coreml-models/whisper-podlodka-turbo/`.

Загрузка в приложении: `WhisperKitConfig(modelFolder: <папка>, download: false)`.
`config.json` НЕ нужен — WhisperKit определяет вариант по размерностям модели и тянет
токенайзер large-v3 онлайн. `TextDecoderContextPrefill.mlmodelc` не обязателен.
WhisperKit при загрузке из modelFolder требует только эти три `.mlmodelc`. Первая
загрузка специализирует 1.5 ГБ под ANE (~5 мин, кэшируется системой навсегда), далее
тёплый прогон ~1.4с.

Архитектура моделей в коде: держи узкий интерфейс, чтобы локальные модели находились
сами: `AppPaths.localModelFolder(name) -> String?` (есть ли AudioEncoder.mlmodelc) и
`availableLocalModels()`; Transcriber.ensure(): если есть локальная папка — грузить
через `modelFolder`, иначе `WhisperKitConfig(model: name)` (на случай других моделей).

## Права и стабильная подпись (КРИТИЧНО)
- **Микрофон:** `NSMicrophoneUsageDescription` в Info.plist; `AVCaptureDevice.requestAccess`.
- **Универсальный доступ (Accessibility):** нужен и для триггера (монитор клавиш), и
  для вставки (CGEvent). `AXIsProcessTrusted()` / `AXIsProcessTrustedWithOptions([
  kAXTrustedCheckOptionPrompt: true])`. Подхватывается только при следующем запуске —
  после выдачи нужен перезапуск приложения.
- **Стабильная самоподписанная подпись (обязательно!):** при ad-hoc подписи каждая
  пересборка меняет cdhash → macOS считает приложение новым → «Универсальный доступ»
  слетает. Сделай `scripts/create-cert.sh`: самоподписанный сертификат с EKU=codeSigning
  в login-keychain. Нюанс OpenSSL 3: PKCS12 экспортировать в **legacy**-формате
  (`-legacy -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES`), иначе Keychain
  не импортирует. `build-app.sh` подписывает этим сертификатом (вложенные бандлы по
  отдельности, без `--deep`), designated requirement тогда = `identifier "<bundle-id>"
  and certificate leaf = H"…"` — стабилен между пересборками. При смене подписи один раз:
  `tccutil reset Accessibility <bundle-id>` (+ `Microphone`) и заново выдать доступ.

## Сборка и упаковка
- `scripts/build-app.sh`: `swift build -c release` → копирует бинарь и `Info.plist` в
  `MyDictate.app/Contents/…` → подписывает сертификатом «MyDictate Self-Signed» (или
  ad-hoc, если его нет, с предупреждением) → `codesign --verify --strict`.
- Info.plist: `LSUIElement=true`, `CFBundleIdentifier=com.mydictate.app`,
  `NSMicrophoneUsageDescription`, `LSMinimumSystemVersion=13.0`. (ATS НЕ нужен —
  сетевых вызовов к localhost нет.)
- Ресурс-бандлов нет: WhisperKit-модель берётся из локальной папки в рантайме.
- Скрытый режим самодиагностики: `./MyDictate.app/Contents/MacOS/MyDictate --selftest
  <audiofile>` — распознаёт файл и печатает результат (для проверки без микрофона).
  Тестовое аудио: `say -v Milena -o /tmp/t.aiff "текст"` (английским голосом русский
  текст НЕ тестировать — даёт транслитерацию).

## Настройки (окно SwiftUI, персист в UserDefaults, домен com.mydictate.app)
- Язык распознавания: `auto`/`ru`/`en`/… (по умолчанию `ru` или `auto`).
- Модель: выпадающий список — локальные модели (`availableLocalModels`) первыми
  (podlodka-turbo), плюс опц. стандартные WhisperKit (base/small/large-v3) с
  авто-загрузкой. По умолчанию — podlodka-turbo.
- Словарь терминов (многострочный, формат `что => на_что`).

Ключи UserDefaults: `language`, `whisperKitModel`, `glossary`, `transcripts` (история),
`didShowWelcome`.

## Состав модулей (раздели чётко)
main.swift (NSApplication accessory + --selftest), AppDelegate.swift (меню-бар,
автомат idle→recording→transcribing→idle, окна, права), Shortcuts.swift (TriggerMonitor
правый ⌥), AudioRecorder.swift (16к mono f32, уровень, пауза), Transcriber.swift
(WhisperKit, локальный modelFolder), TextInjector.swift (буфер + ⌘V + пробел),
RecordingIndicator.swift (HUD, пауза/отмена), Glossary.swift (морфологическая замена),
TranscriptStore.swift (история 10, итог+оригинал+аудио, чистка WAV), HistoryView.swift,
SettingsView.swift, Paths.swift (папки support/coreml-models/recordings),
AudioFile.swift (запись WAV).

Пайплайн: правый ⌥ → запись (WAV) → стоп → WhisperKit(podlodka) → Glossary.apply →
история → вставка(+пробел).

## Критерии готовности
1. Правый ⌥ из любого приложения стартует/останавливает запись; виден индикатор с
   уровнем, паузой и отменой.
2. Русская речь распознаётся локально (podlodka, GPU/ANE) с пунктуацией и
   вставляется в активное поле с пробелом в конце. Тёплый прогон ~1–2с.
3. Словарь терминов нормализует падежи (Клоду → Claude); история (10) переживает
   перезапуск; «Распознать заново» работает; транскрибация файла работает.
4. Нет НИ ОДНОГО обращения к LLM/сети, кроме разовой загрузки токенайзера WhisperKit.
5. `create-cert.sh` → `convert-podlodka.sh` → `build-app.sh release` → `open
   MyDictate.app`; на чистой машine после выдачи прав и перезапуска всё работает,
   права не слетают при пересборках.

## Документация (обязательно)
Создай `spec.md` (все возможности, архитектура, ключи, конвертация модели с патчами,
сборка, грабли) и `CLAUDE.md` с правилом: при ЛЮБОМ изменении функционала
перечитывать `spec.md` и обновлять его, чтобы спека всегда соответствовала коду.

Начни с плана и конвертации модели (самый рискованный шаг), затем реализуй по
модулям. По ходу веди spec.md и CLAUDE.md.
