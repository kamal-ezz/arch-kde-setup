import * as fs from "node:fs";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";

type WorktreeEntry = {
  path: string;
  branch?: string;
  head?: string;
  detached?: boolean;
};

async function gitRoot(pi: ExtensionAPI, cwd: string, signal?: AbortSignal): Promise<string> {
  const result = await pi.exec("git", ["rev-parse", "--show-toplevel"], { cwd, signal, timeout: 5000 });
  if (result.code !== 0) throw new Error(result.stderr || "Not a git repository");
  return result.stdout.trim();
}

function worktreeBaseDir(root: string): string {
  return path.join(root, ".pi", "worktrees");
}

async function ensureDir(dir: string) {
  await fs.promises.mkdir(dir, { recursive: true });
}

async function listWorktrees(pi: ExtensionAPI, cwd: string, signal?: AbortSignal): Promise<WorktreeEntry[]> {
  const result = await pi.exec("git", ["worktree", "list", "--porcelain"], { cwd, signal, timeout: 10000 });
  if (result.code !== 0) throw new Error(result.stderr || "Failed to list worktrees");
  const blocks = result.stdout.trim().split(/\n\n+/).filter(Boolean);
  return blocks.map((block) => {
    const entry: WorktreeEntry = { path: "" };
    for (const line of block.split("\n")) {
      const [key, ...rest] = line.split(" ");
      const value = rest.join(" ").trim();
      if (key === "worktree") entry.path = value;
      if (key === "branch") entry.branch = value.replace("refs/heads/", "");
      if (key === "HEAD") entry.head = value;
      if (key === "detached") entry.detached = true;
    }
    return entry;
  });
}

function localWorktrees(entries: WorktreeEntry[], root: string): WorktreeEntry[] {
  const base = worktreeBaseDir(root);
  return entries.filter((entry) => entry.path.startsWith(base + path.sep));
}

export default function (pi: ExtensionAPI) {
  async function refresh(cwd: string) {
    try {
      const root = await gitRoot(pi, cwd);
      const entries = localWorktrees(await listWorktrees(pi, cwd), root);
      pi.events.emit("worktree:changed", { root, entries });
      return { root, entries };
    } catch {
      pi.events.emit("worktree:changed", { root: null, entries: [] });
      return { root: null, entries: [] };
    }
  }

  pi.on("session_start", async (_event, ctx) => {
    await refresh(ctx.cwd);
  });

  pi.registerCommand("worktree", {
    description: "Manage isolated git worktrees: /worktree [status|create <name> [base]|remove <name>|diff <name>|path <name>]",
    handler: async (args, ctx) => {
      const parts = args.trim().split(/\s+/).filter(Boolean);
      const action = parts[0] || "status";
      const root = await gitRoot(pi, ctx.cwd);
      const baseDir = worktreeBaseDir(root);
      await ensureDir(baseDir);

      if (action === "status") {
        const entries = localWorktrees(await listWorktrees(pi, ctx.cwd), root);
        ctx.ui.notify(entries.length ? entries.map((e) => `${path.basename(e.path)}  ${e.branch || "detached"}`).join("\n") : "No managed worktrees", "info");
        await refresh(ctx.cwd);
        return;
      }

      if (action === "create") {
        const name = parts[1];
        const base = parts[2] || "HEAD";
        if (!name) {
          ctx.ui.notify("Usage: /worktree create <name> [base]", "error");
          return;
        }
        const target = path.join(baseDir, name);
        const branch = `pi-${name}-${Date.now().toString(36)}`;
        const result = await pi.exec("git", ["worktree", "add", "-b", branch, target, base], { cwd: root, timeout: 20000 });
        if (result.code !== 0) throw new Error(result.stderr || "Failed to create worktree");
        await refresh(ctx.cwd);
        ctx.ui.notify(`Created ${target}`, "success");
        return;
      }

      if (action === "remove") {
        const name = parts[1];
        if (!name) {
          ctx.ui.notify("Usage: /worktree remove <name>", "error");
          return;
        }
        const target = path.join(baseDir, name);
        const result = await pi.exec("git", ["worktree", "remove", "--force", target], { cwd: root, timeout: 20000 });
        if (result.code !== 0) throw new Error(result.stderr || "Failed to remove worktree");
        await refresh(ctx.cwd);
        ctx.ui.notify(`Removed ${target}`, "success");
        return;
      }

      if (action === "diff") {
        const name = parts[1];
        if (!name) {
          ctx.ui.notify("Usage: /worktree diff <name>", "error");
          return;
        }
        const target = path.join(baseDir, name);
        const result = await pi.exec("git", ["-C", target, "status", "--short"], { timeout: 10000 });
        ctx.ui.notify(result.stdout.trim() || "No changes", "info");
        return;
      }

      if (action === "path") {
        const name = parts[1];
        if (!name) {
          ctx.ui.notify("Usage: /worktree path <name>", "error");
          return;
        }
        ctx.ui.notify(path.join(baseDir, name), "info");
        return;
      }

      ctx.ui.notify("Usage: /worktree [status|create <name> [base]|remove <name>|diff <name>|path <name>]", "error");
    },
  });

  pi.registerTool({
    name: "create_worktree",
    label: "Create Worktree",
    description: "Create an isolated git worktree under .pi/worktrees for safe parallel work.",
    promptSnippet: "Create an isolated git worktree for experimentation or parallel tasks.",
    promptGuidelines: ["Use create_worktree before isolated parallel edits or risky changes."],
    parameters: Type.Object({
      name: Type.String({ description: "Short worktree name" }),
      base: Type.Optional(Type.String({ description: "Base ref or branch", default: "HEAD" })),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const root = await gitRoot(pi, ctx.cwd, signal);
      const baseDir = worktreeBaseDir(root);
      await ensureDir(baseDir);
      const target = path.join(baseDir, params.name);
      const branch = `pi-${params.name}-${Date.now().toString(36)}`;
      const result = await pi.exec("git", ["worktree", "add", "-b", branch, target, params.base || "HEAD"], { cwd: root, signal, timeout: 20000 });
      if (result.code !== 0) throw new Error(result.stderr || "Failed to create worktree");
      await refresh(ctx.cwd);
      return { content: [{ type: "text", text: target }], details: { path: target, branch } };
    },
    renderCall(args, theme) {
      return new Text(`${theme.fg("toolTitle", theme.bold("create_worktree "))}${theme.fg("accent", args.name)}`, 0, 0);
    },
  });

  pi.registerTool({
    name: "list_worktrees",
    label: "List Worktrees",
    description: "List managed worktrees under .pi/worktrees.",
    parameters: Type.Object({}),
    async execute(_toolCallId, _params, signal, _onUpdate, ctx) {
      const root = await gitRoot(pi, ctx.cwd, signal);
      const entries = localWorktrees(await listWorktrees(pi, ctx.cwd, signal), root);
      return {
        content: [{ type: "text", text: entries.length ? entries.map((e) => `${path.basename(e.path)} ${e.branch || "detached"} ${e.path}`).join("\n") : "No managed worktrees" }],
        details: { entries },
      };
    },
  });
}
