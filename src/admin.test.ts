import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { approvalPage } from "./admin.ts";
import type { ApprovalRecord } from "./db.ts";

function record(upstreamTool: string, args: unknown): ApprovalRecord {
  return {
    id: "ap_test",
    agent: "codex",
    upstream: "gmail",
    tool: `gmail__${upstreamTool}`,
    upstreamTool,
    argsJson: JSON.stringify(args),
    status: "pending",
    createdAt: 1_000,
    expiresAt: 10_000_000,
    decidedAt: null,
    note: null,
  } as unknown as ApprovalRecord;
}

const render = (upstreamTool: string, args: unknown) =>
  approvalPage({ record: record(upstreamTool, args), agentTitle: "Codex", upstreamTitle: "Gmail", csrf: "x", now: 2_000 });

describe("approval page arguments", () => {
  it("shows a held email as an email, body with real line breaks", () => {
    const page = render("send_message", {
      to: ["Ana <ana@example.com>", "sam@example.com"],
      cc: ["lee@example.com"],
      subject: "Committee <list>",
      body: "Hi Ana,\n\nSee you Tuesday.\n<b>Sam</b>",
    });
    assert.match(page, /<dt>To<\/dt><dd>Ana &lt;ana@example.com&gt;, sam@example.com<\/dd>/);
    assert.match(page, /<dt>Cc<\/dt><dd>lee@example.com<\/dd>/);
    assert.ok(!page.includes("<dt>Bcc</dt>"));
    assert.match(page, /<dt>Subject<\/dt><dd>Committee &lt;list&gt;<\/dd>/);
    assert.match(page, /<div class="text body">Hi Ana,\n\nSee you Tuesday.\n&lt;b&gt;Sam&lt;\/b&gt;<\/div>/);
    // The exact JSON is still there, behind the toggle.
    assert.match(page, /<details class="raw"><summary>Raw arguments<\/summary><pre>/);
    assert.match(page, /&quot;body&quot;: &quot;Hi Ana,\\n\\nSee you/);
  });

  it("falls back to generic rows when an email has an argument it doesn't know", () => {
    const page = render("create_draft", { to: ["ana@example.com"], body: "hi", attachment: { name: "x" } });
    assert.ok(!page.includes('class="card email"'));
    assert.match(page, /<dt><code>attachment<\/code><\/dt><dd><pre>\{\n  &quot;name&quot;: &quot;x&quot;\n\}<\/pre>/);
  });

  it("shows other tools' string arguments unescaped, and empty ones as empty", () => {
    const page = render("create_page", { title: "", content: "line one\nline two" });
    assert.match(page, /<dt><code>title<\/code><\/dt><dd><span class="muted">\(empty\)<\/span>/);
    assert.match(page, /<div class="text">line one\nline two<\/div>/);
  });

  it("keeps plain JSON for arguments that aren't an object", () => {
    const page = render("weird", [1, 2]);
    assert.ok(!page.includes("Raw arguments"));
    assert.match(page, /<pre>\[\n  1,\n  2\n\]<\/pre>/);
  });
});
