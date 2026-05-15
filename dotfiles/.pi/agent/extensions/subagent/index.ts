import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { AgentToolResult } from "@earendil-works/pi-agent-core";
import type { Message } from "@earendil-works/pi-ai";
import { StringEnum } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { getMarkdownTheme, withFileMutationQueue } from "@earendil-works/pi-coding-agent";
import { Container, Markdown, Spacer, Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import { type AgentConfig, type AgentScope, discoverAgents } from "./agents.js";

type UsageStats = {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  cost: number;
  contextTokens: number;
  turns: number;
};

type SingleResult = {
  agent: string;
  agentSource: "user" | "project" | "unknown";
  task: string;
  exitCode: number;
  messages: Message[];
  stderr: string;
  usage: UsageStats;
  model?: string;
  stopReason?: string;
  errorMessage?: string;
};

type SubagentDetails = {
  mode: "single" | "parallel";
  agentScope: AgentScope;
  projectAgentsDir: string | null;
  results: SingleResult[];
};

const MAX_PARALLEL_TASKS = 6;
const MAX_CONCURRENCY = 3;

function getPiInvocation(args: string[]): { command: string; args: string[] } {
  const currentScript = process.argv[1];
  const isBunVirtualScript = currentScript?.startsWith("/$bunfs/root/");
  if (currentScript && !isBunVirtualScript && fs.existsSync(currentScript)) {
    return { command: process.execPath, args: [currentScript, ...args] };
  }
  const execName = path.basename(process.execPath).toLowerCase();
  const isGenericRuntime = /^(node|bun)(\.exe)?$/.test(execName);
  if (!isGenericRuntime) return { command: process.execPath, args };
  return { command: "pi", args };
}

function getFinalOutput(messages: Message[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i];
    if (msg.role !== "assistant") continue;
    for (const part of msg.content) {
      if (part.type === "text") return part.text;
    }
  }
  return "";
}

function formatUsage(usage: UsageStats, model?: string): string {
  const parts: string[] = [];
  if (usage.turns) parts.push(`${usage.turns}t`);
  if (usage.input) parts.push(`↑${usage.input}`);
  if (usage.output) parts.push(`↓${usage.output}`);
  if (usage.cacheRead) parts.push(`R${usage.cacheRead}`);
  if (usage.cacheWrite) parts.push(`W${usage.cacheWrite}`);
  if (usage.cost) parts.push(`$${usage.cost.toFixed(4)}`);
  if (usage.contextTokens) parts.push(`ctx:${usage.contextTokens}`);
  if (model) parts.push(model);
  return parts.join(" ");
}

async function writePromptToTempFile(agentName: string, prompt: string): Promise<{ dir: string; filePath: string }> {
  const tmpDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), "pi-subagent-"));
  const safeName = agentName.replace(/[^\w.-]+/g, "_");
  const filePath = path.join(tmpDir, `prompt-${safeName}.md`);
  await withFileMutationQueue(filePath, async () => {
    await fs.promises.writeFile(filePath, prompt, { encoding: "utf-8", mode: 0o600 });
  });
  return { dir: tmpDir, filePath };
}

async function mapWithConcurrencyLimit<TIn, TOut>(
  items: TIn[],
  concurrency: number,
  fn: (item: TIn, index: number) => Promise<TOut>,
): Promise<TOut[]> {
  if (items.length === 0) return [];
  const limit = Math.max(1, Math.min(concurrency, items.length));
  const results: TOut[] = new Array(items.length);
  let nextIndex = 0;
  const workers = new Array(limit).fill(null).map(async () => {
    while (true) {
      const current = nextIndex++;
      if (current >= items.length) return;
      results[current] = await fn(items[current], current);
    }
  });
  await Promise.all(workers);
  return results;
}

type OnUpdateCallback = (partial: AgentToolResult<SubagentDetails>) => void;

