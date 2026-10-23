# App and site dictation profiles

Profiles choose a writing mode and optional local model, recognition-language
hint, Custom instruction or translation target for a destination app. They are
resolved into a value snapshot when dictation starts, including after the
mouse-start countdown. Editing profiles or their mode/model/language/instruction defaults during a take
affects later takes.
File imports, desktop recordings and recovery use their existing explicit settings.

## Matching and user controls

Modes has an app/site profile list with Add, Edit and Delete. The editor supports
an application picker, exact bundle ID, optional name, enabled state, optional site
rule and the overrides above. Studio shows the selected model and frozen style
during recording; the HUD identifies a matched profile.

1. The app bundle ID must match exactly, including case.
2. An enabled, valid site rule takes priority over the app rule. Its scheme, host
   and effective port must match exactly. A path matches itself and descendant
   segments; `/team` does not match `/teammate` or `/team%2Fprivate`.
3. The longest matching path wins. Equal specificity keeps the first stored rule.
   The editor rejects duplicate canonical app/site rules.
4. If document metadata is unavailable, invalid or out of scope, the app rule
   applies. Otherwise global settings apply. A profile never stays active merely
   because a previous take used it.

Rules require an HTTP(S) origin and optional path. Rule queries, fragments,
credentials, dot segments and malformed configuration are rejected. Document
queries and fragments are discarded before matching. Encoded path bytes remain
literal apart from percent-escape hex case; path case remains significant.

The local-model override applies with Local MLX speech. Global settings select
the audio/text providers, endpoints, model for cloud speech, credential scopes,
insertion policy and retention. A profile cannot silently enable cloud processing
or relax field checks. Nil language inherits the global hint; an explicitly empty
hint requests automatic recognition (Cohere's existing blank-hint behavior is
English). Translation output language is a separate override. Custom instructions
use the configured rewrite provider; they do not enable one automatically.

## Narrow document lookup

Document lookup runs only when the captured app has an enabled, valid site rule.
It walks at most 24 ancestors from the focused field, requires a complete
same-process chain to a window, and reads the outermost web area's URL or the
window's document URL. It does not inspect descendants, address-bar values,
window titles, page text or clipboard content. An inner frame/link URL cannot
select the outer page's profile. Ambiguous chains, cycles and ownership changes
fall back rather than guessing.

Lookup has an 80 ms read-admission deadline and temporary 10 ms per-object AX
message timeouts. Each queried object's timeout returns to the process default
before later insertion. This is a bounded query policy, not a measured latency
SLA: OS scheduling and Accessibility implementations can still delay a call.
Captured URLs do not enter the settings snapshot, transcript history or provider
payload. Configured rule URLs remain in the user's settings as expected.

The capture path now checks that a focused AX object belongs to the captured app
before reading selected text; inconsistent focus prevents microphone start.
Insertion rechecks process ownership as well as the existing app/field/cursor
conditions. The actual process-ID API is tested using self-owned AX objects.

Implementation references: [Apple AX ownership](https://developer.apple.com/documentation/applicationservices/1460337-axuielementgetpid),
[per-object timeout behavior](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout),
[URL metadata](https://developer.apple.com/documentation/applicationservices/kaxurlattribute),
[document metadata](https://developer.apple.com/documentation/applicationservices/kaxdocumentattribute),
and [Chromium's accessibility URL adapter](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/accessibility/platform/ax_platform_node_cocoa.mm).
These inform the adapter; they do not establish a Chrome/Safari native pass.

## Storage and older builds

Old app-only profiles decode with all new overrides absent. New profiles carrying
site/model/language/instruction/translation overrides encode the legacy `enabled`
field as false and put their real activation in `contextEnabled`. An older decoder
therefore skips unsupported rules rather than applying a site condition to a whole
app or losing required overrides. New decoders restore the actual state. An old
build can still discard fields it does not understand when saving; back up settings
before downgrading or editing them with an older preview.

## Dry run and evidence

```sh
.build/debug/ospr-cli resolve-profile settings.json com.example.browser https://example.org/team
python3 benchmarks/context_profiles.py --cli .build/debug/ospr-cli
```

The dry run reads a regular JSON file of at most 4 MiB and reports the match kind,
profile ID/name, effective model, language, mode and instruction. It omits the
supplied document URL and makes no AX, microphone, model or provider request.
The black-box harness intentionally supplies an unavailable engine root.

Source `2b7c02f` passes 244 Swift tests, 105 Python tests, lint and the release
build. Twenty new Swift contracts cover matching, snapshots, legacy encoding,
invalid rules, ancestor safety and process ownership. Seventeen real CLI cases
cover routing plus oversized/malformed settings. The CLI smoke is part of CI.

- [Source/build validation](../../benchmarks/results/context-profiles-validation.json)
- [Real CLI results](../../benchmarks/results/context-profile-cli.json)
- [Native presentation boundary](../../benchmarks/results/context-profiles-native-ui.json)
- [Checked implementation references](../data/context-profiles-contract.json)
- [Packaged-head CI](../../benchmarks/results/context-profiles-ci.json)
- [New portable delivery manifest](../../benchmarks/results/context-profiles-release-package.json)
- [Bundled profile CLI cases](../../benchmarks/results/context-profiles-bundled-cli.json)
- [Later insertion attempt](../../benchmarks/results/context-profiles-insertion-preflight.json)

Native startup and Modes presentation were observed in an isolated profile with
both permissions ready. On Add profile, SkyComputerUseService crashed during
inspection; full AX and screenshot attempts failed with its array-index assertion.
OSpr stayed running. The disposable test process was stopped and the normal app
restored with byte-identical settings/history. No profile save/restart, editor
visual acceptance, live browser URL, microphone model/language switch or insertion
pass is claimed. The new `context-profiles-v0` ZIP at `db0987a` includes these
profiles, with the same application source fingerprint as `2b7c02f`. All six
engines and extras pass after offline relocation; the actual bundled CLI passes
all 17 profile cases, both hour-file regressions and all three 80-minute transports.
The ZIP passes CRC, extraction, deep signatures and extracted CLI inventory.
The packaged head passes macOS 15 CI with 244 Swift/105 Python tests and the
17 CLI cases. This is Apple Development signing, not Developer ID/notarization.

A later isolated copy of that portable candidate started its countdown and real
microphone. The intended TextEdit field appeared focused to the automation, but
OSpr captured another foreground app. The take was discarded before recognition;
no public speech was played or insertion attempted. Zero test history, audio or
recovery remains, and the normal app/settings/history were restored unchanged.
The earlier `refinement-v0` ZIP is preserved. Full feature-union and top-three
placement remain unproven.
