import { startServer } from "katari-protocol";
import type { AgentHandlerFn, JsonValue } from "katari-protocol";

interface SearchResult {
  title: string;
  snippet: string;
  url: string;
}

const search: AgentHandlerFn = async (args) => {
  const query = args[0] as string;

  const apiKey = process.env.SEARCH_API_KEY;
  const engineId = process.env.SEARCH_ENGINE_ID;

  if (!apiKey || !engineId) {
    throw new Error("SEARCH_API_KEY and SEARCH_ENGINE_ID must be set");
  }

  const url = new URL("https://www.googleapis.com/customsearch/v1");
  url.searchParams.set("key", apiKey);
  url.searchParams.set("cx", engineId);
  url.searchParams.set("q", query);
  url.searchParams.set("num", "5");

  const res = await fetch(url.toString());
  if (!res.ok) {
    throw new Error(`Search API error: ${res.status} ${await res.text()}`);
  }

  const data = await res.json();
  const items = (data as { items?: { title: string; snippet: string; link: string }[] }).items ?? [];

  const results: SearchResult[] = items.map((item) => ({
    title: item.title,
    snippet: item.snippet,
    url: item.link,
  }));

  return results as unknown as JsonValue;
};

const port = parseInt(process.env.PORT ?? "8004", 10);
const selfBaseUrl = process.env.KATARI_BASE_URL ?? `http://localhost:${port}/katari`;

startServer({
  port,
  selfBaseUrl,
  handlers: { search },
});
