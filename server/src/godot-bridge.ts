import type { IncomingMessage } from "node:http";
import { WebSocketServer, WebSocket } from "ws";

const DEFAULT_PORT = 6505;
const DEFAULT_HEARTBEAT_MS = 10_000;
// T-203: was 30s, which a headless export or a navmesh bake always exceeds.
const DEFAULT_TIMEOUT_MS = 120_000;

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

function envInt(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

export class GodotBridge {
  private wss: WebSocketServer | null = null;
  private client: WebSocket | null = null;
  private pending = new Map<number, PendingRequest>();
  private nextId = 1;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private isAlive = false;

  readonly port: number;
  private readonly timeoutMs: number;
  private readonly heartbeatMs: number;

  constructor(port = Number(process.env.GODOT_MCP_PORT ?? DEFAULT_PORT)) {
    this.port = port;
    this.timeoutMs = envInt("GODOT_MCP_TIMEOUT_MS", DEFAULT_TIMEOUT_MS);
    this.heartbeatMs = envInt("GODOT_MCP_HEARTBEAT_MS", DEFAULT_HEARTBEAT_MS);
  }

  start(): void {
    if (this.wss) return;

    this.wss = new WebSocketServer({
      port: this.port,
      host: "127.0.0.1",
      // T-103: browsers always send Origin on a WS handshake; Godot's
      // WebSocketPeer does not. Rejecting any handshake bearing an Origin
      // blocks drive-by connections from a web page on the same machine.
      verifyClient: (info: { origin: string; secure: boolean; req: IncomingMessage }) => {
        if (info.origin) {
          console.error("[godot-mcp] rejected connection with Origin header:", info.origin);
          return false;
        }
        return true;
      },
    });

    // T-202: EADDRINUSE and friends must not be fatal.
    this.wss.on("error", (err: NodeJS.ErrnoException) => {
      if (err.code === "EADDRINUSE") {
        console.error(
          `[godot-mcp] port ${this.port} is already in use. Another MCP server or Godot ` +
            `instance is probably running. Set GODOT_MCP_PORT to use a different port.`
        );
      } else {
        console.error("[godot-mcp] websocket server error:", err.message);
      }
      this.wss = null;
    });

    this.wss.on("connection", (ws) => {
      // T-103: do not let a newcomer displace a healthy existing client.
      // Last-write-wins let anything that could complete a handshake take over
      // the channel and feed forged tool results back to the agent.
      if (this.client && this.client.readyState === WebSocket.OPEN) {
        console.error("[godot-mcp] refusing second connection; a client is already attached");
        ws.close(1013, "Bridge already has an active client");
        return;
      }

      this.client = ws;
      this.isAlive = true;
      console.error(`[godot-mcp] Godot editor connected on port ${this.port}`);

      ws.on("message", (data) => this.onMessage(data.toString()));
      ws.on("close", () => {
        // T-201: only the *active* client's departure invalidates pending work.
        if (this.client === ws) {
          this.client = null;
          console.error("[godot-mcp] Godot editor disconnected");
          this.rejectAll(new Error("Godot editor disconnected"));
        }
      });
      ws.on("error", () => ws.close());
    });

    // T-204: ping/pong as liveness detection, not just keepalive.
    this.heartbeatTimer = setInterval(() => {
      const ws = this.client;
      if (!ws || ws.readyState !== WebSocket.OPEN) return;

      if (!this.isAlive) {
        console.error("[godot-mcp] peer missed heartbeat; terminating");
        ws.terminate();
        if (this.client === ws) {
          this.client = null;
          this.rejectAll(new Error("Godot editor stopped responding"));
        }
        return;
      }

      this.isAlive = false;
      ws.send(JSON.stringify({ jsonrpc: "2.0", method: "ping", params: {} }));
    }, this.heartbeatMs);

    console.error(`[godot-mcp] WebSocket server listening on ws://127.0.0.1:${this.port}`);
  }

  get connected(): boolean {
    return this.client?.readyState === WebSocket.OPEN;
  }

  /**
   * @param toolTimeoutMs T-203: per-tool floor for known-slow tools. The
   * effective timeout is the larger of this and the configured default, so
   * raising GODOT_MCP_TIMEOUT_MS never shortens a slow tool.
   *
   * Note: on timeout the request is dropped here but Godot keeps executing it.
   * There is no cancellation channel.
   */
  async call(
    method: string,
    params: Record<string, unknown> = {},
    toolTimeoutMs?: number
  ): Promise<unknown> {
    if (!this.connected || !this.client) {
      throw new Error(
        "Godot editor not connected. Open your project in Godot and enable the Godot MCP plugin."
      );
    }

    const id = this.nextId++;
    const client = this.client;
    const timeoutMs = Math.max(this.timeoutMs, toolTimeoutMs ?? 0);

    return new Promise((resolve, reject) => {
      // T-205: register before sending, so a response can never outrun the entry.
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Request timeout after ${timeoutMs}ms: ${method}`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });

      try {
        client.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
      } catch (e) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(e as Error);
      }
    });
  }

  close(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
    this.rejectAll(new Error("Server shutting down"));
    this.client?.close();
    this.client = null;
    this.wss?.close();
    this.wss = null;
  }

  private onMessage(text: string): void {
    let msg: {
      id?: number;
      method?: string;
      result?: unknown;
      error?: { message?: string; code?: number; data?: unknown };
    };

    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }

    // T-204: any traffic proves liveness
    this.isAlive = true;
    if (msg.method === "pong" || msg.method === "ping") return;

    if (msg.id !== undefined) {
      const pending = this.pending.get(msg.id);
      if (!pending) return;
      this.pending.delete(msg.id);
      clearTimeout(pending.timer);
      if (msg.error) {
        pending.reject(new Error(msg.error.message ?? "Unknown Godot error"));
      } else {
        pending.resolve(msg.result ?? {});
      }
    }
  }

  private rejectAll(error: Error): void {
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.reject(error);
      this.pending.delete(id);
    }
  }
}
