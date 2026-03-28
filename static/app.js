const state = {
  showTrail: true,
  history: [],
  latest: null,
  mockPhase: 0,
};

const calibrationTargets = [
  { label: "左上", x: 160, y: 120 },
  { label: "中央上", x: 640, y: 120 },
  { label: "右上", x: 1120, y: 120 },
  { label: "左中", x: 160, y: 360 },
  { label: "中央", x: 640, y: 360 },
  { label: "右中", x: 1120, y: 360 },
  { label: "左下", x: 160, y: 600 },
  { label: "中央下", x: 640, y: 600 },
  { label: "右下", x: 1120, y: 600 },
];

const els = {
  statusText: document.getElementById("statusText"),
  coordText: document.getElementById("coordText"),
  sampleText: document.getElementById("sampleText"),
  blinkText: document.getElementById("blinkText"),
  horizontalText: document.getElementById("horizontalText"),
  verticalText: document.getElementById("verticalText"),
  mappingText: document.getElementById("mappingText"),
  stage: document.getElementById("stage"),
  gazeDot: document.getElementById("gazeDot"),
  targets: document.getElementById("targets"),
  trailCanvas: document.getElementById("trailCanvas"),
  heatmapCanvas: document.getElementById("heatmapCanvas"),
  solveButton: document.getElementById("solveButton"),
  mockButton: document.getElementById("mockButton"),
  resetCalibrationButton: document.getElementById("resetCalibrationButton"),
  toggleTrailButton: document.getElementById("toggleTrailButton"),
};

const trailCtx = els.trailCanvas.getContext("2d");
const heatCtx = els.heatmapCanvas.getContext("2d");

function init() {
  renderTargets();
  bindActions();
  connectStream();
  fetchState();
  requestAnimationFrame(drawLoop);
}

function renderTargets() {
  els.targets.innerHTML = calibrationTargets.map((target, index) => `
    <article class="target-card">
      <strong>${index + 1}. ${target.label}</strong>
      <button data-target-index="${index}">現在値を保存</button>
    </article>
  `).join("");

  els.targets.querySelectorAll("button").forEach((button) => {
    button.addEventListener("click", async () => {
      const target = calibrationTargets[Number(button.dataset.targetIndex)];
      await postJson("/api/calibration/sample", {
        targetX: target.x,
        targetY: target.y,
      });
      fetchState();
    });
  });
}

function bindActions() {
  els.solveButton.addEventListener("click", async () => {
    try {
      const result = await postJson("/api/calibration/solve", {});
      els.mappingText.textContent = JSON.stringify(result.mapping, null, 2);
      fetchState();
    } catch (error) {
      alert(`係数計算に失敗しました: ${error.message}`);
    }
  });

  els.resetCalibrationButton.addEventListener("click", async () => {
    await postJson("/api/calibration/reset", {});
    els.mappingText.textContent = "未較正";
    fetchState();
  });

  els.toggleTrailButton.addEventListener("click", () => {
    state.showTrail = !state.showTrail;
  });

  els.mockButton.addEventListener("click", async () => {
    state.mockPhase += 0.45;
    const h = Math.sin(state.mockPhase) * 0.85;
    const v = Math.cos(state.mockPhase * 0.7) * 0.75;
    const blink = (Math.sin(state.mockPhase * 3.1) + 1) * 0.4;
    await fetch(`/api/mock?h=${h.toFixed(3)}&v=${v.toFixed(3)}&blink=${blink.toFixed(2)}`);
  });
}

async function fetchState() {
  const response = await fetch("/api/state");
  const snapshot = await response.json();
  state.history = snapshot.history || [];
  if (snapshot.latest && snapshot.latest.gaze) {
    state.latest = snapshot.latest;
    applyLatest(snapshot.latest);
  }
  els.sampleText.textContent = String(snapshot.samples ?? 0);
}

function connectStream() {
  const stream = new EventSource("/api/stream");
  stream.onmessage = (event) => {
    const payload = JSON.parse(event.data);
    if (payload.history) {
      state.history = payload.history || [];
      if (payload.latest) {
        state.latest = payload.latest;
        applyLatest(payload.latest);
      }
      els.sampleText.textContent = String(payload.samples ?? 0);
      return;
    }

    state.latest = payload;
    state.history.push({
      x: payload.gaze.x,
      y: payload.gaze.y,
      blinkStrength: payload.raw.blinkStrength,
      timestamp: payload.timestamp,
    });
    if (state.history.length > 180) {
      state.history.shift();
    }
    applyLatest(payload);
  };

  stream.onerror = () => {
    els.statusText.textContent = "再接続中";
  };
}

function applyLatest(payload) {
  const x = payload.gaze.x;
  const y = payload.gaze.y;
  const stageRect = els.stage.getBoundingClientRect();

  els.statusText.textContent = payload.calibrated ? "受信中 / 較正済み" : "受信中 / 仮推定";
  els.coordText.textContent = `${Math.round(x)}, ${Math.round(y)}`;
  els.blinkText.textContent = payload.raw.blinkStrength.toFixed(2);
  els.horizontalText.textContent = payload.smooth.horizontal.toFixed(3);
  els.verticalText.textContent = payload.smooth.vertical.toFixed(3);

  els.gazeDot.style.left = `${(x / 1280) * stageRect.width}px`;
  els.gazeDot.style.top = `${(y / 720) * stageRect.height}px`;
}

function drawLoop() {
  drawHeatmap();
  drawTrail();
  requestAnimationFrame(drawLoop);
}

function drawTrail() {
  const ctx = trailCtx;
  ctx.clearRect(0, 0, 1280, 720);
  if (!state.showTrail || state.history.length < 2) {
    return;
  }

  ctx.lineWidth = 3;
  for (let i = 1; i < state.history.length; i += 1) {
    const prev = state.history[i - 1];
    const next = state.history[i];
    ctx.strokeStyle = `rgba(255,255,255,${i / state.history.length})`;
    ctx.beginPath();
    ctx.moveTo(prev.x, prev.y);
    ctx.lineTo(next.x, next.y);
    ctx.stroke();
  }
}

function drawHeatmap() {
  const ctx = heatCtx;
  ctx.clearRect(0, 0, 1280, 720);
  state.history.forEach((point, index) => {
    const glow = ctx.createRadialGradient(point.x, point.y, 2, point.x, point.y, 48);
    const alpha = Math.max(0.05, index / Math.max(state.history.length, 1) * 0.25);
    glow.addColorStop(0, `rgba(232,93,42,${alpha + 0.2})`);
    glow.addColorStop(1, "rgba(232,93,42,0)");
    ctx.fillStyle = glow;
    ctx.beginPath();
    ctx.arc(point.x, point.y, 48, 0, Math.PI * 2);
    ctx.fill();
  });
}

async function postJson(url, payload) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(text || response.statusText);
  }

  return response.json();
}

init();
