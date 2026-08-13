# Oblix portable Rust core

Oblix's in-scope deterministic client logic is implemented in `rust/`. Flutter,
platform integration, persistence, and transport remain in Dart. Application
code calls the handwritten facade in `lib/core/native/oblix_core.dart`; it does
not import generated Flutter Rust Bridge (FRB) bindings directly.

The migration preserves the existing Dart public models and repository APIs.
Rust returns values or mutation plans, while Dart performs database writes,
network requests, file access, notifications, and UI updates.

## Migrated modules and call sites

| Rust module | Migrated logic | Dart consumers |
| --- | --- | --- |
| `api/crdt.rs` | Field-level LWW winner selection and immutable clock stamping | `data/models/note.dart`, `notebook.dart`, `task.dart`, and `crdt_clock.dart` |
| `api/policy.rs` | Logical timestamps; JWT/refresh and collaboration freshness rules; title, draft, share, tag, filename, import-time, and tag-tie policies; sync backoff, batching and settlement; outbox summarization/retirement; notebook paths and export selection | `core/time/sync_clock.dart`, auth/note repositories, `collaboration_session.dart`, `sync_scheduler.dart`, `sync_notes.dart`, `outbox_dao.dart`, `tag_local_datasource.dart`, `import_export_service.dart`, and `note_editor_screen.dart` |
| `api/text.rs` | UTF-16-aware plain-text diff/apply/rebase and selection transforms | `collaboration_session.dart` and `note_editor_screen.dart` |
| `api/formats.rs` | Markdown import shaping, Markdown/plain-text rendering, safe unique export filenames | Markdown/text import-export adapters under `data/io/` |
| `api/mutations.rs` | Effect-free create/update/delete/restore/completion/rollover planners for notes, notebooks, and tasks | `note_repository.dart`, `notebook_repository.dart`, and `task_repository.dart` |
| `api/tasks.rs` | Repetition rules (parse/serialize/describe, next occurrence, completion advance), task list planning (sections, ordering, subtask threading and rollup), month density, reminder instants, and reorder ranks | `task_repository.dart`, `ui/screens/tasks_screen.dart`, and `ui/widgets/task_calendar.dart` |
| `api/quickadd.rs` | One-line task grammar: dates, times, priorities, labels, lists, repeats, reminder leads, plus UTF-16 highlight spans | `ui/widgets/quick_add_field.dart`, via `task_repository.dart` |
| `api/codecs.rs` | ENEX parsing, EPUB import/export, and Oblix v1/v2 archive import/export including attachments | `enex_parser.dart`, `epub_importer.dart`, `epub_exporter.dart`, `oblix_archive.dart`, orchestrated by `import_export_service.dart` |
| `api/view.rs` | Note-list presentation: one-line snippets and the widening time-window headings (today, yesterday, previous 7/30 days, month, year) over caller-localized civil dates | `ui/widgets/note_timeline.dart`, used by the Notes, notebook, and tag lists |
| `api/prepare.rs` | Improving the image *before* the recognizer reads it: measuring a page's tilt, print size and orientation from a first reading, planning several candidate retries — deskew, upscale, contrast stretch, whole-page turn, per-region relighting — each as an affine plus a colour matrix, applying the per-region levels to the pixels, mapping each retry's boxes back to source pixels, and scoring the readings so the best one wins | `domain/services/scanner/page_preparer.dart`, applied in `document_scanner_mlkit.dart` |
| `misread.rs` | Putting back characters the recognizer read as the wrong glyph, where the capture's own confidently-read vocabulary or a short common-word list supports the correction and the recognizer was unsure | Internal to `api/ocr.rs`; reaches Dart as `ScannedNoteDraft::repaired_words` |
| `api/ocr.rs` | Scanned-page reconstruction: projection-profile deskew, column and band detection, reading order, visual-row merging, running-head stripping, cross-page paragraph healing, page classification into presets, capture-quality scoring, title extraction | `ui/screens/scan_screen.dart`, over boxes from `domain/services/scanner/` |
| `api/doc.rs` | Turning reconstructed rows into a document: heading, list, block-quote and code detection, and table detection drawn as Markdown pipe tables with left/right column anchoring | Internal to `api/ocr.rs`; reaches Dart as the shaped body and its `content_type` |
| `api/textlayer.rs` | The recognizer's output kept beside the image: versioned encoding, flattened search text, query hits narrowed to the matched words, region extraction, and simhash fingerprints for duplicate detection | `data/repositories/text_layer_repository.dart` and `domain/services/scanner/scan_backfill_service.dart` |
| `api/entities.rs` | Dates, times, money, phone numbers, emails, links, card numbers (Luhn-checked), IBANs and postcodes; redaction boxes over the sensitive ones; suggested tasks, events and contacts in civil components | Available to any scan consumer; boxes come from a stored text layer |
| `api/pdf.rs` | PDF pages as reconstruction input: per-page use-text-or-recognize assessment, PDF-to-image coordinate flip, and run merging that keeps layout gaps while rejoining split glyphs | `domain/services/scanner/pdf_reader_pdfrx.dart` |
| `api/script.rs` | Which alphabet a page is in: Unicode-range detection, scoring one recognizer's reading against another's, and the cheap-path gate that decides whether the non-Latin models are worth running | `domain/services/scanner/document_scanner_mlkit.dart` |

