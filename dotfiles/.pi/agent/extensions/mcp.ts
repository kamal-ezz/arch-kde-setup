import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Markdown, Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";

type McpServerConfig = {
  command: string;
  args?: string[];
  cwd?: string;
  env?: Record<string, string>;
  disabled?: boolean;
};

type McpConfig = {
  servers?: Record<string, McpServerConfig>;
};

type JsonRpcResponse = {
  jsonrpc: "2.0";
  id?: number;
  result?: any;
  error?: { code: number; message: string };
};

type McpTool = {
  name: string;
  description?: string;
  inputSchema?: Record<string, unknown>;
};

type McpResource = {
  uri: string;
  name?: string;
  description?: string;
  mimeType?: string;
};

type McpServerRuntime = {
  name: string;
  config: McpServerConfig;
  proc: ChildProcessWithoutNullStreams;
  buffer: string;
  nextId: number;
  pending: Map<number, { resolve: (value: any) => void; reject: (reason?: unknown) => void }>;
  tools: McpTool[];
  resources: McpResource[];
  initialized: boolean;
};

type ServerStatus = {
  configured: boolean;
  disabled: boolean;
  initialized: boolean;
  tools: number;
  resources: number;
  error?: string;
  configSource?: string;
};

type ConfigReadResult = {
  config: McpConfig;
  sources: Record<string, string>;
  files: string[];
  parseErrors: string[];
};

function getGlobalConfigPath(): string {
  return path.join(process.env.HOME || "", ".pi", "agent", "mcp.json");
}

function getProjectConfigPath(cwd: string): string {
  return path.join(cwd, ".pi", "mcp.json");
}

function findProjectConfig(cwd: string): string | null {
  let current = cwd;
  while (true) {
    const candidate = path.join(current, ".pi", "mcp.json");
    if (fs.existsSync(candidate)) return candidate;
    const parent = path.dirname(current);
    if (parent === current) return null;
    current = parent;
  }
}

function readConfig(cwd: string): ConfigReadResult {
  const files = [getGlobalConfigPath(), findProjectConfig(cwd)].filter(Boolean) as string[];
  const sources: Record<string, string> = {};
  const parseErrors: string[] = [];
  let merged: McpConfig = { servers: {} };

  for (const file of files) {
    try {
      if (!fs.existsSync(file)) continue;
      const data = JSON.parse(fs.readFileSync(file, "utf8")) as McpConfig;
      for (const name of Object.keys(data.servers || {})) sources[name] = file;
      merged = { servers: { ...(merged.servers || {}), ...(data.servers || {}) } };
    } catch (error) {
      parseErrors.push(`${file}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  return { config: merged, sources, files, parseErrors };
}

function readConfigFile(file: string): McpConfig {
  if (!fs.existsSync(file)) return { servers: {} };
  const data = JSON.parse(fs.readFileSync(file, "utf8")) as McpConfig;
  return { servers: { ...(data.servers || {}) } };
}

function writeConfigFile(file: string, config: McpConfig) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify({ servers: config.servers || {} }, null, 2)}\n`, "utf8");
}

function writeFrame(proc: ChildProcessWithoutNullStreams, payload: unknown) {
  const json = JSON.stringify(payload);
  proc.stdin.write(`Content-Length: ${Buffer.byteLength(json, "utf8")}\r\n\r\n${json}`);
}

function parseFrames(runtime: McpServerRuntime, chunk: string, onMessage: (message: JsonRpcResponse) => void) {
  runtime.buffer += chunk;
  while (true) {
    const headerEnd = runtime.buffer.indexOf("\r\n\r\n");
    if (headerEnd === -1) return;
    const header = runtime.buffer.slice(0, headerEnd);
    const match = header.match(/Content-Length:\s*(\d+)/i);
    if (!match) {
      runtime.buffer = "";
      return;
    }
    const length = Number(match[1]);
    const bodyStart = headerEnd + 4;
    if (runtime.buffer.length < bodyStart + length) return;
    const body = runtime.buffer.slice(bodyStart, bodyStart + length);
    runtime.buffer = runtime.buffer.slice(bodyStart + length);
    try {
      onMessage(JSON.parse(body));
    } catch {
      // ignore parse errors
    }
  }
}

function createServerRuntime(name: string, config: McpServerConfig, cwd: string): McpServerRuntime {
  const proc = spawn(config.command, config.args ?? [], {
    cwd: config.cwd || cwd,
    env: { ...process.env, ...(config.env ?? {}) },
    stdio: ["pipe", "pipe", "pipe"],
  });

  const runtime: McpServerRuntime = {
    name,
    config,
    proc,
    buffer: "",
    nextId: 1,
    pending: new Map(),
    tools: [],
    resources: [],
    initialized: false,
  };

  proc.stdout.setEncoding("utf8");
  proc.stdout.on("data", (chunk: string) => {
    parseFrames(runtime, chunk, (message) => {
      if (typeof message.id !== "number") return;
      const pending = runtime.pending.get(message.id);
      if (!pending) return;
      runtime.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message));
      else pending.resolve(message.result);
    });
  });

  proc.on("exit", () => {
    for (const [, pending] of runtime.pending) pending.reject(new Error(`MCP server ${name} exited`));
    runtime.pending.clear();
  });

  return runtime;
}

