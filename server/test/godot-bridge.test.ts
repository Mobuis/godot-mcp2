/**
 * godot-bridge.test.ts — behavioural spec for the WebSocket bridge.
 *
 * These tests encode the TARGET behaviour (post-hardening), not current
 * behaviour. Against the unpatched upstream commit most of them FAIL. That is
 * intentional: this file is the oracle the hardening tasks turn green.
 *
 * Mapping to plan task IDs is noted per describe block.
 */
import { describe, it, expect, afterEach, vi } from "vitest";
import { WebSocket, WebSocketServer } from "ws";
import { GodotBridge } from "../src/godot-bridge.js";

// ---------------------------------------------------------------- helpers ---

/** Random high port, to keep parallel test files from colliding. */
let nextPort = 21000 + Math.floor(Math.random() * 3000);
const port = () => nextPort++;

const open = (bridges: GodotBridge[]) => bridges;
let live: GodotBridge[] = [];
let liveSockets: WebSocket[] = [];

function makeBridge(p: number): GodotBridge {
  const b = new GodotBridge(p);
  live.push(b);
  return b;
}

/** Connect a fake "Godot plugin" and resolve once open. */
function connect(p: number, opts: { origin?: string } = {}): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${p}`, {
      headers: opts.origin ? { Origin: opts.origin } : {},
    });
    liveSockets.push(ws);
    const t = setTimeout(() => reject(new Error("connect timeout")), 3000);
    ws.on("open", () => {
      clearTimeout(t);
      resolve(ws);
    });
    ws.on("error", (e) => {
      clearTimeout(t);
      reject(e);
    });
    ws.on("unexpected-response", (_req, res) => {
      clearTimeout(t);
      reject(new Error(`handshake rejected: ${res.statusCode}`));
    });
  });
}

/** Auto-reply to any JSON-RPC request with a fixed result. */
function autoRespond(ws: WebSocket, result: unknown = { ok: true }) {
  ws.on("message", (raw) => {
    const msg = JSON.parse(raw.toString());
    if (msg.id === undefined) return; // ping etc.
    ws.send(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result }));
  });
}

const settle = (ms = 120) => new Promise((r) => setTimeout(r, ms));

afterEach(async () => {
  for (const ws of liveSockets) {
    try {
      ws.removeAllListeners();
      // A socket whose handshake was rejected will still emit 'error'. With no
      // listener attached that surfaces as an unhandled error and pollutes the
      // run, so keep a no-op listener in place through teardown.
      ws.on("error", () => {});
      ws.terminate();
    } catch {}
  }
  liveSockets = [];
  for (const b of live) {
    try {
      b.close();
    } catch {}
  }
  live = [];
  await settle(50);
});

// ------------------------------------------------------------ T-103 auth ----
describe("T-103 — connection authorisation", () => {
  it("binds to loopback only", async () => {
    const p = port();
    const b = makeBridge(p);
    b.start();
    await settle();
    // A connection to 127.0.0.1 must work; the host binding itself is asserted
    // statically by check-invariants.mjs (INV-103).
    const ws = await connect(p);
    expect(ws.readyState).toBe(WebSocket.OPEN);
  });

  it("accepts a client with no Origin header (the Godot plugin)", async () => {
    const p = port();
    makeBridge(p).start();
    await settle();
    await expect(connect(p)).resolves.toBeDefined();
  });

  it("REJECTS a client presenting an Origin header (a browser page)", async () => {
    const p = port();
    makeBridge(p).start();
    await settle();
    // Browsers always send Origin on a WS handshake; Godot's WebSocketPeer does not.
    await expect(connect(p, { origin: "https://evil.example" })).rejects.toThrow();
  });

  it("does not let a later connection silently displace the active client", async () => {
    const p = port();
    const b = makeBridge(p);
    b.start();
    await settle();

    const first = await connect(p);
    autoRespond(first, { from: "first" });
    await settle();

    // A second connection must not become the recipient of in-flight traffic
    // without the first being gone.
    const second = await connect(p);
    autoRespond(second, { from: "second" });
    await settle();

    const res = (await b.call("get_project_info")) as { from?: string };
    expect(res.from).toBe("first");
  });
});

// ------------------------------------------------------ T-201 stale close ---
describe("T-201 — stale socket close", () => {
  it("does not reject the live client's pending requests", async () => {
    const p = port();
    const b = makeBridge(p);
    b.start();
    await settle();

    const active = await connect(p);
    // deliberately slow responder
    active.on("message", (raw) => {
      const msg = JSON.parse(raw.toString());
      if (msg.id === undefined) return;
      setTimeout(() => active.send(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { ok: true } })), 300);
    });
    await settle();

    const pending = b.call("get_project_info");

    // a second, unrelated socket connects and immediately drops
    const stale = await connect(p);
    stale.close();
    await settle(150);

    await expect(pending).resolves.toBeDefined();
  });
});

// ---------------------------------------------------- T-202 server errors ---
describe("T-202 — server error handling", () => {
  it("does not throw an unhandled error when the port is already in use", async () => {
    const p = port();
    const blocker = new WebSocketServer({ port: p, host: "127.0.0.1" });
    await settle();

    const unhandled = vi.fn();
    process.once("uncaughtException", unhandled);

    const b = makeBridge(p);
    expect(() => b.start()).not.toThrow();
    await settle(200);

    expect(unhandled).not.toHaveBeenCalled();
    process.removeListener("uncaughtException", unhandled);
    blocker.close();
  });
});

// --------------------------------------------------------- T-203 timeouts ---
describe("T-203 — request timeout", () => {
  it("is configurable via GODOT_MCP_TIMEOUT_MS", async () => {
    const prev = process.env.GODOT_MCP_TIMEOUT_MS;
    process.env.GODOT_MCP_TIMEOUT_MS = "250";

    const p = port();
    const b = makeBridge(p);
    b.start();
    await settle();

    const ws = await connect(p); // connects but never replies
    expect(ws.readyState).toBe(WebSocket.OPEN);

    const started = Date.now();
    await expect(b.call("get_project_info")).rejects.toThrow(/timeout/i);
    const elapsed = Date.now() - started;

    expect(elapsed).toBeLessThan(2000); // i.e. it used 250ms, not the 30s default

    if (prev === undefined) delete process.env.GODOT_MCP_TIMEOUT_MS;
    else process.env.GODOT_MCP_TIMEOUT_MS = prev;
  });
});

// -------------------------------------------------------- T-204 heartbeat ---
describe("T-204 — dead peer detection", () => {
  it("terminates a peer that stops answering pings", async () => {
    const prev = process.env.GODOT_MCP_HEARTBEAT_MS;
    process.env.GODOT_MCP_HEARTBEAT_MS = "150";

    const p = port();
    const b = makeBridge(p);
    b.start();
    await settle();

    const ws = await connect(p);
    // deliberately never respond to ping
    await settle(700);

    expect(b.connected).toBe(false);

    if (prev === undefined) delete process.env.GODOT_MCP_HEARTBEAT_MS;
    else process.env.GODOT_MCP_HEARTBEAT_MS = prev;
  });
});

// ------------------------------------------------------ baseline contract ---
describe("baseline request/response contract", () => {
  it("rejects call() when no client is connected", async () => {
    const p = port();
    const b = makeBridge(p);
    b.start();
    await settle();
    await expect(b.call("get_project_info")).rejects.toThrow(/not connected/i);
  });

  it("round-trips a request and resolves with the result", async () => {
    const p = port();
    const b = makeBridge(p);
    b.start();
    await settle();
    const ws = await connect(p);
    autoRespond(ws, { name: "TestProject" });
    await settle();
    await expect(b.call("get_project_info")).resolves.toEqual({ name: "TestProject" });
  });

  it("propagates a JSON-RPC error as a rejection", async () => {
    const p = port();
    const b = makeBridge(p);
    b.start();
    await settle();
    const ws = await connect(p);
    ws.on("message", (raw) => {
      const msg = JSON.parse(raw.toString());
      if (msg.id === undefined) return;
      ws.send(JSON.stringify({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "Method not found: bogus" } }));
    });
    await settle();
    await expect(b.call("bogus")).rejects.toThrow(/Method not found/);
  });

  it("does not lose a response that arrives immediately", async () => {
    // Guards T-205: pending must be registered before send().
    const p = port();
    const b = makeBridge(p);
    b.start();
    await settle();
    const ws = await connect(p);
    autoRespond(ws, { fast: true });
    await settle();
    const results = await Promise.all([b.call("a"), b.call("b"), b.call("c")]);
    expect(results).toHaveLength(3);
  });
});
