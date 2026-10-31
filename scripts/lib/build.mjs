// The build: bundles the gateway CLI and the Google server into dist/, with
// the banner that gives the ESM bundles a working `require`. The banner has
// to come from here rather than an npm script: its value holds a real
// newline, and a newline inside an npm script string doesn't survive
// cmd.exe on Windows (checked 31 Oct 2026). The build there ran with only
// the shebang, so a bundled CommonJS dependency whose dynamic require only
// runs on Windows (cross-spawn, from @modelcontextprotocol/client) hit
// esbuild's "Dynamic require of X is not supported" shim and the gateway
// died at startup.

import { build } from "esbuild";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
process.chdir(root);

const banner = [
  "#!/usr/bin/env node",
  "import { createRequire as __connectorsCreateRequire } from 'node:module';",
  "const require = __connectorsCreateRequire(import.meta.url);",
].join("\n");

await build({
  entryPoints: { connectors: "src/cli.ts", "google-mcp": "src/google/server.ts" },
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node26",
  outdir: "dist",
  outExtension: { ".js": ".mjs" },
  legalComments: "none",
  banner: { js: banner },
});

// The banner is what makes the bundles run on Windows; never ship one that
// lost its require half.
for (const name of ["connectors.mjs", "google-mcp.mjs"]) {
  const head = readFileSync(join("dist", name), "utf8").split("\n").slice(0, 3).join("\n");
  if (!head.includes("__connectorsCreateRequire")) {
    throw new Error(`dist/${name} came out without the require banner`);
  }
}
