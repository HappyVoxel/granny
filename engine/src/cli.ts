import fs from "node:fs";
import path from "node:path";
import { GrannyDurableRuntime } from "./runtime.js";
import { ENGINE_PROTOCOL_VERSION, SocketKernelTransport } from "./wire.js";

async function main(): Promise<void> {
  const socketPath = process.env.GRANNY_ENGINE_SOCKET;
  if (!socketPath) {
    process.stderr.write("granny-engine: GRANNY_ENGINE_SOCKET is required\n");
    process.exit(2);
  }

  const stateDir = process.env.GRANNY_ENGINE_STORAGE_DIR || path.dirname(socketPath);
  const { transport } = await SocketKernelTransport.connect(socketPath);

  let runtime: GrannyDurableRuntime | null = null;
  let wakeSweep: ReturnType<typeof setInterval> | null = null;
  let shuttingDown = false;

  const shutdown = async (code = 0) => {
    if (shuttingDown) return;
    shuttingDown = true;
    if (wakeSweep) clearInterval(wakeSweep);
    // Reject any pending socket RPC/stream first so `runtime.close()` cannot hang.
    transport.close();
    try {
      await runtime?.close();
    } catch {
      // Ignore close errors during exit.
    }
    process.exit(code);
  };

  transport.onDisconnect(() => {
    void shutdown(0);
  });
  process.on("SIGINT", () => {
    void shutdown(0);
  });
  process.on("SIGTERM", () => {
    void shutdown(0);
  });

  runtime = await GrannyDurableRuntime.open({
    transport,
    stateDir,
  });

  if (shuttingDown) {
    await runtime.close();
    return;
  }

  if (process.env.GRANNY_TEST_ENGINE_PID) {
    fs.writeFileSync(process.env.GRANNY_TEST_ENGINE_PID, String(process.pid));
  }

  transport.sendEnvelope({
    v: ENGINE_PROTOCOL_VERSION,
    event: "engine.status",
    params: {
      status: "ready",
      lanes: ["interactive", "proactive", "reflection"],
    },
  });

  wakeSweep = setInterval(() => {
    runtime?.nudgeClock();
  }, 15_000);
  wakeSweep.unref();
}

main().catch((err) => {
  const message = err instanceof Error ? err.stack ?? err.message : String(err);
  process.stderr.write(`granny-engine fatal: ${message}\n`);
  process.exit(1);
});
