# Floor for Android

The iOS app is the approved design; this app mirrors it screen for screen (same content, states,
copy and product rules), adapting only where Android has its own convention: system back,
edge-to-edge, Material ripple. Product rules: the repo's `CLAUDE.md`.

## Where it stands

Phase 1 of the Android plan: the Gradle project, the CI job, the design system, the API client and
models for the Finals feed, the app shell (the iOS tab bar: Finals, Week, Bills, Following) and the
Finals screen with its loading, error, empty and offline states. Week, Bills, Following and the vote
screen are visible "Coming soon" placeholders.

What Finals leaves out until a later phase, because it needs a district or follows: the delegation
strip, the All / Following switch, the catch-up deck and the district chip in the header.

## Stack

- Kotlin, Jetpack Compose (Material 3 underneath, themed entirely by Floor's tokens), Navigation
  Compose. One `:app` module, package `app.floor.android`, minSdk 26, compile/target SDK 37.
- AGP 9 with its built-in Kotlin; versions in `gradle/libs.versions.toml`, each a release at least
  two weeks old when pinned.
- OkHttp + kotlinx.serialization against `BuildConfig.API_BASE_URL`
  (`https://floor-api.vercel.app`). Every response a screen reads is saved under the app's cache
  directory (`FileResponseCache`), so a screen opens on its last-seen data and says how old it is.
- Type: Barlow Condensed for scores, labels and headlines (the iOS faces, copied from
  `ios/FloorKit/Sources/DesignSystem/Fonts`), and Inter for running text, standing in for SF Pro.
  Both are OFL; their licences ship in `app/src/main/assets/licences`.
- Colours: `design/Palette.kt` holds every iOS token (light "Marble & Patina", dark the canvas). A
  screen reads `Palette.x`; a hex in a screen is a bug.

## Run it

```bash
cd android
# JDK 17 or newer (21 locally); the Android SDK path in local.properties (sdk.dir=...), never committed.
./gradlew testDebugUnitTest verifyRoborazziDebug assembleDebug lint   # what CI runs
./gradlew recordRoborazziDebug                                        # re-record screenshots after a UI change
./gradlew installDebug                                                # onto a device or emulator
```

## Tests

- **Decode tests** read the real recorded API responses in
  `ios/FloorKit/Tests/ModelsTests/Fixtures` where they live (Gradle passes the path as
  `floor.fixtures`), so both apps decode the same bytes. Add a fixture there, not here.
- **Screenshot tests** (Roborazzi on Robolectric, native graphics) draw each Finals state in light
  and dark at the iOS references' 402-point width, 2x. References are committed under
  `app/src/test/snapshots`; CI's `verifyRoborazziDebug` fails on any pixel change, and uploads the
  diffs. Robolectric 4.17 runs them on SDK 36 (`@Config(sdk = [36])`), its newest.
- Cards print the vote's day in the reader's zone; the tests pin `America/New_York`.

## CI

The `android` job in `.github/workflows/ci.yml` runs on pushes to `main` that touch `android/`, the
shared fixtures or `.github/` (`SCOPE_RULES` in `.github/scripts/guards.conf`). As with iOS, a PR
does not build: run the command above before opening one.
