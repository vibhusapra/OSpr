# Web-field insertion after a misleading AX success

Native testing reproduced a visible failure on the preserved source `7e85e12`
candidate: Chrome textarea and contenteditable fields advertised a settable
`AXSelectedText` attribute and acknowledged its setter, but neither visible value
changed or emitted input events. Both tests were explicitly marked failed. The
original [native receipt](../../benchmarks/results/native-insertion-component.json)
is retained. A setter acknowledgement does not prove editor delivery.

Source `e4bc75c` selects the transport **before any write**. After ordinary
permission/app/field/cursor/selection/cancellation validation, it walks parent
roles for at most 32 nodes. A web-area ancestor selects clipboard paste; native
window/application ancestry retains the existing AX capability/write path.
The walk reads roles/parents only. Errors, cycles and depth overflow stop the
attempt. Focus and cancellation are checked again before paste. A failed or
uncertain AX write still cannot trigger a second paste.

The existing asynchronous clipboard lease remains responsible for restoration.
Only the self-test observes its restoration result; normal dictation does not
wait for that result. Native paste events still depend on the foreground app and
cannot form an atomic transaction with its editor. A focus change can race even
these repeated checks. No new unverified-field allowance or permission is added.

## Verification

Four new tests cover web/native ancestry, unreadable/cyclic/unbounded trees,
misleading selected-text capability bypass, and a changed target during routing.
All **412 Swift / 330 Python tests** pass in
[CI 40118451239](https://github.com/vibhusapra/OSpr/actions/runs/40118451239),
including ten local-model, eight summary and 41 provider contracts, app/report,
standalone library imports and 290 bundled help links. Full local Swift tests and
the release app build pass. Inference backend/Core/CLI sources, model pins and dependency lock are unchanged.

An isolated Apple Development signed native QA overlay uses the new OSpr binary
with the preserved `e27b374` engine/CLI/help. It is not a newly archived distribution.
Actual Chrome textarea insertion, contenteditable insertion and selection replacement
visibly pass; each produces one trusted paste/input sequence. OSpr verifies the
captured clipboard data was restored after all three. Password capture is refused,
and the fixture's explicit baseline check confirms the public password remains
unchanged. A foreground app change is refused before delivery. No microphone,
playback or sound-setting change is involved. TextEdit regression on this new
routing build is pending actual foreground focus; its older-component cursor and
selection checks passed earlier. Broad browser/editor/device, physical shortcut,
slow-app fault and microphone-to-insertion acceptance remain open.

[Public fixture](../../benchmarks/fixtures/insertion-target.html) records only event
types/field IDs, makes no network requests and never reads the clipboard. Serve it
locally and use owned fields. Check the actual app/field before sending, independently
read the destination before choosing **It appeared**, and restore fixtures/app/data.
The testing control tool can operate background windows while OSpr correctly
captures the actual foreground app; background field focus alone is insufficient.

[Bound source/CI validation](../../benchmarks/results/web-insertion-source-validation.json),
[exact native scope](../../benchmarks/results/web-insertion-native.json),
[textarea](../assets/web-insertion-browser-textarea.png),
[contenteditable](../assets/web-insertion-browser-contenteditable.png),
[selection replacement](../assets/web-insertion-browser-selection.png),
[clipboard restoration](../assets/web-insertion-clipboard-restored.png),
[password baseline](../assets/web-insertion-password-baseline.png),
[password refusal](../assets/web-insertion-password-refusal.png).

The normal local-only app is restored with byte-identical settings/history and
unchanged public target files. Test-only browser tabs are reset/closed afterward.
