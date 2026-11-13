import type { JsonValue } from "@earendil-works/chord/json";
import type { JsonObject } from "@earendil-works/pi-durable";
import {
  type AssistantMessage,
  type Model,
  type Models,
  type SimpleStreamOptions,
  type StreamOptions,
  type ToolCall,
  type TranscriptContext,
  type Usage,
  contentText,
  createAssistantMessageEventStream,
  createModels,
  createProvider,
  getCurrentSystemPrompt,
  getCurrentTools,
} from "@earendil-works/pi-ai";
import type { KernelTransport } from "./wire.js";

export const GRANNY_PROVIDER_ID = "granny";
export const GRANNY_API_ID = "granny-socket";

const ZERO_COST = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

function makeUsage(inTokens = 0, outTokens = 0): Usage {
  return {
    input: inTokens,
    output: outTokens,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: inTokens + outTokens,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
  };
}

function tierForModelId(modelId: string): string {
  switch (modelId) {
    case "fast":
      return "fast";
    case "free":
      return "free";
    case "interactive":
    case "default":
    default:
      return "default";
  }
}

function safeParseJsonObject(raw: string): JsonObject {
  try {
    const parsed: unknown = JSON.parse(raw);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      return parsed as JsonObject;
    }
  } catch {
    // Fall back to empty object when a model emits malformed JSON arguments.
  }
  return {};
}

function convertTranscriptToWireMessages(context: TranscriptContext): JsonValue[] {
  const wire: JsonValue[] = [];
  const systemPrompt = getCurrentSystemPrompt(context.messages).trim();
  if (systemPrompt.length > 0) {
    wire.push({ role: "system", content: systemPrompt });
  }

  for (const msg of context.messages) {
    if (msg.role === "system") continue;
    if (msg.role === "user") {
      wire.push({
        role: "user",
        content: typeof msg.content === "string" ? msg.content : contentText(msg.content),
      });
      continue;
    }
    if (msg.role === "assistant") {
      const textParts: string[] = [];
      const toolCalls: JsonValue[] = [];
      for (const block of msg.content) {
        if (block.type === "text") {
          textParts.push(block.text);
        } else if (block.type === "toolCall") {
          toolCalls.push({
            id: block.id,
            name: block.name,
            arguments: JSON.stringify(block.arguments ?? {}),
          });
        }
      }
      const joined = textParts.join("");
      const entry: JsonObject = {
        role: "assistant",
        content: toolCalls.length > 0 && joined.length === 0 ? null : joined,
      };
      if (toolCalls.length > 0) {
        entry.toolCalls = toolCalls;
      }
      wire.push(entry);
      continue;
    }
    if (msg.role === "toolResult") {
      wire.push({
        role: "tool",
        toolCallID: msg.toolCallId,
        name: msg.toolName,
        content: contentText(msg.content),
      });
    }
  }
  return wire;
}

export interface GrannyModelsOptions {
  transport: KernelTransport;
  onModelDelta?: (modelId: string, delta: string) => void;
  shouldEnableReasoning?: (modelId: string) => boolean;
}