async function runSingleAgent(
  defaultCwd: string,
  agents: AgentConfig[],
  agentName: string,
  task: string,
  cwd: string | undefined,
  signal: AbortSignal | undefined,
  onUpdate: OnUpdateCallback | undefined,
  makeDetails: (results: SingleResult[]) => SubagentDetails,
): Promise<SingleResult> {
  const agent = agents.find((entry) => entry.name === agentName);
  if (!agent) {
    return {
      agent: agentName,
      agentSource: "unknown",
      task,
      exitCode: 1,
      messages: [],
      stderr: `Unknown agent: ${agentName}`,
      usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
    };
  }

  const args: string[] = ["--mode", "json", "-p", "--no-session"];
  if (agent.model) args.push("--model", agent.model);
  if (agent.tools?.length) args.push("--tools", agent.tools.join(","));

  let tmpPromptDir: string | null = null;
  let tmpPromptPath: string | null = null;
  const currentResult: SingleResult = {
    agent: agentName,
    agentSource: agent.source,
    task,
    exitCode: 0,
    messages: [],
    stderr: "",
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
    model: agent.model,
  };

  const emitUpdate = () => {
    if (!onUpdate) return;
    onUpdate({
      content: [{ type: "text", text: getFinalOutput(currentResult.messages) || "(running...)" }],
      details: makeDetails([currentResult]),
    });
  };

  try {
    if (agent.systemPrompt.trim()) {
      const tmp = await writePromptToTempFile(agent.name, agent.systemPrompt);
      tmpPromptDir = tmp.dir;
      tmpPromptPath = tmp.filePath;
      args.push("--append-system-prompt", tmpPromptPath);
    }

    args.push(`Task: ${task}`);
    let wasAborted = false;

    const exitCode = await new Promise<number>((resolve) => {
      const invocation = getPiInvocation(args);
      const proc = spawn(invocation.command, invocation.args, {
        cwd: cwd ?? defaultCwd,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
      let buffer = "";

      const processLine = (line: string) => {
        if (!line.trim()) return;
        let event: any;
        try {
          event = JSON.parse(line);
        } catch {
          return;
        }

        if (event.type === "message_end" && event.message) {
          const msg = event.message as Message;
          currentResult.messages.push(msg);
          if (msg.role === "assistant") {
            currentResult.usage.turns++;
            const usage = msg.usage;
            if (usage) {
              currentResult.usage.input += usage.input || 0;
              currentResult.usage.output += usage.output || 0;
              currentResult.usage.cacheRead += usage.cacheRead || 0;
              currentResult.usage.cacheWrite += usage.cacheWrite || 0;
              currentResult.usage.cost += usage.cost?.total || 0;
              currentResult.usage.contextTokens = usage.totalTokens || 0;
            }
            if (!currentResult.model && msg.model) currentResult.model = msg.model;
            if (msg.stopReason) currentResult.stopReason = msg.stopReason;
            if (msg.errorMessage) currentResult.errorMessage = msg.errorMessage;
          }
          emitUpdate();
        }

        if (event.type === "tool_result_end" && event.message) {
          currentResult.messages.push(event.message as Message);
          emitUpdate();
        }
      };

      proc.stdout.on("data", (data) => {
        buffer += data.toString();
        const lines = buffer.split("\n");
        buffer = lines.pop() || "";
        for (const line of lines) processLine(line);
      });

      proc.stderr.on("data", (data) => {
        currentResult.stderr += data.toString();
      });

      proc.on("close", (code) => {
        if (buffer.trim()) processLine(buffer);
        resolve(code ?? 0);
      });

      proc.on("error", () => resolve(1));

      if (signal) {
        const killProc = () => {
          wasAborted = true;
          proc.kill("SIGTERM");
          setTimeout(() => {
            if (!proc.killed) proc.kill("SIGKILL");
          }, 5000);
        };
        if (signal.aborted) killProc();
        else signal.addEventListener("abort", killProc, { once: true });
      }
    });

    currentResult.exitCode = exitCode;
    if (wasAborted) throw new Error("Subagent was aborted");
    return currentResult;
  } finally {
    if (tmpPromptPath) try { fs.unlinkSync(tmpPromptPath); } catch {}
    if (tmpPromptDir) try { fs.rmdirSync(tmpPromptDir); } catch {}
  }
}

const TaskItem = Type.Object({
  agent: Type.String({ description: "Name of the agent to invoke" }),
  task: Type.String({ description: "Task to delegate" }),
  cwd: Type.Optional(Type.String({ description: "Optional working directory" })),
});

const SubagentParams = Type.Object({
  agent: Type.Optional(Type.String({ description: "Single mode agent name" })),
  task: Type.Optional(Type.String({ description: "Single mode task" })),
  tasks: Type.Optional(Type.Array(TaskItem, { description: "Parallel tasks" })),
  agentScope: Type.Optional(StringEnum(["user", "project", "both"] as const)),
  confirmProjectAgents: Type.Optional(Type.Boolean({ default: true })),
  cwd: Type.Optional(Type.String({ description: "Single mode working directory" })),
});

export default function (pi: ExtensionAPI) {
  pi.registerCommand("agents", {
    description: "List available subagents",
    handler: async (args, ctx) => {
      const scope = (args.trim() as AgentScope) || "user";
      const discovery = discoverAgents(ctx.cwd, scope === "project" || scope === "both" ? scope : "user");
      const list = discovery.agents.length
        ? discovery.agents.map((agent) => `${agent.name} (${agent.source}) - ${agent.description}`).join("\n")
        : "No agents found";
      ctx.ui.notify(list, "info");
    },
  });

  pi.registerTool({
    name: "subagent",
    label: "Subagent",
    description: "Delegate work to isolated Pi subagents. Supports single mode (agent + task) and parallel mode (tasks array).",
    parameters: SubagentParams,
    promptSnippet: "Delegate focused work to specialized subagents using the subagent tool.",
    promptGuidelines: [
      "Use subagent when the task can be decomposed into a focused investigation or a parallel set of investigations.",
      "Use subagent with agent=\"scout\" for codebase recon, or agent=\"reviewer\" for review-style passes.",
    ],

    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      const agentScope: AgentScope = params.agentScope ?? "user";
      const discovery = discoverAgents(ctx.cwd, agentScope);
      const agents = discovery.agents;
      const hasTasks = (params.tasks?.length ?? 0) > 0;
      const hasSingle = Boolean(params.agent && params.task);
      const modeCount = Number(hasTasks) + Number(hasSingle);

      const makeDetails = (mode: "single" | "parallel") => (results: SingleResult[]): SubagentDetails => ({
        mode,
        agentScope,
        projectAgentsDir: discovery.projectAgentsDir,
        results,
      });

      if (modeCount !== 1) {
        return {
          content: [{ type: "text", text: "Provide either agent+task or tasks[]." }],
          details: makeDetails("single")([]),
          isError: true,
        };
      }

      if ((agentScope === "project" || agentScope === "both") && (params.confirmProjectAgents ?? true) && ctx.hasUI) {
        const requested = new Set<string>();
        if (params.agent) requested.add(params.agent);
        if (params.tasks) for (const task of params.tasks) requested.add(task.agent);
        const projectAgents = Array.from(requested)
          .map((name) => agents.find((agent) => agent.name === name))
          .filter((agent): agent is AgentConfig => agent?.source === "project");
        if (projectAgents.length > 0) {
          const ok = await ctx.ui.confirm(
            "Run project-local agents?",
            `Agents: ${projectAgents.map((agent) => agent.name).join(", ")}\nSource: ${discovery.projectAgentsDir ?? "(unknown)"}`,
          );
          if (!ok) {
            return {
              content: [{ type: "text", text: "Canceled: project-local agents not approved." }],
              details: makeDetails(hasTasks ? "parallel" : "single")([]),
              isError: true,
            };
          }
        }
      }

      if (params.tasks?.length) {
        if (params.tasks.length > MAX_PARALLEL_TASKS) {
          return {
            content: [{ type: "text", text: `Too many parallel tasks. Max is ${MAX_PARALLEL_TASKS}.` }],
            details: makeDetails("parallel")([]),
            isError: true,
          };
        }

        const allResults: SingleResult[] = new Array(params.tasks.length).fill(null).map((_, index) => ({
          agent: params.tasks![index].agent,
          agentSource: "unknown",
          task: params.tasks![index].task,
          exitCode: -1,
          messages: [],
          stderr: "",
          usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
        }));

        const emitParallelUpdate = () => {
          if (!onUpdate) return;
          const running = allResults.filter((result) => result.exitCode === -1).length;
          const done = allResults.filter((result) => result.exitCode !== -1).length;
          onUpdate({
            content: [{ type: "text", text: `Parallel: ${done}/${allResults.length} done, ${running} running...` }],
            details: makeDetails("parallel")([...allResults]),
          });
        };

        const results = await mapWithConcurrencyLimit(params.tasks, MAX_CONCURRENCY, async (task, index) => {
          const result = await runSingleAgent(
            ctx.cwd,
            agents,
            task.agent,
            task.task,
            task.cwd,
            signal,
            (partial) => {
              if (partial.details?.results[0]) {
                allResults[index] = partial.details.results[0];
                emitParallelUpdate();
              }
            },
            makeDetails("parallel"),
          );
          allResults[index] = result;
          emitParallelUpdate();
          return result;
        });

        const summary = results
          .map((result) => `[${result.agent}] ${result.exitCode === 0 ? "ok" : "failed"}: ${getFinalOutput(result.messages).slice(0, 120) || result.stderr || "(no output)"}`)
          .join("\n\n");

        return {
          content: [{ type: "text", text: summary }],
          details: makeDetails("parallel")(results),
          isError: results.some((result) => result.exitCode !== 0),
        };
      }

      const result = await runSingleAgent(
        ctx.cwd,
        agents,
        params.agent!,
        params.task!,
        params.cwd,
        signal,
        onUpdate,
        makeDetails("single"),
      );

      const text = getFinalOutput(result.messages) || result.stderr || "(no output)";
      return {
        content: [{ type: "text", text }],
        details: makeDetails("single")([result]),
        isError: result.exitCode !== 0,
      };
    },

    renderCall(args, theme) {
      if (args.tasks?.length) {
        const preview = args.tasks.slice(0, 3).map((task: { agent: string; task: string }) => `${task.agent}: ${task.task.slice(0, 36)}`).join("\n  ");
        return new Text(`${theme.fg("toolTitle", theme.bold("subagent parallel"))}\n  ${preview}`, 0, 0);
      }
      return new Text(
        `${theme.fg("toolTitle", theme.bold("subagent "))}${theme.fg("accent", args.agent || "...")}\n  ${theme.fg("dim", (args.task || "").slice(0, 80))}`,
        0,
        0,
      );
    },

    renderResult(result, { expanded }, theme) {
      const details = result.details as SubagentDetails | undefined;
      if (!details || details.results.length === 0) {
        const text = result.content[0];
        return new Text(text?.type === "text" ? text.text : "(no output)", 0, 0);
      }

      const mdTheme = getMarkdownTheme();
      const container = new Container();
      const heading = `${theme.fg("toolTitle", theme.bold(`subagent ${details.mode}`))}${theme.fg("muted", ` [${details.agentScope}]`)}`;
      container.addChild(new Text(heading, 0, 0));

      for (const entry of details.results) {
        const ok = entry.exitCode === 0;
        const icon = ok ? theme.fg("success", "✓") : theme.fg("error", "✗");
        const output = getFinalOutput(entry.messages) || entry.stderr || "(no output)";
        container.addChild(new Spacer(1));
        container.addChild(new Text(`${icon} ${theme.fg("accent", entry.agent)} ${theme.fg("dim", formatUsage(entry.usage, entry.model))}`, 0, 0));
        if (expanded) {
          container.addChild(new Text(theme.fg("muted", `Task: ${entry.task}`), 0, 0));
          container.addChild(new Spacer(1));
          container.addChild(new Markdown(output.trim(), 0, 0, mdTheme));
        } else {
          container.addChild(new Text(theme.fg("toolOutput", output.slice(0, 240)), 0, 0));
        }
      }

      return container;
    },
  });
}
