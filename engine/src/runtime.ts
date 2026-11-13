import path from "node:path";
import { BACKGROUND_CONTEXT, type Context } from "@earendil-works/chord/context";
import type { JsonValue } from "@earendil-works/chord/json";
import {
  type Conversation,
  type ConversationId,
  type Extension,
  Harness,
  type JsonObject,
  type SetTimer,
  type Storage,
  type TaskId,
  type ToolRegistration,
  createRegistry,
  defineDoc,
  defineExtension,
  defineTask,
  defineTool,
} from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { int, num, obj, opt, str } from "@earendil-works/pi-schema";
import { GRANNY_PROVIDER_ID, createGrannyModels } from "./provider.js";
import {
  ENGINE_PROTOCOL_VERSION,
  KernelRpcError,
  type EngineEnvelope,
  type KernelTransport,
} from "./wire.js";

export type LaneName = "interactive" | "proactive" | "reflection";

export type ProbeSpec =
  | { kind: "tabOpen"; urlSubstring: string }
  | { kind: "roundsZero" };

export type ScheduledIntentInput = {
  kind: string;
  fireAt: number;
  note: string;
  probe?: ProbeSpec;
};

type ScheduledIntentCheckpoint =
  | { phase: "sleep" }
  | { phase: "fire" }
  | { phase: "finish"; skipped: string | null };

export type ScheduledIntentResult = {
  fired: boolean;
  skipped?: string;
};

export type FiredIntentRecord = {
  taskId: number;
  kind: string;
  fireAt: number;
  firedAt: number;
  note: string;
  skipped: string | null;
};

export type GrannySessionState = {
  lanes: {
    interactive: number | null;
    proactive: number | null;
    reflection: number | null;
  };
  continuitySummary: string;
  firedIntents: FiredIntentRecord[];
};

export const GrannySessionDoc = defineDoc<GrannySessionState>({
  kind: "granny.session",
  version: 1,
  scope: "session",
  initial: () => ({
    lanes: {
      interactive: null,
      proactive: null,
      reflection: null,
    },
    continuitySummary: "",
    firedIntents: [],
  }),
  checkpointWhen: (_value, _ops, info) => info.deltasSinceBase >= 16,
});

/**
 * Wall-clock aware timer: slices long sleeps into <= `maxSliceMs` hops and
 * re-checks `now()` on every hop so a Mac lid-close sleep (which pauses
 * monotonic `setTimeout` counters while wall-clock `Date.now()` advances)
 * fires overdue Pi Durable tasks within seconds of wake.
 */
export function createWallClockTimer(
  now: () => number = () => Date.now(),
  maxSliceMs = 10_000,
): { setTimer: SetTimer; nudgeAll: () => void; dispose: () => void } {
  const activeChecks = new Set<() => void>();
  const activeDisarms = new Set<() => void>();
  let disposed = false;

  const setTimer: SetTimer = (callback, delayMs, options) => {
    if (disposed) return undefined;
    const targetAt = now() + Math.max(0, delayMs);
    let handle: ReturnType<typeof setTimeout> | undefined;
    let cancelled = false;

    const disarm = () => {
      cancelled = true;
      activeChecks.delete(checkOrRearm);
      activeDisarms.delete(disarm);
      if (handle !== undefined) {
        clearTimeout(handle);
        handle = undefined;
      }
    };

    const checkOrRearm = () => {
      if (cancelled || disposed) return;
      if (handle !== undefined) {
        clearTimeout(handle);
        handle = undefined;
      }
      const remaining = targetAt - now();
      if (remaining <= 0) {
        activeChecks.delete(checkOrRearm);
        activeDisarms.delete(disarm);
        callback();
        return;
      }
      const step = Math.max(1, Math.min(remaining, maxSliceMs));
      handle = setTimeout(checkOrRearm, step);
      if (options.background) {
        handle.unref();
      }
    };

    activeChecks.add(checkOrRearm);
    activeDisarms.add(disarm);
    const initialStep = Math.max(1, Math.min(Math.max(0, delayMs), maxSliceMs));
    handle = setTimeout(checkOrRearm, initialStep);
    if (options.background) {
      handle.unref();
    }

    return disarm;
  };

  const nudgeAll = () => {
    for (const check of [...activeChecks]) {
      check();
    }
  };

  const dispose = () => {
    disposed = true;
    for (const disarm of [...activeDisarms]) {
      disarm();
    }
  };

  return { setTimer, nudgeAll, dispose };
}

