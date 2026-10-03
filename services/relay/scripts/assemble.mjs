import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const baselineSha256 = "3f07a9f97e5948feec13b683735cec1f997cb0f265eceefab9e52247012befa2";
const baselineBytes = 775005;
const manifestPath = path.join(root, "recovery-manifest.json");
const outputPath = path.join(root, "dist/worker.js");

// Each marker starts a byte slice. No separator is inserted between slices.
// Vendor sections remain interleaved with contracts in the deployed order.
const sections = [
  ["00-vendor-zod-prelude-core.js", null],
  ["01-vendor-zod-locales-a-f.js", "// ../../node_modules/.pnpm/zod@4.4.3/node_modules/zod/v4/locales/index.js"],
  ["02-vendor-zod-locales-h-p.js", "// ../../node_modules/.pnpm/zod@4.4.3/node_modules/zod/v4/locales/he.js"],
  ["03-vendor-zod-locales-p-z.js", "// ../../node_modules/.pnpm/zod@4.4.3/node_modules/zod/v4/locales/pl.js"],
  ["04-vendor-zod-core-api.js", "// ../../node_modules/.pnpm/zod@4.4.3/node_modules/zod/v4/core/registries.js"],
  ["05-vendor-zod-classic.js", "// ../../node_modules/.pnpm/zod@4.4.3/node_modules/zod/v4/classic/schemas.js"],
  ["06-contracts.js", "// ../../packages/contracts/src/ids.ts"],
  ["07-vendor-orpc.js", "// ../../node_modules/.pnpm/@orpc+shared@1.15.0_@opentelemetry+api@1.9.0/node_modules/@orpc/shared/dist/index.mjs"],
  ["08-contracts-rpc.js", "// ../../packages/contracts/src/rpc.ts"],
  ["09-schema.js", "// src/schema.ts"],
  ["10-queue.js", "// src/queue.ts"],
  ["11-apns.js", "// src/apns.ts"],
  ["12-auth.js", "// src/auth.ts"],
  ["13-crypto.js", "// src/crypto.ts"],
  ["14-storage.js", "// src/storage.ts"],
  ["15-link-enrollment.js", "// src/link-enrollment.ts"],
  ["16-index.js", "// src/index.ts"],
];

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function requireBaseline(bytes) {
  if (bytes.length !== baselineBytes || sha256(bytes) !== baselineSha256) {
    throw new Error("Input does not match the pinned deployed relay bytes; refusing recovery/output.");
  }
}

function recoverParts(bytes) {
  requireBaseline(bytes);
  const offsets = sections.map(([, marker]) => {
    if (marker === null) return 0;
    // The first classic/schemas.js section precedes another section with that
    // same source label. Preserve both by splitting at the first occurrence.
    const index = bytes.indexOf(Buffer.from(`\n${marker}\n`));
    if (index < 0) throw new Error(`Missing original source boundary: ${marker}`);
    return index + 1;
  });
  return sections.map(([name, marker], index) => {
    const start = offsets[index];
    const end = offsets[index + 1] ?? bytes.length;
    if (start >= end) throw new Error(`Out-of-order source boundary: ${name}`);
    const content = bytes.subarray(start, end);
    return {
      content,
      entry: {
        path: `src/recovered/${name}`,
        startByte: start,
        endByteExclusive: end,
        bytes: content.length,
        sha256: sha256(content),
        originalBoundary: marker,
      },
    };
  });
}

async function recover(sourcePath) {
  const parts = recoverParts(await readFile(path.resolve(sourcePath)));
  const manifest = {
    formatVersion: 1,
    authority: "Deployed primary relay JavaScript module; not original TypeScript",
    sha256: baselineSha256,
    bytes: baselineBytes,
    fragments: parts.map(({ entry }) => entry),
  };
  const files = [
    ...parts.map(({ entry, content }) => [path.join(root, entry.path), content]),
    [manifestPath, Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`)],
  ];
  // Do not silently overwrite subsequent source edits during re-recovery.
  const missing = [];
  for (const [filename, content] of files) {
    try {
      if (!(await readFile(filename)).equals(content)) {
        throw new Error(`Refusing to overwrite different existing file: ${filename}`);
      }
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      missing.push([filename, content]);
    }
  }
  for (const [filename, content] of missing) {
    await mkdir(path.dirname(filename), { recursive: true });
    await writeFile(filename, content, { flag: "wx" });
  }
  console.log(`Recovered ${parts.length} byte slices from pinned relay module. No Worker output built.`);
}

async function build() {
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  if (manifest.formatVersion !== 1 || manifest.sha256 !== baselineSha256 ||
      manifest.bytes !== baselineBytes || manifest.fragments?.length !== sections.length) {
    throw new Error("Recovery manifest does not describe the pinned baseline.");
  }
  let offset = 0;
  const chunks = [];
  for (const [index, [name, marker]] of sections.entries()) {
    const entry = manifest.fragments[index];
    const expectedPath = `src/recovered/${name}`;
    if (entry.path !== expectedPath || entry.originalBoundary !== marker) {
      throw new Error(`Unexpected fragment order/boundary at ${expectedPath}`);
    }
    const bytes = await readFile(path.join(root, expectedPath));
    if (entry.startByte !== offset || entry.bytes !== bytes.length ||
        entry.endByteExclusive !== offset + bytes.length || sha256(bytes) !== entry.sha256) {
      throw new Error(`Fragment differs from recovered baseline: ${expectedPath}`);
    }
    chunks.push(bytes);
    offset += bytes.length;
  }
  const output = Buffer.concat(chunks);
  requireBaseline(output);
  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, output);
  console.log(`dist/worker.js: ${output.length} bytes; SHA256 ${sha256(output)}`);
}

try {
  const [command, ...args] = process.argv.slice(2);
  if (command === "recover" && args.length === 1) {
    await recover(args[0]);
  } else if (command === "build" && args.length === 0) {
    await build();
  } else {
    throw new Error("Usage: node scripts/assemble.mjs build | recover <downloaded-module.js>");
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
