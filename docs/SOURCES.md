# Sources

One row per technical claim the code or the docs rely on, with the official page or official source repository it was checked against. Claims measured on CI (toolchain versions, test results, the export option help text) cite the CI run in [TESTING.md](TESTING.md) instead.

## Containers and metadata

| # | Claim | Source |
|---|---|---|
| 1 | BW64 uses the id `BW64` in place of `RIFF`; a `ds64` chunk is mandatory and must be the first chunk after the header | https://www.itu.int/rec/R-REC-BS.2088-2-202511-I/en |
| 2 | A 32-bit size field holding `0xFFFFFFFF` means the 64-bit value in `ds64` is used; otherwise the 32-bit value is used | https://www.itu.int/rec/R-REC-BS.2088-2-202511-I/en |
| 3 | `ds64` layout: bw64Size low and high, dataSize low and high, dummy low and high, tableLength, then `ChunkSize64` entries (id, size low, size high) for chunks other than `data` | https://www.itu.int/rec/R-REC-BS.2088-2-202511-I/en |
| 4 | In the BWF file structure the bext chunk comes before the fmt chunk | https://tech.ebu.ch/files/live/sites/tech/files/shared/tech/tech3285.pdf (section 2.1) |
| 5 | EBU Tech 3306 (RF64) now points to ITU-R BS.2088 | https://tech.ebu.ch/publications/tech3306 |
| 6 | bext fixed part: Description 256, Originator 32, OriginatorReference 32, OriginationDate 10, OriginationTime 8, TimeReference low and high, Version, UMID 64, five loudness fields, Reserved 180, then CodingHistory | https://tech.ebu.ch/publications/tech3285 |
| 7 | Version is 1 or 2 in current files; loudness fields need Version 2; Reserved must be zero for Versions 1 and 2 | https://tech.ebu.ch/files/live/sites/tech/files/shared/tech/tech3285.pdf |
| 8 | Loudness rounding: integer part of (x + sgn(x) * 0.5) with x the value times 100, and the six worked examples (-22.644 to -22.646, 12.764 to 12.766) | https://tech.ebu.ch/files/live/sites/tech/files/shared/tech/tech3285.pdf |
| 9 | 0x7FFF marks an unused loudness field; valid ranges are -99.99 to 99.99 (0.00 to 99.99 for LoudnessRange) and out-of-range values are ignored | https://tech.ebu.ch/files/live/sites/tech/files/shared/tech/tech3285.pdf |
| 10 | CodingHistory is a series of CR/LF terminated strings | https://tech.ebu.ch/files/live/sites/tech/files/shared/tech/tech3285.pdf |
| 11 | iXML lives in a chunk with id `iXML`, which should have an even byte count, padded with a space | http://www.gallery.co.uk/ixml/iXML_chunk.html |
| 12 | `NSDecimalNumber.RoundingMode.plain` rounds to the closest value and away from zero when halfway | https://developer.apple.com/documentation/foundation/nsdecimalnumber/roundingmode/plain |
| 13 | `XMLParser` is an event driven parser; `shouldResolveExternalEntities` controls whether external entity declarations are reported (left false here) | https://developer.apple.com/documentation/foundation/xmlparser and https://developer.apple.com/documentation/foundation/xmlparser/shouldresolveexternalentities |
| 14 | SHA-256 algorithm and constants; the test messages and digests ("abc", the 448-bit message, and additional cases #1, #3, #4, #6 and #10) | https://csrc.nist.gov/pubs/fips/180-4/upd1/final (FIPS 180-4, https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.180-4.pdf), https://csrc.nist.gov/projects/cryptographic-standards-and-guidelines/example-values and https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Standards-and-Guidelines/documents/examples/SHA2_Additional.pdf |

## File system and Foundation

| # | Claim | Source |
|---|---|---|
| 15 | `FileManager.replaceItemAt` replaces an item "in a manner that ensures no data loss occurs"; APFS provides atomic safe-save | https://developer.apple.com/documentation/foundation/filemanager/replaceitemat(_:withitemat:backupitemname:options:) and https://developer.apple.com/documentation/foundation/about-apple-file-system |
| 16 | `FileHandle` offers `seek(toOffset:)`, `read(upToCount:)`, `write(contentsOf:)` and `synchronize()` | https://developer.apple.com/documentation/foundation/filehandle/seek(tooffset:), https://developer.apple.com/documentation/foundation/filehandle/read(uptocount:), https://developer.apple.com/documentation/foundation/filehandle/write(contentsof:), https://developer.apple.com/documentation/foundation/filehandle/synchronize() |
| 17 | APFS supports sparse files | https://developer.apple.com/documentation/foundation/about-apple-file-system |
| 18 | Sandboxed apps keep access to user-selected items with `startAccessingSecurityScopedResource()`; access that is not given back keeps kernel resources in use, and the app can lose the ability to add locations to its sandbox until it is relaunched | https://developer.apple.com/documentation/foundation/url/startaccessingsecurityscopedresource() |

## Mel front end

| # | Claim | Source |
|---|---|---|
| 19 | `WhisperFeatureExtractor` defaults: feature_size 80, sampling_rate 16000, hop_length 160, chunk_length 30, n_fft 400 | https://huggingface.co/docs/transformers/en/model_doc/whisper |
| 20 | The exact algorithm at the pinned version: pad or truncate to 30 s; numpy path when torch is absent; Hann window `window_function(400, "hann")`; power 2; Slaney mel filters 0 to 8000 Hz with Slaney norm; `log10`; drop the last frame; clamp to max minus 8; `(x + 4) / 4`; the numpy path is described as matching the original torch implementation within 1e-5 | https://github.com/huggingface/transformers/blob/v5.18.0/src/transformers/models/whisper/feature_extraction_whisper.py |
| 21 | `spectrogram()` defaults: `center=True`, `pad_mode="reflect"`, frames stored in a complex64 buffer, `mel_floor=1e-10`, output cast to float32; `window_function` periodic Hann is `np.hanning(n + 1)[:-1]`; `mel_filter_bank` and the Slaney mel scale formulas | https://github.com/huggingface/transformers/blob/v5.18.0/src/transformers/audio_utils.py |
| 22 | `numpy.pad` reflect mode mirrors on the first and last values | https://numpy.org/doc/stable/reference/generated/numpy.pad.html |
| 23 | `numpy.hanning` is 0.5 - 0.5 cos(2 pi n / (M - 1)); numpy 2.5.3 evaluates it as `0.5 + 0.5 * cos(pi * n / (M - 1))` with `n = arange(1 - M, M, 2)`, the expression the Swift window copies | https://numpy.org/doc/stable/reference/generated/numpy.hanning.html and https://github.com/numpy/numpy/blob/v2.5.3/numpy/lib/_function_base_impl.py |
| 24 | `numpy.fft.rfft` returns n // 2 + 1 bins | https://numpy.org/doc/stable/reference/generated/numpy.fft.rfft.html |
| 25 | Accelerate's documented DFT lengths are f * 2^n with f in {1, 3, 5, 9, 15} (the table is given for its interleaved DFT); 400 = 25 * 16 is not one of them, and the test shows the split-complex `vDSP.DiscreteFourierTransform` refusing 400 and accepting 320 | https://developer.apple.com/documentation/accelerate/vdsp/discretefouriertransform/init(previous:count:direction:transformtype:oftype:) and https://developer.apple.com/documentation/accelerate/vdsp/discretefouriertransform |
| 26 | `vDSP_mmulD(A, IA, B, IB, C, IC, M, N, P)` multiplies an M x P matrix by a P x N matrix into M x N | https://developer.apple.com/documentation/accelerate/vdsp_mmuld |

## Swift, packages and tests

| # | Claim | Source |
|---|---|---|
| 27 | Swift 6 language mode enables complete data race checking | https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/enabledataracesafety/ |
| 28 | `Package(swiftLanguageModes:)` and `SwiftLanguageMode.v6` select the language mode in Package.swift | https://developer.apple.com/documentation/packagedescription/package/swiftlanguagemodes and https://developer.apple.com/documentation/packagedescription/swiftlanguagemode/v6 |
| 29 | `.macOS(.v14)` platform, `.copy` resources, executable and test targets | https://developer.apple.com/documentation/packagedescription/supportedplatform/macosversion/v14, https://developer.apple.com/documentation/packagedescription/resource/copy(_:), https://developer.apple.com/documentation/packagedescription/target/executabletarget(name:dependencies:path:exclude:sources:resources:publicheaderspath:packageaccess:csettings:cxxsettings:swiftsettings:linkersettings:plugins:), https://developer.apple.com/documentation/packagedescription/target/testtarget(name:dependencies:path:exclude:sources:resources:packageaccess:csettings:cxxsettings:swiftsettings:linkersettings:plugins:) |
| 30 | Swift Testing (`@Test`, `#expect`, `#require`, parameterised tests) | https://developer.apple.com/documentation/testing |
| 31 | `TaskGroup` for structured concurrency | https://developer.apple.com/documentation/swift/taskgroup |

## App

| # | Claim | Source |
|---|---|---|
| 32 | `@Observable` needs macOS 14.0 | https://developer.apple.com/documentation/observation/observable() |
| 33 | `@Bindable` needs macOS 14.0 | https://developer.apple.com/documentation/swiftui/bindable |
| 34 | In the App Sandbox, open and save panels extend the app's sandbox to the URLs the user selects, and security-scoped access applies to them | https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox |
| 35 | `Table` needs macOS 12.0 | https://developer.apple.com/documentation/swiftui/table |
| 36 | `dropDestination(for:action:isTargeted:)` (macOS 13.0) and `fileImporter` (macOS 11.0) | https://developer.apple.com/documentation/swiftui/view/dropdestination(for:action:istargeted:) and https://developer.apple.com/documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:allowsmultipleselection:oncompletion:) |
| 37 | A local package can be added to an Xcode project and its products linked by app targets | https://developer.apple.com/documentation/xcode/organizing-your-code-with-local-packages |
| 38 | App Sandbox entitlement `com.apple.security.app-sandbox` | https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.app-sandbox |
| 39 | User-selected file access `com.apple.security.files.user-selected.read-write` | https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write |
| 40 | Hardened Runtime | https://developer.apple.com/documentation/security/hardened-runtime |
| 41 | Build settings used: `CODE_SIGN_ENTITLEMENTS`, `CODE_SIGN_IDENTITY`, `CODE_SIGN_STYLE`, `ENABLE_HARDENED_RUNTIME`, `GENERATE_INFOPLIST_FILE`, `SWIFT_VERSION`; `SWIFT_STRICT_CONCURRENCY` is not set because it is always complete in Swift 6 mode | https://developer.apple.com/documentation/xcode/build-settings-reference |
| 42 | Ad hoc signed code is what Xcode calls "Sign to Run Locally" | https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements |
| 43 | `codesign -d --entitlements - --xml` and `codesign -d -vv` print the entitlements and signature; Developer ID signing uses `--timestamp` and `-o runtime` | https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac |
| 44 | `notarytool store-credentials`, `notarytool submit --wait`, `notarytool log`, `ditto -c -k --keepParent`, `stapler staple`, and that a ZIP cannot be stapled | https://developer.apple.com/documentation/security/customizing-the-notarization-workflow |
| 45 | Notarisation requires a Developer ID signature and the hardened runtime | https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution |
| 46 | `NSHostingView`, `NSView.bitmapImageRepForCachingDisplay(in:)`, `NSView.cacheDisplay(in:to:)` and `NSAppearance.Name.darkAqua` (used for the screenshots) | https://developer.apple.com/documentation/swiftui/nshostingview, https://developer.apple.com/documentation/appkit/nsview/bitmapimagerepforcachingdisplay(in:), https://developer.apple.com/documentation/appkit/nsview/cachedisplay(in:to:), https://developer.apple.com/documentation/appkit/nsappearance/name-swift.struct/darkaqua |
| 47 | `xcodebuild test -project ... -scheme ... -destination ...` runs unit tests from the command line | https://developer.apple.com/library/archive/technotes/tn2339/_index.html |

## CI

| # | Claim | Source |
|---|---|---|
| 48 | `macos-latest` is the macOS 26 Arm64 image; Xcode 26.6 is its default (the runner's own `sw_vers` and `xcodebuild -version` output is in every CI log) | https://github.com/actions/runner-images and https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md |
| 49 | Developer ID certificates, which signing for distribution outside the App Store and notarisation need, come with an Apple Developer Program membership, and only the team's Account Holder can create one | https://developer.apple.com/developer-id/ |
| 50 | `push`, `pull_request` and `workflow_dispatch` triggers | https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows |
| 51 | `actions/checkout` v7.0.1 and `actions/upload-artifact` v7.0.1 exist and run on Node 24 | https://github.com/actions/checkout/releases/tag/v7.0.1, https://github.com/actions/checkout/blob/v7.0.1/action.yml, https://github.com/actions/upload-artifact/releases/tag/v7.0.1, https://github.com/actions/upload-artifact/blob/v7.0.1/action.yml |
| 52 | `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` injects the platform's base entitlements into the signature; notarisation requires that `com.apple.security.get-task-allow` is not included | https://developer.apple.com/documentation/xcode/build-settings-reference and https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution |

## Additional rows

| # | Claim | Source |
|---|---|---|
| 53 | A chunk of odd size is followed by a pad byte of value zero that its size field does not count | https://www.itu.int/rec/R-REC-BS.2088-2-202511-I/en |
| 54 | `onChange(of:initial:_:)` with a closure that takes no values (the form used for the selection) needs macOS 14.0 | https://developer.apple.com/documentation/swiftui/view/onchange(of:initial:_:)-8wgw9 |
| 55 | Statements about how the Python reference behaves (D-05 walk bound, D-07 text decoding, D-08 source comment, D-10 chunk order on write, D-12 last chunk wins, D-13 flatten rules, and the effective format tag read from the first two bytes of an extensible sub-format GUID) | The private reference module `evalgate.metadata`, read only; not linkable. The behaviour covered by the corpus is checked by the parity test; the rest was read from its source. |
| 56 | An unstructured task has no parent task; cancellation propagates from a parent to its child tasks | https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/ |
| 57 | ElementTree: an element's `text` is the text before its first subelement; tags of namespaced elements are `{uri}local` | https://docs.python.org/3/library/xml.etree.elementtree.html |
| 58 | The fmt chunk layout (format tag, channels, sample rate, byte rate, block align, bits per sample) and the format tags WAVE_FORMAT_PCM 0x0001, WAVE_FORMAT_IEEE_FLOAT 0x0003 and WAVE_FORMAT_EXTENSIBLE 0xFFFE, whose extension adds 22 bytes | https://www.itu.int/rec/R-REC-BS.2088-2-202511-I/en and https://tech.ebu.ch/files/live/sites/tech/files/shared/tech/tech3285.pdf (appendix on the fmt chunk) |
| 59 | WAVEFORMATEXTENSIBLE: `cbSize` at least 22, then valid bits per sample, channel mask and the sub-format GUID; the sub-formats for PCM and IEEE float | https://learn.microsoft.com/en-us/windows/win32/api/mmreg/ns-mmreg-waveformatextensible and https://learn.microsoft.com/en-us/windows/win32/api/mmeapi/ns-mmeapi-waveformatex |
| 60 | For an app built with Xcode: `xcodebuild archive`, then `xcodebuild -exportArchive` with an export options property list whose keys `xcodebuild -help` lists; `security find-identity -p codesigning -v` lists signing identities; signing each code item with `codesign` is the route for other products | https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac |
| 61 | A workflow step receives a repository secret as an environment variable through the `secrets` context; an expression for a secret that is not set returns an empty string; apart from `GITHUB_TOKEN`, secrets are not passed to the runner when a workflow is triggered from a forked repository; `gh secret set` reads the value from standard input | https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets |
| 62 | Redaction of secrets in logs relies largely on an exact match of the secret's value and is not guaranteed; structured data should not be used as a secret value; a log that exposes a secret should be deleted; anyone with write access to the repository can read its secrets | https://docs.github.com/en/actions/reference/security/secure-use |

## Independent reference

The bext and iXML parity reference is the Python module `evalgate.metadata` from a separate, private evaluation repository, used read only. Its output for each corpus file is committed as golden JSON with the digests of both the WAV and the JSON in `Tests/WaveContainerTests/Fixtures/manifest.json`; `reference/export_metadata_golden.py` regenerates them.
