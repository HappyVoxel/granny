import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import type { JsonValue } from "@earendil-works/chord/json";
import type { JsonObject } from "@earendil-works/pi-durable";
import { GrannyDurableRuntime } from "../src/runtime.js";
import {
  ENGINE_PROTOCOL_VERSION,
  type EngineEnvelope,
  type KernelTransport,
  type ModelStreamDoneWire,
  SocketKernelTransport,
} from "../src/wire.js";

class FakeKernelTransport implements KernelTransport {
  readonly capabilityCalls: Array<{ method: string; params: JsonObject; key?: string }> = [];
  readonly modelStreamCalls: Array<{ messages: JsonValue[]; tools?: JsonValue[]; tier?: string }> = [];
  readonly sentEnvelopes: EngineEnvelope[] = [];
  private readonly inboundListeners = new Set<(env: EngineEnvelope) => void>();

  stateSnapshot: JsonObject = {
    phase: "working",
    date: "2026-11-11",
    dayOff: false,
    tasks: [{ id: "t-1", title: "Ship Slice 4", done: false }],
    slots: [{ id: "morning", time: "09:00", label: "Deep work", tag: "deepWork" }],
    rounds: 0,
    streak: 4,
    blocksEnforced: true,
    nudgesRemaining: 3,
  };

  deviceSnapshot: JsonObject = {
    frontmostApp: { name: "Safari", bundleID: "com.apple.Safari" },
    openTabs: [{ browser: "Safari", url: "https://www.youtube.com/watch?v=abc", title: "Lecture" }],
    calendarEvents: [],
  };

  modelResponder: (
    params: { messages: JsonValue[]; tools?: JsonValue[]; tier?: string },
    onDelta: (text: string) => void,
    signal?: AbortSignal,
  ) => Promise<ModelStreamDoneWire> = async (_params, onDelta) => {
    onDelta("Ngồi vào ");
    onDelta("bàn đi cháu.");
    return {
      text: "Ngồi vào bàn đi cháu.",
      toolCalls: [],
      usage: { in: 20, out: 6 },
    };
  };

  async callCapability(
    method: string,
    params: JsonObject,
    options?: { key?: string },
  ): Promise<JsonValue> {
    this.capabilityCalls.push({ method, params, key: options?.key });
    if (method === "state.read") return this.stateSnapshot;
    if (method === "device.context") return this.deviceSnapshot;
    if (method === "notify.speak") return { delivered: true };
    if (method === "state.task.add") return { taskID: "t-added" };
    if (method === "round.start") return { stage: "deepWork", endsAt: "2026-11-11T10:25:00Z" };
    if (method === "slot.move") return { proposals: [] };
    if (method === "state.task.tick") return { phase: "working" };
    return {};
  }

  streamModel(
    params: { messages: JsonValue[]; tools?: JsonValue[]; tier?: string },
    onDelta: (text: string) => void,
    signal?: AbortSignal,
  ): Promise<ModelStreamDoneWire> {
    this.modelStreamCalls.push(params);
    return this.modelResponder(params, onDelta, signal);
  }

  sendEnvelope(envelope: EngineEnvelope): void {
    this.sentEnvelopes.push(envelope);
  }

  onInbound(handler: (envelope: EngineEnvelope) => void): () => void {
    this.inboundListeners.add(handler);
    return () => this.inboundListeners.delete(handler);
  }

  pushInbound(envelope: EngineEnvelope): void {
    for (const listener of this.inboundListeners) {
      listener(envelope);
    }
  }

  close(): void {}
}

async function waitUntil(
  predicate: () => boolean | Promise<boolean>,
  timeoutMs = 4_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((r) => setTimeout(r, 15));
  }
  throw new Error("timed out waiting for condition");
}

