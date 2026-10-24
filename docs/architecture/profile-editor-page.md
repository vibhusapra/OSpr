# Profile editor page and scoped persistence

Modes now opens Add/Edit profile as a page in the workspace. It uses the same
cards as Studio and keeps Save/Cancel below a scrolling form. It adapts to the
available workspace size instead of requiring a 620×700 sheet. App selection,
exact bundle ID, optional name/site, enabled state, writing mode, local speech
model, explicit automatic/inherited language, Custom instruction and translation
overrides remain. No field or matching capability is removed.

Save validates and persists the profile before closing. A thrown validation,
settings-read or write failure stays in the editor with its draft and a visible
message above the footer. Cancel makes no settings mutation. Duplicate canonical
app/site rules remain rejected. Removal likewise publishes the new list only
after the settings write acknowledges it.

## Keep profile changes separate from global preferences

Previously, Save/Delete mutated the in-memory profile list and called the global
settings save. That could commit pending unrelated fields, refresh credentials or
shortcuts, and reapply history/audio retention; a file-write failure could still
close the editor. The dedicated profile operation reads persisted settings,
changes the profile list, writes it, then publishes the acknowledged list.
Pending global edits remain pending and their persisted values stay unchanged.
Profile operations do not run credential, login-item, shortcut or retention work.
Unreadable settings fail intact; shutdown refuses new profile mutations.

This uses the existing LocalStore atomic file replacement and permission check;
it is not an external transaction or a new settings format. A failure after file
replacement can still mean the disk write happened; the editor reports failure
and retains its draft. Older-profile encoding and routing rules are unchanged.
Profiles continue to affect the next captured settings snapshot; editing a
profile does not rewrite a take already in progress or enable a cloud provider.

## Verification

Frozen source `4b46bb9` passes **424 Swift tests**, including six new platform
regressions: all overrides/edit/removal and model restart; pending globals and
history fingerprint preservation; duplicate/invalid refusal; unreadable settings;
unacknowledged writes; and shutdown refusal. Release build, Ruff and diff checks
pass. The unchanged resolver passes all 17 actual CLI controls with an unavailable
engine root. The inherited backend is unchanged from PR30's clean-runner
418 Swift / 355 Python source; this branch adds the six native tests.

Actual SwiftUI light, dark and compact source layouts are inspected. Form content
scrolls while Save/Cancel remain visible. These are headless source renders,
not interaction or VoiceOver acceptance.

## Native attempt and honest boundary

The initial page at `5e2790a` reached Modes/Add profile, then native inspection
crashed SkyComputerUseService in Array.remove(at:). OSpr stayed alive. No profile
was saved, and no recording, provider, model or insertion was used. After the
control tool refused a Quit action without a successful inspection, only that
owned QA process was stopped; the normal app was restored through Cua with its
eight sessions/265 words. Settings/history hashes are unchanged.

The standard-card source `4b46bb9` has a signed thin QA candidate with a separate
app identity and isolated data folder, background services disabled. The native
tool reported macOS locked before launch. The normal app remains the only running
OSpr process. **The card change is not established as a fix for the inspection
crash.** Native editor controls, Save/Cancel/restart, application picker, actual
browser URL selection and live model/language routing still need acceptance.
No new standalone/notarized package or full-parity claim.

[Source/native boundary](../../benchmarks/results/profile-editor-page-validation.json) ·
[Resolver CLI](../../benchmarks/results/profile-editor-page-cli.json) ·
[Light source layout](../assets/profile-editor-page-light.png) ·
[Dark](../assets/profile-editor-page-dark.png) ·
[Compact](../assets/profile-editor-page-compact.png) ·
[Routing and storage contract](context-profiles.md).
