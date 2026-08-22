/* @section: demo-simulation */
(() => {
  "use strict";

  const state = {
    config: null,
    period: "24h",
    points: [],
    latestSlot: null,
    theme: "light",
    modalReturnFocus: null,
  };

  const PERIODS = {
    "24h": { label: "24 horas", slots: 96, step: 1 },
    "7d": { label: "7 días", slots: 96 * 7, step: 8 },
    "30d": { label: "30 días", slots: 96 * 30, step: 32 },
    "6m": { label: "6 meses", slots: 96 * 183, step: 96 },
  };

  const $ = (id) => document.getElementById(id);
  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
  const round = (value, digits = 2) => Number(value.toFixed(digits));

  function escapeText(value) {
    return String(value ?? "").replace(/[&<>"']/g, (char) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    })[char]);
  }

  function alignedSlot(now = Date.now()) {
    const epoch = Date.parse(state.config.simulation.epochUtc);
    const interval = state.config.meta.updateIntervalMinutes * 60 * 1000;
    return Math.floor((now - epoch) / interval);
  }

  function slotDate(slot) {
    const epoch = Date.parse(state.config.simulation.epochUtc);
    const interval = state.config.meta.updateIntervalMinutes * 60 * 1000;
    return new Date(epoch + slot * interval);
  }

  function chileFormatter(options) {
    return new Intl.DateTimeFormat("es-CL", { timeZone: state.config.meta.timezone, ...options });
  }

  function formatDateTime(date) {
    return chileFormatter({ day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit", hour12: false }).format(date);
  }

  function formatShort(date, period = state.period) {
    if (period === "24h") {
      return chileFormatter({ hour: "2-digit", minute: "2-digit", hour12: false }).format(date);
    }
    if (period === "7d") {
      return chileFormatter({ weekday: "short", hour: "2-digit", hour12: false }).format(date);
    }
    return chileFormatter({ day: "2-digit", month: "2-digit" }).format(date);
  }

  function profileWeight(index) {
    const morning = 1.55 * Math.exp(-Math.pow(index - 29, 2) / 82);
    const midday = 0.58 * Math.exp(-Math.pow(index - 52, 2) / 150);
    const evening = 1.9 * Math.exp(-Math.pow(index - 78, 2) / 94);
    return 0.34 + morning + midday + evening;
  }

  const profileWeights = Array.from({ length: 96 }, (_, index) => profileWeight(index));
  const profileTotal = profileWeights.reduce((sum, value) => sum + value, 0);

  function dailyRate(dayAbsolute) {
    const simulation = state.config.simulation;
    const base = simulation.nominalDailyConsumptionKg;
    const variation = simulation.naturalVariationKg;
    const deterministicWave = 0.68 * Math.sin(dayAbsolute * 1.73) + 0.32 * Math.sin(dayAbsolute * 0.47 + 1.2);
    return clamp(base + variation * deterministicWave, base - variation, base + variation);
  }

  function cycleConsumption(slotInCycle, cycleIndex) {
    const slotsPerDay = state.config.simulation.slotsPerDay;
    const fullDays = Math.floor(slotInCycle / slotsPerDay);
    const daySlot = slotInCycle % slotsPerDay;
    let total = 0;

    for (let day = 0; day < fullDays; day += 1) {
      total += dailyRate(cycleIndex * state.config.device.cycleLengthDays + day);
    }

    const currentRate = dailyRate(cycleIndex * state.config.device.cycleLengthDays + fullDays);
    let partialWeight = 0;
    for (let index = 0; index < daySlot; index += 1) partialWeight += profileWeights[index];
    total += currentRate * (partialWeight / profileTotal);
    return total;
  }

  function readingAt(slot) {
    const cfg = state.config;
    const slotsPerDay = cfg.simulation.slotsPerDay;
    const slotsPerCycle = cfg.device.cycleLengthDays * slotsPerDay;
    const normalized = ((slot % slotsPerCycle) + slotsPerCycle) % slotsPerCycle;
    const cycleIndex = Math.floor(slot / slotsPerCycle);
    const consumed = cycleConsumption(normalized, cycleIndex);
    const net = clamp(cfg.device.netCapacityKg - consumed, cfg.simulation.minimumNetKg, cfg.device.netCapacityKg);
    const gross = net + cfg.device.tareKg;
    const level = clamp((net / cfg.device.netCapacityKg) * 100, 0, 100);

    const batteryCycleSlots = slotsPerDay * 183;
    const batteryPosition = ((slot % batteryCycleSlots) + batteryCycleSlots) % batteryCycleSlots;
    const batteryProgress = batteryPosition / batteryCycleSlots;
    const voltage = cfg.device.batteryStartVoltage - (cfg.device.batteryStartVoltage - cfg.device.batteryEndVoltage) * batteryProgress;
    const battery = clamp(((voltage - 3.5) / (4.5 - 3.5)) * 100, 0, 100);

    return {
      slot,
      date: slotDate(slot),
      cycle: cfg.device.cycleNumberBase + cycleIndex,
      net: round(net),
      gross: round(gross),
      level: round(level, 1),
      voltage: round(voltage),
      battery: round(battery),
    };
  }

  function periodPoints(period, endSlot) {
    const spec = PERIODS[period];
    const start = endSlot - spec.slots;
    const points = [];
    for (let slot = start; slot <= endSlot; slot += spec.step) points.push(readingAt(slot));
    const lastPoint = points[points.length - 1];
    if (!lastPoint || lastPoint.slot !== endSlot) points.push(readingAt(endSlot));
    return points;
  }

  function previousDayConsumption(slot) {
    const start = readingAt(slot - 192);
    const end = readingAt(slot - 96);
    if (end.cycle !== start.cycle) return round(dailyRate(Math.floor((slot - 96) / 96)));
    return round(Math.max(0, start.net - end.net));
  }

  function statusFor(level) {
    if (level < 15) return { label: "Nivel crítico", tone: "danger" };
    if (level < 35) return { label: "Planifica el recambio", tone: "warning" };
    return { label: "Nivel normal", tone: "success" };
  }

  function updateGauge(level) {
    const arcLength = 251.33;
    const value = clamp(level, 0, 100);
    const fill = $("gauge-fill");
    fill.style.strokeDasharray = `${(arcLength * value / 100).toFixed(2)} ${arcLength}`;
    fill.style.stroke = "var(--orange)";
    $("gauge-pct").textContent = `${value.toFixed(1)}%`;
    $("gauge-pct").style.color = "var(--orange)";
  }

  function renderLatest(slot) {
    const cfg = state.config;
    const reading = readingAt(slot);
    const consumption = previousDayConsumption(slot);
    const remaining = reading.net / cfg.simulation.nominalDailyConsumptionKg;
    const readingStatus = statusFor(reading.level);

    $("device-mac").textContent = cfg.meta.deviceMac;
    $("device-model").textContent = `${cfg.device.model} · Cilindro ${cfg.device.cylinder}`;
    $("wifi-name").textContent = cfg.device.wifiName;
    $("cycle-count").textContent = String(reading.cycle);
    $("net-weight").textContent = `${reading.net.toFixed(2)} kg`;
    const grossWeight = $("gross-weight");
    if (grossWeight) grossWeight.textContent = `${reading.gross.toFixed(2)} kg`;
    $("daily-use").textContent = `${consumption.toFixed(2)} kg`;
    $("days-left").textContent = `~${remaining.toFixed(1)} d`;
    $("battery-value").textContent = `${reading.voltage.toFixed(2)} V · ${reading.battery.toFixed(0)}%`;
    $("battery-fill").style.width = `${reading.battery}%`;
    $("battery-fill").style.background = reading.battery < 20 ? "var(--red)" : reading.battery < 40 ? "var(--orange)" : "var(--green)";
    $("last-reading").textContent = `${formatDateTime(reading.date)} (Chile)`;
    $("system-state").textContent = "Vista sin conexión operativa";
    $("level-state").textContent = readingStatus.label;
    $("level-state").className = `metric-note ${readingStatus.tone}`;
    $("connection-dot").className = "status-dot online";
    updateGauge(reading.level);

    const standard = cfg.device.netCapacityKg;
    const real = standard - cfg.device.calibrationDifferenceKg;
    $("cal-standard").textContent = `${standard.toFixed(2)} kg`;
    $("cal-real").textContent = `${real.toFixed(2)} kg`;
    $("cal-diff").textContent = `−${cfg.device.calibrationDifferenceKg.toFixed(2)} kg`;
    $("cal-date").textContent = `Último ciclo simulado: ${formatDateTime(readingAt(slot - (slot % (cfg.device.cycleLengthDays * 96))).date)}`;

    renderRecords(slot);
    renderSummary(reading);
  }

  function renderRecords(slot) {
    const rows = [readingAt(slot), readingAt(slot - 1), readingAt(slot - 2)];
    $("records-body").innerHTML = rows.map((row) => {
      const status = statusFor(row.level);
      return `<tr>
        <td>${escapeText(formatDateTime(row.date))}</td>
        <td><strong>${row.level.toFixed(1)}%</strong></td>
        <td>${row.net.toFixed(2)} kg</td>
        <td>${row.voltage.toFixed(2)} V</td>
        <td><span class="record-badge ${status.tone}">${escapeText(status.label)}</span></td>
      </tr>`;
    }).join("");
  }

  function calculateStats(points) {
    const values = points.map((point) => point.net);
    let consumed = 0;
    for (let index = 1; index < points.length; index += 1) {
      const drop = points[index - 1].net - points[index].net;
      if (drop > 0) consumed += drop;
    }
    return {
      average: values.reduce((sum, value) => sum + value, 0) / values.length,
      maximum: Math.max(...values),
      minimum: Math.min(...values),
      consumed,
    };
  }

  function renderSummary(latest) {
    const stats = calculateStats(state.points.length ? state.points : [latest]);
    const periodLabel = PERIODS[state.period].label;
    $("summary-period").textContent = periodLabel;
    $("summary-period-modal").textContent = periodLabel;
    $("summary-average").textContent = `${stats.average.toFixed(2)} kg`;
    $("summary-max").textContent = `${stats.maximum.toFixed(2)} kg`;
    $("summary-min").textContent = `${stats.minimum.toFixed(2)} kg`;
    $("summary-consumed").textContent = `${stats.consumed.toFixed(2)} kg`;
  }

  /* @section: demo-chart */
  function drawChart() {
    const canvas = $("history-chart");
    const box = canvas.parentElement;
    const rect = box.getBoundingClientRect();
    const width = Math.max(300, rect.width);
    const height = Math.max(250, rect.height);
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = width * dpr;
    canvas.height = height * dpr;
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;

    const ctx = canvas.getContext("2d");
    ctx.scale(dpr, dpr);
    const points = state.points;
    if (!points.length) return;

    const dark = document.documentElement.dataset.theme === "dark";
    const colors = {
      grid: dark ? "rgba(148,163,184,.18)" : "rgba(100,116,139,.16)",
      text: dark ? "#94a3b8" : "#64748b",
      line: "#10b981",
      fillTop: dark ? "rgba(16,185,129,.24)" : "rgba(16,185,129,.16)",
      fillBottom: dark ? "rgba(16,185,129,.07)" : "rgba(16,185,129,.04)",
      point: "#10b981",
    };
    const padding = { top: 18, right: 16, bottom: 34, left: 48 };
    const chartWidth = width - padding.left - padding.right;
    const chartHeight = height - padding.top - padding.bottom;
    const rawMin = Math.min(...points.map((point) => point.net));
    const rawMax = Math.max(...points.map((point) => point.net));
    const minY = Math.max(0, Math.floor((rawMin - 0.5) * 2) / 2);
    const maxY = Math.ceil((Math.max(rawMax, minY + 1) + 0.5) * 2) / 2;
    const xAt = (index) => padding.left + (index / Math.max(1, points.length - 1)) * chartWidth;
    const yAt = (value) => padding.top + (1 - (value - minY) / (maxY - minY)) * chartHeight;

    ctx.clearRect(0, 0, width, height);
    ctx.font = "11px Inter, Segoe UI, sans-serif";
    ctx.fillStyle = colors.text;
    ctx.strokeStyle = colors.grid;
    ctx.lineWidth = 1;

    for (let line = 0; line <= 4; line += 1) {
      const value = minY + ((maxY - minY) * line / 4);
      const y = yAt(value);
      ctx.beginPath();
      ctx.moveTo(padding.left, y);
      ctx.lineTo(width - padding.right, y);
      ctx.stroke();
      ctx.textAlign = "right";
      ctx.fillText(`${value.toFixed(1)} kg`, padding.left - 8, y + 4);
    }

    const tickCount = width < 520 ? 4 : 7;
    for (let tick = 0; tick <= tickCount; tick += 1) {
      const index = Math.round((points.length - 1) * tick / tickCount);
      ctx.textAlign = tick === 0 ? "left" : tick === tickCount ? "right" : "center";
      ctx.fillText(formatShort(points[index].date), xAt(index), height - 10);
    }

    const gradient = ctx.createLinearGradient(0, padding.top, 0, height - padding.bottom);
    gradient.addColorStop(0, colors.fillTop);
    gradient.addColorStop(1, colors.fillBottom);
    ctx.beginPath();
    points.forEach((point, index) => {
      const x = xAt(index);
      const y = yAt(point.net);
      if (index === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    });
    ctx.lineTo(xAt(points.length - 1), height - padding.bottom);
    ctx.lineTo(xAt(0), height - padding.bottom);
    ctx.closePath();
    ctx.fillStyle = gradient;
    ctx.fill();

    ctx.beginPath();
    points.forEach((point, index) => {
      const x = xAt(index);
      const y = yAt(point.net);
      if (index === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    });
    ctx.strokeStyle = colors.line;
    ctx.lineWidth = 2.5;
    ctx.lineJoin = "round";
    ctx.stroke();

    const lastIndex = points.length - 1;
    ctx.beginPath();
    ctx.arc(xAt(lastIndex), yAt(points[lastIndex].net), 4, 0, Math.PI * 2);
    ctx.fillStyle = colors.point;
    ctx.fill();

    canvas._chartGeometry = { padding, chartWidth, points };
  }

  function showChartTooltip(event) {
    const canvas = $("history-chart");
    const geometry = canvas._chartGeometry;
    if (!geometry) return;
    const rect = canvas.getBoundingClientRect();
    const x = event.clientX - rect.left;
    const ratio = clamp((x - geometry.padding.left) / geometry.chartWidth, 0, 1);
    const index = Math.round(ratio * (geometry.points.length - 1));
    const point = geometry.points[index];
    const tooltip = $("chart-tooltip");
    tooltip.innerHTML = `<strong>${point.net.toFixed(2)} kg</strong><span>${escapeText(formatDateTime(point.date))}</span><span>Cilindro N.º ${point.cycle}</span>`;
    tooltip.style.left = `${clamp(x, 78, rect.width - 78)}px`;
    tooltip.style.top = `${Math.max(12, event.clientY - rect.top - 82)}px`;
    tooltip.hidden = false;
  }

  function hideChartTooltip() {
    $("chart-tooltip").hidden = true;
  }

  function changePeriod(period) {
    if (period !== "24h") {
      const periodSelect = $("period-select");
      if (periodSelect) periodSelect.value = "24h";
      showToast("Los periodos de 7 días, 30 días y 6 meses están disponibles en la versión operativa de LevelGas.");
      return;
    }
    state.period = period;
    state.points = periodPoints(period, state.latestSlot);
    const periodSelect = $("period-select");
    if (periodSelect) periodSelect.value = period;
    drawChart();
    renderSummary(readingAt(state.latestSlot));
    $("chart-description").textContent = `Historial simulado de ${PERIODS[period].label.toLowerCase()}. Los valores se calculan localmente y no corresponden a un equipo real.`;
  }

  /* @section: demo-read-only-actions */
  function showToast(message = "Función disponible en la versión operativa de LevelGas.") {
    const toast = $("demo-toast");
    toast.textContent = message;
    toast.classList.add("visible");
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => toast.classList.remove("visible"), 3600);
  }

  function modalFocusableElements(modal) {
    return Array.from(modal.querySelectorAll(
      'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
    )).filter((element) => !element.hidden && element.getAttribute("aria-hidden") !== "true");
  }

  function openModal(id, trigger = document.activeElement) {
    const modal = $(id);
    if (!modal) return;
    state.modalReturnFocus = trigger instanceof HTMLElement ? trigger : null;
    modal.hidden = false;
    document.body.classList.add("modal-open");
    const focusable = modalFocusableElements(modal);
    (focusable[0] || modal.querySelector(".modal-card"))?.focus();
  }

  function closeModal(modal) {
    if (!modal) return;
    modal.hidden = true;
    if (!document.querySelector(".modal-overlay:not([hidden])")) document.body.classList.remove("modal-open");
    state.modalReturnFocus?.focus();
    state.modalReturnFocus = null;
  }

  function keepFocusInsideModal(event, modal) {
    if (event.key !== "Tab") return;
    const focusable = modalFocusableElements(modal);
    if (!focusable.length) {
      event.preventDefault();
      modal.querySelector(".modal-card")?.focus();
      return;
    }
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  function populateConfigModal() {
    const cfg = state.config;
    $("config-cylinder").value = cfg.device.cylinder;
    $("config-tare").value = `${cfg.device.tareKg.toFixed(1)} kg`;
    $("config-full").value = `${cfg.device.fullWeightKg.toFixed(1)} kg`;
    document.querySelectorAll(".cylinder-choice").forEach((button) => {
      button.classList.toggle("selected", button.dataset.cylinder === cfg.device.cylinder);
    });
  }

  function populatePlans() {
    const container = $("plan-grid");
    container.innerHTML = state.config.plans.map((plan) => `<article class="plan-card ${plan.id}">
      <div class="plan-name">${escapeText(plan.name)}</div>
      <div class="plan-price">${escapeText(plan.price)}</div>
      <ul>${plan.features.map((feature) => `<li>${escapeText(feature)}</li>`).join("")}</ul>
      <button type="button" class="button plan-action" data-blocked="plan-${escapeText(plan.id)}">Contratar ${escapeText(plan.name)}</button>
    </article>`).join("");
  }

  function populateProviders() {
    $("provider-list").innerHTML = state.config.demoProviders.map((provider) => `<li>
      <span><strong>${escapeText(provider.name)}</strong><small>${escapeText(provider.phone)}</small></span>
      <button type="button" class="icon-button" data-blocked="provider-call" aria-label="Llamar a ${escapeText(provider.name)}">Llamar</button>
    </li>`).join("");
  }

  function downloadBlob(name, content, type) {
    const blob = new Blob([content], { type });
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = name;
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(link.href), 1000);
  }

  function exportDemo(kind) {
    const points = state.points;
    const rows = [
      ["LEVELGAS — INFORME DEMOSTRATIVO"],
      ["Datos simulados · Sin validez operativa"],
      ["MAC ficticia", state.config.meta.deviceMac],
      ["Periodo", PERIODS[state.period].label],
      [],
      ["Fecha y hora (Chile)", "Cilindro", "Nivel (%)", "Peso neto (kg)", "Peso bruto (kg)", "Batería (V)"],
      ...points.map((point) => [formatDateTime(point.date), point.cycle, point.level.toFixed(1), point.net.toFixed(2), point.gross.toFixed(2), point.voltage.toFixed(2)]),
    ];

    if (kind === "pdf") {
      document.body.classList.add("print-demo");
      window.print();
      setTimeout(() => document.body.classList.remove("print-demo"), 500);
      return;
    }

    const separator = kind === "excel" ? "\t" : ",";
    const escaped = rows.map((row) => row.map((cell) => {
      const text = String(cell ?? "");
      return separator === "," ? `"${text.replace(/"/g, '""')}"` : text;
    }).join(separator)).join("\n");
    const date = slotDate(state.latestSlot).toISOString().slice(0, 10);
    if (kind === "excel") {
      downloadBlob(`LevelGas-DEMO-compatible-Excel-${date}.xls`, `\uFEFF${escaped}`, "application/vnd.ms-excel;charset=utf-8");
    } else {
      downloadBlob(`LevelGas-DEMO-${date}.csv`, `\uFEFF${escaped}`, "text/csv;charset=utf-8");
    }
    showToast("Informe demostrativo descargado. Contiene únicamente datos simulados.");
  }

  function updateCountdown() {
    const interval = state.config.meta.updateIntervalMinutes * 60 * 1000;
    const epoch = Date.parse(state.config.simulation.epochUtc);
    const elapsed = Date.now() - epoch;
    const remaining = interval - (((elapsed % interval) + interval) % interval);
    const minutes = Math.floor(remaining / 60000);
    const seconds = Math.floor((remaining % 60000) / 1000);
    $("next-update").textContent = `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;

    const slot = alignedSlot();
    if (slot !== state.latestSlot) {
      state.latestSlot = slot;
      state.points = periodPoints(state.period, slot);
      renderLatest(slot);
      drawChart();
    }
  }

  function bindEvents() {
    $("period-select").addEventListener("change", (event) => changePeriod(event.currentTarget.value));

    $("theme-toggle").addEventListener("click", () => {
      const dark = document.documentElement.dataset.theme === "dark";
      state.theme = dark ? "light" : "dark";
      document.documentElement.dataset.theme = state.theme;
      $("theme-toggle").setAttribute("aria-label", state.theme === "dark" ? "Activar modo claro" : "Activar modo oscuro");
      $("theme-label").textContent = state.theme === "dark" ? "Modo claro" : "Modo oscuro";
      drawChart();
    });

    $("history-chart").addEventListener("pointermove", showChartTooltip);
    $("history-chart").addEventListener("pointerleave", hideChartTooltip);
    window.addEventListener("resize", () => requestAnimationFrame(drawChart));

    document.addEventListener("click", (event) => {
      const blocked = event.target.closest("[data-blocked]");
      if (blocked) {
        event.preventDefault();
        showToast();
        return;
      }
      const opener = event.target.closest("[data-open-modal]");
      if (opener) openModal(opener.dataset.openModal, opener);
      const closer = event.target.closest("[data-close-modal]");
      if (closer) closeModal(closer.closest(".modal-overlay"));
      if (event.target.classList.contains("modal-overlay")) closeModal(event.target);
      const exporter = event.target.closest("[data-export]");
      if (exporter) exportDemo(exporter.dataset.export);
    });

    document.addEventListener("keydown", (event) => {
      const modal = document.querySelector(".modal-overlay:not([hidden])");
      if (!modal) return;
      if (event.key === "Escape") {
        event.preventDefault();
        closeModal(modal);
        return;
      }
      keepFocusInsideModal(event, modal);
    });

  }

  async function init() {
    try {
      // La demo estática solo carga este archivo JSON local; no usa la API operativa.
      // eslint-disable-next-line local/no-direct-api-request
      const response = await fetch("./demo-data.json", { cache: "no-store" });
      if (!response.ok) throw new Error(`No se pudo cargar la demostración (${response.status})`);
      state.config = await response.json();
      document.title = "Demo interactiva | Dashboard LevelGas";
      populateConfigModal();
      populatePlans();
      populateProviders();
      bindEvents();
      state.latestSlot = alignedSlot();
      state.points = periodPoints(state.period, state.latestSlot);
      renderLatest(state.latestSlot);
      changePeriod(state.period);
      updateCountdown();
      setInterval(updateCountdown, 1000);
      document.body.classList.add("ready");
    } catch (error) {
      console.error(error);
      $("load-error").hidden = false;
      $("load-error").textContent = "No fue posible cargar los datos demostrativos. Recarga la página para intentarlo nuevamente.";
    }
  }

  init();
})();
