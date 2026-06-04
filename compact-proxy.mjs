import http from "node:http";
import https from "node:https";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const port = Number(process.env.CODEX_COMPACT_PROXY_PORT || 18080);
const upstream = new URL(
  process.env.CODEX_COMPACT_PROXY_UPSTREAM ||
    "https://chatgpt.com/backend-api/codex",
);
const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const compactionDir = path.join(codexHome, "local-compaction");
const prefix =
  "Another language model started to solve this problem and produced a summary of its thinking process. You also have access to the state of the tools that were used by that language model. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:";
const logPath = path.join(compactionDir, "proxy-events.jsonl");
const compactScript = (() => {
  const homeScript = path.join(codexHome, "scripts", "local-compact.ps1");
  if (process.env.CODEX_LOCAL_COMPACT_SCRIPT) {
    return process.env.CODEX_LOCAL_COMPACT_SCRIPT;
  }
  if (fs.existsSync(homeScript)) {
    return homeScript;
  }
  return path.join(path.dirname(fileURLToPath(import.meta.url)), "local-compact.ps1");
})();
const localCompactTimeoutMs = Number(
  process.env.CODEX_COMPACT_PROXY_LOCAL_TIMEOUT_MS || 900000,
);
const handoffMaxAgeMs = Number(
  process.env.CODEX_COMPACT_PROXY_HANDOFF_MAX_AGE_MS || 300000,
);

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function appendLog(event) {
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  fs.appendFileSync(
    logPath,
    `${JSON.stringify({ generated_at: new Date().toISOString(), ...event })}\n`,
  );
}

function collectText(value, out = []) {
  if (value == null) return out;
  if (typeof value === "string") {
    out.push(value);
  } else if (Array.isArray(value)) {
    for (const item of value) collectText(item, out);
  } else if (typeof value === "object") {
    for (const key of ["text", "output", "arguments"]) {
      if (typeof value[key] === "string") out.push(value[key]);
    }
    for (const [key, nested] of Object.entries(value)) {
      if (["text", "output", "arguments", "encrypted_content"].includes(key)) {
        continue;
      }
      if (nested && typeof nested === "object") collectText(nested, out);
    }
  }
  return out;
}

function findUuids(text) {
  return [
    ...new Set(
      String(text || "").match(
        /\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/g,
      ) || [],
    ),
  ];
}

function compactResponse(summaryText) {
  return {
    output: [
      {
        type: "message",
        role: "user",
        content: [
          {
            type: "input_text",
            text: `${prefix}\n${summaryText}`,
          },
        ],
      },
    ],
  };
}

function readRecentPrecompactHandoff(marker, requestIds) {
  const eventsPath = path.join(compactionDir, "events.jsonl");
  if (!fs.existsSync(eventsPath)) return null;

  const candidates = [];
  const lines = fs.readFileSync(eventsPath, "utf8").trim().split(/\r?\n/);
  for (let i = lines.length - 1; i >= 0; i--) {
    let event;
    try {
      event = JSON.parse(lines[i]);
    } catch {
      continue;
    }
    if (event.trigger !== "precompact" || !event.markdown) continue;

    const generatedAt = Date.parse(event.generated_at);
    const ageMs = Number.isFinite(generatedAt) ? Date.now() - generatedAt : Infinity;
    if (ageMs > handoffMaxAgeMs) break;
    if (!fs.existsSync(event.markdown)) continue;

    const markdown = fs.readFileSync(event.markdown, "utf8");
    candidates.push({
      markdown,
      markdownPath: event.markdown,
      ageMs,
      event,
    });
  }

  if (marker) {
    const markerMatches = candidates.filter((candidate) =>
      candidate.markdown.includes(marker),
    );
    if (markerMatches.length === 1) {
      return { ...markerMatches[0], match: "marker", candidates: candidates.length };
    }
    if (markerMatches.length > 1) {
      return { ...markerMatches[0], match: "marker-latest", candidates: candidates.length };
    }
  }

  if (requestIds.length > 0) {
    const idMatches = candidates.filter((candidate) => {
      const haystack = [
        candidate.event.session_id,
        candidate.event.thread_id,
        candidate.event.source_session,
        candidate.event.markdown,
        candidate.event.json,
        candidate.markdown,
      ].join("\n");
      return requestIds.some((id) => haystack.includes(id));
    });
    if (idMatches.length === 1) {
      return { ...idMatches[0], match: "session-id", candidates: candidates.length };
    }
    if (idMatches.length > 1) {
      return { ...idMatches[0], match: "session-id-latest", candidates: candidates.length };
    }
  }

  return null;
}

