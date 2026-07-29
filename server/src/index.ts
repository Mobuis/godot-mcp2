#!/usr/bin/env node
import { existsSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { GodotBridge } from "./godot-bridge.js";
import { registerTools } from "./tools.js";

/** Newest mtime of any file with the given extension, recursively. 0 if none. */
function newestMtime(dir: string, ext: string): number {
  let newest = 0;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      newest = Math.max(newest, newestMtime(full, ext));
    } else if (entry.name.endsWith(ext)) {
      newest = Math.max(newest, statSync(full).mtimeMs);
    }
  }
  return newest;
}

/**
 * MCP clients launch `node build/index.js` directly, so nothing forces a
 * rebuild — and build/ is gitignored, so it is whatever was last compiled on
 * this machine, possibly hours before the source it is supposed to represent.
 * That failure is invisible and expensive: an uncompiled fix is indistinguishable
 * from a broken one, and you debug the wrong thing.
 */
function warnIfStale(): void {
  try {
    const buildDir = dirname(fileURLToPath(import.meta.url));
    const srcDir = join(buildDir, "..", "src");
    if (!existsSync(srcDir)) return; // installed without sources; nothing to compare

    const srcTime = newestMtime(srcDir, ".ts");
    const buildTime = newestMtime(buildDir, ".js");
    if (srcTime > buildTime) {
      const behindMin = Math.round((srcTime - buildTime) / 60_000);
      console.error(
        "\n" +
          "  ┌─────────────────────────────────────────────────────────────┐\n" +
          "  │  STALE BUILD — you are not running the code you edited      │\n" +
          "  └─────────────────────────────────────────────────────────────┘\n" +
          `  src/ is ${behindMin} minute(s) newer than build/.\n` +
          "  Run `npm run build` in server/ and restart this MCP server.\n"
      );
    }
  } catch {
    // Never let a diagnostic stop the server from starting.
  }
}

warnIfStale();

const bridge = new GodotBridge();
bridge.start();

const server = new McpServer({
  name: "godot-mcp",
  version: "0.1.0",
});

registerTools(server, bridge);

function shutdown() {
  bridge.close();
  process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

const transport = new StdioServerTransport();
await server.connect(transport);
