// Config-file editing for scripts/install-clients.ps1, run with Node:
//   node scripts/lib/client-config.mjs toml   <file> <check|set|remove> [bodyFile]
//   node scripts/lib/client-config.mjs muse   <file> <check|set|remove>
//   node scripts/lib/client-config.mjs claude <file> <check|set|remove>
//
// The toml and muse subcommands are ports of the Python embedded in
// scripts/install-clients.sh, so both scripts edit the same files the same
// way. claude is the Windows script's own: PowerShell 5.1 strips the quotes
// out of a JSON argument passed to a native command (checked 31 Oct 2026),
// so instead of `claude mcp add-json` the entry is written into the config
// file itself, in the same shape that command writes.
//
// Values arrive through the environment, not the command line, so a token
// never shows up in a process list: CONNECTORS_URL_VALUE,
// CONNECTORS_TOKEN_VALUE, CONNECTORS_HEADERS_HELPER_VALUE.

import fs from "node:fs";
import { dirname } from "node:path";

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

// --- TOML ---------------------------------------------------------------------

// Replaces (mode set, with the new table as body) or removes (mode remove)
// the [mcp_servers.connectors] table in a TOML file, keeping every other
// line as it is. Mode check only looks. Refuses forms it can't edit safely,
// such as an inline table or dotted keys.
function tomlCommand(path, mode, body) {
  if (mode !== "set") body = "";
  const text = fs.existsSync(path) ? fs.readFileSync(path, "utf8") : "";
  // Keep each line's own ending, like Python's splitlines(keepends=True).
  const lines = text.split(/(?<=\n)/);
  const header = /^\s*\[\s*mcp_servers\s*\.\s*(?:connectors|"connectors")\s*(?:\.[^\]]*)?\]\s*(?:#.*)?$/;
  const anyHeader = /^\s*\[/;
  const otherForms = /^\s*(?:mcp_servers\s*\.\s*)?"?connectors"?\s*(?:\.|=)/;
  const out = [];
  let skipping = false;
  let inMcp = false;
  let atRoot = true;
  for (const line of lines) {
    if (anyHeader.test(line)) {
      atRoot = false;
      skipping = header.test(line);
      inMcp = /^\s*\[\s*mcp_servers\s*\]/.test(line);
      if (skipping) continue;
    } else if (!skipping && (inMcp || atRoot) && otherForms.test(line)) {
      fail(`${path} sets connectors in a form this script doesn't edit; change it by hand.`);
    }
    if (!skipping) out.push(line);
  }
  if (mode === "check") return;
  let result = out.join("").replace(/\n+$/, "");
  if (body) result = (result ? `${result}\n\n` : "") + body.replace(/\n+$/, "");
  result += "\n";
  const tmp = `${path}.tmp-connectors`;
  fs.writeFileSync(tmp, result, "utf8");
  fs.renameSync(tmp, path);
}

// --- Muse settings.json ---------------------------------------------------------

// Sets (or removes) mcpServers.connectors in Muse's settings.json. Mode
// check only looks. The URL and token come from the environment.
function museCommand(path, mode) {
  let data = {};
  if (fs.existsSync(path)) {
    try {
      data = JSON.parse(fs.readFileSync(path, "utf8"));
    } catch (error) {
      fail(`${path} isn't plain JSON (${error.message}); change it by hand.`);
    }
  }
  if (data === null || typeof data !== "object" || Array.isArray(data)) {
    fail(`${path} isn't a JSON object; change it by hand.`);
  }
  let servers = data.mcpServers;
  if (servers === undefined || servers === null) servers = {};
  if (typeof servers !== "object" || Array.isArray(servers)) {
    fail(`${path} has an mcpServers that isn't an object; change it by hand.`);
  }
  if (mode === "check") return;
  if (mode === "set") {
    servers.connectors = {
      type: "http",
      url: process.env.CONNECTORS_URL_VALUE,
      headers: { Authorization: `Bearer ${process.env.CONNECTORS_TOKEN_VALUE}` },
    };
    data.mcpServers = servers;
  } else {
    delete servers.connectors;
    if (Object.keys(servers).length > 0) data.mcpServers = servers;
    else delete data.mcpServers;
  }
  fs.mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp-connectors`;
  fs.writeFileSync(tmp, `${JSON.stringify(data, null, 2)}\n`, "utf8");
  fs.renameSync(tmp, path);
}

// --- Claude .claude.json --------------------------------------------------------

// Sets (or removes) mcpServers.connectors in Claude's user config, the file
// `claude mcp add-json --scope user connectors` writes to, keeping every
// other key as it is. Mode check only looks. The URL and the headersHelper
// command line come from the environment.
function claudeCommand(path, mode) {
  let data = {};
  if (fs.existsSync(path)) {
    try {
      data = JSON.parse(fs.readFileSync(path, "utf8"));
    } catch (error) {
      fail(`${path} isn't plain JSON (${error.message}); change it by hand.`);
    }
  }
  if (data === null || typeof data !== "object" || Array.isArray(data)) {
    fail(`${path} isn't a JSON object; change it by hand.`);
  }
  let servers = data.mcpServers;
  if (servers === undefined || servers === null) servers = {};
  if (typeof servers !== "object" || Array.isArray(servers)) {
    fail(`${path} has an mcpServers that isn't an object; change it by hand.`);
  }
  if (mode === "check") return;
  if (mode === "set") {
    servers.connectors = {
      type: "http",
      url: process.env.CONNECTORS_URL_VALUE,
      headersHelper: process.env.CONNECTORS_HEADERS_HELPER_VALUE,
    };
    data.mcpServers = servers;
  } else {
    delete servers.connectors;
    if (Object.keys(servers).length > 0) data.mcpServers = servers;
    else delete data.mcpServers;
  }
  fs.mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp-connectors`;
  fs.writeFileSync(tmp, `${JSON.stringify(data, null, 2)}\n`, "utf8");
  fs.renameSync(tmp, path);
}

// --- Main ------------------------------------------------------------------------

const [command, path, mode, bodyFile] = process.argv.slice(2);
if (!command || !path || !["check", "set", "remove"].includes(mode)) {
  process.stderr.write("usage: client-config.mjs toml|muse|claude <file> <check|set|remove> [bodyFile]\n");
  process.exit(2);
}
if (command === "toml") {
  // For set, the new table comes from a file, so newlines in it never
  // touch the command line.
  const body = mode === "set" && bodyFile ? fs.readFileSync(bodyFile, "utf8") : "";
  tomlCommand(path, mode, body);
}
else if (command === "muse") museCommand(path, mode);
else if (command === "claude") claudeCommand(path, mode);
else {
  process.stderr.write(`unknown command: ${command}\n`);
  process.exit(2);
}
