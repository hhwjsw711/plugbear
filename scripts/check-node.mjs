// Runs before `npm test` and `npm run dev`. On an older Node, 36 tests fail with
// "fetch failed ... invalid onRequestStart method": the built-in fetch can't
// drive the undici this repo uses. That reads like a real bug, so stop early
// and say what's actually wrong.
import { readFileSync } from "node:fs";

const wanted = readFileSync(new URL("../.nvmrc", import.meta.url), "utf8").trim();
const major = Number(process.versions.node.split(".")[0]);
const wantedMajor = Number(wanted.replace(/^v/, "").split(".")[0]);

if (major < wantedMajor) {
  console.error(
    `PlugBear needs Node ${wantedMajor} or newer, and this is ${process.version}.\n` +
      `Run \`nvm install\` (or \`nvm use\`) in this folder for ${wanted}, then try again.`,
  );
  process.exit(1);
}
