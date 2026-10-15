import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { EventEmitter } from "node:events";

function eventBus() {
  const emitter = new EventEmitter();
  return {
    on(name, handler) {
      emitter.on(name, handler);
      return () => emitter.off(name, handler);
    },
    emit(name, data) { emitter.emit(name, data); },
  };
}

test("Pi publishes prompt, tools, interactive input, and final settlement without changing a launch command", async () => {
  const directory = mkdtempSync(join(tmpdir(), "agent-watcher-pi-"));
  const previous = process.env.AGENT_WATCHER_DATA_DIR;
  process.env.AGENT_WATCHER_DATA_DIR = directory;
  try {
    mkdirSync(join(directory, "bin"));
    writeFileSync(join(directory, "bin", "agent-watcher-hook"), `#!${process.execPath}\nconst fs = require("node:fs"); fs.appendFileSync(${JSON.stringify(join(directory, "events.jsonl"))}, fs.readFileSync(0, "utf8") + "\\n");\n`, { mode: 0o700 });
    const { default: extension } = await import("../../Integrations/pi/agent-watcher.ts");
    const handlers = new Map();
    extension({ on: (name, handler) => handlers.set(name, handler), events: eventBus() });
    const context = { mode: "tui", cwd: "/src/project", sessionManager: { getSessionId: () => "pi-session" }, isIdle: () => true, hasPendingMessages: () => false };
    await handlers.get("session_start")({}, context);
    handlers.get("before_agent_start")({ messageType: "user", prompt: "Fix the login redirect" }, context);
    handlers.get("tool_execution_start")({ toolName: "bash", toolCallId: "tool-1", args: { command: "bun test" } }, context);
    handlers.get("ui_prompt_start")({ kind: "confirm", title: "Allow command?" }, context);
    handlers.get("ui_prompt_end")({ kind: "confirm", title: "Allow command?" }, context);
    handlers.get("tool_execution_end")({ toolName: "bash", toolCallId: "tool-1" }, context);
    assert.equal(handlers.has("agent_end"), false, "intermediate agent_end can be followed by retries or queued work");
    await handlers.get("agent_settled")({ aborted: false }, context);
    await handlers.get("agent_settled")({ aborted: true }, context);
    const events = readFileSync(join(directory, "events.jsonl"), "utf8").trim().split("\n").map(JSON.parse);
    assert.deepEqual(events.map(e => e.hook_event_name), ["SessionStart", "UserPromptSubmit", "PreToolUse", "UIPromptStart", "UIPromptEnd", "PostToolUse", "Stop", "Interrupt"]);
    assert.equal(events[1].prompt, "Fix the login redirect");
    assert.equal(events[2].tool_input.command, "bun test");
    assert.equal(events[0].cli_pid, process.pid);
    handlers.get("session_start")({}, { ...context, mode: "print" });
    assert.equal(readFileSync(join(directory, "events.jsonl"), "utf8").trim().split("\n").length, 8);
    handlers.get("session_shutdown")?.({}, context);
  } finally {
    if (previous === undefined) delete process.env.AGENT_WATCHER_DATA_DIR;
    else process.env.AGENT_WATCHER_DATA_DIR = previous;
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Pi stays working while background subagents survive parent settlement and reload", async () => {
  const directory = mkdtempSync(join(tmpdir(), "agent-watcher-subagents-"));
  const previous = process.env.AGENT_WATCHER_DATA_DIR;
  process.env.AGENT_WATCHER_DATA_DIR = directory;
  const handlers = new Map();
  try {
    mkdirSync(join(directory, "bin"));
    const log = join(directory, "events.jsonl");
    writeFileSync(join(directory, "bin", "agent-watcher-hook"), `#!${process.execPath}\nconst fs = require("node:fs"); fs.appendFileSync(${JSON.stringify(log)}, fs.readFileSync(0, "utf8") + "\\n");\n`, { mode: 0o700 });
    const { default: extension } = await import("../../Integrations/pi/agent-watcher.ts");
    const events = eventBus();
    let entries = [{ key: "fleet-1", agent: "reviewer" }, { key: "fleet-2", agent: "builder" }];
    const methods = [];
    events.on("subagents:rpc:v1:request", (request) => {
      methods.push(request.method);
      events.emit(`subagents:rpc:v1:reply:${request.requestId}`, {
        version: 1, requestId: request.requestId, success: true,
        data: { fleet: { version: 1, totalActive: entries.length, entries, omitted: 0 } },
      });
    });
    let messagePending = false;
    const context = { mode: "tui", cwd: "/src/project", sessionManager: { getSessionId: () => "parent-session" }, isIdle: () => true, hasPendingMessages: () => messagePending };
    extension({ on: (name, handler) => handlers.set(name, handler), events });
    const published = () => readFileSync(log, "utf8").trim().split("\n").map(JSON.parse);
    await handlers.get("session_start")({ reason: "reload" }, context);
    assert.ok(published().some(event => event.hook_event_name === "PreToolUse" && event.tool_input.background_count === 2), "reload must recover subagents already running");
    handlers.get("before_agent_start")({ messageType: "user", prompt: "Check the changes" }, context);
    await handlers.get("agent_settled")({ aborted: false }, context);
    assert.equal(published().at(-1).hook_event_name, "PreToolUse", "parent settlement must keep background activity visible");
    assert.equal(published().some(event => event.hook_event_name === "Stop"), false, "parent must not finish while its subagents work");

    entries = entries.slice(1);
    events.emit("subagent:async-complete", { runId: "first-run" });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(published().at(-1).tool_input.background_count, 1, "one child's completion must not clear another");

    handlers.get("agent_start")({}, context);
    entries = [];
    events.emit("subagent:async-complete", { runId: "last-run" });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(published().at(-1).hook_event_name, "PostToolUse", "background completion must not finish a parent that resumed work");
    await handlers.get("agent_settled")({ aborted: false }, context);
    assert.equal(published().at(-1).hook_event_name, "Stop");

    entries = [{ key: "fleet-3", agent: "tester" }];
    events.emit("subagent:async-started", { id: "new-run" });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(published().at(-1).tool_input.background_count, 1);
    entries = [];
    messagePending = true;
    events.emit("subagent:async-complete", { runId: "new-run" });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(published().at(-1).hook_event_name, "PostToolUse", "a queued completion response must keep the parent working");
    messagePending = false;
    events.emit("subagent:child-status", {});
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(published().slice(-2).map(event => event.hook_event_name), ["PostToolUse", "Stop"], "the last subagent must finish an idle parent");
    assert.ok(methods.length > 0 && methods.every(method => method === "status"), "monitoring must only read status");
    assert.ok(published().every(event => event.cli_pid === process.pid && event.session_id === "parent-session"), "all activity must stay on the parent CLI's row");
  } finally {
    handlers.get("session_shutdown")?.({ reason: "quit" });
    if (previous === undefined) delete process.env.AGENT_WATCHER_DATA_DIR;
    else process.env.AGENT_WATCHER_DATA_DIR = previous;
    rmSync(directory, { recursive: true, force: true });
  }
});
