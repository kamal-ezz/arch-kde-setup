import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Markdown, Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";

const MAX_CHARS = 12000;

function truncate(text: string, maxChars = MAX_CHARS): { text: string; truncated: boolean } {
  if (text.length <= maxChars) return { text, truncated: false };
  return {
    text: `${text.slice(0, maxChars)}\n\n[truncated ${text.length - maxChars} chars]`,
    truncated: true,
  };
}

function stripHtml(html: string): string {
  return html
    .replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, " ")
    .replace(/<style\b[^<]*(?:(?!<\/style>)<[^<]*)*<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
}

async function doFetch(url: string, userAgent?: string): Promise<Response> {
  return fetch(url, {
    headers: {
      "user-agent": userAgent || "pi-web-extension/0.1",
      accept: "text/html,application/json,text/plain;q=0.9,*/*;q=0.8",
    },
  });
}

async function braveSearch(query: string, count: number): Promise<any[]> {
  const apiKey = process.env.BRAVE_SEARCH_API_KEY;
  if (!apiKey) throw new Error("BRAVE_SEARCH_API_KEY is not set");

  const url = new URL("https://api.search.brave.com/res/v1/web/search");
  url.searchParams.set("q", query);
  url.searchParams.set("count", String(count));

  const response = await fetch(url, {
    headers: {
      Accept: "application/json",
      "X-Subscription-Token": apiKey,
      "User-Agent": "pi-web-extension/0.1",
    },
  });

  if (!response.ok) {
    throw new Error(`Brave search failed: ${response.status} ${response.statusText}`);
  }

  const data = (await response.json()) as any;
  return Array.isArray(data?.web?.results) ? data.web.results : [];
}

async function ddgSearch(query: string, count: number): Promise<any[]> {
  const url = new URL("https://html.duckduckgo.com/html/");
  url.searchParams.set("q", query);

  const response = await doFetch(url.toString(), "Mozilla/5.0 pi-web-extension");
  if (!response.ok) {
    throw new Error(`DuckDuckGo search failed: ${response.status} ${response.statusText}`);
  }

  const html = await response.text();
  const matches = [...html.matchAll(/<a[^>]+class=\"result__a\"[^>]+href=\"([^\"]+)\"[^>]*>(.*?)<\/a>/g)];
  return matches.slice(0, count).map((match) => ({
    url: match[1],
    title: stripHtml(match[2]),
    description: "",
  }));
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "web_fetch",
    label: "Web Fetch",
    description: "Fetch a URL and return cleaned text content. Best for documentation pages, articles, and web content.",
    promptSnippet: "Fetch a web page and extract readable text.",
    promptGuidelines: [
      "Use web_fetch when the user needs contents from a specific URL.",
    ],
    parameters: Type.Object({
      url: Type.String({ description: "The URL to fetch" }),
      raw: Type.Optional(Type.Boolean({ description: "Return raw HTML instead of extracted text", default: false })),
    }),
    async execute(_toolCallId, params) {
      const response = await doFetch(params.url);
      if (!response.ok) {
        throw new Error(`Fetch failed: ${response.status} ${response.statusText}`);
      }

      const contentType = response.headers.get("content-type") || "";
      const body = await response.text();
      const text = params.raw || !contentType.includes("html") ? body : stripHtml(body);
      const truncated = truncate(text);

      return {
        content: [{ type: "text", text: truncated.text }],
        details: {
          url: params.url,
          contentType,
          raw: params.raw || false,
          truncated: truncated.truncated,
          text: truncated.text,
        },
      };
    },
    renderCall(args, theme) {
      return new Text(
        `${theme.fg("toolTitle", theme.bold("web_fetch "))}${theme.fg("accent", args.url)}`,
        0,
        0,
      );
    },
    renderResult(result, { expanded }, _theme) {
      const details = result.details as { text?: string } | undefined;
      const text = details?.text || result.content.filter((x: any) => x.type === "text").map((x: any) => x.text).join("\n\n");
      if (expanded) return new Markdown(text, 0, 0);
      return new Text(text.slice(0, 500), 0, 0);
    },
  });

  pi.registerTool({
    name: "web_search",
    label: "Web Search",
    description: "Search the web. Uses Brave Search if BRAVE_SEARCH_API_KEY is set, otherwise falls back to DuckDuckGo HTML scraping.",
    promptSnippet: "Search the web for current information or external documentation.",
    promptGuidelines: [
      "Use web_search when the user asks for external information not in the repo.",
    ],
    parameters: Type.Object({
      query: Type.String({ description: "Search query" }),
      count: Type.Optional(Type.Number({ description: "Max results", default: 5 })),
    }),
    async execute(_toolCallId, params) {
      const count = Math.max(1, Math.min(10, Math.floor(params.count || 5)));
      const engine = process.env.BRAVE_SEARCH_API_KEY ? "brave" : "duckduckgo";
      const results = engine === "brave" ? await braveSearch(params.query, count) : await ddgSearch(params.query, count);

      const lines = results.slice(0, count).map((item, index) => {
        const url = item.url || item.link || item.href || "";
        const title = item.title || item.name || url;
        const desc = item.description || item.snippet || item.extra_snippets?.join(" ") || "";
        return `${index + 1}. ${title}\n${url}${desc ? `\n${desc}` : ""}`;
      });

      const text = lines.length ? lines.join("\n\n") : "No results.";
      return {
        content: [{ type: "text", text }],
        details: {
          engine,
          query: params.query,
          count,
          results: results.slice(0, count),
        },
      };
    },
    renderCall(args, theme) {
      return new Text(
        `${theme.fg("toolTitle", theme.bold("web_search "))}${theme.fg("accent", args.query)}`,
        0,
        0,
      );
    },
    renderResult(result, { expanded }, _theme) {
      const text = result.content.filter((x: any) => x.type === "text").map((x: any) => x.text).join("\n\n");
      return new Text(expanded ? text : text.slice(0, 700), 0, 0);
    },
  });

  pi.registerCommand("web", {
    description: "Show web extension status",
    handler: async (_args, ctx) => {
      ctx.ui.notify(
        `web tools ready (${process.env.BRAVE_SEARCH_API_KEY ? "brave + fetch" : "duckduckgo + fetch"})`,
        "info",
      );
    },
  });
}
