#!/usr/bin/env node
/**
 * Starts an Anvil node on port 8546.
 *
 * The vault project deliberately uses a different port from `amm-dex` so both frontends can run
 * side by side without one clobbering the other's chain.
 */
import { spawn } from "node:child_process";

const PORT = process.env.ANVIL_PORT ?? "8546";
const HOST = process.env.ANVIL_HOST ?? "127.0.0.1";

const child = spawn("anvil", ["--port", PORT, "--host", HOST], {
  stdio: "inherit",
  shell: process.platform === "win32",
});

child.on("error", (err) => {
  console.error("\n[anvil] Failed to start Anvil:", err.message);
  console.error("[anvil] Install Foundry first: https://book.getfoundry.sh/getting-started/installation");
  process.exit(1);
});

child.on("exit", (code) => process.exit(code ?? 0));

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    child.kill();
    process.exit(0);
  });
}
