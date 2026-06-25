# Нотаризация ZBS Eye (Developer ID, раздача вне App Store)

> **Почему не App Store.** App Store требует App Sandbox, а под ним невозможны cross-app Accessibility
> (чтение AX-дерева других приложений — главный путь извлечения текста), плюс профиль «вечная память,
> пишет всё» почти гарантированно реджектится по приватности. Все аналоги (Rewind до Apple, screenpipe)
> раздаются через **Developer ID + нотаризацию**. Это и сохраняет фичи, и убирает cdhash/«Open Anyway»/
> TCC-чехарду self-signed (нотаризованная подпись стабильна — права переживают ребилды).

## Что нужно один раз

### 1. Платная Apple Developer Program — $99/год
- https://developer.apple.com/programme/enroll/ → Enroll (как Individual). Оплата $99, активация обычно
  в течение суток.
- Твой текущий серт **«Apple Development»** для нотаризации **НЕ годится** — это тип для запуска на своих
  устройствах. Нужен именно **«Developer ID Application»** (появляется только в платной программе).

### 2. Серт «Developer ID Application»
Проще через Xcode:
- Xcode → **Settings → Accounts** → выбрать Apple ID → **Manage Certificates…** → **«+»** →
  **Developer ID Application**. Серт лёг в login-keychain.
- Проверка: `security find-identity -v -p codesigning | grep "Developer ID Application"` — должна быть строка.

(Альтернатива: developer.apple.com → Certificates → «+» → Developer ID Application → загрузить CSR из
Keychain Access → Certificate Assistant.)

### 3. App-specific password для notarytool
- https://appleid.apple.com → **Sign-In and Security → App-Specific Passwords** → **«+»** → назвать
  «zbseye-notary» → скопировать пароль вида `abcd-efgh-ijkl-mnop`.

### 4. Сохранить креды notarytool в keychain (один раз)
```bash
xcrun notarytool store-credentials zbseye-notary \
  --apple-id ТВОЙ_APPLE_ID_EMAIL \
  --team-id ТВОЙ_TEAM_ID \
  --password ABCD-EFGH-IJKL-MNOP        # тот самый app-specific
```
`TEAM_ID` — 10-символьный код из developer.apple.com → Membership (или из имени серта в скобках:
`Developer ID Application: Имя (ABCDE12345)`).

## Сборка + нотаризация (каждый релиз)

```bash
bash scripts/build-notarized.sh
```
Скрипт сам: соберёт Release с **Hardened Runtime**, подпишет **Developer ID** + secure timestamp,
упакует e5-модель, отправит в Apple (`notarytool --wait`, ~2–10 мин), сделает `stapler staple` и проверит
`spctl` (должно быть `accepted, source=Notarized Developer ID`). На выходе — `dist/ZBSEye-notarized-*.zip`.

## Установка у получателя
Распаковать в `/Applications`, запустить **двойным кликом** — Gatekeeper пропускает без «Open Anyway»
(даже оффлайн, благодаря stapled-тикету). Права Screen Recording / Accessibility / Microphone выдаются
один раз; подпись стабильна, ребилды их не сбрасывают.

## Если notarytool отклонил
`xcrun notarytool log <submission-id> --keychain-profile zbseye-notary` — покажет, что не подписано
(чаще: вложенный код без Hardened Runtime/timestamp, или лишний entitlement `get-task-allow` из Debug).
Скрипт собирает Release (без `get-task-allow`) и ставит `--options runtime --timestamp` на сборку, так что
обычно проходит с первого раза.

## Текущее состояние (до программы)
- Серт сейчас: только self-signed «Slishu Dev» + «Apple Development». Нотаризация заблокирована до п.1–2.
- Пока программы нет — `scripts/build-release.sh` (self-signed, установка через «Open Anyway»). Минусы
  self-signed (cdhash/TCC-чехарда при каждом ребилде) — ровно то, что нотаризация убирает.