test("sleep-resume: durable intent fires immediately after a wall-clock Mac sleep jump", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "granny-durable-sleep-"));
  try {
    let clock = Date.parse("2026-11-11T09:00:00Z");
    const transport = new FakeKernelTransport();
    let proactiveStep = 0;
    transport.modelResponder = async (params, onDelta) => {
      assert.equal(params.tier, "fast");
      proactiveStep += 1;
      if (proactiveStep === 1) {
        return {
          text: "",
          toolCalls: [
            {
              id: "call_speak_1",
              name: "notify_speak",
              arguments: JSON.stringify({
                text: "Hết 25 phút đọc rồi cháu, quay lại việc chính nha.",
                reason: "followup",
              }),
            },
            {
              id: "call_cont_1",
              name: "continuity_save",
              arguments: JSON.stringify({
                summary: "Reminded grandchild after 25m YouTube negotiation.",
              }),
            },
          ],
          usage: { in: 30, out: 15 },
        };
      }
      onDelta("Done.");
      return { text: "Done.", toolCalls: [], usage: { in: 25, out: 2 } };
    };

    const runtime = await GrannyDurableRuntime.open({
      transport,
      stateDir: dir,
      now: () => clock,
    });

    const fireAt = clock + 25 * 60_000;
    const scheduled = await runtime.scheduleIntent({
      kind: "warn.followup",
      fireAt,
      note: "Check whether grandchild finished the 25m video",
      probe: { kind: "tabOpen", urlSubstring: "youtube.com" },
    });
    assert.equal(scheduled.fireAt, fireAt);

    // 5 minutes later: still sleeping, zero model spend.
    clock += 5 * 60_000;
    runtime.nudgeClock();
    await new Promise((r) => setTimeout(r, 40));
    assert.equal(transport.modelStreamCalls.length, 0);

    // Simulate Mac lid-close sleep jumping 30 minutes past deadline.
    clock += 30 * 60_000;
    runtime.nudgeClock();

    await waitUntil(() =>
      transport.capabilityCalls.some((c) => c.method === "notify.speak"),
    );
    await runtime.waitForIdle();

    assert.ok(
      transport.sentEnvelopes.some((e) => e.event === "intent.fired"),
      "expected intent.fired push",
    );
    const speakCall = transport.capabilityCalls.find((c) => c.method === "notify.speak");
    assert.equal(speakCall?.key, "call_speak_1");
    const snap = await runtime.sessionSnapshot();
    assert.equal(
      snap?.continuitySummary,
      "Reminded grandchild after 25m YouTube negotiation.",
    );

    await runtime.close();
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("crash recovery: lane conversation IDs and sleeping intents survive SQLite restart", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "granny-durable-crash-"));
  try {
    let clock = Date.parse("2026-11-11T10:00:00Z");
    const transport1 = new FakeKernelTransport();
    const runtime1 = await GrannyDurableRuntime.open({
      transport: transport1,
      stateDir: dir,
      now: () => clock,
    });

    const originalLaneIds = {
      interactive: Number(runtime1.lanes.interactive.id),
      proactive: Number(runtime1.lanes.proactive.id),
      reflection: Number(runtime1.lanes.reflection.id),
    };
    assert.notEqual(originalLaneIds.interactive, originalLaneIds.proactive);
    assert.notEqual(originalLaneIds.proactive, originalLaneIds.reflection);

    const { taskId } = await runtime1.scheduleIntent({
      kind: "slot.check",
      fireAt: clock + 20 * 60_000,
      note: "Check morning deep-work slot",
    });

    // Shut down process #1 before `fireAt` arrives.
    await runtime1.close();
    assert.equal(transport1.sentEnvelopes.length, 0);

    // Process #2 starts 25 minutes later on the same SQLite database.
    clock += 25 * 60_000;
    const transport2 = new FakeKernelTransport();
    const runtime2 = await GrannyDurableRuntime.open({
      transport: transport2,
      stateDir: dir,
      now: () => clock,
    });

    assert.equal(Number(runtime2.lanes.interactive.id), originalLaneIds.interactive);
    assert.equal(Number(runtime2.lanes.proactive.id), originalLaneIds.proactive);
    assert.equal(Number(runtime2.lanes.reflection.id), originalLaneIds.reflection);

    const outcome = await runtime2.waitForTask(taskId);
    assert.deepEqual(outcome, {
      status: "completed",
      result: { fired: true },
    });
    assert.ok(
      transport2.sentEnvelopes.some((e) => e.event === "intent.fired"),
      "recovered sleeping intent fired after restart",
    );
    await runtime2.waitForIdle();
    await runtime2.close();
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("zero-LLM wait probes skip model turns when tab closed or round already paid", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "granny-durable-probe-"));
  try {
    let clock = Date.parse("2026-11-11T11:00:00Z");
    const transport = new FakeKernelTransport();
    transport.deviceSnapshot = {
      frontmostApp: { name: "Xcode", bundleID: "com.apple.dt.Xcode" },
      openTabs: [{ browser: "Safari", url: "https://developer.apple.com", title: "Docs" }],
      calendarEvents: [],
    };
    transport.stateSnapshot = {
      ...transport.stateSnapshot,
      rounds: 2,
    };

    const runtime = await GrannyDurableRuntime.open({
      transport,
      stateDir: dir,
      now: () => clock,
    });

    const tabTask = await runtime.scheduleIntent({
      kind: "tab.watch",
      fireAt: clock + 60_000,
      note: "Ensure YouTube tab closed",
      probe: { kind: "tabOpen", urlSubstring: "youtube.com" },
    });
    const roundTask = await runtime.scheduleIntent({
      kind: "idle.watch",
      fireAt: clock + 60_000,
      note: "Ensure first tomato ran",
      probe: { kind: "roundsZero" },
    });

    clock += 120_000;
    runtime.nudgeClock();

    const tabOutcome = await runtime.waitForTask(tabTask.taskId);
    const roundOutcome = await runtime.waitForTask(roundTask.taskId);
    assert.deepEqual(tabOutcome, {
      status: "completed",
      result: { fired: false, skipped: "probe:tab_closed" },
    });
    assert.deepEqual(roundOutcome, {
      status: "completed",
      result: { fired: false, skipped: "probe:already_paid" },
    });
    assert.equal(
      transport.modelStreamCalls.length,
      0,
      "zero model.stream calls should happen when probes short-circuit",
    );

    await runtime.close();
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("AF_UNIX socket transport: interactive tool loop recovers duplicate key & chat.abort spares proactive intents", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "granny-durable-sock-"));
  const sockPath = path.join(dir, "engine.sock");

  const serverConns: net.Socket[] = [];
  const fromEngine: EngineEnvelope[] = [];
  let streamTurn = 0;
  let hangNextStream = false;

  const server = net.createServer((conn) => {
    serverConns.push(conn);
    let buf = "";
    conn.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      let nl: number;
      while ((nl = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (!line) continue;
        const msg = JSON.parse(line) as EngineEnvelope;
        fromEngine.push(msg);

        if (msg.method === "hello") {
          conn.write(
            JSON.stringify({
              v: ENGINE_PROTOCOL_VERSION,
              id: msg.id,
              result: {
                role: "kernel",
                impl: "granny/0.1.2",
                capabilities: ["state.read", "state.task.add", "model.stream"],
                limits: { nudgesRemaining: 3, quietStart: 23, quietEnd: 7 },
              },
            }) + "\n",
          );
          continue;
        }
        if (msg.method === "state.task.add") {
          // Simulate idempotency replay: kernel answers `duplicate` carrying original result.
          conn.write(
            JSON.stringify({
              v: ENGINE_PROTOCOL_VERSION,
              id: msg.id,
              error: {
                code: "duplicate",
                reason: "key already applied",
                retryable: false,
                result: { taskID: "t-deduped" },
              },
            }) + "\n",
          );
          continue;
        }
        if (msg.method === "model.stream") {
          if (hangNextStream) {
            conn.write(
              JSON.stringify({
                v: ENGINE_PROTOCOL_VERSION,
                id: msg.id,
                event: "model.delta",
                params: { text: "Đang nghĩ..." },
              }) + "\n",
            );
            continue;
          }
          streamTurn += 1;
          if (streamTurn === 1) {
            conn.write(
              JSON.stringify({
                v: ENGINE_PROTOCOL_VERSION,
                id: msg.id,
                event: "model.done",
                params: {
                  text: "",
                  toolCalls: [
                    {
                      id: "call_dup_1",
                      name: "state_task_add",
                      arguments: JSON.stringify({ title: "Apply 5 jobs" }),
                    },
                  ],
                  usage: { in: 15, out: 8 },
                },
              }) + "\n",
            );
          } else {
            conn.write(
              JSON.stringify({
                v: ENGINE_PROTOCOL_VERSION,
                id: msg.id,
                event: "model.delta",
                params: { text: "Ngoại ghi " },
              }) + "\n",
            );
            conn.write(
              JSON.stringify({
                v: ENGINE_PROTOCOL_VERSION,
                id: msg.id,
                event: "model.delta",
                params: { text: "vào sổ rồi nhé!" },
              }) + "\n",
            );
            conn.write(
              JSON.stringify({
                v: ENGINE_PROTOCOL_VERSION,
                id: msg.id,
                event: "model.done",
                params: {
                  text: "Ngoại ghi vào sổ rồi nhé!",
                  toolCalls: [],
                  usage: { in: 28, out: 9 },
                },
              }) + "\n",
            );
          }
        }
      }
    });
  });

  await new Promise<void>((resolve) => server.listen(sockPath, resolve));

  try {
    let clock = Date.parse("2026-11-11T14:00:00Z");
    const { transport } = await SocketKernelTransport.connect(sockPath);
    const runtime = await GrannyDurableRuntime.open({
      transport,
      stateDir: dir,
      now: () => clock,
    });

    // 1. Complete interactive prompt with duplicate-key recovery.
    const activeConn = serverConns[0]!;
    activeConn.write(
      JSON.stringify({
        v: ENGINE_PROTOCOL_VERSION,
        id: "c-run-1",
        method: "chat.prompt",
        params: { text: "Thêm việc nộp 5 CV giúp cháu", stream: true },
      }) + "\n",
    );

    await waitUntil(() =>
      fromEngine.some((m) => m.id === "c-run-1" && m.event === "chat.done"),
    );

    const deltas = fromEngine
      .filter((m) => m.id === "c-run-1" && m.event === "chat.delta")
      .map((m) => (m.params as Record<string, unknown>).text);
    assert.deepEqual(deltas, ["Ngoại ghi ", "vào sổ rồi nhé!"]);

    const doneEvt = fromEngine.find((m) => m.id === "c-run-1" && m.event === "chat.done")!;
    const doneParams = doneEvt.params as Record<string, unknown>;
    assert.equal(doneParams.text, "Ngoại ghi vào sổ rồi nhé!");
    assert.equal((doneParams.toolCalls as unknown[]).length, 1);

    // 2. Schedule a proactive intent, then abort an in-flight interactive prompt:
    //    the background proactive intent must survive!
    const bgIntent = await runtime.scheduleIntent({
      kind: "survive.abort",
      fireAt: clock + 10 * 60_000,
      note: "Background check must survive chat.abort",
    });

    hangNextStream = true;
    activeConn.write(
      JSON.stringify({
        v: ENGINE_PROTOCOL_VERSION,
        id: "c-slow",
        method: "chat.prompt",
        params: { text: "câu hỏi dài", stream: true },
      }) + "\n",
    );
    await waitUntil(() =>
      fromEngine.some((m) => m.id === "c-slow" && m.event === "chat.delta"),
    );

    activeConn.write(
      JSON.stringify({
        v: ENGINE_PROTOCOL_VERSION,
        id: "c-abort",
        method: "chat.abort",
        params: { id: "c-slow" },
      }) + "\n",
    );
    await new Promise((r) => setTimeout(r, 80));

    // Advance clock so the proactive intent fires after chat.abort!
    hangNextStream = false;
    clock += 15 * 60_000;
    runtime.nudgeClock();

    const bgOutcome = await runtime.waitForTask(bgIntent.taskId);
    assert.deepEqual(bgOutcome, {
      status: "completed",
      result: { fired: true },
    });

    await runtime.waitForIdle();
    await runtime.close();
    transport.close();
  } finally {
    for (const c of serverConns) c.destroy();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
