# Built-in avatar provenance

App source commit: `8633c7f7f6027abd8928f7fc7dfc2f77ccc3272d`.

Public preview seed: `agent`; every `HermesBlobFace.Kind.allCases` silhouette.
SVG bytes are `HermesBlobFace.render(seed: "agent", kind: kind).svg`, unchanged.

Sources (SHA-256):
- `Bighelp/Companion/HermesFaces/HermesBlobFace.swift`: `2f6ea18e17793f43d4f1e0111cd468e49033afc84f7b9065135764a97756d0fe`
- `Bighelp/Companion/HermesFaces/HermesFaceViews.swift`: `9847d5985784d4ad141c0b5df92e60258ec44e2a810244e3738df558a24e65b3`

License and attribution: `THIRD_PARTY_NOTICES.txt` copied from `Bighelp/Resources/ThirdParty-NOTICES.txt`.

Reproduce and verify from the repo root: `bash scripts/export-builtin.sh`.

Catalog nativeLook follows the chosen agent name/color; these are deterministic static previews, not locked user-specific faces.
