# Native TextEdit insertion observed; acoustic reference remains open

The existing isolated QA app at source `9a51603` now has one observed native
TextEdit insertion. This does not accept the newer checked streaming-v0 build or
complete microphone/reference-speech, clipboard, selection-editing, browser,
editor, secure-field, physical shortcut or device tests.

Direct app-bound focus reported a TextEdit field while the real foreground target
was another app. Opening `/System/Applications/TextEdit.app` through Finder's
normal **Open Finder item** action during the three-second countdown changed the
actual target captured by OSpr to TextEdit. The HUD confirmed it. A focus-only
take was discarded before recognition.

A clean second take used local Parakeet/English, Verbatim and auto-paste, with
filters/preview and retained audio off. QuickTime played the approved public WAV
once; Finder reopened TextEdit to restore the captured destination. After manual
finish, the actual recognizer output appeared in the owned TextEdit field. Both
native UI states were inspected. The delivery method (AX versus clipboard) was
not separately instrumented. The unexpected output remains only in private local
QA history and owner-only local evidence; it is not published.

The output did not match the public reference. Read-only device inspection found
MacBook Pro Microphone and Speakers as defaults, with **speaker output muted**
and scalar volume 0.1250000149. No sound settings were changed. The fixture itself
was decoded and verified: six seconds of exact-zero lead, the exact public
5.855-second Quilter source PCM, and four seconds of exact-zero tail. QuickTime
reached the end. Muted output prevents an acoustic reference test; the unexpected
recognition is not treated as fixture accuracy evidence.

The owned TextEdit file was restored and saved to its exact original sentinel
plus newline. QA was quit, normal OSpr visibly restored at eight sessions / 265
words, and settings/history hashes still match the baseline. No retained or
recovery audio files remain in QA. The owned public player is paused at 00:00.

One bounded confirmation is pending: temporarily unmute the speakers at 25% for
one 16-second public test, then restore the current muted/12.5% state. The
computer-use confirmation policy requires explicit approval for an unrequested
system setting change. No dependent playback or settings change should occur
before that answer. Existing microphone/Accessibility and public-audio permissions
remain valid; no repeat permission request is needed.

The public receipt `native-textedit-finder-insertion.json` records the build,
workflow, source PCM recipe, observed insertion, muted route and restoration.
It is native observation evidence, not an independently replayed recognizer or
insertion verifier. The full goal and the broader release gates remain open.
