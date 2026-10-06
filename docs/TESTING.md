# Testing

The results table on this page is copied from the CI log of run https://github.com/Mudassar-sys/stemkit/actions/runs/37400549002 (commit 9ae0e0a, the last change to code and tests; later commits change documents only), on a GitHub-hosted `macos-latest` runner: macOS 26.6.2, Xcode 26.6 (build 17F113), Swift 6.3.3. Tests print their measurements on lines with a fixed prefix (`PARITY`, `MEL`, `DFT`, `FUZZ`, `FUZZ_DISK`, `SPARSE`, `BENCHMARK`, `SCREENSHOT`, `GUARD`, `DOUBLE`), and two CI steps print `CLI_SMOKE` and `SIGNATURE_CHECK`, so every figure can be found in the log by its prefix. Counts in the test list below (cases, bytes, sizes) come from the test sources.

GitHub reports that the artifacts of the run named above expire on 2027-01-04. The figures this page quotes are copied into the table below so they outlive the logs.

## How CI runs the tests

`.github/workflows/ci.yml` runs on every push to main, on pull requests and on manual dispatch, with two jobs:

- **Package build and tests**: `swift build` and `swift test` in the release configuration with testing enabled, with the name list for the repository guard passed from a repository secret (the step stops if the secret is not available); a command line smoke test (`inspect`, `set`, `verify` on a corpus file, with the JSON output checked by a short Python script); the log and the screenshots are uploaded as artifacts.
- **App build and tests**: `xcodebuild build` of the app (Release, ad hoc signed), a check of the embedded entitlements and the hardened runtime flag with `codesign`, then `xcodebuild test` of the app's unit tests.

## Results of run 37400549002 (last code change)

| Measurement | Value from the log |
|---|---|
| Python reference parity | `PARITY files=15 fields_compared=420 mismatches=0` |
| Mel parity, per clip (6 clips) | `MEL clip=<name> max_abs_error=0.0 mean_abs_error=0.0 exact=240000/240000` for sweep, noise_bursts, tones, silence, short and longer_than_chunk |
| Mel reference versions | `MEL reference transformers=5.18.0 numpy=2.5.3` |
| DFT against the naive DFT | `DFT max_abs_error_vs_naive=1.4210854715202004e-14` |
| Fuzzing in memory | `FUZZ cases=8028 parsed=2174 typed_errors=5854 untyped=0` |
| Fuzzing on disk | `FUZZ_DISK written=196 typed_errors=44 untyped=0` |
| Sparse RF64 | `SPARSE RF64 logical_bytes=4294970158 allocated_bytes=20480`, `SPARSE RF64 data_sha256=282ed140bf44705b8c3d6318b0d38ba30b9bd0e7491feb6165fafd441b37b0a4` |
| Sparse BW64 | `SPARSE BW64 logical_bytes=4294970158 allocated_bytes=20480`, same data hash |
| Double rounding example | `DOUBLE 1.005*100=100.49999999999999` |
| Benchmark (not gated) | `BENCHMARK mel_frames_per_second=215085 chunks_per_second=71.70`; the fourteen runs that printed it ranged from 105720 (run 37385637470) to 268006 (run 37379753362), so it depends on the runner |
| Command line smoke test | `CLI_SMOKE ok write_path=in-place data_sha256=cd664de2c017b111226206eff0a8b507456da41f63a50d031b9302ed9ba54067` |
| Repository guards | `GUARD text_files_scanned=63` |
| Package tests | `Test run with 49 tests in 14 suites passed` |
| App signature | `flags=0x10002(adhoc,runtime)`, `SIGNATURE_CHECK ok` |
| App entitlements | `embedded entitlements: {'com.apple.security.files.user-selected.read-write': True, 'com.apple.security.app-sandbox': True}` |
| App unit tests | `Test run with 14 tests in 1 suite passed`, `TEST SUCCEEDED` |
| Export option help text used by RELEASE.md | app job, Toolchain step: `method : String ... Available options: app-store-connect, release-testing, enterprise, debugging, developer-id, mac-application, and validation`, and the `signingCertificate`, `signingStyle` and `teamID` entries |
| Screenshot, light | `SCREENSHOT file=stem-inspector-light.png pixels=1440x810 bytes=156647 sha256=1cf747af5f09fcd414691f18327be11edcaccc7c482af2d7b1052fd071b9a2fe` |
| Screenshot, dark | `SCREENSHOT file=stem-inspector-dark.png pixels=1440x810 bytes=159821 sha256=5aa121c5d52474874220f6b0ec5965f9a3df33d6e47cbd018594eb788acc1b97` |

## Test list

Package tests (`swift test`), by suite:

**Python reference parity**
- Every corpus file matches the reference field by field (15 files; each WAV is first checked against the SHA-256 recorded by the Python export)
- Corpus files parse as RIFF, 24-bit PCM mono at 48 kHz, five seconds