export function createGrannyModels(options: GrannyModelsOptions): Models {
  const catalog: readonly Model<typeof GRANNY_API_ID>[] = (
    ["interactive", "default", "fast", "free"] as const
  ).map((id) => ({
    id,
    name: `Granny (${id})`,
    api: GRANNY_API_ID,
    provider: GRANNY_PROVIDER_ID,
    baseUrl: "unix://engine.sock",
    reasoning: false,
    input: ["text"],
    cost: ZERO_COST,
    contextWindow: 128_000,
    maxTokens: 8_192,
  }));

  const runStream = (
    requestModel: Model<string>,
    context: TranscriptContext,
    streamOptions?: StreamOptions | SimpleStreamOptions,
  ) => {
    const out = createAssistantMessageEventStream();

    queueMicrotask(async () => {
      const partial: AssistantMessage = {
        role: "assistant",
        content: [],
        api: requestModel.api,
        provider: requestModel.provider,
        model: requestModel.id,
        usage: makeUsage(),
        stopReason: "stop",
        timestamp: Date.now(),
      };

      const signal = streamOptions?.signal;
      if (signal?.aborted) {
        const aborted: AssistantMessage = { ...partial, stopReason: "aborted" };
        out.push({ type: "error", reason: "aborted", error: aborted });
        out.end(aborted);
        return;
      }

      try {
        const wireMessages = convertTranscriptToWireMessages(context);
        const activeTools = getCurrentTools(context.messages).map((tool) => ({
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters as unknown as JsonValue,
        }));

        out.push({ type: "start", partial: { ...partial } });
        let textStarted = false;
        let textContent = "";

        const reasoning = options.shouldEnableReasoning?.(requestModel.id) ?? false;
        const done = await options.transport.streamModel(
          {
            messages: wireMessages,
            ...(activeTools.length > 0 ? { tools: activeTools } : {}),
            tier: tierForModelId(requestModel.id),
            reasoning,
          },
          (delta) => {
            if (!delta) return;
            if (!textStarted) {
              textStarted = true;
              partial.content = [{ type: "text", text: "" }];
              out.push({ type: "text_start", contentIndex: 0, partial: { ...partial } });
            }
            textContent += delta;
            partial.content = [{ type: "text", text: textContent }];
            out.push({
              type: "text_delta",
              contentIndex: 0,
              delta,
              partial: { ...partial },
            });
            options.onModelDelta?.(requestModel.id, delta);
          },
          signal,
        );

        // If the upstream returned final text without incremental deltas, emit it cleanly.
        if (!textStarted && done.text.length > 0) {
          textStarted = true;
          textContent = done.text;
          partial.content = [{ type: "text", text: "" }];
          out.push({ type: "text_start", contentIndex: 0, partial: { ...partial } });
          partial.content = [{ type: "text", text: textContent }];
          out.push({
            type: "text_delta",
            contentIndex: 0,
            delta: textContent,
            partial: { ...partial },
          });
          options.onModelDelta?.(requestModel.id, textContent);
        }

        if (textStarted) {
          out.push({
            type: "text_end",
            contentIndex: 0,
            content: textContent,
            partial: { ...partial },
          });
        }

        const parsedToolCalls: ToolCall[] = [];
        for (const rawCall of done.toolCalls) {
          if (!rawCall.name) continue;
          const contentIndex = partial.content.length;
          const argsObj = safeParseJsonObject(rawCall.arguments);
          const toolCall: ToolCall = {
            type: "toolCall",
            id: rawCall.id,
            name: rawCall.name,
            arguments: argsObj,
          };
          partial.content = [
            ...partial.content,
            { type: "toolCall", id: rawCall.id, name: rawCall.name, arguments: {} },
          ];
          out.push({ type: "toolcall_start", contentIndex, partial: { ...partial } });
          if (rawCall.arguments) {
            partial.content[contentIndex] = toolCall;
            out.push({
              type: "toolcall_delta",
              contentIndex,
              delta: rawCall.arguments,
              partial: { ...partial },
            });
          }
          partial.content[contentIndex] = toolCall;
          out.push({
            type: "toolcall_end",
            contentIndex,
            toolCall,
            partial: { ...partial },
          });
          parsedToolCalls.push(toolCall);
        }

        const stopReason = parsedToolCalls.length > 0 ? "toolUse" : "stop";
        const finalMessage: AssistantMessage = {
          ...partial,
          usage: makeUsage(done.usage.in, done.usage.out),
          stopReason,
          timestamp: Date.now(),
        };
        out.push({ type: "done", reason: stopReason, message: finalMessage });
        out.end(finalMessage);
      } catch (err) {
        const isAbort = Boolean(signal?.aborted) || (err instanceof Error && err.message === "aborted");
        const reason = isAbort ? "aborted" : "error";
        const errMsg = err instanceof Error ? err.message : String(err);
        const failedMessage: AssistantMessage = {
          ...partial,
          stopReason: reason,
          errorMessage: errMsg,
          timestamp: Date.now(),
        };
        out.push({ type: "error", reason, error: failedMessage });
        out.end(failedMessage);
      }
    });

    return out;
  };

  const provider = createProvider({
    id: GRANNY_PROVIDER_ID,
    name: "Granny Socket Provider",
    auth: {
      apiKey: {
        name: "Granny Kernel Socket",
        resolve: async () => ({ auth: {} }),
      },
    },
    models: catalog,
    api: {
      stream: runStream,
      streamSimple: runStream,
    },
  });

  const models = createModels();
  models.setProvider(provider);
  return models;
}
