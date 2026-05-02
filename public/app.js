const endpoints = {
  matrix: "/api/benchmark/matrix",
  "monte-carlo-pi": "/api/benchmark/monte-carlo-pi",
  "heat-diffusion": "/api/benchmark/heat-diffusion",
  "random-walk": "/api/benchmark/random-walk",
  dataframe: "/api/benchmark/dataframe",
};

let chart;

const statusBadge = document.getElementById("statusBadge");
const resultJson = document.getElementById("resultJson");
const resultTime = document.getElementById("resultTime");
const explanation = document.getElementById("explanation");
const heatmap = document.getElementById("heatmap");

function setStatus(ok, text) {
  statusBadge.textContent = text;
  statusBadge.classList.toggle("ok", ok);
  statusBadge.classList.toggle("bad", !ok);
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "Request failed");
  return data;
}

function formPayload(form) {
  const payload = {};
  for (const element of form.elements) {
    if (!element.name) continue;
    payload[element.name] = Number.parseInt(element.value, 10);
  }
  return payload;
}

function sleep(ms) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

async function pollJob(jobId) {
  for (let attempt = 0; attempt < 120; attempt += 1) {
    const data = await api(`/api/jobs/${jobId}`);
    const job = data.job;
    resultTime.textContent = `Job #${job.id} ${job.status}`;
    if (job.status === "done") return job.result;
    if (job.status === "failed") throw new Error(job.error || "Benchmark job failed");
    await sleep(500);
  }
  throw new Error("Benchmark job timed out while waiting for a result");
}

function renderChart(result) {
  const ctx = document.getElementById("chart");
  heatmap.hidden = true;
  if (chart) chart.destroy();

  if (result.benchmark === "heat-diffusion") {
    ctx.hidden = true;
    renderHeatmap(result.chart.heatmap);
    return;
  }

  ctx.hidden = false;
  const config = result.benchmark === "random-walk"
    ? {
        type: "line",
        data: {
          labels: result.chart.x.map((_, index) => index),
          datasets: [{
            label: "Path",
            data: result.chart.x.map((x, index) => ({ x, y: result.chart.y[index] })),
            borderColor: "#36d399",
            backgroundColor: "rgba(54, 211, 153, 0.18)",
            pointRadius: 0,
            tension: 0.15,
          }],
        },
        options: baseChartOptions(true),
      }
    : {
        type: "line",
        data: {
          labels: result.chart.labels,
          datasets: [{
            label: result.benchmark,
            data: result.chart.data,
            borderColor: "#59a6ff",
            backgroundColor: "rgba(89, 166, 255, 0.18)",
            fill: result.benchmark !== "matrix",
            tension: 0.25,
          }],
        },
        options: baseChartOptions(false),
      };
  chart = new Chart(ctx, config);
}

function baseChartOptions(scatter) {
  return {
    responsive: true,
    maintainAspectRatio: false,
    parsing: scatter ? false : true,
    scales: {
      x: { ticks: { color: "#98a2b3" }, grid: { color: "#2d3440" }, type: scatter ? "linear" : "category" },
      y: { ticks: { color: "#98a2b3" }, grid: { color: "#2d3440" } },
    },
    plugins: {
      legend: { labels: { color: "#f2f5f7" } },
    },
  };
}

function renderHeatmap(values) {
  heatmap.hidden = false;
  heatmap.innerHTML = "";
  heatmap.style.gridTemplateColumns = `repeat(${values.length}, 1fr)`;
  for (const row of values) {
    for (const value of row) {
      const cell = document.createElement("div");
      const hue = 218 - Math.round(value * 180);
      cell.className = "heat-cell";
      cell.style.background = `hsl(${hue}, 86%, ${28 + value * 42}%)`;
      heatmap.appendChild(cell);
    }
  }
}

function renderResult(result) {
  resultTime.textContent = `${result.duration_ms} ms at ${new Date(result.timestamp).toLocaleString()}`;
  explanation.textContent = result.explanation;
  explanation.classList.remove("error-text");
  resultJson.textContent = JSON.stringify({
    input: result.input,
    result: result.result,
    duration_ms: result.duration_ms,
  }, null, 2);
  renderChart(result);
}

function renderHistory(runs) {
  document.getElementById("runCount").textContent = runs.length;
  document.getElementById("lastDuration").textContent = runs[0] ? `${runs[0].duration_ms} ms` : "None";
  const list = document.getElementById("historyList");
  list.innerHTML = "";
  if (runs.length === 0) {
    list.innerHTML = '<p class="muted">No runs yet.</p>';
    return;
  }
  for (const run of runs) {
    const item = document.createElement("div");
    item.className = "history-item";
    item.innerHTML = `
      <div class="history-title">
        <span>${run.benchmark_type}</span>
        <span>${run.duration_ms} ms</span>
      </div>
      <div class="history-meta">${run.input_size} · ${new Date(run.created_at).toLocaleString()}</div>
    `;
    list.appendChild(item);
  }
}

async function refreshRuns() {
  const data = await api("/api/runs");
  renderHistory(data.runs);
}

async function checkHealth() {
  try {
    const health = await api("/health");
    if (health.storage) {
      document.getElementById("storageBackend").textContent = `${health.storage} history`;
    }
    setStatus(true, "Healthy");
  } catch {
    setStatus(false, "Health check failed");
  }
}

for (const card of document.querySelectorAll(".bench-card")) {
  const benchmark = card.dataset.benchmark;
  const form = card.querySelector("form");
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = form.querySelector("button");
    button.disabled = true;
    button.textContent = "Queued";
    explanation.textContent = "Benchmark queued...";
    explanation.classList.remove("error-text");
    try {
      const queued = await api(endpoints[benchmark], {
        method: "POST",
        body: JSON.stringify(formPayload(form)),
      });
      resultTime.textContent = `Job #${queued.job_id} queued`;
      explanation.textContent = "Benchmark running...";
      button.textContent = "Running";
      const result = await pollJob(queued.job_id);
      renderResult(result);
      await refreshRuns();
    } catch (error) {
      explanation.textContent = error.message;
      explanation.classList.add("error-text");
    } finally {
      button.disabled = false;
      button.textContent = "Run";
    }
  });
}

document.getElementById("refreshRuns").addEventListener("click", refreshRuns);
checkHealth();
refreshRuns();
