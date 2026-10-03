#!/usr/bin/env python3
"""Export approved bundled marks for Workers Static Assets; never deploy or fetch.

Requires macOS /usr/bin/sips for export, Python 3 stdlib only for --validate-only.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zlib

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "Bighelp/Resources/Assets.xcassets"
NOTICES = ROOT / "Bighelp/Resources/ProviderLogos-NOTICES.txt"
APPROVED_NAMES = frozenset(
    "ProviderLogo" + name for name in (
        "Anthropic", "Claude", "Codex", "GitHubCopilot", "Google", "HuggingFace",
        "LMStudio", "Mistral", "OpenAI", "OpenRouter", "Venice",
    )
)
MAX_IMAGE_BYTES = 1024 * 1024
MAX_IMAGE_DIMENSION = 1024
EXPORT_DIMENSION = 512
MAX_SOURCE_DIMENSION = 4096
MAX_MANIFEST_BYTES = 64 * 1024
MAX_RETAINED_IMAGES = 1000
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
HASH = re.compile(r"[0-9a-f]{64}\Z")
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_.-]{0,127}\Z")
LOCAL_URL = re.compile(r"url\(\s*#([A-Za-z_][A-Za-z0-9_.-]{0,127})\s*\)", re.I)
SVG_NS = "http://www.w3.org/2000/svg"
SVG_TAGS = frozenset((
    "svg", "path", "rect", "g", "defs", "clipPath", "mask", "filter",
    "feFlood", "feBlend", "feGaussianBlur", "linearGradient", "stop", "style",
    "metadata",
))
SVG_ATTRIBUTES = frozenset((
    "fill", "height", "width", "result", "x", "y", "d", "id", "filter",
    "filterUnits", "color-interpolation-filters", "flood-opacity", "in", "in2",
    "stdDeviation", "style", "viewBox", "rx", "fill-rule", "clip-rule",
    "stop-color", "offset", "opacity", "x1", "y1", "x2", "y2",
    "gradientUnits", "version", "type", "bottomLeftOrigin", "class",
    "clip-path", "maskUnits", "mask", "{http://www.w3.org/XML/1998/namespace}space",
))
CSS_PROPERTIES = frozenset((
    "fill", "fill-opacity", "opacity", "mask-type", "enable-background",
    "stop-color", "stop-opacity",
))
HEADERS = """/*
  X-Content-Type-Options: nosniff
  Access-Control-Allow-Origin: *
  Referrer-Policy: no-referrer

/provider-logos/v1/images/*
  Cache-Control: public, max-age=31536000, immutable
  Content-Type: image/png

/provider-logos/v1/manifest.json
  Cache-Control: public, max-age=300, must-revalidate
  Content-Type: application/json; charset=utf-8

/ProviderLogos-NOTICES.txt
  Cache-Control: public, max-age=300, must-revalidate
  Content-Type: text/plain; charset=utf-8
"""


class ExportError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ExportError(message)


def read_bounded(path, limit):
    require(stat.S_ISREG(path.lstat().st_mode), f"Not a regular file: {path}")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    require(0 < len(data) <= limit, f"Empty or oversized file: {path}")
    return data


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(data):
    def invalid_constant(value):
        raise ExportError(f"Invalid JSON constant: {value}")
    return json.loads(data, object_pairs_hook=unique_object, parse_constant=invalid_constant)


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def check_css(declarations):
    for declaration in declarations.split(";"):
        if declaration.strip():
            name, separator, value = declaration.partition(":")
            require(separator and name.strip() in CSS_PROPERTIES and value.strip(),
                    "SVG contains an unsupported CSS declaration")


def validate_svg(data):
    """Fail closed on active content, resource references, and parser ambiguity.

    This deliberately supports only the static vocabulary used by approved marks,
    not arbitrary SVG. Original bytes, including the canvas, go to sips unchanged.
    """
    text = data.decode("utf-8")
    require(all(c in "\t\r\n" or 32 <= ord(c) <= 126 for c in text),
            "SVG must contain plain UTF-8/ASCII markup without control characters")
    # No DTDs, entities (including character-reference obfuscation), comments,
    # processing instructions, or alternate XML encodings enter the renderer.
    require(not any(token in text for token in ("<!", "<?", "&")),
            "SVG declarations, entities and processing instructions are not supported")
    root = ET.fromstring(data)
    require(root.tag == f"{{{SVG_NS}}}svg", "Expected an SVG root")
    identifiers, references = set(), set()
    stack = [(root, 0)]
    node_count = 0
    while stack:
        element, depth = stack.pop()
        node_count += 1
        require(node_count <= 4096 and depth <= 32, "SVG structure exceeds limits")
        tag = element.tag
        allowed = tag in {f"{{{SVG_NS}}}{name}" for name in SVG_TAGS}
        # Inert Adobe metadata retained by the approved Anthropic source.
        allowed = allowed or tag in {"{ns_sfw;}sfw", "{ns_sfw;}slices", "{ns_sfw;}sliceSourceBounds"}
        require(allowed, f"Unsupported SVG element: {tag}")
        require(element is root or tag != root.tag, "Nested SVG canvases are not supported")
        for name, value in element.attrib.items():
            require(name in SVG_ATTRIBUTES, f"Unsupported SVG attribute: {name}")
            if name == "type":
                require(tag == f"{{{SVG_NS}}}style" and value == "text/css", "Unsupported SVG content type")
                continue
            require(re.fullmatch(r"[A-Za-z0-9#_.+%(),;:\s-]*", value, re.ASCII),
                    f"Unsupported SVG attribute value: {name}")
            references.update(LOCAL_URL.findall(value))
            remaining = LOCAL_URL.sub("", value)
            require("url" not in remaining.lower(), "SVG resources must be local fragment URLs")
            functions = re.findall(r"([A-Za-z-]+)\s*\(", remaining)
            require(all(fn in {"color", "rgb", "rgba", "hsl", "hsla"} for fn in functions),
                    "Unsupported SVG value function")
            if name == "style":
                check_css(value)
            if name == "id":
                require(IDENTIFIER.fullmatch(value) and value not in identifiers, "Invalid or duplicate SVG id")
                identifiers.add(value)
        if tag == f"{{{SVG_NS}}}style":
            require(element.get("type", "text/css") == "text/css" and not list(element),
                    "Unsupported SVG stylesheet")
            css = element.text or ""
            rules = list(re.finditer(r"\s*\.[A-Za-z_][A-Za-z0-9_-]*\s*\{([^{}]*)\}\s*", css))
            require("".join(rule.group() for rule in rules) == css, "Only simple SVG class styles are supported")
            for rule in rules:
                # Stylesheets are restricted further: no functions or resource syntax.
                require(re.fullmatch(r"[A-Za-z0-9#_.+%:;\s-]*", rule[1], re.ASCII), "Unsupported SVG stylesheet value")
                check_css(rule[1])
        else:
            require(not (element.text or "").strip(), "Unexpected SVG text content")
        require(not (element.tail or "").strip(), "Unexpected text after SVG element")
        stack.extend((child, depth + 1) for child in element)
    require(references <= identifiers, "SVG references a missing local definition")
    viewbox = re.split(r"[\s,]+", root.get("viewBox", "").strip())
    require(len(viewbox) == 4, "SVG requires an explicit viewBox")
    x, y, width, height = map(float, viewbox)
    require(all(math.isfinite(n) and abs(n) <= MAX_SOURCE_DIMENSION for n in (x, y, width, height))
            and width > 0 and height > 0, "Invalid or oversized SVG viewBox")
    if "width" in root.attrib or "height" in root.attrib:
        dimensions = []
        for name in ("width", "height"):
            value = root.get(name, "")
            require(re.fullmatch(r"[0-9]+(?:\.[0-9]+)?(?:px)?", value), "SVG canvas needs absolute dimensions")
            dimensions.append(float(value.removesuffix("px")))
        width, height = dimensions
        require(all(0 < n <= MAX_SOURCE_DIMENSION for n in dimensions), "Oversized SVG canvas")
    return width, height


def load_sources():
    image_sets = sorted(ASSETS.glob("ProviderLogo*.imageset"))
    require({p.stem for p in image_sets} == APPROVED_NAMES, "Bundled provider names differ from the approved export allowlist")
    sources = {}
    for image_set in image_sets:
        require(image_set.is_dir() and not image_set.is_symlink(), f"Invalid imageset: {image_set.name}")
        contents = load_json(read_bounded(image_set / "Contents.json", MAX_MANIFEST_BYTES))
        require(isinstance(contents, dict) and isinstance(contents.get("images"), list), "Invalid Contents.json")
        variants = {}
        for row in contents["images"]:
            require(isinstance(row, dict) and set(row) <= {"filename", "idiom", "appearances"}
                    and row.get("idiom") == "universal", "Only universal, unscaled SVG images are supported")
            appearances = row.get("appearances", [])
            require(appearances in ([], [{"appearance": "luminosity", "value": "dark"}]), "Unsupported logo appearance")
            appearance = "dark" if appearances else "light"
            require(appearance not in variants, "Duplicate logo appearance")
            filename = row.get("filename")
            if not isinstance(filename, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.svg", filename):
                raise ExportError("Logo filename must be a local SVG basename")
            data = read_bounded(image_set / filename, MAX_IMAGE_BYTES)
            variants[appearance] = (data, validate_svg(data))
        require(set(variants) == {"light", "dark"}, f"Missing any/dark variant: {image_set.stem}")
        sources[image_set.stem] = variants
    return sources


def png_dimensions(data):
    require(data.startswith(PNG_SIGNATURE) and len(data) >= 33
            and data[8:16] == b"\x00\x00\x00\rIHDR", "Invalid PNG signature or IHDR")
    return struct.unpack(">II", data[16:24])


def png_chunks(data):
    png_dimensions(data)
    offset = 8
    chunks = []
    while offset < len(data):
        require(offset + 12 <= len(data), "Truncated PNG chunk")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        end = offset + length + 12
        require(end <= len(data), "Truncated PNG payload")
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:end - 4]
        crc = struct.unpack(">I", data[end - 4:end])[0]
        require(zlib.crc32(kind + payload) == crc, "PNG chunk checksum mismatch")
        chunks.append((kind, payload, data[offset:end]))
        offset = end
    require(chunks[-1][:2] == (b"IEND", b""), "PNG is missing its terminal IEND")
    require(sum(kind == b"IHDR" for kind, _, _ in chunks) == 1
            and sum(kind == b"IEND" for kind, _, _ in chunks) == 1, "Duplicate PNG boundary chunk")
    return chunks


def validate_png(data):
    require(len(data) <= MAX_IMAGE_BYTES, "PNG exceeds 1 MiB")
    width, height = png_dimensions(data)
    require(0 < width <= MAX_IMAGE_DIMENSION and 0 < height <= MAX_IMAGE_DIMENSION, "PNG dimensions exceed limits")
    chunks = png_chunks(data)
    depth, color, compression, filtering, interlace = data[24:29]
    require(depth in (8, 16) and color in (4, 6) and (compression, filtering, interlace) == (0, 0, 0),
            "Expected a non-interlaced PNG with an alpha channel")
    require(all(kind not in {b"acTL", b"fcTL", b"fdAT"} for kind, _, _ in chunks), "Animated PNG is not supported")
    require(all(kind[:1].islower() or kind in {b"IHDR", b"PLTE", b"IDAT", b"IEND"}
                for kind, _, _ in chunks), "Unknown critical PNG chunk")
    compressed = b"".join(payload for kind, payload, _ in chunks if kind == b"IDAT")
    stride = 1 + width * (4 if color == 6 else 2) * (depth // 8)
    decoder = zlib.decompressobj()
    pixels = decoder.decompress(compressed, stride * height + 1)
    require(len(pixels) == stride * height and decoder.eof and not decoder.unused_data
            and not decoder.unconsumed_tail, "Invalid or oversized PNG pixel stream")
    require(all(pixels[row * stride] <= 4 for row in range(height)), "Invalid PNG row filter")
    return width, height


def run_sips(*arguments):
    result = subprocess.run(["/usr/bin/sips", *map(str, arguments)], capture_output=True, text=True, timeout=45)
    require(result.returncode == 0, "System sips conversion failed: " + result.stderr.strip()[:500])


def render_png(data, canvas, temporary):
    source, raster = temporary / "source.svg", temporary / "render.png"
    source.write_bytes(data)  # Exact validated bytes; never rewrite the bundled SVG.
    raster.unlink(missing_ok=True)  # Never accept a previous conversion's output.
    run_sips("--setProperty", "format", "png", source, "--out", raster)
    raw = read_bounded(raster, 64 * MAX_IMAGE_BYTES)
    width, height = png_dimensions(raw)
    require(0 < width <= MAX_SOURCE_DIMENSION and 0 < height <= MAX_SOURCE_DIMENSION, "Unexpected rendered canvas")
    if max(width, height) > EXPORT_DIMENSION:
        run_sips("--resampleHeightWidthMax", EXPORT_DIMENSION, raster, "--out", raster)
        raw = read_bounded(raster, MAX_IMAGE_BYTES)
    # Retain pixel/color data, discard timestamps, text, EXIF and other nonvisual
    # metadata so local paths and conversion times cannot enter public artifacts.
    retained = {b"IHDR", b"PLTE", b"IDAT", b"IEND", b"cHRM", b"gAMA", b"iCCP", b"sBIT", b"sRGB", b"tRNS"}
    png = PNG_SIGNATURE + b"".join(chunk for kind, _, chunk in png_chunks(raw) if kind in retained)
    width, height = validate_png(png)
    require(max(width, height) <= EXPORT_DIMENSION, "sips did not respect the export size")
    source_width, source_height = canvas
    # Permit at most one raster-pixel rounding error per dimension, not cropping.
    require(abs(width * source_height - height * source_width) <= source_width + source_height,
            "sips changed the SVG canvas proportions")
    return png


def validate_manifest(manifest):
    require(isinstance(manifest, dict) and set(manifest) == {"schemaVersion", "revision", "logos"}, "Invalid manifest fields")
    require(type(manifest["schemaVersion"]) is int and manifest["schemaVersion"] == 1, "Unsupported manifest schema")
    logos = manifest["logos"]
    require(isinstance(logos, dict) and set(logos) == APPROVED_NAMES, "Manifest provider mapping differs from approved names")
    expected_revision = digest(canonical_json({"schemaVersion": 1, "logos": logos}))
    require(manifest["revision"] == expected_revision, "Manifest revision mismatch")
    referenced = set()
    for name, variants in logos.items():
        require(isinstance(variants, dict) and set(variants) == {"light", "dark"}, f"Invalid appearances: {name}")
        for image in variants.values():
            require(isinstance(image, dict) and set(image) == {"path", "sha256"}, "Invalid image descriptor")
            sha = image["sha256"]
            require(isinstance(sha, str) and HASH.fullmatch(sha), "Invalid image digest")
            require(image["path"] == f"images/{sha}.png", "Image path must match its content digest")
            referenced.add(image["path"])
    return referenced


def validate_output(output):
    """Verify a closed public tree, including every retained old image."""
    require(output.is_dir() and not output.is_symlink(), "Output must be a real directory")
    base = output / "provider-logos/v1"
    allowed_directories = {"provider-logos", "provider-logos/v1", "provider-logos/v1/images"}
    required_files = {"_headers", NOTICES.name, "provider-logos/v1/manifest.json"}
    found_files, images = set(), set()
    for directory, directories, files in os.walk(output, followlinks=False):
        for name in directories + files:
            path = Path(directory) / name
            relative = path.relative_to(output).as_posix()
            require(not path.is_symlink(), f"Symlink in public output: {relative}")
            if path.is_dir():
                require(relative in allowed_directories, f"Unexpected public directory: {relative}")
            else:
                found_files.add(relative)
                if relative not in required_files:
                    require(re.fullmatch(r"provider-logos/v1/images/[0-9a-f]{64}\.png", relative),
                            f"Unexpected public file: {relative}")
                    data = read_bounded(path, MAX_IMAGE_BYTES)
                    validate_png(data)
                    require(path.stem == digest(data), f"Content hash mismatch: {relative}")
                    images.add(path.relative_to(base).as_posix())
                    require(len(images) <= MAX_RETAINED_IMAGES, "Retained image limit reached; review retention before export")
    require(required_files <= found_files, "Incomplete public output")
    manifest = load_json(read_bounded(base / "manifest.json", MAX_MANIFEST_BYTES))
    require(validate_manifest(manifest) <= images, "Manifest references a missing image")
    require(read_bounded(output / "_headers", MAX_MANIFEST_BYTES) == HEADERS.encode("utf-8"), "Unexpected public headers")
    read_bounded(output / NOTICES.name, MAX_IMAGE_BYTES).decode("utf-8")
    return manifest, len(images)


def export(output):
    sources = load_sources()  # Validate every source before invoking the renderer.
    notices = read_bounded(NOTICES, MAX_IMAGE_BYTES)
    notices.decode("utf-8")
    require(Path("/usr/bin/sips").is_file(), "Export requires macOS system /usr/bin/sips")
    if output.exists() and any(output.iterdir()):
        validate_output(output)  # Never mix private/unknown files into a public tree.
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".provider-logos-", dir=output.parent) as temporary_path:
        temporary = Path(temporary_path)
        public = temporary / "public"
        images = public / "provider-logos/v1/images"
        images.mkdir(parents=True)
        logos, rendered = {}, {}
        for name, variants in sources.items():
            logos[name] = {}
            for appearance, (data, canvas) in variants.items():
                source_hash = digest(data)
                if source_hash not in rendered:
                    png = render_png(data, canvas, temporary)
                    sha = digest(png)
                    rendered[source_hash] = {"path": f"images/{sha}.png", "sha256": sha}
                    (images / f"{sha}.png").write_bytes(png)
                logos[name][appearance] = rendered[source_hash]
        manifest = {"schemaVersion": 1, "logos": logos}
        manifest["revision"] = digest(canonical_json(manifest))
        (images.parent / "manifest.json").write_bytes(canonical_json(manifest) + b"\n")
        (public / "_headers").write_text(HEADERS, encoding="utf-8")
        (public / NOTICES.name).write_bytes(notices)
        validate_output(public)
        destination = output / "provider-logos/v1/images"
        destination.mkdir(parents=True, exist_ok=True)
        combined = {p.name for p in destination.iterdir()} | {p.name for p in images.iterdir()}
        require(len(combined) <= MAX_RETAINED_IMAGES, "Retained image limit reached; review retention before export")
        # Append immutable objects first, preserve old references, replace manifest
        # last. A failed conversion never alters the previous complete export.
        for path in images.iterdir():
            target = destination / path.name
            if not target.exists():
                os.replace(path, target)
        for name in ("_headers", NOTICES.name, "provider-logos/v1/manifest.json"):
            os.replace(public / name, output / name)
    return validate_output(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="Dedicated public output directory (retains previous PNGs)")
    parser.add_argument("--validate-only", action="store_true", help="Validate an existing public export without rendering or writing")
    args = parser.parse_args()
    try:
        output = args.output.expanduser()
        require(not output.is_symlink(), "Output directory must not be a symlink")
        # Resolve macOS's standard /var -> /private/var temporary-directory alias.
        # validate_output separately rejects links inside the public tree.
        output = output.resolve()
        require(output != ROOT and output not in ROOT.parents
                and not output.is_relative_to(ROOT / "Bighelp"), "Output overlaps repository source")
        manifest, image_count = validate_output(output) if args.validate_only else export(output)
        print(json.dumps({"action": "validated" if args.validate_only else "exported",
                          "revision": manifest["revision"], "logos": len(manifest["logos"]),
                          "images": image_count, "output": str(output)}, sort_keys=True))
    except (ExportError, OSError, UnicodeError, ET.ParseError, ValueError, zlib.error, subprocess.TimeoutExpired) as error:
        print(f"Provider logo export failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
