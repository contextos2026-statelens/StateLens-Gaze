#!/usr/bin/env node
"use strict";

const crypto = require("crypto");
const http = require("http");

const WS_PORT = Number(process.env.WS_PORT || 9000);
const INGEST_URL = process.env.INGEST_URL || "http://127.0.0.1:8765/api/ingest";
const ENABLE_FORWARD = process.env.ENABLE_FORWARD !== "0";

function createAcceptKey(secWebSocketKey) {
  return crypto
    .createHash("sha1")
    .update(secWebSocketKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11", "binary")
    .digest("base64");
}

function decodeFrames(buffer) {
  const frames = [];
  let offset = 0;

  while (offset + 2 <= buffer.length) {
    const b0 = buffer[offset];
    const b1 = buffer[offset + 1];

    const fin = (b0 & 0x80) !== 0;
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) !== 0;
    let payloadLen = b1 & 0x7f;
    let headerLen = 2;

    if (payloadLen === 126) {
      if (offset + 4 > buffer.length) break;
      payloadLen = buffer.readUInt16BE(offset + 2);
      headerLen = 4;
    } else if (payloadLen === 127) {
      if (offset + 10 > buffer.length) break;
      const high = buffer.readUInt32BE(offset + 2);
      const low = buffer.readUInt32BE(offset + 6);
      const big = high * 2 ** 32 + low;
      if (big > Number.MAX_SAFE_INTEGER) {
        throw new Error("Payload too large");
      }
      payloadLen = big;
      headerLen = 10;
    }

    const maskLen = masked ? 4 : 0;
    const frameLen = headerLen + maskLen + payloadLen;
    if (offset + frameLen > buffer.length) break;

    let payloadStart = offset + headerLen;
    let payload = buffer.slice(payloadStart + maskLen, payloadStart + maskLen + payloadLen);

    if (masked) {
      const maskKey = buffer.slice(payloadStart, payloadStart + 4);
      const out = Buffer.alloc(payload.length);
      for (let i = 0; i < payload.length; i += 1) {
        out[i] = payload[i] ^ maskKey[i % 4];
      }
      payload = out;
    }

    frames.push({ fin, opcode, payload });
    offset += frameLen;
  }

  return { frames, rest: buffer.slice(offset) };
}

function buildFrame(opcode, payloadBuffer) {
  const payloadLen = payloadBuffer.length;
  let header;
  if (payloadLen < 126) {
    header = Buffer.from([0x80 | opcode, payloadLen]);
  } else if (payloadLen <= 0xffff) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(payloadLen, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    const high = Math.floor(payloadLen / 2 ** 32);
    const low = payloadLen >>> 0;
    header.writeUInt32BE(high, 2);
    header.writeUInt32BE(low, 6);
  }
  return Buffer.concat([header, payloadBuffer]);
}

async function maybeForward(rawText) {
  if (!ENABLE_FORWARD) return;
  if (!rawText || rawText === "heartbeat") return;

  let parsed;
  try {
    parsed = JSON.parse(rawText);
  } catch {
    return;
  }

  let payload = null;
  if (typeof parsed.horizontal === "number" && typeof parsed.vertical === "number") {
    payload = parsed;
  } else if (parsed.currentData && typeof parsed.currentData === "object") {
    payload = parsed.currentData;
  } else if (parsed.data && typeof parsed.data === "object") {
    payload = parsed.data;
  } else if (
    typeof parsed.eyeMoveRight === "number" ||
    typeof parsed.eyeMoveLeft === "number" ||
    typeof parsed.eyeMoveUp === "number" ||
    typeof parsed.eyeMoveDown === "number"
  ) {
    const right = Number(parsed.eyeMoveRight || 0);
    const left = Number(parsed.eyeMoveLeft || 0);
    const up = Number(parsed.eyeMoveUp || 0);
    const down = Number(parsed.eyeMoveDown || 0);
    payload = {
      horizontal: right - left,
      vertical: up - down,
      blinkStrength: Number(parsed.blinkStrength || 0),
      source: "logger/currentData",
      timestamp: Date.now() / 1000,
    };
  }
  if (!payload) return;

  try {
    await fetch(INGEST_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch (err) {
    console.error(`[forward] ${String(err)}`);
  }
}

const server = http.createServer((req, res) => {
  if (req.url === "/healthz") {
    res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("ok");
    return;
  }
  res.writeHead(426, { "Content-Type": "text/plain; charset=utf-8" });
  res.end("Upgrade Required");
});

server.on("upgrade", (req, socket) => {
  const key = req.headers["sec-websocket-key"];
  if (!key) {
    socket.destroy();
    return;
  }

  const acceptKey = createAcceptKey(key);
  const headers = [
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Accept: ${acceptKey}`,
    "\r\n",
  ];
  socket.write(headers.join("\r\n"));

  console.log(`[ws] connected from ${socket.remoteAddress}:${socket.remotePort}`);

  let pending = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    pending = Buffer.concat([pending, chunk]);
    let decoded;
    try {
      decoded = decodeFrames(pending);
    } catch (err) {
      console.error(`[ws] decode error: ${String(err)}`);
      socket.destroy();
      return;
    }
    pending = decoded.rest;

    for (const frame of decoded.frames) {
      if (!frame.fin) continue;
      if (frame.opcode === 0x8) {
        socket.write(buildFrame(0x8, Buffer.alloc(0)));
        socket.end();
        return;
      }
      if (frame.opcode === 0x9) {
        socket.write(buildFrame(0xA, frame.payload));
        continue;
      }
      if (frame.opcode !== 0x1) continue;

      const text = frame.payload.toString("utf8");
      const now = new Date().toLocaleTimeString("ja-JP", { hour12: false });
      if (text === "heartbeat") {
        console.log(`[${now}] heartbeat`);
      } else {
        const preview = text.length > 220 ? `${text.slice(0, 220)}...` : text;
        console.log(`[${now}] ${preview}`);
      }
      void maybeForward(text);
    }
  });

  socket.on("close", () => console.log("[ws] disconnected"));
  socket.on("error", (err) => console.error(`[ws] socket error: ${String(err)}`));
});

server.listen(WS_PORT, "0.0.0.0", () => {
  console.log(`[ws] listening on ws://0.0.0.0:${WS_PORT}`);
  console.log(`[ws] forwarding: ${ENABLE_FORWARD ? INGEST_URL : "disabled"}`);
});