const INTERACTIVE_PROMPT = `You are Granny, a strict but affectionate grandmother task coach.
Reply in the same language the grandchild writes in (Vietnamese as "Ngoại"/"cháu", Finnish as "Mummo"/"kulta", or English as "granny"/"dear").
Keep answers short, warm, concrete, and under 3 sentences. Never invent tasks or bypass rules: use tools to read today's state, split vague tasks, move timetable slots, start a deep-work round, or schedule a follow-up check with intent_schedule when negotiating temporary research time.`;

const PROACTIVE_PROMPT = `You are Granny's background proactive lane.
Inspect today's state before acting. Compare what you see with the continuity summary from your previous check: if nothing meaningful changed, or nudgesRemaining is 0, or no nudge is genuinely helpful right now, do NOT call notify_speak — just update continuity_save if needed and finish quietly.
When a nudge is warranted, call notify_speak with ONE short, warm sentence in the grandchild's language and record what you said via continuity_save.`;

const REFLECTION_PROMPT = `You are Granny's quiet end-of-day reflection lane.
Read today's state and summarize factual completion patterns in one plain sentence without scolding.`;

function textToolResult(payload: JsonValue, isError = false) {
  const text = typeof payload === "string" ? payload : JSON.stringify(payload);
  return {
    output: [{ type: "text" as const, text }],
    isError,
  };
}

export interface GrannyDurableOptions {
  transport: KernelTransport;
  stateDir?: string;
  storage?: Storage;
  now?: () => number;
  setTimer?: SetTimer;
  context?: Context;
}

type ScheduledIntentTaskType = ReturnType<
  typeof defineTask<ScheduledIntentInput, ScheduledIntentCheckpoint, ScheduledIntentResult>
>;

export class GrannyDurableRuntime {
  readonly harness: Harness;
  readonly lanes: Record<LaneName, Conversation>;
  private readonly transport: KernelTransport;
  private readonly ctx: Context;
  private readonly nowFn: () => number;
  private readonly intentTaskDef: ScheduledIntentTaskType;
  private readonly nudgeTimers?: () => void;
  private readonly disposeTimers?: () => void;
  private interactiveQueue: Promise<void> = Promise.resolve();
  private readonly queuedInteractiveRunIds = new Set<string>();
  private activeInteractiveRunId: string | null = null;
  private activeInteractiveReasoning = false;
  private activeInteractiveEmittedText = "";
  private readonly abortedRunIds = new Set<string>();
  private unsubscribeInbound?: () => void;
  private closed = false;

  private constructor(
    harness: Harness,
    lanes: Record<LaneName, Conversation>,
    transport: KernelTransport,
    ctx: Context,
    nowFn: () => number,
    intentTaskDef: ScheduledIntentTaskType,
    nudgeTimers?: () => void,
    disposeTimers?: () => void,
  ) {
    this.harness = harness;
    this.lanes = lanes;
    this.transport = transport;
    this.ctx = ctx;
    this.nowFn = nowFn;
    this.intentTaskDef = intentTaskDef;
    this.nudgeTimers = nudgeTimers;
    this.disposeTimers = disposeTimers;
  }

