// `katari-mcp list-tools` — connect to one MCP server, list its tools, and emit the listing JSON
// that `katari mcp pull` code-generates typed bindings from. The connection mirrors the runtime
// transport's shape (streamable HTTP first, one fallback to HTTP+SSE, so both generations of servers
// answer the same `--url`), and auth mirrors the program surface: explicit `--header k=v` pairs ride
// on every request, `--oauth` runs the OAuth authorization flow (`performLogin`) — but the credential
// stays IN MEMORY: a pull is a dev-time read, so nothing is stored anywhere.

import type { OAuthClientProvider } from "@modelcontextprotocol/sdk/client/auth.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { SSEClientTransport } from "@modelcontextprotocol/sdk/client/sse.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type {
  OAuthClientInformationMixed,
  OAuthClientMetadata,
  OAuthTokens,
} from "@modelcontextprotocol/sdk/shared/auth.js";
import { type LoginCallbacks, type McpLoginCredential, performLogin } from "./index.js";

export interface ListToolsArguments {
  url: string;
  headers: Record<string, string>;
  oauth: boolean;
  scope?: string;
}

/** Parse `list-tools`'s argv (everything after the subcommand). Throws with a usage message on
 *  anything unexpected — the CLI maps that to exit 2, keeping "mis-invoked" distinct from "the
 *  listing failed". Unlike `login`'s parser this one walks flag by flag, because `--oauth` is a
 *  bare switch while the others carry values. */
export function parseListToolsArguments(argv: string[]): ListToolsArguments {
  let url: string | undefined;
  let scope: string | undefined;
  let oauth = false;
  const headers: Record<string, string> = {};
  let index = 0;
  while (index < argv.length) {
    const flag = argv[index];
    switch (flag) {
      case "--oauth":
        oauth = true;
        index += 1;
        break;
      case "--url":
      case "--scope":
      case "--header": {
        const value = argv[index + 1];
        if (value === undefined) {
          throw new Error(`${flag} requires a value`);
        }
        if (flag === "--url") url = value;
        else if (flag === "--scope") scope = value;
        else {
          const separator = value.indexOf("=");
          if (separator <= 0) {
            throw new Error(`--header expects key=value, got: ${value}`);
          }
          headers[value.slice(0, separator)] = value.slice(separator + 1);
        }
        index += 2;
        break;
      }
      default:
        throw new Error(`unknown argument: ${flag ?? ""}`);
    }
  }
  if (url === undefined || url === "") {
    throw new Error("--url <server> is required");
  }
  // Auth is a sum, not a bag: a server authenticates with explicit headers OR an OAuth credential,
  // never both — accepting both would silently drop one, so reject the combination outright.
  if (oauth && Object.keys(headers).length > 0) {
    throw new Error("--header and --oauth cannot be combined (auth is one or the other)");
  }
  if (scope !== undefined && !oauth) {
    throw new Error("--scope only applies together with --oauth");
  }
  const base: ListToolsArguments = { url, headers, oauth };
  return scope === undefined ? base : { ...base, scope };
}

/** One listed tool, as `katari mcp pull` consumes it: the server-declared name / description and the
 *  schemas as plain JSON Schema documents (passed through verbatim — the CLI's decoder is the
 *  authority on which subset it understands). */
export interface ListedTool {
  name: string;
  description: string;
  inputSchema: unknown;
  outputSchema?: unknown;
}

export interface ToolListing {
  tools: ListedTool[];
}

/** The `--oauth` provider: the freshly performed login's credential, held in memory only. Reaching
 *  the interactive step again mid-listing means the just-issued tokens were rejected — surface that
 *  instead of looping the browser flow. */
class InMemoryCredentialProvider implements OAuthClientProvider {
  private credential: McpLoginCredential;

  constructor(credential: McpLoginCredential) {
    this.credential = credential;
  }

  /** No redirect target exists after the login round; `undefined` marks the flow non-interactive. */
  get redirectUrl(): undefined {
    return undefined;
  }

  /** Only consulted for dynamic registration, which never re-runs here (the login round already
   *  registered the client); minimal but well-formed metadata in case a server inspects it. */
  get clientMetadata(): OAuthClientMetadata {
    return {
      client_name: "katari-mcp",
      redirect_uris: [],
      grant_types: ["refresh_token"],
      token_endpoint_auth_method: "none",
    };
  }

  clientInformation(): OAuthClientInformationMixed {
    return this.credential.clientInformation;
  }

  saveClientInformation(clientInformation: OAuthClientInformationMixed): void {
    this.credential = { ...this.credential, clientInformation };
  }

  tokens(): OAuthTokens {
    return this.credential.tokens;
  }

  saveTokens(tokens: OAuthTokens): void {
    this.credential = { ...this.credential, tokens };
  }

  redirectToAuthorization(): never {
    throw new Error("the server rejected the freshly authorized credential");
  }

  saveCodeVerifier(): never {
    throw new Error("the PKCE steps belong to the login round, which already completed");
  }

  codeVerifier(): never {
    throw new Error("the PKCE steps belong to the login round, which already completed");
  }
}

/** Connect to the server, list its tools, and return the listing. `--oauth` first runs the shared
 *  interactive login flow (`performLogin`) and keeps the credential in memory for this one
 *  connection; explicit headers ride on every request otherwise. */
export async function performListTools(
  { url, headers, oauth, scope }: ListToolsArguments,
  callbacks: LoginCallbacks,
): Promise<ToolListing> {
  const options: { requestInit?: RequestInit; authProvider?: OAuthClientProvider } = {};
  if (oauth) {
    const credential = await performLogin(
      scope === undefined ? { url } : { url, scope },
      callbacks,
    );
    options.authProvider = new InMemoryCredentialProvider(credential);
  } else if (Object.keys(headers).length > 0) {
    options.requestInit = { headers };
  }

  const connect = async (kind: "streamable" | "sse"): Promise<Client> => {
    const client = new Client({ name: "katari-mcp", version: "0.1.0" });
    const target = new URL(url);
    await client.connect(
      kind === "streamable"
        ? new StreamableHTTPClientTransport(target, options)
        : new SSEClientTransport(target, options),
    );
    return client;
  };
  // Streamable HTTP first, one fallback to HTTP+SSE; both failing reports the streamable error (the
  // current protocol's) — the same order the runtime transport connects with.
  let client: Client;
  try {
    client = await connect("streamable");
  } catch (streamableError) {
    try {
      client = await connect("sse");
    } catch {
      throw streamableError;
    }
  }
  try {
    const { tools } = await client.listTools();
    return {
      tools: tools.map((tool) => ({
        name: tool.name,
        description: tool.description ?? "",
        inputSchema: tool.inputSchema ?? {},
        ...(tool.outputSchema !== undefined ? { outputSchema: tool.outputSchema } : {}),
      })),
    };
  } finally {
    await client.close();
  }
}
