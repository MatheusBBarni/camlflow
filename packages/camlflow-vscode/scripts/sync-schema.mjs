import { copyFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const packageDir = resolve(scriptDir, "..");
const sourcePath = resolve(packageDir, "../../schemas/camlflow.schema.json");
const targetPath = resolve(packageDir, "generated/camlflow.schema.json");

mkdirSync(dirname(targetPath), { recursive: true });
copyFileSync(sourcePath, targetPath);

console.log(`synced ${targetPath}`);