  static async open(options: GrannyDurableOptions): Promise<GrannyDurableRuntime> {
    const ctx = options.context ?? BACKGROUND_CONTEXT;
    const nowFn = options.now ?? (() => Date.now());
    const storage =
      options.storage ??
      (await openNodeSqliteStorage(
        path.join(options.stateDir ?? ".", "engine", "durable.sqlite"),
      ));

    let runtimeRef: GrannyDurableRuntime | null = null;

    const scheduledIntentTask = defineTask<
      ScheduledIntentInput,
      ScheduledIntentCheckpoint,
      ScheduledIntentResult
    >({
      name: "granny.intent",
      version: 1,
      initial: () => ({ phase: "sleep" }),
      phases: {
        sleep: async (task, taskRuntime, phaseCtx) => {
          const nowMs = taskRuntime.now();
          if (nowMs < task.input.fireAt) {
            await taskRuntime.sleepUntil(task.input.fireAt, { phase: "fire" }, phaseCtx);
            return;
          }
          await taskRuntime.commit(() => ({
            status: "running",
            checkpoint: { phase: "fire" },
          }), phaseCtx);
        },
        fire: async (task, taskRuntime, phaseCtx) => {
          const probeSkip = await evaluateWaitProbe(options.transport, task.input.probe);
          const firedAt = taskRuntime.now();

          const snap = await taskRuntime.snapshot(GrannySessionDoc, phaseCtx);
          const proactiveId =
            typeof snap?.lanes.proactive === "number"
              ? (snap.lanes.proactive as ConversationId)
              : undefined;
          const proactiveHandle =
            proactiveId !== undefined
              ? await taskRuntime.conversation(proactiveId, phaseCtx)
              : undefined;

          let shouldEmitPush = false;

          await taskRuntime.commit(async (tx) => {
            const doc = await tx.doc(GrannySessionDoc);
            const alreadyRecorded = doc.firedIntents.some(
              (item) => item.taskId === Number(task.id),
            );
            if (!alreadyRecorded && !probeSkip && proactiveHandle) {
              // Call submit(tx, ...) before any table write in this commit so
              // the proactive turn admission and intent record commit atomically.
              const prompt = buildProactiveIntentPrompt(task.input, doc.continuitySummary);
              await proactiveHandle.submit(tx, {
                type: "input",
                content: prompt,
                whenBusy: "followUp",
              });
            }
            if (!alreadyRecorded) {
              doc.firedIntents.push({
                taskId: Number(task.id),
                kind: task.input.kind,
                fireAt: task.input.fireAt,
                firedAt,
                note: task.input.note,
                skipped: probeSkip ?? null,
              });
              if (doc.firedIntents.length > 100) {
                doc.firedIntents.splice(0, doc.firedIntents.length - 100);
              }
              shouldEmitPush = !probeSkip;
            }
            return {
              status: "running",
              checkpoint: { phase: "finish", skipped: probeSkip ?? null },
            };
          }, phaseCtx);

          if (shouldEmitPush) {
            options.transport.sendEnvelope({
              v: ENGINE_PROTOCOL_VERSION,
              event: "intent.fired",
              params: {
                taskId: Number(task.id),
                kind: task.input.kind,
                note: task.input.note,
                firedAt,
              },
            });
          }
        },
        finish: async (task, taskRuntime, phaseCtx) => {
          const skipped = task.state.checkpoint.skipped;
          await taskRuntime.commit(() => ({
            status: "terminal",
            outcome: {
              status: "completed",
              result: skipped ? { fired: false, skipped } : { fired: true },
            },
          }), phaseCtx);
        },
      },
      abort: async (_task, taskRuntime, phaseCtx) => {
        await taskRuntime.commit(() => ({
          status: "terminal",
          outcome: { status: "aborted", reason: "cancelled" },
        }), phaseCtx);
      },
    });

    const stateReadTool = defineTool({
      name: "state_read",
      description: "Read today's phase, tasks, timetable slots, finished rounds, streak, and remaining nudge budget.",
      parameters: obj({}),
      replay: "safe",
      execute: async () => {
        try {
          const res = await options.transport.callCapability("state.read", {});
          return textToolResult(res);
        } catch (err) {
          return textToolResult(errorText(err), true);
        }
      },
    });

    const deviceContextTool = defineTool({
      name: "device_context",
      description: "Read native macOS context: frontmost app, open browser tabs, and today's calendar events.",
      parameters: obj({}),
      replay: "safe",
      execute: async () => {
        try {
          const res = await options.transport.callCapability("device.context", {});
          return textToolResult(res);
        } catch (err) {
          return textToolResult(errorText(err), true);
        }
      },
    });

    const taskAddTool = defineTool({
      name: "state_task_add",
      description: "Propose adding a concrete task to today's notebook.",
      parameters: obj({
        title: str(),
        detail: opt(str()),
        slotID: opt(str()),
      }),
      replay: "unsafe",
      execute: async (args, api) => {
        try {
          const params: JsonObject = {
            title: args.title,
            ...(args.detail ? { detail: args.detail } : {}),
            ...(args.slotID ? { slotID: args.slotID } : {}),
          };
          const res = await options.transport.callCapability("state.task.add", params, {
            key: api.callId,
          });
          return textToolResult(res);
        } catch (err) {
          return textToolResult(errorText(err), true);
        }
      },
    });

    const taskTickTool = defineTool({
      name: "state_task_tick",
      description: "Mark a task done or undone (the kernel refuses unpaid last ticks).",
      parameters: obj({
        taskID: str(),
        done: opt(str()),
      }),
      replay: "unsafe",
      execute: async (args, api) => {
        try {
          const doneBool = args.done === undefined ? true : args.done !== "false";
          const res = await options.transport.callCapability(
            "state.task.tick",
            { taskID: args.taskID, done: doneBool },
            { key: api.callId },
          );
          return textToolResult(res);
        } catch (err) {
          return textToolResult(errorText(err), true);
        }
      },
    });

    const slotMoveTool = defineTool({
      name: "slot_move",
      description: "Move a task to a timetable slot ID (or omit slotID to re-propose).",
      parameters: obj({
        taskID: str(),
        slotID: opt(str()),
      }),
      replay: "unsafe",
      execute: async (args, api) => {
        try {
          const params: JsonObject = {
            taskID: args.taskID,
            ...(args.slotID !== undefined ? { slotID: args.slotID } : {}),
          };
          const res = await options.transport.callCapability("slot.move", params, {
            key: api.callId,
          });
          return textToolResult(res);
        } catch (err) {
          return textToolResult(errorText(err), true);
        }
      },
    });

    const roundStartTool = defineTool({
      name: "round_start",
      description: "Start a Pomodoro deep-work round now.",
      parameters: obj({}),
      replay: "unsafe",
      execute: async (_args, api) => {
        try {
          const res = await options.transport.callCapability(
            "round.start",
            {},
            { key: api.callId },
          );
          return textToolResult(res);
        } catch (err) {
          return textToolResult(errorText(err), true);
        }
      },
    });

    const notifySpeakTool = defineTool({
      name: "notify_speak",
      description: "Ask the kernel to speak and post one short coaching nudge (subject to quiet hours and daily budget).",
      parameters: obj({
        text: str(),
        reason: str(),
        slotID: opt(str()),
      }),
      replay: "unsafe",
      execute: async (args, api) => {
        try {
          const params: JsonObject = {
            text: args.text,
            reason: args.reason,
            ...(args.slotID ? { slotID: args.slotID } : {}),
          };
          const res = await options.transport.callCapability("notify.speak", params, {
            key: api.callId,
          });
          return textToolResult(res);
        } catch (err) {
          return textToolResult(errorText(err), true);
        }
      },
    });

    const intentScheduleTool = defineTool({
      name: "intent_schedule",
      description: "Schedule a durable follow-up check that survives restarts and Mac sleep, optionally gated by a zero-LLM probe.",
      parameters: obj({
        kind: str(),
        delayMinutes: opt(num()),
        fireAtMs: opt(int()),
        note: str(),
        probeTabUrl: opt(str()),
        probeRoundsZero: opt(str()),
      }),
      replay: "unsafe",
      execute: async (args, api, toolCtx) => {
        const baseNow = api.now();
        const fireAt =
          args.fireAtMs !== undefined
            ? args.fireAtMs
            : baseNow + Math.max(1, Math.round((args.delayMinutes ?? 15) * 60_000));

        const probe: ProbeSpec | undefined = args.probeTabUrl
          ? { kind: "tabOpen", urlSubstring: args.probeTabUrl }
          : args.probeRoundsZero === "true"
            ? { kind: "roundsZero" }
            : undefined;

        let taskIdNum = 0;
        await api.commit(async (tx) => {
          const doc = await tx.doc(GrannySessionDoc);
          const proactiveConvId =
            typeof doc.lanes.proactive === "number"
              ? (doc.lanes.proactive as ConversationId)
              : undefined;
          const created = await tx.createTask(
            scheduledIntentTask,
            {
              kind: args.kind,
              fireAt,
              note: args.note,
              ...(probe ? { probe } : {}),
            },
            {
              ownership: { kind: "conversation" },
              ...(proactiveConvId !== undefined ? { conversationId: proactiveConvId } : {}),
              background: true,
            },
          );
          taskIdNum = Number(created);
        }, toolCtx);
        return textToolResult({ scheduled: true, taskId: taskIdNum, fireAt });
      },
    });

    const continuitySaveTool = defineTool({
      name: "continuity_save",
      description: "Save a one-line continuity summary of what the proactive lane just observed and said.",
      parameters: obj({
        summary: str(),
      }),
      replay: "safe",
      execute: async (args, api, toolCtx) => {
        await api.commit(async (tx) => {
          const doc = await tx.doc(GrannySessionDoc);
          doc.continuitySummary = args.summary.slice(0, 280);
        }, toolCtx);
        return textToolResult({ saved: true });
      },
    });

    const grannyExtension = defineExtension({
      name: "granny",
      tools: [
        stateReadTool,
        deviceContextTool,
        taskAddTool,
        taskTickTool,
        slotMoveTool,
        roundStartTool,
        notifySpeakTool,
        intentScheduleTool,
        continuitySaveTool,
      ],
      tasks: [scheduledIntentTask],
    });

    const registry = createRegistry();
    registry.install(grannyExtension);

    const wallTimer = options.setTimer ? undefined : createWallClockTimer(nowFn);
    const models = createGrannyModels({
      transport: options.transport,
      onModelDelta: (modelId, delta) => {
        runtimeRef?.onModelDelta(modelId, delta);
      },
      shouldEnableReasoning: (modelId) => {
        return modelId === "interactive" && Boolean(runtimeRef?.activeInteractiveReasoning);
      },
    });

    const harness = await Harness.open(
      storage,
      {
        models,
        registry,
        now: nowFn,
        setTimer: options.setTimer ?? wallTimer!.setTimer,
      },
      ctx,
    );

    const lanes = await ensureThreeLanes(harness, ctx, grannyExtension, {
      interactive: [
        stateReadTool,
        deviceContextTool,
        taskAddTool,
        taskTickTool,
        slotMoveTool,
        roundStartTool,
        intentScheduleTool,
      ],
      proactive: [
        stateReadTool,
        deviceContextTool,
        notifySpeakTool,
        slotMoveTool,
        intentScheduleTool,
        continuitySaveTool,
      ],
      reflection: [stateReadTool],
    });
    const runtime = new GrannyDurableRuntime(
      harness,
      lanes,
      options.transport,
      ctx,
      nowFn,
      scheduledIntentTask,
      wallTimer?.nudgeAll,
      wallTimer?.dispose,
    );
    runtimeRef = runtime;
    runtime.attachInboundHandlers();
    harness.resume();
    return runtime;
  }

