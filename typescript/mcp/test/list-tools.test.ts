// Tests for `list-tools`: the argv seam (what exit-2 usage errors guard) and the listing itself
// against a REAL loopback MCP server (the SDK's stateless streamable-HTTP shape, mirroring the
// runtime's mcp-integration test) — pinning that the emitted JSON carries exactly what `katari mcp
// pull` consumes (name / description / inputSchema / outputSchema when declared) and that `--header`
// pairs ride on the actual HTTP requests. The `--oauth` path shares `performLogin`, whose seams are
// covered by login.test.ts; a full IdP round needs a browser and is exercised by hand.

import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { z } from "zod";
import { parseListToolsArguments, performListTools } from "../src/list-tools.js";

describe("parseListToolsArguments", () => {
  test("parses --url alone (anonymous access, no headers)", () => {
    expect(parseListToolsArguments(["--url", "https://mcp.example.test/mcp"])).toEqual({
      url: "https://mcp.example.test/mcp",
      headers: {},
      oauth: false,
    });
  });

  test("collects repeated --header pairs and splits on the first =", () => {
    expect(
      parseListToolsArguments([
        "--url",
        "https://mcp.example.test/mcp",
        "--header",
        "authorization=Bearer a=b",
        "--header",
        "x-tenant=acme",
      ]),
    ).toEqual({
      url: "https://mcp.example.test/mcp",
      headers: { authorization: "Bearer a=b", "x-tenant": "acme" },
      oauth: false,
    });
  });

  test("parses --oauth with --scope", () => {
    expect(
      parseListToolsArguments(["--url", "https://x.test/mcp", "--oauth", "--scope", "repo"]),
    ).toEqual({ url: "https://x.test/mcp", headers: {}, oauth: true, scope: "repo" });
  });

  test("rejects a missing --url, a bare --scope, a malformed header, unknown flags", () => {
    expect(() => parseListToolsArguments([])).toThrowError(/--url/);
    expect(() => parseListToolsArguments(["--url", "u", "--scope", "s"])).toThrowError(/--oauth/);
    expect(() => parseListToolsArguments(["--url", "u", "--header", "novalue"])).toThrowError(
      /key=value/,
    );
    expect(() => parseListToolsArguments(["--url", "u", "--nope"])).toThrowError(
      /unknown argument/,
    );
    expect(() => parseListToolsArguments(["--url"])).toThrowError(/requires a value/);
  });
});

describe("performListTools against a loopback MCP server", () => {
  let httpServer: Server;
  let url = "";
  const seenAuthorizationHeaders: Array<string | undefined> = [];

  function readBody(request: IncomingMessage): Promise<unknown> {
    return new Promise((resolve, reject) => {
      let raw = "";
      request.setEncoding("utf8");
      request.on("data", (chunk: string) => {
        raw += chunk;
      });
      request.on("end", () => {
        try {
          resolve(raw === "" ? undefined : JSON.parse(raw));
        } catch (error) {
          reject(error instanceof Error ? error : new Error(String(error)));
        }
      });
      request.on("error", reject);
    });
  }

  beforeAll(async () => {
    // A stateless streamable-HTTP MCP server: a fresh server + transport per request (the same
    // shape the runtime's integration test drives).
    httpServer = createServer((request, response) => {
      void (async () => {
        seenAuthorizationHeaders.push(request.headers.authorization);
        const mcp = new McpServer({ name: "list-tools-test", version: "1.0.0" });
        mcp.registerTool(
          "add",
          {
            description: "Adds two integers.",
            inputSchema: { x: z.number(), y: z.number() },
            outputSchema: { sum: z.number() },
          },
          ({ x, y }) => ({
            content: [],
            structuredContent: { sum: x + y },
          }),
        );
        mcp.registerTool("ping", {}, () => ({ content: [{ type: "text", text: "pong" }] }));
        const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
        response.on("close", () => {
          void transport.close();
          void mcp.close();
        });
        await mcp.connect(transport);
        await transport.handleRequest(request, response, await readBody(request));
      })().catch(() => {
        if (!response.headersSent) response.writeHead(500).end();
      });
    });
    await new Promise<void>((resolve) => httpServer.listen(0, "127.0.0.1", resolve));
    const address: AddressInfo | string | null = httpServer.address();
    if (address === null || typeof address === "string") {
      throw new Error("the loopback server has no port");
    }
    url = `http://127.0.0.1:${address.port}/mcp`;
  });

  afterAll(async () => {
    await new Promise<void>((resolve) => {
      httpServer.closeAllConnections();
      httpServer.close(() => resolve());
    });
  });

  test("lists the tools with their schemas (outputSchema only where declared)", async () => {
    const listing = await performListTools(
      { url, headers: {}, oauth: false },
      { log: () => {} },
    );
    const names = listing.tools.map((tool) => tool.name).sort();
    expect(names).toEqual(["add", "ping"]);

    const add = listing.tools.find((tool) => tool.name === "add");
    if (add === undefined) throw new Error("add tool missing from the listing");
    expect(add.description).toBe("Adds two integers.");
    expect(add.inputSchema).toMatchObject({
      type: "object",
      properties: { x: { type: "number" }, y: { type: "number" } },
      required: ["x", "y"],
    });
    expect(add.outputSchema).toMatchObject({
      type: "object",
      properties: { sum: { type: "number" } },
    });

    const ping = listing.tools.find((tool) => tool.name === "ping");
    if (ping === undefined) throw new Error("ping tool missing from the listing");
    expect(ping.description).toBe("");
    expect("outputSchema" in ping).toBe(false);

    // The emitted JSON is exactly the listing (what the CLI's stdout carries).
    const decoded: unknown = JSON.parse(JSON.stringify(listing));
    expect(decoded).toEqual(listing);
  });

  test("--header pairs ride on the actual HTTP requests", async () => {
    seenAuthorizationHeaders.length = 0;
    await performListTools(
      { url, headers: { authorization: "Bearer sk-list" }, oauth: false },
      { log: () => {} },
    );
    expect(seenAuthorizationHeaders.length).toBeGreaterThan(0);
    for (const header of seenAuthorizationHeaders) {
      expect(header).toBe("Bearer sk-list");
    }
  });
});
