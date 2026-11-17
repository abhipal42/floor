# Floor for Android

The iOS app is the approved design; this app mirrors it screen for screen (same content, states,
copy and product rules), adapting only where Android has its own convention: system back,
edge-to-edge, Material ripple. Product rules: the repo's `CLAUDE.md`.

## Where it stands

Phase 1 of the Android plan: the Gradle project, the CI job, the design system, the API client and
models for the Finals feed, the app shell (the iOS tab bar: Finals, Week, Bills, Following) and the
Finals screen with its loading, error, empty and offline states.

Phase 2: the vote screen, opened from any card in the Finals feed (`GET /v1/votes/{id}`): "What
this vote is" (folds; its "?" opens the full "Kinds of vote" list from `GET /v1/vote-kinds`), the
broadcast scoreboard, the threshold bar, the box score with who crossed party lines, the bill or
nomination, and the full roll as squares by party; a Speaker election gets its own board and the
ballot. Loading, error and saved-copy states as on Finals. The vote's time is printed in the
device's zone and locale, both passed in (`whenLabel`), never read behind the screen's back.

Phase 3: the Bills tab and the bill screen. The tab searches bills by number or words
(`GET /v1/search`, 300 ms after the last keystroke, never saved) and lists the 32 topics
(`GET /v1/topics`); a topic's page filters All · Moving · Law · Stalled and pages through
`GET /v1/topics/{name}/bills`. The bill screen (`GET /v1/bills/{id}`) draws the header, "On the
floor this week" from `GET /v1/schedule`, the AI section from `/analysis` (labelled AI, every line
cited to its CRS paragraph, a line whose quote isn't in that paragraph cut, the API's disclaimer
under it; a 404 is "none yet": hidden when the bill has a CRS summary, "No summary yet" when it
has none), six levels to law with its roll calls (each opens the vote screen), its topic, the CRS
summary, Speak up, Share and the CBO estimate. Share is the system share sheet with
`/share`'s line and link, or, unreachable, iOS's `ShareFallback` on floor-web-seven.vercel.app. The
vote screen's bill card now gives the bill's "level N of 6". Finals and Bills each keep their own
stack, and a vote, bill or topic can be pushed on either; a hidden tab's stack ignores system back.

Week and Following are visible "Coming soon" placeholders.

What Android leaves out until a later phase, because it needs a district or follows: on Finals the
delegation strip, the All / Following switch, the catch-up deck and the district chip; on a vote,
"Your members" (iOS draws none without a district either); on a bill, "Your members on this bill"
and Follow; on a topic, Follow; in search, members (a member has no screen yet, and iOS's member
rows are Follow toggles). Speak up is built whole (your members only, no stance preselected, "Copy
& open form" copies the fixed message and opens the office's form, the call script opens the
dialer, Floor sends nothing), but the app has no district yet, so it shows iOS's "Set your district
first" card, without the button and without iOS's pointer to a member's Contact tab, neither of
which exists on Android yet. iOS keeps topics and search behind Following's "+ Add"; with no
Following tab yet, Android's Bills tab carries them instead of iOS's list of bills from the feed.
iOS shows "Kinds of vote" and Speak up as sheets; Android pushes the first as a screen so system
back closes it, and shows Speak up as a bottom sheet.

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
- The vote screen's snapshots (`VoteSnapshotTest`) draw each screen light, dark and `large`: the
  200% font scale, Android's largest and the stand-in for iOS's ax5. A size meant not to grow goes
  through `Dp.toSp()`, not a division by the font scale: Android 14 scales large text non-linearly,
  so dividing drew the scoreboard's numbers at half size at 200%.
- `BillsSnapshotTest` draws the Bills tab, search, a topic's page, H.R. 5267 (on the floor) and
  H.R. 1013, the AI section on its own (the only analysis fixture is H.R. 6363's, with no bill
  response to put it under, as on iOS) and Speak up with and without a district (Austin, TX-37,
  from `reps-location-austin`). At 200% a heading's note goes under it rather than beside it, and
  the six-levels diagram stays fixed-size as on iOS: grown, its names broke mid-word.

## CI

The `android` job in `.github/workflows/ci.yml` runs on pushes to `main` that touch `android/`, the
shared fixtures or `.github/` (`SCOPE_RULES` in `.github/scripts/guards.conf`). As with iOS, a PR
does not build: run the command above before opening one.
