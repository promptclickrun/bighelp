# Built-in avatar provenance

App source commit: `8633c7f7f6027abd8928f7fc7dfc2f77ccc3272d`.

Every `HermesShapeFace.pickerShapes` entry; `primaryColor` (`#8b5cf6`).
Exact native resting 40×44 drawing: default sampled ring, eyes and catchlights.
Triangle includes native negative-y points; no silhouette correction or clipping is added.

Sources (SHA-256):
- `Bighelp/Companion/HermesFaces/HermesShapeFace.swift`: `6e0219a524503d064cfa1a0a3fea1c73348edda8f65117b0789a207851efdcbd`
- `Bighelp/Companion/HermesFaces/HermesFaceViews.swift`: `9847d5985784d4ad141c0b5df92e60258ec44e2a810244e3738df558a24e65b3`

License and attribution: `THIRD_PARTY_NOTICES.txt` copied from `Bighelp/Resources/ThirdParty-NOTICES.txt`.

Reproduce and verify from the repo root: `bash scripts/export-builtin.sh`.

Catalog nativeLook follows the chosen agent name/color; these are deterministic static previews, not locked user-specific faces.
