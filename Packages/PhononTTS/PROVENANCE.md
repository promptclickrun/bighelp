# PhononTTS provenance

- Upstream repository: https://github.com/gradium-ai/xn-ptts
- Upstream release: `v0.5.0` (commit `e851445158f07061f063e3edff0080f9426c0da2`)
- Upstream path: `ios/PhononTTS/Sources/PhononTTS/Phonon.swift`
- Compiled core: `PhononCore.xcframework.zip` from the same release, fetched by
  `Package.swift` and checked against its SHA-256
- Vendored on: 2026-10-27

`Phonon.swift` was copied from the release above. One change: `SpeechStats` and `Phonon`
carry `@available(iOS 18.0, macOS 15.0, *)`, because this package keeps the app's iOS 17
minimum while Phonon's Core ML models need iOS 18 or later. Upstream's `PhononModels` and
`PhononPlayer` are not used: the app downloads the model and plays the audio itself.

The code is MIT or Apache-2.0 (`LICENSE-MIT`, `LICENSE-APACHE`, copied from the same
release). The app downloads only the Phonon 31m English model, which is Apache 2.0. The
Phonon 40m models are CC BY-NC 4.0 and must not ship in bighelp.