  /** Re-checks wall-clock timers and resumes the scheduler (e.g. after a simulated or real sleep jump). */
  nudgeClock(): void {
    this.nudgeTimers?.();
    if (!this.closed) {
      this.harness.resume();
    }
  }

  async scheduleIntent(input: {
    kind: string;
    fireAt: number;
    note: string;
    probe?: ProbeSpec;
  }): Promise<{ taskId: number; fireAt: number }> {
    let createdId = 0;
    await this.harness.commit(async (tx) => {
      const id = await tx.createTask(
        this.intentTaskDef,
        {
          kind: input.kind,
          fireAt: input.fireAt,
          note: input.note,
          ...(input.probe ? { probe: input.probe } : {}),
        },
        {
          ownership: { kind: "conversation" },
          conversationId: this.lanes.proactive.id,
          background: true,
        },
      );
      createdId = Number(id);
    }, this.ctx);
    this.harness.resume();
    return { taskId: createdId, fireAt: input.fireAt };
  }

  async sessionSnapshot(): Promise<Readonly<GrannySessionState> | undefined> {
    return this.harness.snapshot(GrannySessionDoc, this.ctx);
  }

  async waitForIdle(): Promise<void> {
    await this.harness.waitForIdle(this.ctx);
  }

  async waitForTask(taskId: number): Promise<JsonValue> {
    const settled = await this.harness.waitForTask(taskId as unknown as TaskId<JsonValue>, this.ctx);
    return settled.state.outcome as unknown as JsonValue;
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.unsubscribeInbound?.();
    try {
      await this.harness.close(this.ctx);
    } finally {
      this.disposeTimers?.();
    }
  }

