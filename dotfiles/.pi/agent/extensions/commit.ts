import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

async function getRepoRoot(pi: ExtensionAPI): Promise<string | null> {
  const { stdout, code } = await pi.exec("git", ["rev-parse", "--show-toplevel"]);
  if (code !== 0) return null;
  const root = stdout.trim();
  return root.length > 0 ? root : null;
}

export default function (pi: ExtensionAPI) {
  pi.registerCommand("commit", {
    description: "Stage all changes and create a git commit",
    handler: async (args, ctx) => {
      const repoRoot = await getRepoRoot(pi);
      if (!repoRoot) {
        ctx.ui.notify("Not inside a git repository", "error");
        return;
      }

      const { stdout: status, code: statusCode } = await pi.exec("git", ["-C", repoRoot, "status", "--porcelain"]);
      if (statusCode !== 0) {
        ctx.ui.notify("Unable to read git status", "error");
        return;
      }
      if (status.trim().length === 0) {
        ctx.ui.notify("No changes to commit", "info");
        return;
      }

      const defaultMessage = args.trim() || "Update files";
      const message = (await ctx.ui.input("Commit message:", defaultMessage))?.trim();
      if (!message) return;

      const ok = await ctx.ui.confirm(
        "Create commit?",
        `Repository: ${repoRoot}\n\nMessage:\n${message}`,
      );
      if (!ok) return;

      const { code: addCode } = await pi.exec("git", ["-C", repoRoot, "add", "-A"]);
      if (addCode !== 0) {
        ctx.ui.notify("git add failed", "error");
        return;
      }

      const { stdout: commitOut, stderr: commitErr, code: commitCode } = await pi.exec("git", [
        "-C",
        repoRoot,
        "commit",
        "-m",
        message,
      ]);

      if (commitCode !== 0) {
        ctx.ui.notify(commitErr.trim() || "git commit failed", "error");
        return;
      }

      ctx.ui.notify(commitOut.trim() || `Committed: ${message}`, "info");
    },
  });
}