The handwritten facade converts Dart records and models into the generated FRB
DTOs and converts results back. `lib/core/native/generated/` and
`rust/src/frb_generated.rs` are generated and committed.

## What intentionally remains in Dart

- Flutter widgets, controllers, lifecycle/bootstrap, navigation, themes, and
  editor state.
- SQLite access, migrations, DAOs, repository side effects, outbox row writes,
  and model/persistence serialization.
- HTTP, WebSocket and connectivity handling, authentication storage, sync
  scheduling, retries, and collaboration-session orchestration.
- Platform file picking, sharing, attachment blob I/O, UUID generation, current
  time, and timezone-sensitive legacy date parsing. Dart passes deterministic
  values to Rust instead of Rust acquiring platform state.
- ZIP packaging for bulk Markdown/plain-text exports. Rust chooses filenames
  and renders file contents; Dart creates those two ZIP containers.
- Camera/gallery capture, the ML Kit text recognizer, the ML Kit digital-ink
  recognizer, and PDFium via `pdfrx`. All four are thin sources of *text plus a
  box*; every decision about how those boxes become a note is made in Rust.
  Each is Android/iOS-or-native only, so each sits behind a conditional import
  in `domain/services/scanner/`.
- Rendering a PDF page to pixels, and encoding that bitmap so the recognizer
  will take it. Rust decides *whether* a page needs rendering
  (`assess_pdf_page`); the platform does the rendering.
- Decoding, redrawing and re-encoding a page image for a second recognition
  pass, and sampling its luma histogram from a thumbnail. Rust decides whether a
  retry is worth making and emits the exact affine and colour matrix to use
  (`plan_page_prepare`); `page_preparer_flutter.dart` runs them through a
  `Canvas`. It is the same split as PDF rendering: the pixel work is the
  platform's, every judgement about it is the core's.
- Dart implementations of migrated algorithms and legacy codecs. They are the
  web/pre-initialization compatibility path and the differential-test oracle.
  The whole scanning surface — `api/ocr.rs`, `api/doc.rs`, `api/textlayer.rs`,
  `api/entities.rs`, `api/pdf.rs`, `api/prepare.rs` — deliberately has no such
  mirror: it can
  only run where a recognizer or PDFium exists, which is where the native core
  is always loaded, so a second implementation would be unreachable code free
  to drift. The Dart facade throws there, exactly as the archive codecs do, and
  `test/scanned_text_shaping_test.dart` pins that every one of those entry
  points refuses rather than quietly returning a different answer.
- `api/quickadd.rs` is the one migrated module whose mirror is deliberately
  *degraded* rather than absent or equivalent. A second natural-language date
  grammar in Dart would drift from the first invisibly, and the failure that
  produces — a task quietly filed on the wrong day — is worse than not parsing
  at all, so the fallback returns the typed line as the title with no tokens
  consumed. `api/tasks.rs` keeps a full mirror in
  `lib/core/native/task_engine_dart.dart`, because widget tests never
  initialize the native core and the Tasks screen still has to render.

### Reading a page that is not in a Latin alphabet

