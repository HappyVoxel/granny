import net from "node:net";
import type { JsonValue } from "@earendil-works/chord/json";
import type { JsonObject } from "@earendil-works/pi-durable";

export const ENGINE_PROTOCOL_VERSION = 1;
export const ENGINE_VERSION = "0.1.2";

export const DECLARED_CAPABILITIES = [
  "state.read",
  "device.context",
  "state.task.add",
  "state.task.tick",
  "slot.move",
  "round.start",
  "notify.speak",
  "trace.emit",
  "model.stream",
] as const;

export interface EngineErrorPayload {
  code: "refused" | "invalid" | "stale" | "duplicate" | "unavailable" | "internal";
  reason: string;
  retryable: boolean;
  result?: JsonValue;
}

export interface EngineEnvelope {
  v: number;
  id?: string;
  key?: string;
  method?: string;
  params?: JsonValue;
  result?: JsonValue;
  event?: string;
  error?: EngineErrorPayload;
}

export interface ModelToolCallWire {
  id: string;
  name: string;
  arguments: string;
}

export interface ModelStreamDoneWire {
  text: string;
  toolCalls: ModelToolCallWire[];
  usage: { in: number; out: number };
}

export class KernelRpcError extends Error {
  readonly code: EngineErrorPayload["code"];
  readonly retryable: boolean;

  constructor(payload: EngineErrorPayload) {
    super(`${payload.code}: ${payload.reason}`);
    this.name = "KernelRpcError";
    this.code = payload.code;
    this.retryable = payload.retryable;
  }
}

export interface KernelTransport {
  callCapability(
    method: string,
    params: JsonObject,
    options?: { key?: string; signal?: AbortSignal; timeoutMs?: number },
  ): Promise<JsonValue>;

  streamModel(
    params: {
      messages: JsonValue[];
      tools?: JsonValue[];
      tier?: string;
      reasoning?: boolean;
    },
    onDelta: (text: string) => void,
    signal?: AbortSignal,
    timeoutMs?: number,
  ): Promise<ModelStreamDoneWire>;

  sendEnvelope(envelope: EngineEnvelope): void;
  onInbound(handler: (envelope: EngineEnvelope) => void): () => void;
  close(): void;
}

interface PendingRpc {
  resolve: (value: JsonValue) => void;
  reject: (err: Error) => void;
  cleanup?: () => void;
}

interface PendingStream {
  onDelta: (text: string) => void;
  touch?: () => void;
  resolve: (done: ModelStreamDoneWire) => void;
  reject: (err: Error) => void;
  cleanup?: () => void;
}

const DEFAULT_RPC_TIMEOUT_MS = 30_000;
const DEFAULT_STREAM_IDLE_TIMEOUT_MS = 45_000;

export class SocketKernelTransport implements KernelTransport {
  private readonly socket: net.Socket;
  private nextSeq = 1;
  private readonly pendingRpcs = new Map<string, PendingRpc>();
  private readonly pendingStreams = new Map<string, PendingStream>();
  private readonly inboundListeners = new Set<(envelope: EngineEnvelope) => void>();
  private readonly bufferedInbound: EngineEnvelope[] = [];
  private closed = false;

