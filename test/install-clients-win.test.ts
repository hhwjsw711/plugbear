// scripts/install-clients.ps1 against a temporary USERPROFILE, with
// stand-ins for the client CLIs and the real connectors CLI minting tokens
// in a temp data folder whose agents.json and settings.json are made up.
// Nothing here touches real configs or the real token store.
// The PowerShell script only runs on Windows; elsewhere this is skipped.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

const REPO = fileURLToPath(new URL("../", import.meta.url));
const SCRIPT = join(REPO, "scripts", "install-clients.ps1");
const STUBS = join(REPO, "test", "fixtures", "bin-win");
const URL_ = "https://gateway.example.ts.net:8443/mcp";

// One agent per client, three extra Claude config folders (claude-old's
// doesn't exist on this machine), and one agent with no client.
const AGENTS = [
  { id: "claude", title: "Claude", upstreams: ["*"], client: { type: "claude" } },
  { id: "claude-work", title: "Claude (claude-work)", upstreams: ["*"], client: { type: "claude", configDir: "~/accounts/claude-work" } },
  { id: "claude-old", title: "Claude (claude-old)", upstreams: ["*"], client: { type: "claude", configDir: "~/accounts/claude-old" } },
  { id: "claude-team", title: "Claude (claude-team)", upstreams: ["*"], client: { type: "claude", configDir: "~/accounts/claude-team" } },
  { id: "codex", title: "Codex", upstreams: ["*"], client: { type: "codex" } },
  { id: "grok", title: "Grok", upstreams: ["*"], toolSeparator: "_", client: { type: "grok" } },
  { id: "muse", title: "Muse", upstreams: ["*"], client: { type: "muse" } },
  { id: "notes", title: "A phone app", upstreams: ["deepwiki"] },
];

const CODEX_BEFORE = `model = "gpt-6.1-sol"
# A comment Sam wrote
[profiles.fast]
model = "gpt-6-luna"

[mcp_servers.connectors]
url = "https://old.example/mcp"

[mcp_servers.connectors.env]
OLD = "1"

[mcp_servers.other]
command = "other-server"
args = ["--flag"]
`;

const GROK_BEFORE = `[ui]
theme = "dark"
`;

const CLAUDE_BEFORE = `${JSON.stringify({ numStartups: 5, mcpServers: { old: { type: "http", url: "https://old.example/mcp" } } }, null, 2)}\n`;

