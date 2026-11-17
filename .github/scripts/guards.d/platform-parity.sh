# platform-parity — Floor ships every app change on iOS AND Android (owner's rule, 2026-11-16).
#
# PROJECT-OWNED (guards.d). A PR that changes the app's code on one platform must change the other
# platform's app code too, so the two never drift apart one feature at a time. "App code" is the
# shipped sources only — tests, snapshots, fixtures, project files and docs don't count either way:
#   iOS:     ios/FloorKit/Sources/**.swift, ios/Floor/**.swift, ios/FloorWidgets/**.swift
#   Android: android/app/src/main/**
#
# Opt out with the `single-platform` label or a `[skip parity]` commit tag — for a change that is
# genuinely one platform's (an iOS-only crash fix, a widget API only one side has), and say why in
# the PR body. A feature is never single-platform: build the other side in the same PR.

EXTRA+=(platform-parity)

PARITY_IOS='^ios/(FloorKit/Sources/.*|Floor/.*|FloorWidgets/.*)\.swift$'
PARITY_ANDROID='^android/app/src/main/'

cmd_platform_parity() {
  local ios android
  ios=$(printf '%s\n' "$CHANGED" | grep -E "$PARITY_IOS" || true)
  android=$(printf '%s\n' "$CHANGED" | grep -E "$PARITY_ANDROID" || true)
  if [ -z "$ios" ] && [ -z "$android" ]; then
    echo "✓ no app code changed on either platform."
    return 0
  fi
  if [ -n "$ios" ] && [ -n "$android" ]; then
    echo "✓ app code changed on both iOS and Android."
    return 0
  fi
  exempt single-platform "[skip parity]" && return 0
  local has missing files
  if [ -n "$ios" ]; then has="iOS"; missing="Android (android/app/src/main/)"; files="$ios"
  else has="Android"; missing="iOS (ios/FloorKit/Sources, ios/Floor, ios/FloorWidgets)"; files="$android"; fi
  echo "::error::This PR changes $has app code but not $missing. Floor ships every app change on both platforms (CLAUDE.md › Shipping). Build the other side in this PR, or — only for a change that is genuinely one platform's — add the 'single-platform' label (or a '[skip parity]' commit tag) and say why in the PR body."
  printf '%s\n' "$files" | sed -n '1,8p' | sed 's/^/    /'
  return 1
}
