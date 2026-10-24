# Insertion setup self-test

Studio offers **Test insertion…** without requiring a microphone or loaded
speech model. A three-second countdown lets the user focus a text field in
another app. The test captures that destination at expiry, shows its app name,
the fixed phrase `OSpr is ready.`, and whether a selection will be replaced.
A separate **Send test phrase** click is required. It never sends on expiry.

The floating panel cannot become key or main, preserving the destination's
keyboard focus. Actual field/app/cursor/selection and Accessibility checks run
again through the same `InsertionTarget.paste` method used by dictation. Known
password fields are refused before reading selected text or touching clipboard.
Unverified-field compatibility remains an explicit existing setting; a test
using it warns before confirmation rather than implying the field is verified.

Transport acknowledgement is separate from visible success. After sending, the
panel asks whether the phrase appeared. Only the user's **It appeared** response
marks the test confirmed. Direct AX success or posting a paste event alone does
not prove delivery. Failed/cancelled/replaced tasks cannot update another test.
Permission is checked at start and confirmation. The captured field is released
on send/cancel/failure. Test state is in memory only; no transcript history,
audio recording, model request, provider upload or preference change is made.

## Clipboard observability

`InsertionTarget.paste` returns a discardable delivery method; existing dictation
callers retain their timing and behavior. Only the setup test attaches a clipboard
completion observer. The existing 700 ms restoration timer stays asynchronous.

The observer distinguishes restored captured data, a newer user copy,
supersession by another paste, restoration disabled by preference, and failed
verification. Captured readable item/type/data snapshots are compared after
restoration; clipboard contents never appear in the test UI or receipts. A
later user copy wins. Overlapping leases retain the original snapshot. State
is committed/released before callbacks, allowing safe reentrant leases.
Ordinary dictation without an observer performs no extra snapshot verification.

## Source validation

Eight controller/AppModel tests cover permission denial/revocation, capture at
expiry, separate send/visible acknowledgement, configuration snapshot, target
release, stale countdown/send/clipboard callbacks, failure and quit/cancel without
an engine or recovery loss. Four new named-pasteboard tests cover rich/binary
restoration, newer-copy/opt-out outcomes, callback reentrancy and timer order.
The complete local suites pass **347 Swift / 248 Python tests** and Ruff.

Offscreen renders of the actual SwiftUI source cover countdown, ready, sent,
confirmed, long destination/compatibility captions and light/dark presentation.
They are simulated layout fixtures, not native insertion evidence.

## Native acceptance to run on the isolated signed candidate

Use only owned public-text targets. Check the displayed destination before
confirming; do not operate or inject into the protected host. Record the actual
field text independently before clicking **It appeared**. Restore owned files
and the normal app/data afterward.

- TextEdit insertion at cursor and replacement of an owned selection.
- Browser textarea/contenteditable delivery, including actual clipboard fallback
  and its observed restoration status.
- Password field refusal with unchanged owned value.
- Cursor/app change between capture and confirmation refuses the send.
- Cancel before expiry, choose-another-field and explicit negative acknowledgement.

This component test does not establish microphone/ASR-to-insertion, physical
Fn/PTT/device, broad application compatibility, live latency or release readiness.
The single pending audible-test confirmation is independent; no playback or sound
setting is needed for this workflow.
