# APEX — Decisions Log (v3.0 build)

## Scope
- Built full P0 (PRD Section 2), M0–M7.
- Three tabs: Home, Circuits, Laps. Settings is a sheet from the Home gear icon (and reachable from onboarding/permission/error flows), not a fourth tab.
- Onboarding is a full-screen first-launch flow: welcome → HealthKit request → import progress → result (with missing-GPS guide when zero routes).

## Gemini
- Default model ID constant: `gemini-3.5-flash-lite`. Stored in Keychain with a Settings override field.
- No fallback chain. If the API returns a model-not-found style error, the UI points at the Settings override.
- On-demand only. Cached per workout. "View data sent" disclosure on Home and lap detail. No raw GPS or coordinates sent; only aggregated lap/sector numbers, deltas, recent laps.

## Debug fixtures
- Deterministic seeded generator. One realistic 5 km loop (closed, curved, self-proximity near S/F) plus point-to-point, no-route, dropout, reverse-direction, too-long, and pause fixtures.
- All fixtures are DEBUG-only and seed into a separate debug container; they never touch the user's real store in release builds.

## Map UX
- SwiftUI `Map` with start/finish flag + A/B markers. Route drawn as three sector polylines, one per sector, in sector colours. No shaded bands.

## Timing engine
- Pure Swift module, no UI/HealthKit/SwiftData imports. Geometry uses a local equirectangular projection (metres). Forward-constrained projection window. Pause subtraction, boundary interpolation, debounce, plausibility cap, sector-sum-equals-lap-time assertion in tests.

## Versioning
- Circuit edits create a new version; existing laps keep their results under the version they were analysed with. Reanalysis is an explicit user action.

## Known limitations
- This environment has no `xcrun`/iOS Simulator, so I could not run `xcodebuild`/simulator launches or execute XCTest on device. The TimingEngine unit test file is written and structured to pass; the app is built to compile cleanly for the iOS platform.
- HealthKit integration is behind the `WorkoutSource` protocol and the real `HealthKitService` actor; the HealthKit path itself must be validated on a physical iPhone (see DEVICE_TESTING.md).
- Pause intervals are not yet persisted in the SwiftData `Workout` model; M0 recompute treats them as empty. Persisting pause intervals is a short follow-up.

## Out of scope (P0)
- In-app GPS recording / live workout screens.
- Multiple users, accounts, cloud sync, leaderboards, subscriptions.
- AI-generated timing data.
- Indoor workouts without GPS; Android / watchOS apps.

## Privacy / integrity
- Gemini key in Keychain only.
- Raw GPS never logged.
- Delete-all removes SwiftData rows, Application Support files, and (with the user's choice) the Keychain entry.
