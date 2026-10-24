# Insertion acknowledgement and clipboard fallback

Previously, every unsuccessful `AXUIElementSetAttributeValue` call led directly
to a Command-V fallback. An Accessibility messaging failure does not give OSpr a
reliable account of the destination's final state. A write may have taken effect
before its acknowledgement was lost. A second transport could duplicate text.

`InsertionTransport` now admits at most one acknowledged write, with fallback
only after an explicit unsupported or read-only result:

| Native result | Action |
| --- | --- |
| Selected-text capability succeeds and is writable | Revalidate, attempt one AX write |
| Capability succeeds but is not writable | Revalidate, use the existing clipboard lease/paste |
| Capability or write reports `attributeUnsupported` / `notImplemented` | Revalidate, use clipboard/paste |
| Write succeeds | Return AX transport; no clipboard mutation or paste event |
| Any other capability error | Stop before writing or changing clipboard |
| Any other write error, including `cannotComplete`, invalid element or unknown code | Stop; ask the user to check the destination before inserting again |
| No captured element and existing compatibility setting permits it | Revalidate, then clipboard/paste |

No native write or fallback is retried automatically. The normal caller saves
the transcript before attempting insertion, retaining it when transport fails.
The setup self-test uses the same guard and cannot mark an unacknowledged write
as sent or confirmed. No writing mode or provider/model behavior changes.

The same app, owner, field, cursor, selected passage and access checks run again
after capability IPC and before either write or clipboard fallback. A known
secure subrole is rechecked before reading selection data; compatibility mode
also refuses a secure/inconsistently owned destination discovered at send time.
The active app and permission are checked after the field queries. Cancellation
is checked before and after validation. Clipboard timing remains asynchronous.

This reduces stale-focus exposure; it does not make AX plus global keyboard
events atomic. The user can still switch focus after the last check. No code
claims transactional insertion, an exactly-once external effect, or proof of
visible delivery from an AX success/paste event. A client returning an explicit
unsupported result after applying a write would violate the assumed result
contract and remains outside this guarantee.

## Evidence and costs

Nine new transport tests exercise actual orchestration with controlled native
outcomes: a write that applies text but loses its acknowledgement, all other
known/unknown failure categories, unsupported/read-only routes, exact effect
ordering, destination changes during either native request, cancellation before
and during requests, unverified routing and paste failure propagation.
The full local suites pass **356 Swift / 248 Python tests**, with zero failures,
and Ruff passes.

These tests do not contact a live editor or post real keyboard events. Native
TextEdit/browser/read-only/secure-field and slow-app checks await manual Mac
unlock. The capability query and repeated validation add IPC work. Their live
latency and compatibility cost have not been measured; no speedup is claimed.
The older source `0aff573` signed self-test candidate remains unchanged and does
not contain this guard.

## Separate signed candidate

`dist/insertion-delivery-guard-v0/OSpr.app` is source
`7e85e12541206c577752ec03a85044f786f7a363`, application fingerprint
`02133f7bc2cdbac6283368f887c44b84cccca043edc57a773e059eeb8240669b`.
The 394,427,049-byte ZIP is SHA-256
`faf3be0a904e56af9ffd03102e9ad8266d563e665bfc733c3382d5e753c2f7ae`.
It passes CRC, extraction, deep signatures, identical executables, extracted
offline CLI inventory and license-byte checks. Relocated/offline/hostile-PYTHONPATH
replay passes six ASR engines, six neural-edge routes, detector abstention,
notes/speakers/mix/review/upload preparation/model inventories and MCP. All 227
bundled relative help links resolve. The bundled report is the source snapshot
before these final receipts.

A same-identity re-signed QA copy changes only the explicit Info data-directory
key. Its isolated local-only profile has no history and has not been launched.
Normal persisted settings/history match the earlier baseline byte for byte.
No recording, playback, sound change or target-field mutation occurred. This is
Apple Development signed, macOS 26.6.2 arm64, with separate weights; no Developer
ID/notarized, clean-Mac/older-OS/updater, live insertion or consumer ranking
acceptance is claimed.

[Archive checks](../../benchmarks/results/insertion-delivery-guard-package.json),
[portable runtime checks](../../benchmarks/results/insertion-delivery-guard-portable.json),
[source and native state](../../benchmarks/results/insertion-delivery-guard-source-validation.json).
Source CI 40092596085 passes the matching 356 Swift / 248 Python tests, app/report
build, 227 help links and clean-runner runtime checks.

Apple's [setter documentation](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)
distinguishes unsupported attributes from failed messaging. The installed
Xcode 26.5 `AXUIElement.h` additionally describes capability-query messaging
failure as often due to a timeout. The fallback policy is OSpr's conservative
interpretation, not an Apple guarantee of exactly-once behavior. The
[capability API](https://developer.apple.com/documentation/applicationservices/1459972-axuielementisattributesettable)
provides the explicit read-only check. Checked 2026-10-24.
