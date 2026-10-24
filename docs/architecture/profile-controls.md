# Native profile controls and stored routing

The current release GUI passes scoped native profile controls in a private,
session-only Application Support profile. The QA overlay is signed with the
existing trusted identity and uses the compiled GUI from the verified
`7a6e9ff` preview. Its private Info.plist requires a new signature; temporary
signature-stripped copies compare byte-identical to the packaged GUI.
No production code changed for this check.
[Native evidence](../../benchmarks/results/profile-controls-native.json).

The previous Custom/site/instruction profile reopens after quit/restart. Editing
it to Translate, Qwen3-ASR, explicit automatic speech language, French target and
Off persists all fields. The UI canonicalizes
`https://EXAMPLE.COM:443/project/` to `https://example.com/project`.

Global instruction and German target edits were deliberately left unsaved before
this profile operation. Profile Save preserved persisted global settings. After
quit/restart, those global fields reverted to their original instruction and
English target, while the profile remained Off with its own French target,
Qwen3-ASR and explicit automatic-language checkbox. Re-enabling the rule keeps
its identity and exact overrides.

A new profile with the same app and equivalent canonical site is rejected with a
visible error above Save. The draft stays open, and rejection/Cancel leaves the
settings file byte-for-byte unchanged. This check is distinct from invalid-field
validation, which disables Save before any write.

Removing the language and translation overrides removes their JSON keys, and the
row stops claiming an automatic-language override. The actual CLI then resolves
the inherited translation target to persisted English. No translation is run.

## From the native file to the real resolver

Three checkpoints are published with **only rootPath replaced** by a public
non-engine path. Actual private native files and the public versions produce
identical results in eleven real bundled Swift resolver requests.

| Saved state | Matching app/site result | Speech language | Translation instruction |
|---|---|---|---|
| Disabled | Global Verbatim / Parakeet | Global | Return transcript unchanged |
| Enabled | Translate / Qwen3-ASR | Explicit automatic | French |
| Inherited | Translate / Qwen3-ASR | Global | English |

Outside-site and foreign-app controls keep global settings for every checkpoint.
Mixed-case/default-port document URLs match; query/fragment metadata is not
returned by the resolver. The disabled state also avoids reporting document
metadata as available. All three files preserve the same profile identity and
global settings. Modern `enabled:false` remains the older-reader fence;
`contextEnabled` carries the current enabled state.

[Disabled checkpoint](../../benchmarks/fixtures/profile-controls-disabled.json) ·
[Enabled checkpoint](../../benchmarks/fixtures/profile-controls-enabled.json) ·
[Inherited checkpoint](../../benchmarks/fixtures/profile-controls-inherited.json) ·
[Eleven-request receipt](../../benchmarks/results/profile-controls-resolver.json).

Reproduce the stored-routing checks with an existing built CLI:

```sh
uv run --frozen --all-extras python benchmarks/profile_controls.py \
  --cli .build/debug/ospr-cli --output /tmp/ospr-profile-controls.json
```

The same command runs in CI. It does not launch the app, request permissions,
load models or call a provider. Original seventeen resolver controls still pass.
The existing standalone archive is preserved; its frozen 358-link help predates
this new acceptance evidence. No new distribution is implied.

## Native observations and limits

[Translation draft](../assets/profile-controls-translation-draft.png) ·
[Global defaults after restart](../assets/profile-controls-globals-after-restart.png) ·
[Visible duplicate error](../assets/profile-controls-duplicate-error.png) ·
[Inherited summary and global target](../assets/profile-controls-inherited-profile.png).

The QA candidate is stopped and normal OSpr is visibly restored at eight
sessions/265 words. Normal settings/history and executable/metadata hashes match
the pre-test baseline; the owned TextEdit target is unchanged. The private QA
profile contains only synthetic settings and is retained separately.

These are light-mode native configuration controls and explicit-URL resolver
checks. They do not establish live browser URL metadata, actual capture-time
routing, ASR/translation fidelity, insertion or physical shortcuts. Native Delete,
dark/compact layouts and VoiceOver remain open. One Edit action reported a
transient AX failure; refreshed state showed the editor had opened. This does
not establish an inspection-service reliability fix. No microphone, model,
provider, playback, clipboard insertion or OS permission change was used.
