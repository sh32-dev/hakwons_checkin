# AGENTS.md

## Project
- Flutter Android app for academy check-in/out.
- Main UI lives in `lib/screens`.
- Attendance and auth logic live in `lib/services`.
- Android USB ACR122U reader code lives in `android/app/src/main/kotlin/com/hagwons/hagwons_checkin/MainActivity.kt`.

## Development
- Keep changes scoped to the requested behavior.
- Preserve the Firestore schema unless explicitly asked to migrate it.
- The ACR122U reader should remain USB CCID based; do not reintroduce the ACS SDK dependency without explicit approval.
- Attendance card IDs are NDEF Text values, normalized by removing whitespace, colons, and hyphens, then uppercasing.
- Do not use UID fallback for attendance IDs.

## Verification
- Run Flutter static analysis after Dart changes:
  ```sh
  flutter analyze
  ```
- Run tests after service or policy changes:
  ```sh
  flutter test
  ```
- Run Android debug build after Android resource or native changes:
  ```sh
  cd android && ./gradlew :app:assembleDebug
  ```

## Notes
- Google Play Services / ProviderInstaller warnings in Android logs are usually unrelated to ACR122U card reading.
- Launcher icons are stored under `android/app/src/main/res/mipmap-*`.
