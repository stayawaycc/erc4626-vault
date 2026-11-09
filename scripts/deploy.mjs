#!/usr/bin/env node
/**
 * Deploys the vault stack to a local Anvil node and writes `deployments/<chainid>.json`.
 */
import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";

const RPC = process.env.RPC_URL ?? "http://127.0.0.1:8546";

async function rpcReady() {
  for (let i = 0; i < 30; i++) {
    try {
      const res = await fetch(RPC, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
      });
      if (res.ok) return true;
    } catch {
      // not up yet
    }
    await sleep(1000);
  }
  return false;
}

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: "inherit",
      shell: process.platform === "win32",
      env: {
        ...process.env,
        NO_PROXY: "127.0.0.1,localhost",
        no_proxy: "127.0.0.1,localhost",
        FOUNDRY_DISABLE_NIGHTLY_WARNING: "1",
      },
    });
    child.on("error", reject);
    child.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`${command} exited with ${code}`))));
  });
}

async function main() {
  process.stdout.write(`[deploy] waiting for ${RPC} ... `);
  if (!(await rpcReady())) {
    console.error("\n[deploy] RPC never came up. Is Anvil running? Try `npm run dev:anvil`.");
    process.exit(1);
  }
  console.log("ready");

  console.log("[deploy] deploying vault, strategy and mocks");
  await run("forge", ["script", "script/Deploy.s.sol", "--rpc-url", RPC, "--broadcast"]);

  console.log("[deploy] done. Addresses written to deployments/31337.json");
}

main().catch((err) => {
  console.error("[deploy] failed:", err.message);
  process.exit(1);
});