  private onModelDelta(modelId: string, delta: string): void {
    if (modelId !== "interactive" || !this.activeInteractiveRunId) return;
    const runId = this.activeInteractiveRunId;
    if (this.abortedRunIds.has(runId)) return;
    this.activeInteractiveEmittedText += delta;
    this.transport.sendEnvelope({
      v: ENGINE_PROTOCOL_VERSION,
      id: runId,
      event: "chat.delta",
      params: { text: delta },
    });
  }

  private attachInboundHandlers(): void {
    this.unsubscribeInbound = this.transport.onInbound((envelope) => {
      void this.dispatchInbound(envelope);
    });
  }

  private async dispatchInbound(envelope: EngineEnvelope): Promise<void> {
    if (this.closed) return;

    if (envelope.method === "chat.prompt") {
      const runId = envelope.id ?? `c-${this.nowFn()}`;
      const params = (envelope.params ?? {}) as Record<string, unknown>;
      const text = typeof params.text === "string" ? params.text.trim() : "";
      const reasoning = params.reasoning === true;
      this.queuedInteractiveRunIds.add(runId);
      this.interactiveQueue = this.interactiveQueue.then(
        () => this.handleChatPrompt(runId, text, reasoning),
        () => this.handleChatPrompt(runId, text, reasoning),
      );
      await this.interactiveQueue;
      return;
    }

    if (envelope.method === "chat.abort") {
      const params = (envelope.params ?? {}) as Record<string, unknown>;
      const targetId =
        typeof params.id === "string" && params.id ? params.id : (envelope.id ?? "");
      if (!targetId) return;
      if (this.activeInteractiveRunId === targetId) {
        this.abortedRunIds.add(targetId);
        await this.lanes.interactive.abort(this.ctx, { background: false });
      } else if (this.queuedInteractiveRunIds.has(targetId)) {
        this.abortedRunIds.add(targetId);
      }
      return;
    }

    if (envelope.method === "intent.schedule") {
      const reqId = envelope.id ?? "intent-1";
      const params = (envelope.params ?? {}) as Record<string, unknown>;
      const kind = typeof params.kind === "string" && params.kind ? params.kind : "followup";
      const fireAt =
        typeof params.fireAt === "number"
          ? params.fireAt
          : this.nowFn() + 15 * 60_000;
      const payload = (params.payload ?? {}) as Record<string, unknown>;
      const note = typeof payload.note === "string" ? payload.note : kind;
      let probe: ProbeSpec | undefined;
      if (typeof payload.probeUrl === "string" && payload.probeUrl) {
        probe = { kind: "tabOpen", urlSubstring: payload.probeUrl };
      } else if (payload.probeRoundsZero === true) {
        probe = { kind: "roundsZero" };
      }
      try {
        const scheduled = await this.scheduleIntent({ kind, fireAt, note, probe });
        this.transport.sendEnvelope({
          v: ENGINE_PROTOCOL_VERSION,
          id: reqId,
          result: scheduled,
        });
      } catch (err) {
        this.transport.sendEnvelope({
          v: ENGINE_PROTOCOL_VERSION,
          id: reqId,
          error: {
            code: "internal",
            reason: errorText(err),
            retryable: false,
          },
        });
      }
      return;
    }

    if (envelope.method) {
      this.transport.sendEnvelope({
        v: ENGINE_PROTOCOL_VERSION,
        id: envelope.id ?? "",
        error: {
          code: "invalid",
          reason: `unsupported method ${envelope.method}`,
          retryable: false,
        },
      });
      return;
    }

    if (envelope.event) {
      const params = ((envelope.params && typeof envelope.params === "object" && !Array.isArray(envelope.params))
        ? envelope.params
        : {}) as JsonObject;
      if (envelope.event === "day.rollover") {
        await this.handleReflectionEvent(params);
      } else if (
        envelope.event === "day.woke" ||
        envelope.event === "slot.entered" ||
        envelope.event === "round.idle" ||
        envelope.event === "round.finished" ||
        envelope.event === "warn.continued"
      ) {
        await this.handleProactiveEvent(envelope.event, params);
      }
    }
  }

