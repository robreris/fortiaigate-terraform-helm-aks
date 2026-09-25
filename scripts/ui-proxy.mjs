#!/usr/bin/env node
// Local stand-in for the Application Gateway: reach the FortiAIGate web UI
// through kubectl port-forwards when the ingress isn't usable (e.g. AGIC 502s
// on the self-signed backend cert, or no DNS for ingress_host yet).
//
// The browser UI calls /api/* on its own origin, so forwarding only the webui
// Service loads the login page but login fails. This script port-forwards
// webui, api and core, and serves them on ONE https origin with the same path
// routing as the chart's ingress:
//   /ui    -> webui:3000
//   /api/  -> api:8000
//   /      -> core:8080
//
// Usage:  node scripts/ui-proxy.mjs [listenPort]   (default 8443)
// Then open https://localhost:8443/ui and accept the self-signed cert warning.
// Ctrl-C stops the proxy and the port-forwards.

import { spawn, execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import https from "node:https";
import os from "node:os";
import path from "node:path";

const NAMESPACE = process.env.FAIG_NAMESPACE || "fortiaigate";
const LISTEN_PORT = Number(process.argv[2] || 8443);

// [path prefix, service, service port, local forward port] — first match wins.
const ROUTES = [
  ["/ui", "webui", 3000, 13000],
  ["/api/", "api", 8000, 18000],
  ["/", "core", 8080, 18080],
];

// Self-signed cert for the local listener, generated once and reused.
const certDir = path.join(os.homedir(), ".cache", "faig-ui-proxy");
const keyFile = path.join(certDir, "key.pem");
const certFile = path.join(certDir, "cert.pem");
if (!existsSync(keyFile) || !existsSync(certFile)) {
  mkdirSync(certDir, { recursive: true });
  execFileSync("openssl", [
    "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "365",
    "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
    "-keyout", keyFile, "-out", certFile,
  ], { stdio: "ignore" });
}

const forwards = ROUTES.map(([, svc, port, localPort]) => {
  const pf = spawn("kubectl", ["-n", NAMESPACE, "port-forward", `svc/${svc}`, `${localPort}:${port}`], {
    stdio: ["ignore", "ignore", "inherit"],
  });
  pf.on("exit", (code) => {
    if (!shuttingDown) {
      console.error(`port-forward to svc/${svc} exited (${code}); stopping.`);
      shutdown(1);
    }
  });
  return pf;
});

let shuttingDown = false;
function shutdown(code = 0) {
  shuttingDown = true;
  for (const pf of forwards) pf.kill();
  process.exit(code);
}
process.on("SIGINT", () => shutdown(0));
process.on("SIGTERM", () => shutdown(0));

// The backends serve HTTPS with the chart's (self-signed) serving cert.
const upstreamAgent = new https.Agent({ rejectUnauthorized: false, keepAlive: true });

const server = https.createServer(
  { key: readFileSync(keyFile), cert: readFileSync(certFile) },
  (req, res) => {
    const [, svc, , localPort] = ROUTES.find(([prefix]) => req.url.startsWith(prefix));
    const upstream = https.request(
      {
        host: "127.0.0.1",
        port: localPort,
        method: req.method,
        path: req.url,
        headers: req.headers,
        agent: upstreamAgent,
      },
      (up) => {
        res.writeHead(up.statusCode, up.headers);
        up.pipe(res);
      },
    );
    upstream.on("error", (err) => {
      console.error(`${req.method} ${req.url} -> ${svc}: ${err.message}`);
      if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
      res.end(`upstream ${svc} error: ${err.message}\n`);
    });
    req.pipe(upstream);
  },
);

// Give the port-forwards a moment to bind before accepting traffic.
setTimeout(() => {
  server.listen(LISTEN_PORT, () => {
    console.log(`FortiAIGate UI: https://localhost:${LISTEN_PORT}/ui  (Ctrl-C to stop)`);
  });
}, 2000);
