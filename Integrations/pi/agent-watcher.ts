// Agent Watcher integration. Managed by Agent Watcher.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

export default function agentWatcher(pi: ExtensionAPI) {
  const root = process.env.AGENT_WATCHER_DATA_DIR || join(homedir(), "Library", "Application Support", "AgentWatcher");
  const bridge = join(root, "bin", "agent-watcher-hook");
  const backgroundToolID = "agent-watcher-background-subagents";
  let context: ExtensionContext | undefined;
  let generation = 0;
  let timer: ReturnType<typeof setInterval> | undefined;
  let pending: { promise: Promise<void>; cancel: () => void } | undefined;
  let available = false;
  let checked = false;
  let parentRunning = false;
  let settlement = "Stop";
  let backgroundCount = 0;
  let backgroundDetail = "";
  let completionPending = false;

  function report(ctx: ExtensionContext, hook: string, fields: Record<string, unknown> = {}) {
    if (ctx.mode !== "tui") return;
    try {
      spawnSync(bridge, ["pi"], {
        input: JSON.stringify({
          session_id: ctx.sessionManager.getSessionId(),
          cwd: ctx.cwd,
          cli_pid: process.pid,
          hook_event_name: hook,
          ...fields,
        }),
        stdio: ["pipe", "ignore", "ignore"],
        timeout: 800,
      });
    } catch {
      // The CLI must keep working when the companion app is unavailable.
    }
  }

  function publishBackground(ctx: ExtensionContext) {
    report(ctx, "PreToolUse", {
      tool_name: "subagent", tool_use_id: backgroundToolID,
      tool_input: { background_count: backgroundCount, background_detail: backgroundDetail },
    });
  }

  function finishBackground(ctx: ExtensionContext) {
    if (completionPending && !parentRunning && ctx.isIdle() && !ctx.hasPendingMessages()) {
      completionPending = false;
      report(ctx, settlement);
    }
  }

  function refreshBackground(fresh = false): Promise<void> {
    if (!context || (checked && !available)) return Promise.resolve();
    if (pending) return fresh ? pending.promise.then(() => refreshBackground()) : pending.promise;
    const ctx = context;
    const currentGeneration = generation;
    const requestId = randomUUID();
    let cancel = () => {};
    const promise = new Promise<void>((resolve) => {
      let unsubscribe = () => {};
      const finish = () => {
        clearTimeout(timeout);
        unsubscribe();
        resolve();
      };
      cancel = finish;
      const timeout = setTimeout(() => { checked = true; finish(); }, 500);
      unsubscribe = pi.events.on(`subagents:rpc:v1:reply:${requestId}`, (reply: any) => {
        if (generation !== currentGeneration) { finish(); return; }
        checked = true;
        const fleet = reply?.data?.fleet;
        if (reply?.version === 1 && reply.success === true && fleet?.version === 1
          && Number.isSafeInteger(fleet.totalActive) && fleet.totalActive >= 0 && fleet.totalActive <= 10_000) {
          available = true;
          checked = true;
          const count = fleet.totalActive;
          const detail = (Array.isArray(fleet.entries) ? fleet.entries : []).slice(0, 3)
            .filter((entry: any) => typeof entry?.agent === "string")
            .map((entry: any) => typeof entry.role === "string" ? `${entry.agent}: ${entry.role}` : entry.agent)
            .join(", ").slice(0, 120);
          if (count > 0 && (count !== backgroundCount || detail !== backgroundDetail)) {
            completionPending = false;
            backgroundCount = count;
            backgroundDetail = detail;
            publishBackground(ctx);
          } else if (count === 0 && backgroundCount > 0) {
            backgroundCount = 0;
            backgroundDetail = "";
            completionPending = true;
            report(ctx, "PostToolUse", { tool_name: "subagent", tool_use_id: backgroundToolID });
          }
          finishBackground(ctx);
        }
        finish();
      });
    });
    const request = { promise, cancel };
    pending = request;
    void promise.then(() => { if (pending === request) pending = undefined; });
    try {
      // Read the package-owned, current-session projection. Never launch or steer work.
      pi.events.emit("subagents:rpc:v1:request", { version: 1, requestId, method: "status" });
    } catch { cancel(); }
    return promise;
  }

  for (const channel of ["subagents:rpc:v1:ready", "subagent:async-started", "subagent:async-complete", "subagent:child-status"]) {
    pi.events.on(channel, () => {
      checked = false;
      void refreshBackground();
    });
  }

  pi.on("session_start", async (_event, ctx) => {
    if (ctx.mode !== "tui") return;
    generation++;
    pending?.cancel();
    pending = undefined;
    clearInterval(timer);
    context = ctx;
    available = false;
    checked = false;
    parentRunning = !ctx.isIdle();
    backgroundCount = 0;
    backgroundDetail = "";
    completionPending = false;
    report(ctx, "SessionStart");
    timer = setInterval(() => {
      if (backgroundCount > 0 || completionPending) void refreshBackground();
    }, 1_000);
    timer.unref();
    await refreshBackground();
  });
  pi.on("session_shutdown", () => {
    generation++;
    clearInterval(timer);
    pending?.cancel();
    pending = undefined;
    context = undefined;
  });
  pi.on("agent_start", () => { parentRunning = true; });
  pi.on("before_agent_start", (event, ctx) => {
    parentRunning = true;
    report(ctx, "UserPromptSubmit", { prompt: event.messageType === "user" ? event.prompt : "" });
    if (backgroundCount > 0) publishBackground(ctx);
  });
  pi.on("tool_execution_start", (event, ctx) => {
    report(ctx, "PreToolUse", { tool_name: event.toolName, tool_use_id: event.toolCallId, tool_input: event.args });
  });
  pi.on("tool_execution_end", (event, ctx) => {
    report(ctx, "PostToolUse", { tool_name: event.toolName, tool_use_id: event.toolCallId, tool_input: {} });
    void refreshBackground();
  });
  pi.on("ui_prompt_start", (event, ctx) => {
    report(ctx, "UIPromptStart", { kind: event.kind, title: event.title });
  });
  pi.on("ui_prompt_end", (event, ctx) => {
    report(ctx, "UIPromptEnd", { kind: event.kind, title: event.title });
  });
  pi.on("agent_settled", async (event, ctx) => {
    if (ctx.mode !== "tui") return;
    const currentGeneration = generation;
    await refreshBackground(true);
    if (generation !== currentGeneration) return;
    parentRunning = false;
    settlement = event.aborted ? "Interrupt" : "Stop";
    if (backgroundCount > 0) {
      publishBackground(ctx);
    } else {
      completionPending = false;
      report(ctx, settlement);
    }
  });
}