function setup() {
  const root = mkdtempSync(join(tmpdir(), "connectors-install-win-"));
  const home = join(root, "home");
  const accounts = join(home, "accounts");
  mkdirSync(join(accounts, "claude-work"), { recursive: true });
  mkdirSync(join(accounts, "claude-team"), { recursive: true });
  writeFileSync(join(home, ".claude.json"), CLAUDE_BEFORE);
  writeFileSync(join(accounts, "claude-work", ".claude.json"), CLAUDE_BEFORE);
  writeFileSync(join(accounts, "claude-team", ".claude.json"), CLAUDE_BEFORE);
  mkdirSync(join(home, ".codex"), { recursive: true });
  writeFileSync(join(home, ".codex", "config.toml"), CODEX_BEFORE);
  mkdirSync(join(home, ".grok"), { recursive: true });
  writeFileSync(join(home, ".grok", "config.toml"), GROK_BEFORE);
  mkdirSync(join(home, ".config", "muse"), { recursive: true });
  writeFileSync(join(home, ".config", "muse", "settings.json"), JSON.stringify({ schema_version: 1, tui: { x: true } }));
  const data = join(root, "data");
  const configDir = join(data, "config");
  mkdirSync(configDir, { recursive: true });
  writeFileSync(join(configDir, "agents.json"), JSON.stringify(AGENTS));
  // The MCP URL comes from the gateway's publicUrl.
  writeFileSync(
    join(configDir, "settings.json"),
    JSON.stringify({ mode: "tailscale", publicUrl: "https://gateway.example.ts.net:8443", adminLogins: ["sam@example.com"] }),
  );
  const clientDir = join(root, "client");
  const clientLog = join(root, "clients.log");

  // A clean environment: USERPROFILE pointed at the temp home, the token
  // store in a temp folder, and the stub CLIs on PATH. Windows env lookups
  // are case-insensitive but the block Node builds is not, so every key
  // this overrides is dropped from the inherited environment first.
  const baseEnv: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value === undefined) continue;
    if (/^(path|home|userprofile|appdata|localappdata|code_x_home|grok_home|connectors_.+|fake_.+|claude_config_dir)$/i.test(key)) continue;
    baseEnv[key] = value;
  }
  const systemRoot = process.env.SystemRoot ?? "C:\\Windows";
  // powershell.exe lives in System32\WindowsPowerShell\v1.0, not System32
  // itself, so it's spawned by full path and PATH carries the tools the
  // script runs (cmd.exe comes from ComSpec, icacls.exe from System32).
  const powershell = join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
  const withStubs = { ...baseEnv, PATH: `${STUBS};${systemRoot}\\System32;${systemRoot}` };
  const withoutStubs = { ...baseEnv, PATH: `${systemRoot}\\System32;${systemRoot}` };

  const run = (args: string[], extra: Record<string, string> = {}, path = withStubs) => {
    const env = {
      ...path,
      USERPROFILE: home,
      CONNECTORS_HOME: data,
      CONNECTORS_CLIENT_DIR: clientDir,
      CONNECTORS_CLI: `${process.execPath} ${join(REPO, "src", "cli.ts")} --home ${data}`,
      CONNECTORS_NODE: process.execPath,
      FAKE_CLIENT_LOG: clientLog,
      ...extra,
    };
    const result = spawnSync(powershell, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SCRIPT, ...args], {
      env,
      encoding: "utf8",
      timeout: 180000,
      // Without a console of their own, these would flash a window on the
      // desktop for every run of the script.
      windowsHide: true,
    });
    return { status: result.status, all: `${result.stdout ?? ""}${result.stderr ?? ""}` };
  };
  const tokens = () => {
    const dir = join(clientDir, "tokens");
    if (!existsSync(dir)) return new Map<string, string>();
    return new Map(
      readdirSync(dir)
        .filter((name) => name.endsWith(".token"))
        .map((name) => [name.replace(/\.token$/, ""), readFileSync(join(dir, name), "utf8").trim()]),
    );
  };
  return { root, home, data, clientDir, clientLog, run, tokens, withoutStubs };
}

const describeWin = process.platform === "win32" ? describe : describe.skip;

