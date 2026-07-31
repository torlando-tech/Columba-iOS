# Maestro UI flows

This directory holds [Maestro](https://maestro.mobile.dev/) flows the
columba-suite **ui-screenshotter** agent runs against the iOS Simulator on
each `columba-suite/*` PR that touches UI files. The agent captures
each flow at BASE_REF and HEAD, in both light and dark Simulator
appearances, and links the resulting PNG pair from the PR's PLAN.md so
reviewers can see the visual change before merging.

## Adding a flow

1. New file `flows/<name>.yml`. Use existing flows as templates.
2. Make it deterministic: `clearState: true` + `clearKeychain: true` on
   launch, pass `ui-screenshotter: true` to create a disposable DEBUG identity,
   and make no persisted network-state assumptions.
3. End with `takeScreenshot: <name>` (the agent expects the PNG to land
   at `./<name>.png`).
4. Don't add voice-call flows yet — they need a debug-only `lxma://debug/...`
   URL handler that doesn't exist (Stage 1 limitation).
5. Assert a stable screen-specific accessibility identifier immediately before
   `takeScreenshot`; optional tab taps must never silently capture another tab.
6. For asynchronously rendered content, wait on an app/native readiness
   identifier rather than an animation timeout. The map flow waits for
   MapLibre's `mapViewDidBecomeIdle` signal through `map_canvas_ready`.

## Running locally

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
export PATH="$JAVA_HOME/bin:$HOME/.maestro/bin:$PATH"
maestro --device <UDID> test flows/contacts-list.yml
```

The `<UDID>` is from `xcrun simctl list devices booted`.

## Pull-request CI

`.github/workflows/tests.yml` installs the already-built shipping simulator app
and runs all four flows on every pull request targeting `main`. A failed
landmark or readiness assertion fails the required test job. Screenshots and
Maestro diagnostics are uploaded as the `ui-screenshots` artifact even when a
flow fails.

## Stage roadmap

- **Stage 1** (now): deterministic landmark/readiness assertions, capture, and
  write the table to PLAN.md; PR CI also archives the screenshots.
- **Stage 2**: pixel diff column.
- **Stage 3**: regression gating (PR fails if golden flow drifts > N%).
- **Stage 4**: graduate to PR comments + GitHub-attachment uploads.

Plan: `~/.claude/plans/ui-screenshotter.md` (vault `Agent Plans/`).