On-device text recognition is not one model but five — Latin, Chinese,
Devanagari, Japanese, Korean — and a model only reads the script it was trained
on. All five are bundled by `android/app/build.gradle.kts`; the plugin declares
four of them `compileOnly`, so without those lines the classes are referenced
but absent and R8 fails the release build.

Choosing between them is circular: picking the model needs the script, and
reading the script needs a model. `api/script.rs` breaks it by scoring readings
against each other rather than trying to answer in one shot — the model that
fits comes back with far more text, in the script it was looking for, at higher
confidence. Running all five on every page would be wasteful, so the platform
reads with Latin first and only pays for the rest when `reading_looks_wrong`
says the first answer looks like a mismatch.

Cyrillic, Greek, Arabic, Hebrew and Thai are *detected* but have no on-device
model. `ScriptReport.recognizable` reports that honestly so the app can say why
a page cannot be read, rather than presenting the Latin model's guesses as
words.

### Reading a page twice, from a better image

Everything after recognition works on boxes the model has already emitted.
Reconstruction can fix reading order, banding and paragraphs; it cannot recover
a character the model misread. Once the recognizer has spoken, the *text* is
fixed — so the only remaining lever on character accuracy is what the model was
shown, which is what `api/prepare.rs` exists for.

It reuses the first reading as a measurement of the photograph. The boxes reveal
the page's tilt and its printed line height, and a luma histogram from a
thumbnail reveals how much of the tonal range the lighting actually used. Tilt
past a degree or two, print too small to give the model enough pixels per
character, or ink and paper squeezed into a few levels each cost real accuracy
and are all cheap to undo — so when one of them is bad enough to be worth a
second recognition pass, the core emits an affine and a colour matrix, the
platform draws that bitmap, and the same model reads it again.

Note that this is the one place the *pixels* are straightened rather than the
boxes. `api/ocr.rs` deskews boxes, which is what reading order needs and all it
can do after the fact; `measure_page_geometry` is shared between the two so a
retry can never disagree with reconstruction about how crooked a page is.

The retry is a candidate, never a replacement. Preprocessing can also make a
page worse — an over-stretched histogram eats thin strokes and a rotation
resamples every glyph — so `choose_page_reading` scores the readings and the
original holds a tie, exactly as Latin is the incumbent above. The worst case is
time spent, not text lost.

There is more than one candidate, because the corrections do not stand or fall
together: a page helped by being turned and hurt by having its contrast
stretched cannot be judged from a single image that does both.
`plan_page_candidates` therefore offers up to three, and each is read and scored
on its own. Two of them exist for cases the earlier measurements could not see:

- **Orientation.** A page photographed on its side says so in its geometry —
  the recognizer reports columns of glyphs, taller than they are wide, where an
  upright page reports lines — so `PageMeasure::upright_share` catches it
  without reading anything. A page photographed upside down leaves no geometric
  trace at all, so the half turn is offered on the first reading's quality
  alone, and only when it came back as debris rather than as language.
- **Uneven lighting.** A colour matrix is one curve over the whole sheet, which
  is the right correction for a uniformly dim page and no correction at all for
  the commonest bad capture: a page lit from one side, where the paper in shadow
  is darker than the ink in the light. `PageLumaSample::tiles` — the same
  thumbnail, summed into a grid — is what distinguishes the two, since a
  histogram cannot say *where* a page used its range. When the lighting is
  uneven, `normalize_page_contrast` re-levels the drawn bitmap per region,
  interpolating between tiles so no tile edge becomes a seam through a glyph,
  and leaving the result grey rather than thresholded so a thin stroke keeps the
  antialiasing that says where its edge is.

The platform's share of that is unchanged in kind: it decodes, draws and
encodes, and hands the core a pixel buffer for the one correction that cannot be
expressed as a matrix. Each page is also under a wall-clock budget in
`document_scanner_mlkit.dart`, checked between passes so a page never abandons a
recognition it has already paid for.

### Word boxes

A recognizer that breaks its lines into words is asked for them, and
`OcrLineInput::words` carries them through. They are extra evidence, never the
model — a PDF's text runs are not words and several recognizers report none, so
every use degrades to the line boxes. Three things depend on them:

- `tilt_direction` can only vote on boxes that share a printed line. On a page
  reported as one box per row it has nothing to say, and the deskew correctly
  gives up rather than guess a direction. Every line of words is a row of
  row-mates, which turns the page that could not be straightened at all into the
  ordinary case.
- ML Kit on Android frequently reports no line confidence while reporting one
  per element. `OcrLineInput::effective_confidence` averages the words, which
  recovers the capture-quality verdict, the low-confidence filter, and the retry
  comparison on pages that would otherwise be scored "no opinion".
- A search highlight can sit on the words it matched rather than on an
  interpolation along the line, which proportional spacing makes an estimate at
  best. The layer stores them as a trailing element per line, so a layer written
  before they existed still decodes and a source without them still encodes
  exactly as it did.

### Where scanned pages live

A scan produces three things: a note, the source images as attachments, and a
*text layer* per page. The text layer is what the recognizer saw — every line
with its box and confidence — encoded by `api/textlayer.rs` and stored in the
local `text_layers` table (schema v7).

It is local-only and outside the CRDT tables on purpose. A text layer is
derived from an attachment the device already holds, so syncing it would pay to
move something every device can regenerate; it carries no field clocks and
never reaches the outbox. Keeping it buys four things that are otherwise
impossible once the prose has been lifted off the page: searching a photograph
by a word printed on it (`text_layers_fts`, joined into note search), drawing a
highlight on the right words, copying one region of a form, and re-reading a
page with different options without photographing it again.

Keeping these boundaries means the Rust crate has no Flutter, database,
filesystem, or socket dependency and does not read the system clock.

## Runtime selection and initialization

`oblix_core.dart` selects `oblix_core_native.dart` only when `dart.library.io`
is available; web selects `oblix_core_fallback.dart`.

On a native app, `AppBootstrap.init()` awaits `initializeOblixCore()` before it
opens repositories or starts sync. After initialization, the facade invokes
Rust. Initialization failures are not swallowed, so a missing or unloadable
native asset prevents native startup. Before initialization, CRDT, policy,
text, format, and mutation calls use the behaviorally equivalent Dart oracle.

The low-level native codec facade is deliberately stricter: direct calls to
`parseEnexCore`, `importEpubCore`, `exportEpubCore`,
`encodeOblixArchiveCore`, or `decodeOblixArchiveCore` throw `StateError` until
Rust is initialized. Production `data/io` adapters check `isRustCoreReady` and
use their retained Dart codec when the core is unavailable.

On web, initialization is a no-op and `isRustCoreReady` remains false.
Deterministic non-codec facade calls and the high-level import/export adapters
stay in Dart; the low-level native-only codec entry points remain unavailable.
Generated FRB web glue does not mean a Wasm core is built or initialized; no
Rust/Wasm runtime is currently shipped.

## Pinned bridge and Native Assets stack

The version pins must move together:

| Component | Version | Pin location |
| --- | --- | --- |
| Known-good Flutter / Dart | `3.41.6` stable / `3.11.4` | Flutter revision in `.metadata`; Dart constraint in `pubspec.yaml` |
| Rust toolchain | `1.94.1` | `rust/rust-toolchain.toml` |
| `flutter_rust_bridge` (Dart and Rust) | `2.13.0-beta.5` | `pubspec.yaml`, `rust/Cargo.toml`, lockfiles |
| `flutter_rust_bridge_hooks` | `2.13.0-beta.5` | `pubspec.yaml`, `pubspec.lock` |
| `flutter_rust_bridge_codegen` CLI | `2.13.0-beta.5` | developer install command below |
| `cargo-expand` CLI | `1.0.124` | developer install command below |
| `native_toolchain_rust` | `1.0.4+0` | transitive pin in `pubspec.lock` |
| `native_toolchain_c` | `0.19.2` | transitive pin in `pubspec.lock` |
| `code_assets` / `hooks` | `1.2.1` / `2.0.2` | transitive pins in `pubspec.lock` |

Flutter is not enforced by a repository version manager. `.metadata` records
the known-good Flutter revision
`db50e20168db8fee486b9abf32fc912de3bc5b6a`, while `pubspec.yaml` and
`pubspec.lock` define the Dart/Flutter compatibility range; verify the local
SDK instead of assuming that any stable Flutter release is equivalent.