  private async handleChatPrompt(runId: string, text: string, reasoning = false): Promise<void> {
    this.queuedInteractiveRunIds.delete(runId);
    if (this.closed || this.abortedRunIds.has(runId)) {
      this.abortedRunIds.delete(runId);
      return;
    }
    if (!text) {
      this.transport.sendEnvelope({
        v: ENGINE_PROTOCOL_VERSION,
        id: runId,
        event: "chat.done",
        params: { text: "", toolCalls: [] },
      });
      return;
    }

    try {
      const beforeView = await this.lanes.interactive.context(this.ctx);
      const startIndex = beforeView.messages.length;

      this.activeInteractiveRunId = runId;
      this.activeInteractiveReasoning = reasoning;
      this.activeInteractiveEmittedText = "";

      const submission = await this.lanes.interactive.submit(
        { type: "input", content: text, whenBusy: "followUp" },
        this.ctx,
      );
      const settled = await submission.wait(this.ctx);

      if (this.abortedRunIds.has(runId)) {
        this.abortedRunIds.delete(runId);
        return;
      }

      const afterView = await this.lanes.interactive.context(this.ctx);
      const newMessages = afterView.messages.slice(startIndex);
      const assistantTexts: string[] = [];
      const toolCalls: JsonValue[] = [];
      let assistantError: string | undefined;

      for (const msg of newMessages) {
        if (msg.role !== "assistant") continue;
        if (msg.stopReason === "error" && msg.errorMessage) {
          assistantError = msg.errorMessage;
        }
        for (const block of msg.content) {
          if (block.type === "text" && block.text) {
            assistantTexts.push(block.text);
          } else if (block.type === "toolCall") {
            toolCalls.push({
              id: block.id,
              name: block.name,
              arguments: block.arguments as unknown as JsonValue,
            });
          }
        }
      }

      if (settled.status === "unanswered" || (assistantError && assistantTexts.length === 0)) {
        const settledDetail =
          settled.status === "unanswered" &&
          "detail" in settled &&
          typeof settled.detail === "string" &&
          settled.detail
            ? settled.detail
            : undefined;
        this.transport.sendEnvelope({
          v: ENGINE_PROTOCOL_VERSION,
          id: runId,
          event: "chat.error",
          params: { reason: settledDetail ?? assistantError ?? "unanswered" },
        });
        return;
      }

      const finalText =
        assistantTexts.join("\n").trim() || this.activeInteractiveEmittedText.trim();
      this.transport.sendEnvelope({
        v: ENGINE_PROTOCOL_VERSION,
        id: runId,
        event: "chat.done",
        params: { text: finalText, toolCalls },
      });
    } catch (err) {
      if (!this.abortedRunIds.has(runId)) {
        this.transport.sendEnvelope({
          v: ENGINE_PROTOCOL_VERSION,
          id: runId,
          event: "chat.error",
          params: { reason: errorText(err) },
        });
      }
      this.abortedRunIds.delete(runId);
    } finally {
      if (this.activeInteractiveRunId === runId) {
        this.activeInteractiveRunId = null;
        this.activeInteractiveReasoning = false;
        this.activeInteractiveEmittedText = "";
      }
    }
  }

