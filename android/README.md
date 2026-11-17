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

Phase 4: members, your district and following.

- **Member screen** (`member/`, `GET /v1/members/{id}` and `/votes`): the player card, Votes · Money ·
  Contact, the three rings, the last-40 grid and its readout, the computed "did you know". Money is
  Funding (`/funding`: FEC totals, the bar, PAC checks; committees only, never an individual
  donor) and Disclosures (`/disclosures`: ranges as filed, trades with days-to-file against the
  deadline, paper filings as links, the AI tag on a transcribed report, the "A home is listed only
  when it earns income" line; off, the API's reason as a placeholder). Contact dials, writes and
  links. Follow sits on top; your own rep reads "Your rep".
- **Members-elect** (`/v1/members-elect`): the LEAVING tag, ELECT rows under the member they replace
  ("takes office Jan 3" or "when <State> certifies"), dashed pending-seat cards (never a name), and
  the elect screen (takes-office banner with its source, "No votes yet", FEC totals or a
  placeholder, "No House/Senate office yet"). The `elect` and `electInk` tokens are in `Palette.kt`.
- **Your district** (`onboarding/`): "Pull your three." by address or by location, both sent once
  to `/v1/reps` and never kept (a point rounded to 4 decimals first). Location is asked for only
  when "Use my location" is tapped (coarse and fine; an approximate grant says so), read once from
  the platform `LocationManager`. The district is kept in DataStore (`store/DeviceStore.kt`, out of
  backups) with the follow list. Finals gains the header chip, your three with loyalty rings (the
  members-elect list while a seat changes hands), the All / Following switch, member chips on
  cards and the followed bill or topic above a title; a vote gains "Your members"; a bill gains
  Follow bill, "✓ Following" on its topic and "Your members on this bill"; Speak up writes to your
  real members, and without a district offers "Set your district".
- **Following** (`following/`): Members · Bills · Topics, edit (hide or show a rep, unfollow,
  reorder) and "+ Add" (search over members, bills and topics with All / Senate / House). The
  Bills tab's search now has members too, each opening the member screen.

Phase 5: the Week tab, app links and the home-screen widgets.

- **Week** (`week/`, `GET /v1/schedule?week=`): THIS WEEK / NEXT WEEK / WEEK OF with arrows to step
  a week at a time (the Monday is Washington's, `Schedule.monday`), House · N and Senate. The House
  side groups the Majority Leader's list as the House does ("Debated under a rule", "Fast track,
  needs ⅔", "Other items"), what you follow first with the gold edge and a FOLLOWING tag (a bill, or
  through a followed topic), five rows then "+ N more", items taken off the list dimmed at the end.
  The Senate side is the next meeting, the Daily Digest's program verbatim with each measure it
  names linked to its bill, the measures named, and "plans a day at a time". An unpublished week says
  so in dashed placeholders, never "recess". A bill opens on the Week tab's own stack.
- **App links**: `https://floor-web-seven.vercel.app/bill/{congress}/{type}/{number}` opens the bill
  screen (an `autoVerify` intent filter on that host and `/bill/`). `model/FloorLink.kt` parses it
  exactly as iOS `FloorLink` does, its tests ported case for case; anything else under `/bill/`
  (the `card.png`) just opens the app. The API serves `/.well-known/assetlinks.json` for
  `app.floor.android` (`apps/api/src/share.ts`, `assetLinks`; the landing page's `vercel.json`
  proxies it). **Its default fingerprint is the DEBUG keystore of the Mac the app was first built
  on: a release (or Play App Signing) certificate's SHA-256 must be added through
  `ANDROID_CERT_SHA256` (comma-separated, on floor-api) before the Play Store**, or release builds
  open the link in the browser.
- **Widgets** (`widget/`, Jetpack Glance): "Latest final" (small: the newest final vote in your
  members' records, the score, and your rep's chip) and "Your members" (medium: your three's latest
  votes, each row opening its vote). Both read your district and follows from the app's DataStore and
  fetch `/v1/members/{id}/votes?limit=25` through the app's own response cache, the same request the
  Finals feed makes, so offline they show what the app last saw, with "As of …" past two hours. They
  refresh every 30 minutes (`updatePeriodMillis`) and when the app goes to the background. A tap opens
  the vote (`floor://vote/…`, an explicit intent to `MainActivity`), or the app from an empty or
  error state.

Where Android differs from iOS, and why: no catch-up deck yet. The Week tab's "Nothing you follow
is scheduled" leaves out "and you can get an alert". The widgets draw headlines in the system's
condensed sans (RemoteViews can't carry the bundled Barlow), head with the app icon's F rather than
the chamber glyph, keep no snapshot of their own (the response cache is the saved copy), and the
medium one has no member pick (iOS's Edit Widget): it is your reps, else the first three you follow. No alerts: iOS's bell and switches
need push, which needs FCM, so the Following tab says "Alerts come to Android later" instead. No
iCloud sync (and no tombstones for it). Following is reordered with Move up / Move down rather than
a drag handle. Any change to what you follow reloads Finals' feed whole, where iOS fetches only what
the change adds. iOS keeps topics and search behind Following's "+ Add" only; Android keeps them on
the Bills tab too. iOS shows "Kinds of vote" and Speak up as sheets; Android pushes the first as a
screen so system back closes it, and shows Speak up and "+ Add" as bottom sheets. Portraits are
fetched with OkHttp from the same `unitedstates/images` files iOS reads; tests draw initials
(`LocalLoadsPortraits`).

## What's not built

- **Push** (vote and bill alerts, and the Live Activity's equivalent, an ongoing notification for an
  open vote): needs a Firebase project for FCM, and the API's device registration taught to send to
  it. Until then Following says "Alerts come to Android later".
- **Sync across devices** (iOS's iCloud follow sync): the follow list stays on this phone.
- **The catch-up deck.**
- **Release signing and the Play Store**: no release keystore, no listing, `versionName` still
  hand-set. A release certificate's fingerprint also has to go into `ANDROID_CERT_SHA256` (above).

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
- `MemberSnapshotTest` draws the member screen (Cruz's record, Doggett's Contact, Funding and
  disclosures, Nadler's transcribed report, disclosures off), the member-elect screen and the vote's
  "Your members"; `DistrictSnapshotTest` draws onboarding, Finals with your three (and Michigan's
  seat changing hands), the Following tab and search with members-elect.
- `WeekSnapshotTest` draws the House (light, dark, large) and Senate sides of the week of Nov 16,
  the empty week of Nov 23 on both sides, and a failed load. `WidgetSnapshotTest` has Glance compose
  each widget's RemoteViews, applies them to a view and captures it: both widgets light and dark,
  stale, no members and failed. `WidgetFeedTest` checks what they show on the TX-37 records, as iOS's
  `WidgetFeedTests` do.
- `BillsSnapshotTest` draws the Bills tab, search, a topic's page, H.R. 5267 (on the floor) and
  H.R. 1013, the AI section on its own (the only analysis fixture is H.R. 6363's, with no bill
  response to put it under, as on iOS) and Speak up with and without a district (Austin, TX-37,
  from `reps-location-austin`). At 200% a heading's note goes under it rather than beside it, and
  the six-levels diagram stays fixed-size as on iOS: grown, its names broke mid-word.

## CI

The `android` job in `.github/workflows/ci.yml` runs on pushes to `main` that touch `android/`, the
shared fixtures or `.github/` (`SCOPE_RULES` in `.github/scripts/guards.conf`). As with iOS, a PR
does not build: run the command above before opening one.
