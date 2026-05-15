import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type GuardrailMode = "auto" | "ask" | "read-only" | "yolo";

type GuardrailState = {
  mode: GuardrailMode;
};

const STATE_KEY = "guardrails-state";
const PROTECTED_PATH_PATTERNS = [
  /(^|\/)\.env(\.|$)/i,
  /(^|\/)\.git(\/|$)/,
  /(^|\/)node_modules(\/|$)/,
  /\.pem$/i,
  /\.key$/i,
  /(^|\/)secrets?(\/|\.|$)/i,
];

const SAFE_BASH = /^\s*(pwd|ls(\s|$)|find(\s|$)|fd(\s|$)|rg(\s|$)|grep(\s|$)|cat(\s|$)|head(\s|$)|tail(\s|$)|sed\s+-n(\s|$)|awk(\s|$)|tree(\s|$)|git\s+(status|diff|log|show|branch)(\s|$)|npm\s+(list|run\s+lint|run\s+test)(\s|$)|pnpm\s+(list|test|lint)(\s|$)|yarn\s+(list|test|lint)(\s|$))/i;
const DANGEROUS_BASH = /(\brm\b|\bsudo\b|\bmv\b|\bchmod\b|\bchown\b|\bdd\b|\bmkfs\b|\bshutdown\b|\breboot\b|\bkillall\b|\bcurl\b.*\|\s*(sh|bash)|\bwget\b.*\|\s*(sh|bash))/i;

function isProtectedPath(path: string): boolean {
  return PROTECTED_PATH_PATTERNS.some((pattern) => pattern.test(path));
}

function isSafeBash(command: string): boolean {
  return SAFE_BASH.test(command.trim());
}

function isDangerousBash(command: string): boolean {
  return DANGEROUS_BASH.test(command);
}

function statusText(mode: GuardrailMode, ctx: ExtensionContext): string {
  const theme = ctx.ui.theme;
  const color =
    mode === "yolo"
      ? "error"
      : mode === "read-only"
        ? "warning"
        : mode === "ask"
          ? "accent"
          : "dim";
  return theme.fg(color, `guard:${mode}`);
}

export default function (pi: ExtensionAPI) {
  let mode: GuardrailMode = "auto";

  function persist() {
    pi.appendEntry<GuardrailState>(STATE_KEY, { mode });
  }

  function applyUI(ctx: ExtensionContext) {
    if (!ctx.hasUI) return;
    ctx.ui.setStatus("guardrails", statusText(mode, ctx));
  }

  function restore(ctx: ExtensionContext) {
    let restored: GuardrailMode | undefined;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === STATE_KEY) {
        const data = entry.data as GuardrailState | undefined;
        if (
          data?.mode === "auto" ||
          data?.mode === "ask" ||
          data?.mode === "read-only" ||
          data?.mode === "yolo"
        ) {
          restored = data.mode;
        }
      }
    }
    mode = restored ?? "auto";
    applyUI(ctx);
  }

  async function confirm(ctx: ExtensionContext, title: string, body: string): Promise<boolean> {
    if (!ctx.hasUI) return false;
    const choice = await ctx.ui.select(`${title}\n\n${body}`, ["Allow", "Block"]);
    return choice === "Allow";
  }

  pi.registerCommand("guardrails", {
    description: "Guardrail mode: /guardrails [auto|ask|read-only|yolo|status]",
    handler: async (args, ctx) => {
      const next = args.trim().toLowerCase();
      if (!next || next === "status") {
        ctx.ui.notify(`Guardrails: ${mode}`, "info");
        applyUI(ctx);
        return;
      }

      if (next !== "auto" && next !== "ask" && next !== "read-only" && next !== "yolo") {
        ctx.ui.notify("Usage: /guardrails [auto|ask|read-only|yolo|status]", "error");
        return;
      }

      mode = next;
      persist();
      applyUI(ctx);
      ctx.ui.notify(`Guardrails set to ${mode}`, next === "yolo" ? "warning" : "success");
    },
  });

  pi.on("session_start", async (_event, ctx) => {
    restore(ctx);
  });

  pi.on("session_tree", async (_event, ctx) => {
    restore(ctx);
  });

  pi.on("tool_call", async (event, ctx) => {
    if (mode === "yolo") return;

    if (event.toolName === "write" || event.toolName === "edit") {
      const path = String((event.input as { path?: unknown }).path ?? "");

      if (mode !== "yolo" && isProtectedPath(path)) {
        ctx.ui.notify?.(`Blocked protected path: ${path}`, "warning");
        return { block: true, reason: `Protected path blocked: ${path}` };
      }

      if (mode === "read-only") {
        return { block: true, reason: `${event.toolName} blocked in read-only mode` };
      }

      if (mode === "ask" || mode === "auto") {
        const ok = await confirm(ctx, `Allow ${event.toolName}?`, `Path: ${path}`);
        if (!ok) return { block: true, reason: `Blocked ${event.toolName} by user` };
      }

      return;
    }

    if (event.toolName === "bash") {
      const command = String((event.input as { command?: unknown }).command ?? "");
      const safe = isSafeBash(command);
      const dangerous = isDangerousBash(command);

      if (mode === "read-only" && !safe) {
        return { block: true, reason: `bash blocked in read-only mode: ${command}` };
      }

      if (mode === "ask") {
        const ok = await confirm(ctx, "Allow bash command?", command);
        if (!ok) return { block: true, reason: "Bash command blocked by user" };
        return;
      }

      if (mode === "auto" && (!safe || dangerous)) {
        const ok = await confirm(
          ctx,
          dangerous ? "Dangerous bash command" : "Allow bash command?",
          command,
        );
        if (!ok) return { block: true, reason: "Bash command blocked by user" };
      }
    }
  });
}