  private async handleProactiveEvent(event: string, params: JsonObject): Promise<void> {
    // Cheap zero-LLM pre-gate: check state.read before waking the proactive model lane.
    try {
      const stateRaw = await this.transport.callCapability("state.read", {});
      const state = (stateRaw && typeof stateRaw === "object" && !Array.isArray(stateRaw))
        ? (stateRaw as Record<string, unknown>)
        : {};
      if (state.dayOff === true || state.nudgesRemaining === 0 || state.phase === "night") {
        return;
      }
      if (event === "day.woke" && typeof params.frogs === "number" && params.frogs <= 0) {
        return;
      }
      const snap = await this.sessionSnapshot();
      const continuity = snap?.continuitySummary ?? "";
      const prompt = [
        `Domain event: ${event}`,
        `Event params: ${JSON.stringify(params)}`,
        `Current state: ${JSON.stringify(state)}`,
        continuity ? `Previous continuity summary: ${continuity}` : "Previous continuity summary: (none)",
      ].join("\n");

      await this.lanes.proactive.submit(
        { type: "input", content: prompt, whenBusy: "followUp" },
        this.ctx,
      );
    } catch (err) {
      process.stderr.write(`granny-engine: proactive lane failed: ${errorText(err)}\n`);
    }
  }

  private async handleReflectionEvent(params: JsonObject): Promise<void> {
    try {
      const prompt = `Day rollover summary event: ${JSON.stringify(params)}. Read state_read if needed and summarize patterns briefly.`;
      await this.lanes.reflection.submit(
        { type: "input", content: prompt, whenBusy: "followUp" },
        this.ctx,
      );
    } catch (err) {
      process.stderr.write(`granny-engine: reflection lane failed: ${errorText(err)}\n`);
    }
  }
}