describeWin("install-clients.ps1", () => {
  const t = setup();
  const first = t.run([]);

  it("wires every installed client and never prints a token", () => {
    assert.equal(first.status, 0, first.all);
    const tokens = t.tokens();
    assert.deepEqual([...tokens.keys()].sort(), ["claude", "claude-team", "claude-work", "codex", "grok", "muse"]);
    for (const [agent, token] of tokens) {
      assert.match(token, new RegExp(`^cn_${agent}_[0-9a-f]{64}$`));
      assert.ok(!first.all.includes(token), `${agent}'s token was printed`);
    }
    // claude-old's folder isn't there, and notes has no client, so they get nothing.
    assert.match(first.all, /claude-old\r?\n {2}skipped: .*claude-old doesn't exist/);
    assert.match(first.all, /notes\r?\n {2}skipped: agents\.json gives notes no client/);
    assert.match(first.all, /Done: claude claude-work claude-team codex grok muse\. Skipped: claude-old notes\. Failed: none\./);
  });

  it("writes a headers helper that reads the token files", () => {
    const headers = join(t.clientDir, "headers.cmd");
    assert.ok(existsSync(headers));
    // The /S form keeps the inner quotes, so a path with spaces works;
    // windowsVerbatimArguments stops Node escaping the quotes cmd can't read.
    const printed = spawnSync("cmd.exe", ["/d", "/s", "/c", `""${headers}" codex"`], {
      env: { ...t.withoutStubs },
      encoding: "utf8",
      windowsVerbatimArguments: true,
      windowsHide: true,
    });
    assert.equal(printed.status, 0, printed.stderr);
    assert.deepEqual(JSON.parse(printed.stdout), { Authorization: `Bearer ${t.tokens().get("codex")}` });
  });

  it("adds the connectors entry to each Claude config file with headersHelper", () => {
    const headers = join(t.clientDir, "headers.cmd");
    const home = JSON.parse(readFileSync(join(t.home, ".claude.json"), "utf8"));
    assert.deepEqual(home.mcpServers.connectors, { type: "http", url: URL_, headersHelper: `${headers} claude` });
    assert.deepEqual(home.mcpServers.old, { type: "http", url: "https://old.example/mcp" });
    assert.equal(home.numStartups, 5);
    const work = JSON.parse(readFileSync(join(t.home, "accounts", "claude-work", ".claude.json"), "utf8"));
    assert.equal(work.mcpServers.connectors.headersHelper, `${headers} claude-work`);
    const team = JSON.parse(readFileSync(join(t.home, "accounts", "claude-team", ".claude.json"), "utf8"));
    assert.equal(team.mcpServers.connectors.headersHelper, `${headers} claude-team`);
    // The claude CLI was asked to list servers afterwards, once per config.
    const log = readFileSync(t.clientLog, "utf8");
    const lists = log.split(/\r?\n/).filter((line) => line.includes("claude dir=") && line.includes("mcp list"));
    assert.equal(lists.length, 3);
    assert.ok(!log.includes("cn_"));
  });

  it("replaces Codex's connectors table, keeps everything else and backs it up", () => {
    const config = readFileSync(join(t.home, ".codex", "config.toml"), "utf8");
    assert.equal(config.match(/\[mcp_servers\.connectors\]/g)?.length, 1);
    assert.ok(!config.includes("old.example"));
    assert.ok(!config.includes("[mcp_servers.connectors.env]"));
    assert.ok(config.includes('# A comment Sam wrote\n[profiles.fast]\nmodel = "gpt-6-luna"'));
    assert.ok(config.includes('[mcp_servers.other]\ncommand = "other-server"'));
    assert.ok(config.includes(`url = "${URL_}"`));
    // A TOML literal string, so the backslashes in the Windows path survive.
    assert.ok(config.includes(`http_headers_helper = '${join(t.clientDir, "headers.cmd")} codex'`));
    assert.ok(config.includes("tool_timeout_sec = 300"));
    assert.ok(!config.includes("cn_"));
    const backups = readdirSync(join(t.home, ".codex")).filter((name) => name.startsWith("config.toml.bak-connectors-"));
    assert.equal(backups.length, 1);
    assert.equal(readFileSync(join(t.home, ".codex", backups[0]!), "utf8"), CODEX_BEFORE);
  });

  it("points Grok at the token file", () => {
    const config = readFileSync(join(t.home, ".grok", "config.toml"), "utf8");
    const tokenFile = join(t.clientDir, "tokens", "grok.token");
    assert.ok(config.startsWith(GROK_BEFORE));
    assert.ok(config.includes(`[mcp_servers.connectors]\r\nurl = "${URL_}"\r\nbearer_token_file = '${tokenFile}'`));
    assert.equal(readFileSync(tokenFile, "utf8").trim(), t.tokens().get("grok"));
  });

  it("gives Muse a literal header", () => {
    const path = join(t.home, ".config", "muse", "settings.json");
    const settings = JSON.parse(readFileSync(path, "utf8"));
    assert.equal(settings.schema_version, 1);
    assert.deepEqual(settings.tui, { x: true });
    assert.deepEqual(settings.mcpServers.connectors, {
      type: "http",
      url: URL_,
      headers: { Authorization: `Bearer ${t.tokens().get("muse")}` },
    });
  });

  it("is safe to run again: same tokens, one table each", () => {
    const before = t.tokens();
    const again = t.run([]);
    assert.equal(again.status, 0, again.all);
    assert.deepEqual(t.tokens(), before);
    assert.match(again.all, /token: already there/);
    const codex = readFileSync(join(t.home, ".codex", "config.toml"), "utf8");
    assert.equal(codex.match(/\[mcp_servers\.connectors\]/g)?.length, 1);
    const grok = readFileSync(join(t.home, ".grok", "config.toml"), "utf8");
    assert.equal(grok.match(/\[mcp_servers\.connectors\]/g)?.length, 1);
    const claude = JSON.parse(readFileSync(join(t.home, ".claude.json"), "utf8"));
    assert.equal(Object.keys(claude.mcpServers).length, 2);
  });

  it("changes nothing on a dry run", () => {
    const codex = readFileSync(join(t.home, ".codex", "config.toml"), "utf8");
    const before = t.tokens();
    const dry = t.run(["-DryRun", "-Rotate"]);
    assert.equal(dry.status, 0, dry.all);
    assert.match(dry.all, /Dry run: nothing changed\./);
    assert.equal(readFileSync(join(t.home, ".codex", "config.toml"), "utf8"), codex);
    assert.deepEqual(t.tokens(), before);
  });

  it("rotates tokens on the gateway and in the token files", () => {
    const before = t.tokens();
    const rotated = t.run(["-Rotate", "-Only", "codex,grok"]);
    assert.equal(rotated.status, 0, rotated.all);
    const after = t.tokens();
    assert.notEqual(after.get("codex"), before.get("codex"));
    assert.notEqual(after.get("grok"), before.get("grok"));
    assert.equal(after.get("muse"), before.get("muse"));
    assert.equal(readFileSync(join(t.clientDir, "tokens", "grok.token"), "utf8").trim(), after.get("grok"));
    const secrets = JSON.parse(readFileSync(join(t.data, "secrets", "agents.json"), "utf8"));
    assert.ok(secrets.agents.codex.rotatedAt);
  });

  it("replaces the gateway's token when this machine lost its copy", () => {
    rmSync(join(t.clientDir, "tokens", "muse.token"));
    const again = t.run(["-Only", "muse"]);
    assert.equal(again.status, 0, again.all);
    assert.match(again.all, /The gateway already has a token for muse that this machine doesn't; replacing it/);
    assert.match(t.tokens().get("muse") ?? "", /^cn_muse_/);
  });

  it("puts Codex's config back when Codex rejects it", () => {
    const u = setup();
    const result = u.run(["-Only", "codex"], { FAKE_CODEX_REJECT: "1" });
    assert.notEqual(result.status, 0);
    assert.match(result.all, /Codex didn't accept the new config/);
    assert.equal(readFileSync(join(u.home, ".codex", "config.toml"), "utf8"), CODEX_BEFORE);
  });

  it("refuses a connectors entry it can't edit safely", () => {
    const u = setup();
    const inline = `${CODEX_BEFORE}\n[mcp_servers]\nconnectors = { url = "x" }\n`;
    writeFileSync(join(u.home, ".codex", "config.toml"), inline);
    const result = u.run(["-Only", "codex"]);
    assert.equal(result.status, 1);
    assert.match(result.all, /sets connectors in a form this script doesn't edit/);
    assert.ok(!result.all.includes("Codex: [mcp_servers.connectors] set"));
    assert.match(result.all, /Failed: codex\./);
    assert.equal(readFileSync(join(u.home, ".codex", "config.toml"), "utf8"), inline);
  });

  it("says Codex failed, not that it's wired, when it refuses an edit and codex isn't on PATH", () => {
    const u = setup();
    const inline = `${CODEX_BEFORE}\n[mcp_servers]\nconnectors = { url = "x" }\n`;
    writeFileSync(join(u.home, ".codex", "config.toml"), inline);
    const result = u.run(["-Only", "codex"], {}, u.withoutStubs);
    assert.equal(result.status, 1, result.all);
    assert.ok(!result.all.includes("Codex: [mcp_servers.connectors] set"));
    assert.equal(readFileSync(join(u.home, ".codex", "config.toml"), "utf8"), inline);
  });

  it("refuses Grok's inline form without writing anything, and still wires the others", () => {
    const u = setup();
    const inline = `${GROK_BEFORE}\n[mcp_servers]\nconnectors = { url = "x" }\n`;
    writeFileSync(join(u.home, ".grok", "config.toml"), inline);
    const result = u.run(["-Only", "grok,muse"]);
    assert.equal(result.status, 1, result.all);
    assert.match(result.all, /sets connectors in a form this script doesn't edit/);
    assert.ok(!result.all.includes("Grok: [mcp_servers.connectors] set"));
    assert.equal(readFileSync(join(u.home, ".grok", "config.toml"), "utf8"), inline);
    assert.ok(!existsSync(join(u.clientDir, "tokens", "grok.token")));
    assert.ok(!u.tokens().has("grok"), "a token was minted for a config that can't be wired");
    // Muse came after Grok and was still wired.
    assert.match(result.all, /Muse: mcpServers\.connectors set/);
    assert.match(result.all, /Done: muse\. Skipped: none\. Failed: grok\./);
  });

  it("puts Grok's config back when Grok can't read it", () => {
    const u = setup();
    const result = u.run(["-Only", "grok"], { FAKE_GROK_REJECT: "1" });
    assert.equal(result.status, 1, result.all);
    assert.match(result.all, /Grok didn't accept the new config/);
    assert.equal(readFileSync(join(u.home, ".grok", "config.toml"), "utf8"), GROK_BEFORE);
  });

  it("leaves a Muse settings file that isn't plain JSON alone, with a clear message", () => {
    const u = setup();
    const jsonc = '{\n  // Sam\'s comment\n  "schema_version": 1\n}\n';
    writeFileSync(join(u.home, ".config", "muse", "settings.json"), jsonc);
    const result = u.run(["-Only", "muse"]);
    assert.equal(result.status, 1, result.all);
    assert.match(result.all, /settings\.json isn't plain JSON .*change it by hand/);
    assert.ok(!result.all.includes("Muse: mcpServers.connectors set"));
    assert.equal(readFileSync(join(u.home, ".config", "muse", "settings.json"), "utf8"), jsonc);
    assert.ok(!u.tokens().has("muse"));
  });

  it("mints no token for a client that isn't on this machine", () => {
    const u = setup();
    rmSync(join(u.home, ".grok"), { recursive: true });
    rmSync(join(u.home, ".config", "muse"), { recursive: true });
    const result = u.run(["-Only", "codex,grok,muse"], {}, u.withoutStubs);
    assert.equal(result.status, 0, result.all);
    assert.deepEqual([...u.tokens().keys()], ["codex"]);
    assert.match(result.all, /grok\r?\n {2}skipped: grok isn't installed/);
    assert.match(result.all, /Skipped: grok muse\./);
    const secrets = JSON.parse(readFileSync(join(u.data, "secrets", "agents.json"), "utf8"));
    assert.deepEqual(Object.keys(secrets.agents), ["codex"]);
  });

  it("takes everything out again with -Remove", () => {
    const removed = t.run(["-Remove"]);
    assert.equal(removed.status, 0, removed.all);
    assert.equal(t.tokens().size, 0);
    const codex = readFileSync(join(t.home, ".codex", "config.toml"), "utf8");
    assert.ok(!codex.includes("connectors"));
    assert.ok(codex.includes("[mcp_servers.other]"));
    assert.ok(!readFileSync(join(t.home, ".grok", "config.toml"), "utf8").includes("connectors"));
    assert.ok(!existsSync(join(t.clientDir, "tokens", "grok.token")));
    const muse = JSON.parse(readFileSync(join(t.home, ".config", "muse", "settings.json"), "utf8"));
    assert.equal(muse.mcpServers, undefined);
    const claude = JSON.parse(readFileSync(join(t.home, ".claude.json"), "utf8"));
    assert.equal(claude.mcpServers.connectors, undefined);
    assert.deepEqual(claude.mcpServers.old, { type: "http", url: "https://old.example/mcp" });
  });
});