  private constructor(socket: net.Socket) {
    this.socket = socket;
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      let nl: number;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (!line) continue;
        let msg: EngineEnvelope;
        try {
          msg = JSON.parse(line) as EngineEnvelope;
        } catch {
          continue;
        }
        this.handleLine(msg);
      }
    });
    socket.on("close", () => this.failAll("kernel socket closed"));
    socket.on("error", (e) => this.failAll(`kernel socket error: ${e.message}`));
  }

  private failAll(reason: string): void {
    this.closed = true;
    if (this.pendingRpcs.size === 0 && this.pendingStreams.size === 0) return;
    const err = new Error(reason);
    for (const p of this.pendingRpcs.values()) {
      p.cleanup?.();
      p.reject(err);
    }
    this.pendingRpcs.clear();
    for (const s of this.pendingStreams.values()) {
      s.cleanup?.();
      s.reject(err);
    }
    this.pendingStreams.clear();
  }

  static async connect(
    socketPath: string,
    impl = `granny-engine/${ENGINE_VERSION}`,
  ): Promise<{ transport: SocketKernelTransport; limits?: JsonObject }> {
    const socket = await new Promise<net.Socket>((resolve, reject) => {
      const conn = net.createConnection(socketPath);
      const onErr = (err: Error) => {
        conn.removeListener("connect", onConnect);
        reject(err);
      };
      const onConnect = () => {
        conn.removeListener("error", onErr);
        resolve(conn);
      };
      conn.once("error", onErr);
      conn.once("connect", onConnect);
    });

    const transport = new SocketKernelTransport(socket);
    const reply = await transport.callCapability("hello", {
      role: "engine",
      impl,
      capabilities: [...DECLARED_CAPABILITIES],
    });
    const obj = (reply && typeof reply === "object" && !Array.isArray(reply))
      ? (reply as JsonObject)
      : {};
    if (obj.role !== "kernel") {
      transport.close();
      throw new Error(`expected kernel hello role, got ${String(obj.role)}`);
    }
    const limits = (obj.limits && typeof obj.limits === "object" && !Array.isArray(obj.limits))
      ? (obj.limits as JsonObject)
      : undefined;
    return { transport, limits };
  }

  onDisconnect(cb: () => void): void {
    if (this.closed || this.socket.destroyed) {
      queueMicrotask(cb);
      return;
    }
    this.socket.once("close", cb);
  }

  sendEnvelope(envelope: EngineEnvelope): void {
    if (this.closed || this.socket.destroyed) return;
    this.socket.write(`${JSON.stringify(envelope)}\n`);
  }

  onInbound(handler: (envelope: EngineEnvelope) => void): () => void {
    this.inboundListeners.add(handler);
    if (this.bufferedInbound.length > 0) {
      const queued = this.bufferedInbound.splice(0, this.bufferedInbound.length);
      queueMicrotask(() => {
        if (!this.inboundListeners.has(handler)) return;
        for (const msg of queued) {
          handler(msg);
        }
      });
    }
    return () => this.inboundListeners.delete(handler);
  }

  callCapability(
    method: string,
    params: JsonObject,
    options?: { key?: string; signal?: AbortSignal; timeoutMs?: number },
  ): Promise<JsonValue> {
    if (this.closed) {
      return Promise.reject(new Error("kernel socket closed"));
    }
    if (options?.signal?.aborted) {
      return Promise.reject(new Error("aborted"));
    }
    const id = `e-${this.nextSeq++}`;
    const timeoutMs = options?.timeoutMs ?? DEFAULT_RPC_TIMEOUT_MS;
    return new Promise<JsonValue>((resolve, reject) => {
      const timer = setTimeout(() => {
        const entry = this.pendingRpcs.get(id);
        if (!entry) return;
        this.pendingRpcs.delete(id);
        entry.cleanup?.();
        reject(
          new KernelRpcError({
            code: "internal",
            reason: `capability ${method} timed out after ${timeoutMs}ms`,
            retryable: true,
          }),
        );
      }, timeoutMs);
      timer.unref();
      const onAbort = () => {
        clearTimeout(timer);
        this.pendingRpcs.delete(id);
        reject(new Error("aborted"));
      };
      options?.signal?.addEventListener("abort", onAbort, { once: true });
      this.pendingRpcs.set(id, {
        resolve,
        reject,
        cleanup: () => {
          clearTimeout(timer);
          options?.signal?.removeEventListener("abort", onAbort);
        },
      });
      this.sendEnvelope({
        v: ENGINE_PROTOCOL_VERSION,
        id,
        ...(options?.key ? { key: options.key } : {}),
        method,
        params,
      });
    });
  }

  streamModel(
    params: {
      messages: JsonValue[];
      tools?: JsonValue[];
      tier?: string;
      reasoning?: boolean;
    },
    onDelta: (text: string) => void,
    signal?: AbortSignal,
    timeoutMs = DEFAULT_STREAM_IDLE_TIMEOUT_MS,
  ): Promise<ModelStreamDoneWire> {
    if (this.closed) {
      return Promise.reject(new Error("kernel socket closed"));
    }
    if (signal?.aborted) {
      return Promise.reject(new Error("aborted"));
    }
    const id = `ms-${this.nextSeq++}`;
    return new Promise<ModelStreamDoneWire>((resolve, reject) => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      const armIdleTimer = () => {
        if (timer !== undefined) clearTimeout(timer);
        timer = setTimeout(() => {
          const entry = this.pendingStreams.get(id);
          if (!entry) return;
          this.pendingStreams.delete(id);
          entry.cleanup?.();
          reject(
            new KernelRpcError({
              code: "internal",
              reason: `model.stream timed out after ${timeoutMs}ms`,
              retryable: true,
            }),
          );
        }, timeoutMs);
        timer.unref();
      };
      armIdleTimer();

      const onAbort = () => {
        if (timer !== undefined) clearTimeout(timer);
        this.pendingStreams.delete(id);
        reject(new Error("aborted"));
      };
      signal?.addEventListener("abort", onAbort, { once: true });
      this.pendingStreams.set(id, {
        onDelta,
        touch: armIdleTimer,
        resolve,
        reject,
        cleanup: () => {
          if (timer !== undefined) clearTimeout(timer);
          signal?.removeEventListener("abort", onAbort);
        },
      });
      const wireParams: JsonObject = {
        messages: params.messages,
        ...(params.tools && params.tools.length > 0 ? { tools: params.tools } : {}),
        ...(params.tier ? { tier: params.tier } : {}),
        ...(params.reasoning !== undefined ? { reasoning: params.reasoning } : {}),
      };
      this.sendEnvelope({
        v: ENGINE_PROTOCOL_VERSION,
        id,
        method: "model.stream",
        params: wireParams,
      });
    });
  }

  close(): void {
    this.failAll("kernel socket closed");
    this.socket.destroy();
  }

  private handleLine(msg: EngineEnvelope): void {
    if (msg.id && this.pendingStreams.has(msg.id)) {
      const pending = this.pendingStreams.get(msg.id)!;
      if (msg.event === "model.delta") {
        pending.touch?.();
        const params = msg.params as JsonObject | undefined;
        if (params && typeof params.text === "string") {
          pending.onDelta(params.text);
        }
        return;
      }
      if (msg.event === "model.done") {
        this.pendingStreams.delete(msg.id);
        pending.cleanup?.();
        const raw = (msg.params ?? {}) as Record<string, unknown>;
        const rawUsage = (raw.usage ?? {}) as Record<string, unknown>;
        const rawCalls = Array.isArray(raw.toolCalls) ? raw.toolCalls : [];
        pending.resolve({
          text: typeof raw.text === "string" ? raw.text : "",
          toolCalls: rawCalls.map((c, idx) => {
            const item = (c ?? {}) as Record<string, unknown>;
            return {
              id: typeof item.id === "string" && item.id ? item.id : `call_${idx}`,
              name: typeof item.name === "string" ? item.name : "",
              arguments: typeof item.arguments === "string" ? item.arguments : "{}",
            };
          }),
          usage: {
            in: typeof rawUsage.in === "number" ? rawUsage.in : 0,
            out: typeof rawUsage.out === "number" ? rawUsage.out : 0,
          },
        });
        return;
      }
      if (msg.error) {
        this.pendingStreams.delete(msg.id);
        pending.cleanup?.();
        pending.reject(new KernelRpcError(msg.error));
        return;
      }
    }

    if (msg.id && this.pendingRpcs.has(msg.id)) {
      const pending = this.pendingRpcs.get(msg.id)!;
      this.pendingRpcs.delete(msg.id);
      pending.cleanup?.();
      if (msg.error) {
        if (msg.error.code === "duplicate" && msg.error.result !== undefined) {
          pending.resolve(msg.error.result);
          return;
        }
        pending.reject(new KernelRpcError(msg.error));
        return;
      }
      pending.resolve(msg.result ?? null);
      return;
    }

    if (this.inboundListeners.size === 0) {
      if (this.bufferedInbound.length < 32) {
        this.bufferedInbound.push(msg);
      }
      return;
    }

    for (const listener of this.inboundListeners) {
      listener(msg);
    }
  }
}