function request(runtime: McpServerRuntime, method: string, params?: unknown): Promise<any> {
  const id = runtime.nextId++;
  return new Promise((resolve, reject) => {
    runtime.pending.set(id, { resolve, reject });
    writeFrame(runtime.proc, { jsonrpc: "2.0", id, method, params });
  });
}

function notify(runtime: McpServerRuntime, method: string, params?: unknown) {
  writeFrame(runtime.proc, { jsonrpc: "2.0", method, params });
}

async function initializeServer(runtime: McpServerRuntime) {
  await request(runtime, "initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "pi-mcp-extension", version: "0.3.0" },
  });
  notify(runtime, "notifications/initialized", {});
  const tools = await request(runtime, "tools/list", {});
  runtime.tools = Array.isArray(tools?.tools) ? tools.tools : [];
  try {
    const resources = await request(runtime, "resources/list", {});
    runtime.resources = Array.isArray(resources?.resources) ? resources.resources : [];
  } catch {
    runtime.resources = [];
  }
  runtime.initialized = true;
}

function toolResultText(result: any): string {
  if (Array.isArray(result?.content)) {
    return result.content
      .map((item: any) => (item?.type === "text" && typeof item.text === "string" ? item.text : JSON.stringify(item, null, 2)))
      .join("\n\n");
  }
  return typeof result === "string" ? result : JSON.stringify(result ?? {}, null, 2);
}

function normalizeSchema(schema: unknown): Record<string, unknown> {
  if (schema && typeof schema === "object") return schema as Record<string, unknown>;
  return { type: "object", properties: {}, additionalProperties: true };
}

