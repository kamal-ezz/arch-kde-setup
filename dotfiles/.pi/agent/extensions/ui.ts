import * as path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type DashboardState = {
  worktrees: Array<{ path: string; branch?: string }>;
  mcpReady: number;
  mcpTotal: number;
};

export default function (pi: ExtensionAPI) {
  const state: DashboardState = {
    worktrees: [],
    mcpReady: 0,
    mcpTotal: 0,
  };

  function render(ctx: ExtensionContext) {
    if (!ctx.hasUI) return;
    const theme = ctx.ui.theme;
    const lines: string[] = [];
    lines.push(
      `${theme.fg("accent", "workspace")} ${theme.fg("dim", `worktrees:${state.worktrees.length}`)}  ${theme.fg("dim", `mcp:${state.mcpReady}/${state.mcpTotal}`)}`,
    );
    if (state.worktrees.length > 0) {
      for (const worktree of state.worktrees.slice(0, 3)) {
        lines.push(`${theme.fg("muted", "↳")} ${path.basename(worktree.path)} ${theme.fg("dim", worktree.branch || "detached")}`);
      }
      if (state.worktrees.length > 3) lines.push(theme.fg("dim", `... +${state.worktrees.length - 3} more`));
    }
    ctx.ui.setWidget("dashboard", lines, { placement: "belowEditor" });
  }

  pi.on("session_start", async (_event, ctx) => {
    render(ctx);
  });

  pi.events.on("worktree:changed", (payload: { entries?: Array<{ path: string; branch?: string }> }) => {
    state.worktrees = payload.entries || [];
  });

  pi.events.on("mcp:changed", (payload: { ready?: number; total?: number }) => {
    state.mcpReady = payload.ready || 0;
    state.mcpTotal = payload.total || 0;
  });

  for (const eventName of ["turn_end", "turn_start", "session_tree"] as const) {
    pi.on(eventName, async (_event, ctx) => {
      render(ctx);
    });
  }

  pi.registerCommand("dashboard", {
    description: "Refresh the lightweight Pi dashboard widget",
    handler: async (_args, ctx) => {
      render(ctx);
      ctx.ui.notify("Dashboard refreshed", "info");
    },
  });
}