async function ensureThreeLanes(
  harness: Harness,
  ctx: Context,
  grannyExtension: Extension,
  laneTools: Record<LaneName, readonly ToolRegistration<any, any>[]>,
): Promise<Record<LaneName, Conversation>> {
  const existing = await harness.snapshot(GrannySessionDoc, ctx);
  const laneConfigs: Record<
    LaneName,
    { modelId: string; instructions: string }
  > = {
    interactive: {
      modelId: "interactive",
      instructions: INTERACTIVE_PROMPT,
    },
    proactive: {
      modelId: "fast",
      instructions: PROACTIVE_PROMPT,
    },
    reflection: {
      modelId: "default",
      instructions: REFLECTION_PROMPT,
    },
  };

  const resolved: Partial<Record<LaneName, Conversation>> = {};

  for (const name of ["interactive", "proactive", "reflection"] as const) {
    const savedId = existing?.lanes[name];
    if (typeof savedId === "number") {
      const found = await harness.conversation(savedId as ConversationId, ctx);
      if (found) {
        resolved[name] = found;
        continue;
      }
    }
    const cfg = laneConfigs[name];
    const created = await harness.createConversation(
      {
        ownership: { kind: "ownerless" },
        agent: {
          model: { provider: GRANNY_PROVIDER_ID, modelId: cfg.modelId },
          extensions: [grannyExtension],
          tools: laneTools[name],
          instructions: cfg.instructions,
          maxTurns: 8,
        },
      },
      ctx,
    );
    const createdId = Number(created.id);
    await harness.commit(async (tx) => {
      const doc = await tx.doc(GrannySessionDoc);
      doc.lanes[name] = createdId;
    }, ctx);
    resolved[name] = created;
  }

  return resolved as Record<LaneName, Conversation>;
}

async function evaluateWaitProbe(
  transport: KernelTransport,
  probe?: ProbeSpec,
): Promise<string | undefined> {
  if (!probe) return undefined;
  try {
    if (probe.kind === "tabOpen") {
      const res = await transport.callCapability("device.context", {});
      const obj = (res && typeof res === "object" && !Array.isArray(res))
        ? (res as Record<string, unknown>)
        : {};
      const tabs = Array.isArray(obj.openTabs) ? obj.openTabs : [];
      const needle = probe.urlSubstring.toLowerCase();
      const stillOpen = tabs.some((tab) => {
        const entry = (tab ?? {}) as Record<string, unknown>;
        return typeof entry.url === "string" && entry.url.toLowerCase().includes(needle);
      });
      return stillOpen ? undefined : "probe:tab_closed";
    }
    if (probe.kind === "roundsZero") {
      const res = await transport.callCapability("state.read", {});
      const obj = (res && typeof res === "object" && !Array.isArray(res))
        ? (res as Record<string, unknown>)
        : {};
      if (obj.dayOff === true || obj.phase === "rewarded" || (typeof obj.rounds === "number" && obj.rounds > 0)) {
        return "probe:already_paid";
      }
      return undefined;
    }
  } catch {
    // If a probe cannot read state, let the turn inspect rather than dropping silently.
  }
  return undefined;
}

function buildProactiveIntentPrompt(input: ScheduledIntentInput, continuity: string): string {
  return [
    `Scheduled intent fired (${input.kind}): ${input.note}`,
    continuity ? `Previous continuity summary: ${continuity}` : "Previous continuity summary: (none)",
    "Check state_read (and device_context if relevant) and decide whether one short notify_speak nudge is needed.",
  ].join("\n");
}

function errorText(err: unknown): string {
  if (err instanceof KernelRpcError) {
    return `${err.code}: ${err.message}`;
  }
  return err instanceof Error ? err.message : String(err);
}
