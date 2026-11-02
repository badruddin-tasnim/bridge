## Summary

Briefly describe what this Pull Request changes and why.

Fixes #(issue number, if applicable)

## Scope of Changes

- [ ] **Android App** (`android-app/` — Kotlin / XML Views)
- [ ] **macOS Menu Bar App** (`mac-app/` — Swift / SwiftUI)
- [ ] **Wire Protocol** (`TCP :8765` newline-delimited JSON messages)
- [ ] **Documentation / CI**

## Test Plan

- [ ] Android APK builds cleanly (`cd android-app && ./gradlew assembleDebug`)
- [ ] macOS App builds cleanly (`cd mac-app && make clean && make`)
- [ ] Tested on physical Android device & Mac over local Wi-Fi

## Security & Privacy Checklist

- [ ] No external/cloud network calls or analytics SDKs added
- [ ] No plaintext user clipboard or notification contents logged to `Logcat` / stdout
- [ ] Any new Android permission in `AndroidManifest.xml` is strictly necessary and documented in `README.md`