function runLocalCompactor(inputText) {
  return new Promise((resolve, reject) => {
    const escapedScript = compactScript.replace(/'/g, "''");
    const command = [
      "[Console]::InputEncoding=[System.Text.UTF8Encoding]::new($false)",
      "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false)",
      `& '${escapedScript}' -Trigger proxycompact -Force`,
    ].join("; ");
    const proc = spawn(
      "powershell",
      [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        command,
      ],
      { windowsHide: true },
    );

    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      proc.kill();
      reject(new Error(`local compact timed out after ${localCompactTimeoutMs}ms`));
    }, localCompactTimeoutMs);

    proc.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    proc.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    proc.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    proc.on("close", () => {
      clearTimeout(timer);
      try {
        const result = JSON.parse(stdout.trim().split(/\r?\n/).pop() || "{}");
        if (result.status !== "ok") {
          throw new Error(result.message || stderr || "local compact failed");
        }
        const markdown = fs.readFileSync(result.latest, "utf8");
        resolve({ result, markdown });
      } catch (error) {
        reject(new Error(`${error.message}; stderr=${stderr.trim()}`));
      }
    });
    proc.stdin.end(inputText);
  });
}

async function summarizeCompactRequest(req, body) {
  const parsed = JSON.parse(body.toString("utf8"));
  const text = collectText(parsed).join("\n");
  const marker = text.match(/[A-Z0-9_]*MARKER[A-Z0-9_]*_[A-Z0-9_]+/)?.[0] || null;
  const requestIds = findUuids(
    `${req.url}\n${JSON.stringify(req.headers)}\n${body.toString("utf8")}\n${text}`,
  );
  const handoff = readRecentPrecompactHandoff(marker, requestIds);
  if (handoff) {
    const summary = [
      "LOCAL_COMPACT_PROXY_SUMMARY=YES",
      "LOCAL_COMPACT_PROXY_SOURCE=precompact-handoff",
      marker ? `MARKER=${marker}` : "MARKER=NONE",
      `INPUT_TEXT_CHARS=${text.length}`,
      `HANDOFF_MARKDOWN=${handoff.markdownPath}`,
      `HANDOFF_AGE_MS=${Math.max(0, handoff.ageMs)}`,
      `HANDOFF_MATCH=${handoff.match}`,
      "",
      handoff.markdown,
    ].join("\n");
    return {
      marker,
      textChars: text.length,
      source: "precompact-handoff",
      handoffPath: handoff.markdownPath,
      handoffAgeMs: handoff.ageMs,
      handoffMatch: handoff.match,
      handoffCandidates: handoff.candidates,
      requestIds: requestIds.length,
      response: compactResponse(summary),
    };
  }

  const proxyContext = [
    "Codex /responses/compact request text follows.",
    marker ? `Detected marker: ${marker}` : "Detected marker: NONE",
    "",
    text,
  ].join("\n");

  try {
    const local = await runLocalCompactor(proxyContext);
    const summary = [
      "LOCAL_COMPACT_PROXY_SUMMARY=YES",
      "LOCAL_COMPACT_PROXY_SOURCE=local-compact.ps1",
      marker ? `MARKER=${marker}` : "MARKER=NONE",
      `INPUT_TEXT_CHARS=${text.length}`,
      "",
      local.markdown,
    ].join("\n");
    return {
      marker,
    textChars: text.length,
    source: "local-compact.ps1",
    requestIds: requestIds.length,
    response: compactResponse(summary),
  };
  } catch (error) {
    appendLog({ kind: "local_compact_error", message: error.message });
  }

  const summary = [
    "LOCAL_COMPACT_PROXY_SUMMARY=YES",
    "LOCAL_COMPACT_PROXY_SOURCE=stub",
    marker ? `MARKER=${marker}` : "MARKER=NONE",
    `INPUT_TEXT_CHARS=${text.length}`,
    "",
    "Immediate next action:",
    "- Continue the interrupted turn from this injected local summary.",
    "- If a tool output just caused automatic compaction, satisfy the latest user instruction without re-running completed tools unless required.",
    "",
    "Recent context excerpt:",
    text.slice(-4000),
  ].join("\n");

  return {
    marker,
    textChars: text.length,
    source: "stub",
    requestIds: requestIds.length,
    response: compactResponse(summary),
  };
}