`hook/build.dart` runs `FlutterRustBridgeNativeAssetsBuilder` for the `rust`
crate. Flutter test/run/build commands therefore compile a release-mode native
asset for their target and bundle it automatically; do not copy a DLL/shared
library into a platform runner by hand. `Cargo.lock` and `pubspec.lock` are part
of the reproducible build and must remain committed.

The codec dependencies with deliberately exact manifest pins are
`chrono 0.4.26`, `regex 1.11.1`, `roxmltree 0.20.0`, and `zip 2.4.2` (Deflate
only). `zip 2.4.2` replaced the yanked `2.2.2` release; do not restore that old
pin.

## Developer setup and commands

Run commands from `cyclux/`.

Install the pinned tools once:

```text
rustup toolchain install 1.94.1 --profile minimal --component clippy --component rustfmt
cargo install flutter_rust_bridge_codegen --version 2.13.0-beta.5 --locked
cargo install cargo-expand --version 1.0.124 --locked
flutter pub get
```

Manual target-install examples are:

```text
rustup target add x86_64-pc-windows-msvc --toolchain 1.94.1
rustup target add aarch64-linux-android --toolchain 1.94.1
```

The committed `rust-toolchain.toml` requests all intended Android, iOS,
Windows, Linux, and macOS triples. Fresh rustup provisioning from that manifest
may therefore install all of them, not just the host target.

Normal native development needs no separate Cargo build:

```text
flutter run -d windows
flutter build windows --debug
```

The Native Assets hook invokes Cargo automatically. Platform SDKs still have
to supply the target linker (for example, Visual Studio Build Tools, an Android
NDK, or Xcode).

### Regenerate FRB bindings

Regenerate only after a public Rust API/DTO changes:

```text
cargo +1.94.1 metadata --manifest-path rust/Cargo.toml --locked --format-version 1
flutter_rust_bridge_codegen generate
cargo +1.94.1 fmt --manifest-path rust/Cargo.toml
dart tool/normalize_frb_generated.dart
dart format lib/core/native/generated
```

`flutter_rust_bridge.yaml` disables dependency probing, automatic upgrades,
formatting, and fixes so codegen is deterministic and does not race another
Flutter process. The explicit format commands above are therefore required.

FRB `2.13.0-beta.5` can complete generation after a failed Cargo metadata probe
and emit generated loader values such as:

```text
stem: 'UNKNOWN',
ioDirectory: 'UNKNOWN',
```

Do not repair generated files by hand. `oblix_core_native.dart` deliberately
loads the library with a handwritten `ExternalLibraryLoaderConfig` and passes
that library to `RustLib.init`, so these generated defaults are not used on
native platforms. The authoritative values in the facade are:

```text
stem: 'oblix_core',
ioDirectory: 'rust/target/release/',
```

Keep the explicit loader until a later pinned FRB release both emits the right
defaults and passes the full platform smoke matrix. Verify it after codegen:

```text
rg "stem: 'oblix_core'" lib/core/native/oblix_core_native.dart
rg '@generated by `flutter_rust_bridge`@ 2.13.0-beta.5' lib/core/native/generated rust/src/frb_generated.rs
```

The Dart and Rust generated halves must report the same codegen version and
content hash. Do not copy only one half or hand-edit bridge output.

The pinned serialized FRB codec also decodes Rust strings with Dart's standard
UTF-8 decoder, which removes a leading UTF-8 BOM (`U+FEFF`). The committed
`tool/normalize_frb_generated.dart` applies a checked, idempotent repair to the
single generated decoder site so arbitrary note/archive text is preserved.
Run it after every generation; it fails instead of guessing if the generator's
shape changes.

### Checks and tests

```text
cargo +1.94.1 fmt --manifest-path rust/Cargo.toml -- --check
cargo +1.94.1 clippy --locked --manifest-path rust/Cargo.toml --all-targets -- -D warnings
cargo +1.94.1 test --locked --manifest-path rust/Cargo.toml
dart analyze lib test
flutter analyze
flutter test test/rust_crdt_core_test.dart
flutter test test/rust_portable_core_test.dart
flutter test test/rust_codecs_and_mutations_test.dart
flutter test test/scanned_text_shaping_test.dart
flutter test test/scan_text_layer_test.dart
flutter test
```

