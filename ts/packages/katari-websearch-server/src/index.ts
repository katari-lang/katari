import { startServer } from "katari-protocol";
import type { AgentHandlerFn, JsonValue } from "katari-protocol";

interface SearchResult {
  title: string;
  snippet: string;
  url: string;
}

const search: AgentHandlerFn = async (args) => {
  const a = args as Record<string, JsonValue>;
  const query = a.query as string;

  const apiKey = process.env.TAVILY_API_KEY;
  if (!apiKey) {
    throw new Error("TAVILY_API_KEY must be set");
  }

  const res = await fetch("https://api.tavily.com/search", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      query,
      max_results: 5,
      search_depth: "basic",
    }),
  });

  if (!res.ok) {
    throw new Error(`Tavily API error: ${res.status} ${await res.text()}`);
  }

  const data = (await res.json()) as {
    results?: { title: string; content: string; url: string }[];
  };

  const results: SearchResult[] = (data.results ?? []).map((item) => ({
    title: item.title,
    snippet: item.content,
    url: item.url,
  }));

  return results as unknown as JsonValue;
};

const port = parseInt(process.env.PORT ?? "8004", 10);
const endpoint = process.env.KATARI_BASE_URL ?? `http://localhost:${port}`;
const databaseUrl = process.env.DATABASE_URL;

startServer({
  port,
  endpoint,
  databaseUrl,
  agentDefs: {
    search: { handler: search, description: "Search the web using Tavily" },
  },
});
