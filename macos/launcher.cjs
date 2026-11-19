/**
 * Unified desktop launcher for OpenSource Hub (macOS).
 * Starts both the Next.js standalone web server and the background sync worker
 * using the bundled Node.js runtime, and handles clean shutdown on SIGTERM/SIGINT.
 */
const path = require("node:path");
const { fork } = require("node:child_process");

const serverDir = __dirname;
process.chdir(serverDir);

const workerPath = path.join(serverDir, "worker.cjs");
const nextServerPath = path.join(serverDir, "server.js");

let workerProc = null;
let shuttingDown = false;

function startWorker() {
  if (shuttingDown) return;
  workerProc = fork(workerPath, [], {
    cwd: serverDir,
    env: process.env,
    stdio: "inherit",
  });
  workerProc.on("exit", (code, signal) => {
    if (shuttingDown) return;
    console.error(`[launcher] worker exited (code=${code}, signal=${signal}), restarting in 3s...`);
    setTimeout(startWorker, 3000);
  });
}

function shutdown(sig) {
  if (shuttingDown) return;
  shuttingDown = true;
  if (workerProc && !workerProc.killed) {
    try {
      workerProc.kill(sig);
    } catch {
      /* ignore */
    }
  }
  setTimeout(() => process.exit(0), 1500).unref();
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

// Start background worker alongside Next.js standalone server
startWorker();
require(nextServerPath);