The focused Flutter tests initialize the native library and compare Rust with
the retained Dart oracle, including UTF-16/emoji vectors and production codec
and mutation call sites. A first Flutter test/build may need registry access to
populate Cargo's cache.

## Codec safety boundary

Native ENEX, EPUB, and Oblix codecs operate on caller-supplied strings/bytes;
they do not read arbitrary filesystem paths. They reject absolute paths,
backslashes, NULs, drive/URI-like `:` segments, empty/`.`/`..` components,
duplicate ZIP entries, invalid UTF-8 text entries, and invalid archive IDs.
Declared and actual decompressed entry sizes are both checked. ENEX `DOCTYPE`
declarations are stripped before XML parsing, so external DTD/entity expansion
is not performed. Oblix decoding rejects unsupported newer versions. Legacy
Oblix timestamp strings return through the handwritten Dart boundary for exact
`DateTime.tryParse` grammar, historical timezone/DST behavior, and fallback
ordering; Rust still performs the bounded ZIP and JSON decoding.

The enforced ceilings are:

| Resource | Limit |
| --- | ---: |
| Input archive bytes or encoded output archive | 256 MiB |
| ZIP entries | 10,000 |
| One uncompressed ZIP entry | 128 MiB |
| Total uncompressed ZIP data | 512 MiB |
| One XML or JSON document | 64 MiB |
| Notes | 10,000 |
| Title plus content for one note | 4,000,000 UTF-16 code units |
| Title plus content across all notes | 32,000,000 UTF-16 code units |
| Declared attachments | 10,000 |

UTF-16 accounting intentionally matches Dart, including supplementary Unicode
characters. Size arithmetic is checked for overflow. A declared Oblix
attachment whose blob is missing remains a nonfatal skipped attachment for
v1/v2 compatibility; unsafe paths and exceeded budgets are fatal. The Dart
facade translates typed codec failures to `FormatException` for existing
callers, so callers do not currently receive the Rust error-kind enum.

ZIP processing is bounded but eager rather than streaming. Entries are
decompressed into memory before format parsing, output archives are assembled
in memory, and attachment buffers cross the DTO/archive boundary. The limits
prevent unbounded expansion; they do not promise low peak memory usage.

## Validation and platform caveats

On the Windows x64 development host, Rust formatting, Clippy, and all 227 Rust
unit tests pass, `dart analyze lib test` reports no issues, and the complete
Flutter suite passes 196/196 — including the native CRDT, portable-core parity,
and codec/mutation differential tests, and `test/task_engine_test.dart`, which
pins the Dart task-engine oracle independently of Rust. A final Windows x64
debug application build also passes: Flutter produced `oblix.exe` and packaged
`oblix_core.dll` under `build/windows/x64/runner/Debug/`; the DLL matches the
Native Assets output by timestamp and size.

Adding a plugin can leave a stale `build/native_assets/` behind, after which
`flutter test` crashes copying a duplicate `sqlite3.dll`
(`PathExistsException`, errno 183). Deleting that directory clears it; it is a
Flutter tooling issue, not a fault in the crate or the bridge.

`flutter analyze` remains the canonical Flutter/CI analysis command listed
above, but it did not complete in this workspace because of the Flutter
startup/build tooling lock. It is not counted as a passing local validation
result.

Android, iOS, Linux, macOS, Windows ARM64, and Rust/Wasm builds have not been
validated. Targets in `rust-toolchain.toml` declare intended build coverage;
they are not evidence that platform linkers, Native Assets packaging, signing,
or runtime loading works. No Wasm target is configured. Add per-platform
CI/build validation before release.

The committed bindings remove the code-generator requirement from ordinary
builds, but native builds still require Rust/Cargo, the requested Rust target,
and the platform linker because the Native Assets hook compiles the crate.
Ordinary tests that do not call `initializeOblixCore()` may exercise only the
Dart fallback; the three focused Rust tests initialize it explicitly.

The core's web fallback is covered by Dart behavior, but the complete Flutter
web application currently has unrelated platform blockers. Do not treat the
native test results as a successful web build.
