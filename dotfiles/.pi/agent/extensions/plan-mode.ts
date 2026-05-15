import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const READ_ONLY_TOOLS = ["read", "bash"];
const NORMAL_TOOLS = ["read", "bash", "edit", "write"];

function toolNames(tools: Array<string | { name: string }>): string[] {
  return tools.map((tool) => (typeof tool === "string" ? tool : tool.name)).filter(Boolean);
}

const SAFE_BASH = /^(\s*(cat|head|tail|less|more|grep|rg|find|fd|ls|pwd|tree|git\s+(status|log|diff|branch)(\s|$)|npm\s+(list|outdated)(\s|$)|yarn\s+info(\s|$)|uname(\s|$)|whoami(\s|$)|date(\s|$)|uptime(\s|$)))/;

function isSafeCommand(command: string): boolean {
  return SAFE_BASH.test(command);
}

export default function (pi: ExtensionAPI) {
  let planMode = false;
  let previousTools: string[] | undefined;

  function update(ctx?: ExtensionContext) {
    if (!ctx?.hasUI) return;
    ctx.ui.setStatus("plan-mode", planMode ? ctx.ui.theme.fg("warning", "⏸ plan") : undefined);
  }

  async function toggle(ctx: ExtensionContext) {
    planMode = !planMode;
    if (planMode) {
      previousTools = toolNames(pi.getActiveTools() as Array<string | { name: string }>);
      pi.setActiveTools(READ_ONLY_TOOLS);
      ctx.ui.notify("Plan mode enabled", "info");
    } else {
      pi.setActiveTools(previousTools ?? NORMAL_TOOLS);
      previousTools = undefined;
      ctx.ui.notify("Plan mode disabled", "info");
    }
    update(ctx);
  }

  pi.registerCommand("plan", {
    description: "Toggle plan mode",
    handler: async (_args, ctx) => toggle(ctx),
  });

  pi.registerShortcut("shift+tab", {
    description: "Toggle plan mode",
    handler: async (ctx) => toggle(ctx),
  });

  pi.on("before_agent_start", async (event) => {
    if (!planMode) return;
    return {
      systemPrompt: `${event.systemPrompt}\n\nPLAN MODE ACTIVE:\n- You are in read-only planning mode.\n- Do not modify files or system state.\n- You may inspect files and propose a plan only.\n- Available tools are limited to read and safe bash commands.`,
    };
  });

  pi.on("tool_call", async (event) => {
    if (!planMode || event.toolName !== "bash") return;
    const command = String((event.input as { command?: unknown }).command ?? "");
    if (!isSafeCommand(command)) {
      return {
        block: true,
        reason: `Plan mode: blocked command\n${command}`,
      };
    }
  });

  pi.on("session_start", (_event, ctx) => update(ctx));
  pi.on("session_shutdown", (_event, ctx) => update(ctx));
}