function upstreamPath(reqUrl) {
  const incoming = new URL(reqUrl, `http://127.0.0.1:${port}`);
  const stripped = incoming.pathname.replace(
    /^\/(?:backend-api\/codex|v1)(?=\/|$)/,
    "",
  );
  const target = new URL(upstream);
  target.pathname = `${target.pathname.replace(/\/$/, "")}${stripped}`;
  target.search = incoming.search;
  return target;
}

function safeEnd502(res, error) {
  try {
    if (!res.headersSent) {
      res.writeHead(502, { "content-type": "application/json" });
    }
    if (!res.writableEnded) {
      res.end(JSON.stringify({ error: error.message || String(error) }));
    }
  } catch {
    // best effort
  }
}

function forward(req, res, body) {
  const target = upstreamPath(req.url);
  const headers = { ...req.headers };
  delete headers.host;
  delete headers.connection;
  headers["content-length"] = String(body.length);

  const client = target.protocol === "https:" ? https : http;
  const upstreamReq = client.request(
    target,
    { method: req.method, headers },
    (upstreamRes) => {
      try {
        res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
      } catch (error) {
        appendLog({ kind: "forward_error", path: req.url, message: `writeHead failed: ${error.message}` });
        safeEnd502(res, error);
        return;
      }
      upstreamRes.on("error", (error) => {
        appendLog({ kind: "forward_error", path: req.url, message: `upstream stream error: ${error.message}` });
        safeEnd502(res, error);
      });
      upstreamRes.pipe(res);
    },
  );
  upstreamReq.on("error", (error) => {
    appendLog({ kind: "forward_error", path: req.url, message: error.message });
    safeEnd502(res, error);
  });
  upstreamReq.end(body);
}

function requestLogDetails(body) {
  const text = body.toString("utf8");
  let inputText = "";
  try {
    const parsed = JSON.parse(text);
    inputText = collectText(parsed.input).join("\n");
  } catch {
    inputText = "";
  }
  const combined = `${text}\n${inputText}`;
  const marker =
    combined.match(/[A-Z0-9_]*MARKER[A-Z0-9_]*_[A-Z0-9_]+/)?.[0] || null;
  return {
    body_chars: text.length,
    input_text_chars: inputText.length || null,
    has_proxy_summary: combined.includes("LOCAL_COMPACT_PROXY_SUMMARY=YES"),
    marker,
  };
}

const server = http.createServer(async (req, res) => {
  const body = await readBody(req);
  if (req.method === "POST" && new URL(req.url, "http://local").pathname.endsWith("/responses/compact")) {
    try {
      const compact = await summarizeCompactRequest(req, body);
      appendLog({
        kind: "compact",
        path: req.url,
        source: compact.source,
        marker: compact.marker,
        input_text_chars: compact.textChars,
        handoff_path: compact.handoffPath ?? null,
        handoff_age_ms: compact.handoffAgeMs ?? null,
        handoff_match: compact.handoffMatch ?? null,
        handoff_candidates: compact.handoffCandidates ?? null,
        request_ids: compact.requestIds ?? null,
      });
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(compact.response));
    } catch (error) {
      appendLog({ kind: "compact_error", path: req.url, message: error.message });
      res.writeHead(500, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: error.message }));
    }
    return;
  }

  appendLog({
    kind: "forward",
    path: req.url,
    method: req.method,
    ...requestLogDetails(body),
  });
  forward(req, res, body);
});

process.on("uncaughtException", (error) => {
  appendLog({ kind: "uncaught_exception", message: error.message, stack: error.stack });
});
process.on("unhandledRejection", (reason) => {
  appendLog({ kind: "unhandled_rejection", message: reason?.message || String(reason) });
});

server.listen(port, "127.0.0.1", () => {
  appendLog({ kind: "listening", port, upstream: upstream.toString() });
  console.error(`compact proxy listening on http://127.0.0.1:${port}`);
});
