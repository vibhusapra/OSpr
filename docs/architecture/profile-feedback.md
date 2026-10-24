# Profile feedback and scoped native acceptance

A query-bearing site rule correctly disabled Save, but its explanation was below
the visible part of the form. Validation now sits outside the scrolling form,
immediately above Save/Cancel. If the profile is valid but its writing mode needs
an inactive rewrite provider, that explanation uses the same footer position.
Validation takes priority. Text uses the normal label color; the warning icon
retains its orange accent. Matching, persistence and provider behavior are unchanged.

## What was observed natively

The [receipt](../../benchmarks/results/profile-feedback-validation.json) separates
the tested executable/source phases. A unique ad-hoc QA identity used a disposable
Application Support profile, with background services disabled. The normal app
remained running. No microphone, model loading, provider, insertion or new macOS
permission was used.

On parent `2814c3d`, the current card-based editor opened successfully. The native
application picker selected TextEdit and filled `com.apple.TextEdit` and its name.
Cancel left the settings file byte-for-byte unchanged. Pending global instruction
and translation edits remained visible but unsaved.

A separate native draft selected Custom mode, Whisper Turbo, French and a profile
instruction. Making only its private QA folder read-only forced a real save
failure. The editor retained all fields, displayed the error above Save and left
the settings bytes unchanged. Restoring the folder to owner-only write access
and retrying saved the profile. The settings file remained mode0600; the test
folder is restored to0700.

The saved local model, language and instruction were correct, while global
instructions, English translation, local routing and history policy retained
their persisted values. Editing the existing profile reopened all overrides with
Enable checked; cancelling a rename preserved the stored configuration. A native
query-bearing site rule disabled Save and exposed the visibility issue fixed here.

The initial footer build `8f1b00b` reopened the saved profile in Modes after a full
quit/relaunch. The profile survived and the unrelated pending globals reverted to
their persisted defaults. macOS then locked before final-footer or further site
controls could be exercised. The final source is rendered and tested below; it
is **not** represented as a completed native pass of the moved footer.

Two batched operations reported transient AX errors; the following observations
showed the requested toggles/page change had completed. This work does not claim
to identify or universally fix the earlier inspection-service crash.

[Picked app](../assets/profile-native-picked-app.png) ·
[Real save failure and retained draft](../assets/profile-native-save-failure.png) ·
[Original validation visibility issue](../assets/profile-native-validation-before.png).

## Native settings to actual resolver

The actual saved file resolves to Custom, Whisper Turbo, `fr` and the profile
instruction for TextEdit. A foreign app keeps the global Verbatim/Parakeet route.
A [public, path-sanitized copy](../../benchmarks/fixtures/profile-native-saved-settings.json)
resolves identically. The [routing receipt](../../benchmarks/results/profile-native-saved-routing.json)
records all three calls. These are context-resolution checks, not live browser
metadata, recording, inference, rewriting or insertion tests.

Modern overrides intentionally encode `enabled:false` and `contextEnabled:true`.
The current reader uses the latter; older readers skip the incomplete modern
rule. Native reopening and actual CLI resolution both read this saved enabled
state correctly. The [separate 17 resolver controls](../../benchmarks/results/profile-feedback-cli.json)
cover app/site boundaries, disabled rules, inherited/cloud model handling, format
compatibility and malformed/oversized inputs.

```sh
swift test
swift build -c release
uv run --frozen --all-extras pytest -q
uv run --frozen --all-extras python benchmarks/context_profiles.py \
  --cli .build/debug/ospr-cli --output /tmp/profile-resolver.json
.build/debug/ospr-cli resolve-profile \
  benchmarks/fixtures/profile-native-saved-settings.json com.apple.TextEdit
```

## Final source layouts

438 Swift / 355 Python tests, release build, Ruff and 17 CLI controls pass locally.
Six actual NSHostingView source renders were inspected: invalid site in
[light](../assets/profile-feedback-invalid-site-light.png) and
[dark](../assets/profile-feedback-invalid-site-dark.png),
[empty Custom instruction](../assets/profile-feedback-invalid-custom.png),
inactive provider in [light](../assets/profile-feedback-provider-off-light.png)
and [dark](../assets/profile-feedback-provider-off-dark.png), and
[compact stress](../assets/profile-feedback-compact-stress.png).
The 744×588 case uses a constrained editor body; 500×480 is a smaller component
stress case. Neither establishes native resizing acceptance. Footer explanations and
Save/Cancel remain visible while the form scrolls. These images are headless
layouts, not native control/scroll or VoiceOver acceptance.

Reproduce from the repository root using `benchmarks/profile_feedback_render.swift`:

```sh
(
set -e
profile_render_test=Tests/OSprPlatformTests/ProfileFeedbackRenderTemporary.swift
test ! -e "$profile_render_test"
cp benchmarks/profile_feedback_render.swift \
  "$profile_render_test"
trap 'rm -f "$profile_render_test"' EXIT
swift test --filter ProfileFeedbackRenderTemporary
)
```

## Remaining acceptance

The final prepared QA app is stopped. The normal app remains running with
unchanged settings/history hashes; no unlock request was sent. Native final-footer
feedback, site-profile creation/canonicalization, translation/automatic-language
controls, enable/delete, duplicate errors, VoiceOver, real Chrome/Safari URL
metadata and live model/language routing remain open. The earlier scoped native
checks do not establish these additional interactions.

Existing signed standalone ZIPs predate this footer change. No new distribution,
performance, full-parity or product-ranking claim follows from this work.