**SHA-256 (FIPS 180-4, NIST example values)**
- NIST example values: the two SHA-256 examples and the additional test data ("abc", the 448-bit message, and additional cases #1, #3, #4, #6 and #10, which include the padding boundaries at 55, 56 and 64 bytes and one million zero bytes)
- Incremental updates of any split equal a single update

**Metadata writes** (every test that writes calls the integrity check before and after)
- Read then write reproduces every corpus file byte for byte, on both paths
- Editing one bext field changes only that field's bytes (12 cases: description, originator, originator reference, date, time, time reference, UMID and all five loudness fields)
- Loudness edits follow the version rule: a version 1 chunk is raised to 2
- A longer iXML at the end of the file takes the streaming path and keeps every other chunk
- A growing bext followed by JUNK is written in place and the JUNK chunk shrinks
- A shrinking bext followed by JUNK is written in place, the JUNK grows and old bytes are zeroed
- A new bext is inserted before fmt through the streaming path
- Shrinking by 8 bytes or more is in place with a new JUNK chunk; by less, a streaming rewrite
- Appending iXML after an odd last chunk without its pad byte adds the pad byte first
- A Version 1 chunk raised to Version 2 marks the other loudness fields as not used (and the version setter's rules both ways, including Version 0 and the UMID)
- Unknown chunks and odd pad bytes survive a streaming rewrite unchanged
- RF64 streaming rewrite updates the ds64 size and keeps the data size marker (RF64 and BW64)
- Writes that would replace a duplicated chunk are refused before touching the file

**Files above 4 GiB (sparse)**
- RF64 and BW64 with a 64-bit data size parse, and in-place writes keep the audio hash (2 cases; bext edited before the data chunk, iXML edited after it, beyond the 4 GiB offset)

**ds64 chunk size table**
- 0xFFFFFFFF sizes of other chunks come from table entries, in order, once each
- A filler sized by the ds64 table is not resized in place; the rewrite keeps the table valid
- A table length that does not fit the chunk is a typed error

**Fuzzing**
- Thousands of truncations and bit flips end in a typed error or a valid parse (every truncation length up to 1,200 bytes of four seed files, RIFF, RF64, BW64 and RF64 with a ds64 table, plus 1,000 random mutations per seed file, fixed random seed)
- Mutated files on disk: reads and writes end in a typed error or keep the audio hash (hashed independently of the writer; a refused write must leave the file byte for byte unchanged)

**Tech 3285 v2 loudness rounding**
- The specification's examples (6 cases, decimal and hexadecimal results)
- A binary double can miss a decimal tie, which is why the API takes Decimal
- Zero, not used and ranges

**fmt chunk**
- PCM 16, 24 and 32 bit and IEEE float 32 and 64 bit (5 cases)
- WAVE_FORMAT_EXTENSIBLE resolves the sub-format (2 cases)
- Malformed fmt chunks are typed errors
- iXML flattening is bounded: too many elements or too much output is a typed error
- Container errors are typed

**Direct DFT**
- Accelerate's DFT setup rejects length 400 and accepts a documented length
- Matrix DFT equals the naive O(N^2) DFT on random frames
- Known transforms: impulse, constant and a cosine on a bin

**Whisper log-mel parity**
- Every reference clip matches element by element (6 clips; each input and feature file is first checked against its manifest SHA-256; threshold 1e-6 per element and 2e-7 mean, reasoning in D-17)
- Mel filters: 201 x 80, no empty filter, and the Slaney mel scale round trips
- Benchmark: frames per second on this machine (reported, not gated)

**Naming template**
- Tokens render and the extension is kept
- Values are sanitised for file names
- Errors are typed

**File worker on disk**
- Expand, load, save with a verified hash, and rename (including a case-only rename and the folder write probe)
- View model over the real worker: load a folder, edit, save, badge verified

**Screenshots**
- Main window, light and dark, from real files (also checks that a multi-file edit keeps each file's own description)

**Repository guards**
- The scan covers the repository
- No em dash anywhere
- No client, company or person names (the list comes from the `STEMKIT_DENIED_NAMES` secret and is never printed; the test fails if the list is empty, and CI checks the number of entries, see D-26)
- No contact details
- No statement of how long anything took
- The guards detect planted samples and pass clean text (the same functions the scan uses, on samples built at run time)

App unit tests (`xcodebuild test`, no disk, an in-memory file service):

**Inspector view model**
- Loading fills the table and records each failure on its own row (and dropping the files again retries the failed one in place)
- A drop that names the same file twice gives one row
- Files dropped while a batch runs are queued and loaded afterwards
- Text typed in the inspector survives the end of a batch
- A selection change keeps unapplied edits and shows the new row's other fields (and Revert discards them)
- Cancel also drops items queued behind the batch
- Without folder access the user is asked; a declined request skips the renames
- At most maxConcurrent files are in flight
- Cancel stops scheduling new files and reports how many did not start (files in flight finish, files never started leave no row, and dropping again loads them)
- Saving edits shows a verified badge when the audio hash is unchanged
- Editing one field for several selected files changes only that field
- A changed audio hash after a save is shown as a failed check
- A value that does not fit bext is reported on the row and nothing is written
- Naming preview, duplicate detection and apply

## Fixtures

| Fixture | Produced by | Recorded in |
|---|---|---|
| 15 corpus WAV files and their golden JSON | `reference/export_metadata_golden.py` with the Python reference module | `Tests/WaveContainerTests/Fixtures/manifest.json` (SHA-256 of every WAV and JSON) |
| 6 mel clips (16-bit inputs, float32 features 80 x 3000) | `reference/make_mel_fixtures.py`, transformers 5.18.0, numpy 2.5.3, Python 3.13.7, torch absent | `Tests/MelFrontEndTests/Fixtures/manifest.json` (versions, parameters, SHA-256, shapes) |
| Screenshots | the Screenshots test on CI | SHA-256 above; the files in `docs/screenshots/` were downloaded from the `screenshots` artifact of the run named at the top and committed unchanged (same SHA-256). The images changed once more in that run, because round 6 added a Revert button to the inspector; before that, every run from 37379279062 to 37399666190 printed the same two digests, so the render is repeatable. |
