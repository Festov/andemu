# TSD Process Emulator (portable)

Автономный пакет для Windows: Android Emulator + ваше ТСД-приложение без Android Studio и без эмуляторов с рекламой (BlueStacks / LDPlayer / Nox).

## Требования

| Параметр | Минимум | Рекомендуется |
|----------|---------|---------------|
| ОС | Windows 10/11 x64 | Windows 11 x64 |
| RAM | 8 GB | 16 GB |
| Диск | 5–8 GB свободно | SSD |
| CPU | с виртуализацией | i5 / Ryzen 5+ |
| BIOS | VT-x / AMD-V включены | + Windows Hypervisor Platform (WHPX) |
| Java | не нужна заранее | при первом запуске сама скачается JDK 17 (Temurin) в `runtime\jdk`, если на ПК нет JDK 17+ |

**Виртуализация:** в Windows: *Параметры → Приложения → Дополнительные компоненты → Платформа гипервизора Windows* (или Hyper-V). Без этого эмулятор будет очень медленным или не запустится.

## Быстрый старт

1. Скопируйте папку `andemu` на ПК.
2. Положите APK в `app\` (имя файла = `apkFileName` в `config.json`).
3. При необходимости отредактируйте `config.json` (экран, API, package).
4. Дважды кликните **`Start-TSD-Emulator.vbs`** (без окна консоли).  
   Файл `.bat` тоже можно — он сразу вызывает VBS и закрывается.
5. Первый запуск при необходимости скачает JDK 17 (~180 MB) и SDK (~3–6 GB), создаст AVD — нужен интернет.
6. Последующие запуски сразу откроют эмулятор и приложение.

## Настройка config.json

| Поле | Назначение |
|------|------------|
| `apkFileName` | Имя APK в папке `app\` |
| `apkPackage` | Package name (можно оставить `""` — определится автоматически) |
| `androidVersion` / `androidApi` / `systemImage` | Версия Android как на ТСД |
| `screenWidth` / `screenHeight` / `screenDpi` | Экран ТСД |
| `ramMb` | RAM виртуального устройства |
| `emulatorArgs` | Доп. аргументы emulator.exe |
| `hideEmulatorToolbarOnStart` | Скрывать боковую панель (rotate) |

### Пример под типичный ТСД 480×800

```json
"androidApi": "android-30",
"systemImage": "system-images;android-30;google_apis;x86_64",
"screenWidth": 480,
"screenHeight": 800,
"screenDpi": 240
```

### Как узнать package name APK

**Вариант A — оставить пустым:** скрипт попробует `aapt` / `pm list packages` после установки.

**Вариант B — вручную** (если установлен bundletool/aapt или Android SDK):

```bat
aapt dump badging app\your-app.apk | findstr package
```

**Вариант C — после установки на эмулятор:**

```bat
runtime\android-sdk\platform-tools\adb.exe shell pm list packages
```

## Эмуляция штрихкода

Железный сканер Zebra/Honeywell в эмуляторе **недоступен**. Варианты:

1. Клавиатура эмулятора → ввод кода → Enter  
2. Скрипт:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\scan-barcode.ps1 4601234567890
```

Без Enter:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\scan-barcode.ps1 -Code 4601234567890 -NoEnter
```

3. Вручную:

```bat
runtime\android-sdk\platform-tools\adb.exe shell input text 4601234567890
runtime\android-sdk\platform-tools\adb.exe shell input keyevent 66
```

4. Если приложение сканирует **камерой**: в окне эмулятора *Extended controls (…)* → *Camera*.

Если приложение завязано на **DataWedge / vendor SDK** — нужен mock или тестовый режим в самом приложении.

## Панель эмулятора (громкость / поворот)

Правая панель `emulator.exe` **скрыта постоянно**: кнопка rotate ломает размер окна.

Ориентация экрана при старте фиксируется в портрет (`accelerometer_rotation=0`).

Окно закрывается штатной кнопкой Windows в заголовке эмулятора.

## Логи

Все запуски пишут файлы в папку `logs\`:

| Файл | Содержание |
|------|------------|
| `setup-latest.log` / `setup-*.log` | Установка SDK |
| `start-latest.log` / `start-*.log` | Запуск эмулятора и APK |
| `toolbar-latest.log` | Хелпер скрытия боковой панели |
| `scan-latest.log` | Эмуляция штрихкода |

При ошибке скрипт печатает путь к логу в консоль (`[LOG] ...`).

## Сборка portable / installer

После успешного `setup` и наличия APK:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-installer.ps1
```

Результат в `dist\`:

- `andemu-portable.zip` — полный portable-архив  
- `install.bat` — распаковка ZIP в `%USERPROFILE%\andemu`  
- `TSD-Emulator-Setup.iss` — шаблон [Inno Setup](https://jrsoftware.org/isinfo.php) для одного `TSD-Emulator-Setup.exe`

> Установщик получится большим: в него входит уже скачанный Android SDK + system image.

## Структура

```
andemu/
├── Start-TSD-Emulator.vbs      # основной запуск (без консоли)
├── Start-TSD-Emulator.bat      # тонкая обёртка → VBS
├── config.json
├── README.md
├── app/                        # положите APK сюда
├── scripts/
│   ├── launch.vbs
│   ├── common.ps1
│   ├── setup.ps1
│   ├── start.ps1
│   ├── toggle-emulator-toolbar.ps1
│   ├── scan-barcode.ps1
│   └── build-installer.ps1
├── runtime/                    # создаётся setup (~3–6 GB, в git не входит)
├── avd/                        # AVD (в git не входит)
├── logs/                       # логи (в git не входит)
└── dist/                       # сборка portable (в git не входит)
```

## Типичные ошибки

| Симптом | Что проверить |
|---------|----------------|
| Эмулятор не стартует / чёрный экран | Виртуализация в BIOS; WHPX / Hyper-V; антивирус |
| Очень медленно | Включить аппаратную виртуализацию; больше RAM; SSD; убрать `-gpu swiftshader_indirect` только если есть рабочий GPU accel |
| `setup` не качает | Интернет, доступ к `dl.google.com`, корпоративный прокси/firewall |
| APK не ставится | Неверная архитектура (нужен x86_64 / universal APK); несовместимый `minSdk`; битый файл |
| Приложение не запускается | Неверный `apkPackage`; нет LAUNCHER activity |
| HAXM / WHPX ошибки | На Win10/11 предпочтителен WHPX, не Intel HAXM; не смешивать конфликтующие гипервизоры |
| Повторный setup | Идемпотентен: не ломает уже созданный AVD, только обновляет `config.ini` под экран/RAM |

## Ограничения

- После setup размер пакета **~3–6 GB** — это нормально.  
- Сканер штрихкодов ТСД (Zebra/Honeywell) в эмуляторе недоступен.  
- DataWedge / vendor SDK требуют mock или тестовый режим.  
- На слабых ПК может быть медленно; для продакшен-демо: i5/Ryzen 5, 16 GB RAM.

## Что заполнить под ваш ТСД

В `config.json`:

- Модель ТСД / Android API / `systemImage`
- `screenWidth` × `screenHeight`, `screenDpi`
- `apkFileName`, `apkPackage`
- Способ ввода: hardware scanner / camera / manual / vendor SDK

## Ручной запуск скриптов

```powershell
# Только установка SDK + AVD
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup.ps1

# Только запуск (после setup)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\start.ps1
```

## Лицензии

Скрипты проекта — для внутреннего использования. Android SDK / Emulator / system images распространяются на условиях Google (лицензии принимаются автоматически при `setup`).