export default function (pi: ExtensionAPI) {
  const runtimes = new Map<string, McpServerRuntime>();
  const registered = new Set<string>();
  const serverStatus = new Map<string, ServerStatus>();
  let configMeta: ConfigReadResult | null = null;
  let started = false;

  function emitStatus(ctx?: ExtensionContext) {
    const statuses = Array.from(serverStatus.entries());
    const ready = statuses.filter(([, status]) => status.initialized).length;
    const total = statuses.filter(([, status]) => status.configured && !status.disabled).length;
    if (ctx?.hasUI) ctx.ui.setStatus("mcp", ctx.ui.theme.fg("dim", `mcp:${ready}/${total}`));
    pi.events.emit("mcp:changed", { ready, total, servers: statuses.map(([name, status]) => ({ name, ...status })) });
  }

  function stopRuntime(name: string) {
    const runtime = runtimes.get(name);
    if (!runtime) return;
    try {
      runtime.proc.kill("SIGTERM");
    } catch {
      // ignore
    }
    runtimes.delete(name);
  }

  function stopAll() {
    for (const name of Array.from(runtimes.keys())) stopRuntime(name);
    started = false;
  }

  function setConfiguredStatuses() {
    serverStatus.clear();
    if (!configMeta) return;
    for (const [name, server] of Object.entries(configMeta.config.servers || {})) {
      serverStatus.set(name, {
        configured: true,
        disabled: !!server.disabled,
        initialized: false,
        tools: 0,
        resources: 0,
        configSource: configMeta.sources[name],
      });
    }
  }

  async function ensureToolRegistrations(runtime: McpServerRuntime) {
    for (const tool of runtime.tools) {
      const toolName = `mcp__${runtime.name}__${tool.name}`;
      if (registered.has(toolName)) continue;
      registered.add(toolName);
      pi.registerTool({
        name: toolName,
        label: `${runtime.name}:${tool.name}`,
        description: tool.description || `MCP tool ${tool.name} from ${runtime.name}`,
        parameters: normalizeSchema(tool.inputSchema),
        promptSnippet: `Call MCP tool ${tool.name} from server ${runtime.name}.`,
        promptGuidelines: [`Use ${toolName} when the task specifically needs MCP server ${runtime.name}.`],
        async execute(_toolCallId, params) {
          const active = runtimes.get(runtime.name);
          if (!active?.initialized) throw new Error(`MCP server not ready: ${runtime.name}`);
          const result = await request(active, "tools/call", { name: tool.name, arguments: params });
          return {
            content: [{ type: "text", text: toolResultText(result) }],
            details: { server: runtime.name, tool: tool.name, raw: result },
          };
        },
        renderCall(args, theme) {
          return new Text(`${theme.fg("toolTitle", theme.bold("mcp "))}${theme.fg("accent", `${runtime.name}:${tool.name}`)}\n  ${theme.fg("dim", JSON.stringify(args).slice(0, 180))}`, 0, 0);
        },
      });
    }
  }

  async function startServer(name: string, config: McpServerConfig, ctx: ExtensionContext) {
    const runtime = createServerRuntime(name, config, ctx.cwd);
    runtimes.set(name, runtime);
    try {
      await initializeServer(runtime);
      await ensureToolRegistrations(runtime);
      serverStatus.set(name, {
        configured: true,
        disabled: !!config.disabled,
        initialized: true,
        tools: runtime.tools.length,
        resources: runtime.resources.length,
        configSource: configMeta?.sources[name],
      });
    } catch (error) {
      stopRuntime(name);
      serverStatus.set(name, {
        configured: true,
        disabled: !!config.disabled,
        initialized: false,
        tools: 0,
        resources: 0,
        error: error instanceof Error ? error.message : String(error),
        configSource: configMeta?.sources[name],
      });
      if (ctx.hasUI) ctx.ui.notify(`MCP ${name} failed: ${serverStatus.get(name)?.error}`, "warning");
    }
  }

  async function startAll(ctx: ExtensionContext, force = false) {
    if (force) stopAll();
    configMeta = readConfig(ctx.cwd);
    setConfiguredStatuses();
    if (started && !force) {
      emitStatus(ctx);
      return;
    }
    started = true;

    for (const [name, serverConfig] of Object.entries(configMeta.config.servers || {})) {
      if (serverConfig.disabled) continue;
      await startServer(name, serverConfig, ctx);
    }

    emitStatus(ctx);
  }

  async function reloadServer(name: string, ctx: ExtensionContext) {
    configMeta = readConfig(ctx.cwd);
    const config = configMeta.config.servers?.[name];
    if (!config) throw new Error(`Unknown MCP server in config: ${name}`);
    stopRuntime(name);
    serverStatus.set(name, {
      configured: true,
      disabled: !!config.disabled,
      initialized: false,
      tools: 0,
      resources: 0,
      configSource: configMeta.sources[name],
    });
    if (!config.disabled) await startServer(name, config, ctx);
    emitStatus(ctx);
  }

  function doctorReport(): string {
    const lines: string[] = [];
    lines.push("MCP doctor");
    lines.push("");
    lines.push(`Config files checked:`);
    for (const file of configMeta?.files || []) lines.push(`- ${file}`);
    if ((configMeta?.parseErrors.length || 0) > 0) {
      lines.push("");
      lines.push("Parse errors:");
      for (const error of configMeta!.parseErrors) lines.push(`- ${error}`);
    }
    const statuses = Array.from(serverStatus.entries());
    if (statuses.length === 0) {
      lines.push("");
      lines.push("No MCP servers configured.");
      return lines.join("\n");
    }
    lines.push("");
    lines.push("Servers:");
    for (const [name, status] of statuses) {
      lines.push(`- ${name}`);
      lines.push(`  source: ${status.configSource || "unknown"}`);
      lines.push(`  state: ${status.disabled ? "disabled" : status.initialized ? "ready" : "not ready"}`);
      lines.push(`  tools/resources: ${status.tools}/${status.resources}`);
      if (status.error) lines.push(`  error: ${status.error}`);
    }
    return lines.join("\n");
  }

  function resolveConfigTarget(cwd: string, scope?: string): string {
    if (scope === "project") return getProjectConfigPath(cwd);
    return getGlobalConfigPath();
  }

  function parseAddArgs(raw: string): { scope: "global" | "project"; name: string; command: string; args: string[] } | null {
    const parts = raw.match(/(?:"[^"]*"|'[^']*'|\S+)/g)?.map((part) => part.replace(/^['"]|['"]$/g, "")) || [];
    let scope: "global" | "project" = "global";
    if (parts[0] === "--project") {
      scope = "project";
      parts.shift();
    } else if (parts[0] === "--global") {
      parts.shift();
    }
    const [name, command, ...args] = parts;
    if (!name || !command) return null;
    return { scope, name, command, args };
  }

  pi.on("session_start", async (_event, ctx) => {
    await startAll(ctx);
  });

  pi.on("session_shutdown", async () => {
    stopAll();
  });

  pi.registerTool({
    name: "mcp_list_resources",
    label: "MCP List Resources",
    description: "List resources exposed by configured MCP servers.",
    parameters: Type.Object({
      server: Type.Optional(Type.String({ description: "Optional server name filter" })),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      await startAll(ctx);
      const entries = Array.from(runtimes.entries())
        .filter(([name]) => !params.server || params.server === name)
        .flatMap(([name, runtime]) => runtime.resources.map((resource) => ({ server: name, ...resource })));
      return {
        content: [{ type: "text", text: entries.length ? entries.map((entry) => `${entry.server}  ${entry.uri}${entry.name ? `  ${entry.name}` : ""}`).join("\n") : "No MCP resources" }],
        details: { resources: entries },
      };
    },
  });

  pi.registerTool({
    name: "mcp_read_resource",
    label: "MCP Read Resource",
    description: "Read a resource from an MCP server.",
    parameters: Type.Object({
      server: Type.String({ description: "MCP server name" }),
      uri: Type.String({ description: "Resource URI" }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      await startAll(ctx);
      const runtime = runtimes.get(params.server);
      if (!runtime) throw new Error(`Unknown MCP server: ${params.server}`);
      const result = await request(runtime, "resources/read", { uri: params.uri });
      const text = Array.isArray(result?.contents)
        ? result.contents.map((item: any) => item?.text || item?.blob || JSON.stringify(item, null, 2)).join("\n\n")
        : JSON.stringify(result ?? {}, null, 2);
      return {
        content: [{ type: "text", text }],
        details: { server: params.server, uri: params.uri, raw: result },
      };
    },
    renderResult(result, { expanded }) {
      const text = result.content.filter((item: any) => item.type === "text").map((item: any) => item.text).join("\n\n");
      return expanded ? new Markdown(text, 0, 0) : new Text(text.slice(0, 600), 0, 0);
    },
  });

  pi.registerCommand("mcp", {
    description: "MCP status and control: /mcp [status|reload [server]|tools|resources|doctor|add|remove|edit-config]",
    handler: async (args, ctx) => {
      const trimmed = args.trim();
      const [action = "status", maybeServer, ...rest] = trimmed.split(/\s+/).filter(Boolean);

      if (action === "reload") {
        if (maybeServer) {
          await reloadServer(maybeServer, ctx);
          ctx.ui.notify(`MCP server reloaded: ${maybeServer}`, "success");
        } else {
          await startAll(ctx, true);
          ctx.ui.notify("MCP reloaded", "success");
        }
        return;
      }

      if (action === "add") {
        const parsed = parseAddArgs(trimmed.slice(action.length).trim());
        if (!parsed) {
          ctx.ui.notify("Usage: /mcp add [--project|--global] <name> <command> [args...]", "error");
          return;
        }
        const target = resolveConfigTarget(ctx.cwd, parsed.scope);
        const config = readConfigFile(target);
        config.servers ||= {};
        config.servers[parsed.name] = {
          command: parsed.command,
          args: parsed.args.length ? parsed.args : undefined,
        };
        writeConfigFile(target, config);
        await startAll(ctx, true);
        ctx.ui.notify(`Added MCP server ${parsed.name} to ${target}`, "success");
        return;
      }

      if (action === "remove") {
        const scope = maybeServer === "--project" ? "project" : maybeServer === "--global" ? "global" : undefined;
        const name = scope ? rest[0] : maybeServer;
        if (!name) {
          ctx.ui.notify("Usage: /mcp remove [--project|--global] <name>", "error");
          return;
        }
        const target = resolveConfigTarget(ctx.cwd, scope);
        const config = readConfigFile(target);
        if (!config.servers?.[name]) {
          ctx.ui.notify(`No MCP server named ${name} in ${target}`, "warning");
          return;
        }
        delete config.servers[name];
        writeConfigFile(target, config);
        await startAll(ctx, true);
        ctx.ui.notify(`Removed MCP server ${name} from ${target}`, "success");
        return;
      }

      if (action === "edit-config") {
        const scope = maybeServer === "project" ? "project" : "global";
        const target = resolveConfigTarget(ctx.cwd, scope);
        if (!fs.existsSync(target)) writeConfigFile(target, { servers: {} });
        const editor = process.env.VISUAL || process.env.EDITOR;
        if (!editor) {
          ctx.ui.notify(`Set EDITOR or VISUAL, then open: ${target}`, "warning");
          return;
        }
        const result = await pi.exec(editor, [target], { cwd: ctx.cwd, timeout: 3600 });
        if (result.code !== 0) {
          ctx.ui.notify(`Editor exited with code ${result.code}. File: ${target}`, "warning");
        } else {
          await startAll(ctx, true);
          ctx.ui.notify(`Edited ${target}`, "success");
        }
        return;
      }

      await startAll(ctx);

      if (action === "doctor") {
        ctx.ui.notify(doctorReport(), "info");
        return;
      }

      if (action === "tools") {
        const lines = Array.from(runtimes.entries()).flatMap(([name, runtime]) => runtime.tools.map((tool) => `${name}: ${tool.name}${tool.description ? ` - ${tool.description}` : ""}`));
        ctx.ui.notify(lines.length ? lines.join("\n") : "No MCP tools", "info");
        return;
      }

      if (action === "resources") {
        const lines = Array.from(runtimes.entries()).flatMap(([name, runtime]) => runtime.resources.map((resource) => `${name}: ${resource.uri}${resource.name ? ` - ${resource.name}` : ""}`));
        ctx.ui.notify(lines.length ? lines.join("\n") : "No MCP resources", "info");
        return;
      }

      const lines = Array.from(serverStatus.entries()).map(([name, status]) => `${name}: ${status.disabled ? "disabled" : status.initialized ? "ready" : "not ready"}${status.error ? ` - ${status.error}` : ""} (${status.tools} tools, ${status.resources} resources)`);
      ctx.ui.notify(lines.length ? lines.join("\n") : "No MCP servers configured", "info");
    },
  });
}
