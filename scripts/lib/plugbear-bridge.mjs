// A stdio bridge to the gateway's HTTP MCP endpoint, for clients that only
// speak stdio (TeleAgent's tool settings, for one). Runs as
//   node plugbear-bridge.mjs
// with PLUGBEAR_URL (default http://127.0.0.1:8795/mcp) and PLUGBEAR_TOKEN
// in the environment; the token never touches a command line, so no quoting
// can mangle it on the way through cmd.exe or npx.
//
// The gateway speaks streamable HTTP with a bearer token; this process is a
// plain pipe: stdio JSON-RPC in front, the SDK's HTTP client behind.

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  PingRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const url = process.env.PLUGBEAR_URL ?? "http://127.0.0.1:8795/mcp";
const token = process.env.PLUGBEAR_TOKEN;
if (!token) {
  process.stderr.write("plugbear-bridge: PLUGBEAR_TOKEN is not set\n");
  process.exit(2);
}

const client = new Client({ name: "plugbear-bridge", version: "1.0.0" });
await client.connect(
  new StreamableHTTPClientTransport(new URL(url), {
    requestInit: { headers: { Authorization: `Bearer ${token}` } },
  }),
);

const server = new Server({ name: "plugbear-bridge", version: "1.0.0" }, { capabilities: { tools: {} } });

server.setRequestHandler(PingRequestSchema, async () => ({}));

server.setRequestHandler(ListToolsRequestSchema, async () => {
  const result = await client.listTools();
  return { tools: result.tools };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const result = await client.callTool({
    name: request.params.name,
    arguments: request.params.arguments,
  });
  return result;
});

await server.connect(new StdioServerTransport());
process.stderr.write(`plugbear-bridge: proxying ${url}\n`);
