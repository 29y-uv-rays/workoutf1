# APEX — Device Testing Notes

This document records HealthKit and real-device validation that cannot be done with the debug fixtures or in this environment.

## Before release
- [ ] Physical iPhone + Apple Watch: record runs, walks, cycles with routes; confirm APEX imports them without duplicates across multiple syncs.
- [ ] Third-party workouts without routes: confirm `missingGPS` state and no crashes.
- [ ] Background delivery: close APEX, record a workout, reopen APEX, confirm new workout appears.
- [ ] Anchor-based sync: delete a workout in Health, re-sync, confirm APEX behaviour matches Settings choice (keep vs remove).
- [ ] Large history: 1000+ workouts, confirm batching and lazy lists.
- [ ] GPS edge cases: indoor, GPS off, ride with pauses, point-to-point, reverse direction, near-duplicate circuits.
- [ ] VoiceOver pass on lap detail, sector blocks, settings, onboarding.
- [ ] Gemini key: validate, regenerate, rate-limit, offline, model-not-found.

## Known gaps to close on device
- Pause interval persistence in the Workout model.
- Full HKAnchoredObjectQuery resume after interruptions.
- Background delivery reliability per iOS version.
