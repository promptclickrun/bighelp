import { spawnSync } from "node:child_process";
import { existsSync, unlinkSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const GENERATED_TYPES_FILENAME = "worker-configuration.d.ts";

export function cleanupRelayTypes(cwd = process.cwd()) {
  const generatedTypesPath = resolve(cwd, GENERATED_TYPES_FILENAME);
  if (!existsSync(generatedTypesPath)) return false;

  unlinkSync(generatedTypesPath);
  return true;
}

function runCommand(command, args, { cwd }) {
  const result = spawnSync(command, args, {
    cwd,
    shell: false,
    stdio: "inherit",
  });
  if (result.error) {
    console.error(`Unable to run ${command}: ${result.error.message}`);
  }
  return result;
}

function exitCode(result) {
  return typeof result?.status === "number" ? result.status : 1;
}

export function runRelayTypeCheck({
  cwd = process.cwd(),
  runCommand: commandRunner = runCommand,
} = {}) {
  try {
    const generated = commandRunner("wrangler", ["types"], { cwd });
    if (exitCode(generated) !== 0) return exitCode(generated);

    return exitCode(commandRunner("tsc", ["--noEmit"], { cwd }));
  } finally {
    cleanupRelayTypes(cwd);
  }
}

const entrypoint = process.argv[1] && resolve(process.argv[1]);
if (entrypoint === fileURLToPath(import.meta.url)) {
  process.exitCode = runRelayTypeCheck();
}
