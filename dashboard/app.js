const $ = (id) => document.getElementById(id);
const money = (value, digits = 2) => new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  minimumFractionDigits: digits,
  maximumFractionDigits: digits,
}).format(value || 0);
const number = (value, digits = 2) => new Intl.NumberFormat("en-US", {
  minimumFractionDigits: digits,
  maximumFractionDigits: digits,
}).format(value || 0);
const compact = (value) => new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 2 }).format(value || 0);
const token = (value, digits = 6) => number(value, digits).replace(/0+$/, "").replace(/\.$/, "");
const shortHash = (value) => value ? `${value.slice(0, 6)}...${value.slice(-4)}` : "--";
const set = (id, value) => { const node = $(id); if (node) node.textContent = value; };

function duration(seconds) {
  const value = Math.max(0, Math.floor(seconds || 0));
  const hours = Math.floor(value / 3600);
  const minutes = Math.floor((value % 3600) / 60);
  const secs = value % 60;
  if (hours) return `${hours}H ${String(minutes).padStart(2, "0")}M`;
  return `${minutes}M ${String(secs).padStart(2, "0")}S`;
}

function clock(timestamp) {
  return new Date(timestamp * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function renderPnl(current) {
  const pnl = current.netPnlUsd;
  const positive = pnl >= 0;
  set("pnl-sign", positive ? "+" : "-");
  set("net-pnl", money(Math.abs(pnl)));
  set("net-pnl-pct", `${positive ? "+" : ""}${number(current.netPnlPct, 3)}%`);
  const line = $("net-pnl").parentElement;
  line.classList.toggle("negative", !positive);
  document.title = `${positive ? "+" : "-"}${money(Math.abs(pnl))} / Base Canary`;

  set("strategy-value", money(current.strategyValueUsd));
  set("capital-benchmark", `Opening basis ${money(current.capitalBenchmarkUsd)}`);
  set("hook-revenue", money(current.hookRevenueValueUsd));
  set("hook-weth", `${token(current.balances.retainedRevenueWeth, 9)} WETH since relaunch`);
  set("lp-fees", money(current.lpFeeValueUsd));
  set("lp-range", `Range ${current.inRange ? "active" : "out"} / tick ${current.tick}`);
  set("reference-price", money(current.referencePrice, 2));
  set("pool-price", money(current.poolPrice, 2));
  const delta = current.referencePrice ? (current.poolPrice / current.referencePrice - 1) * 10000 : 0;
  set("price-delta", `${delta >= 0 ? "+" : ""}${number(delta, 2)} bps`);
}

function renderComposition(current) {
  const parts = [
    ["lp", current.lpPrincipalValueUsd],
    ["fees", current.lpFeeValueUsd],
    ["revenue", current.hookBalanceValueUsd],
    ["adapters", current.adapterValueUsd],
  ];
  const total = parts.reduce((sum, item) => sum + item[1], 0) || 1;
  $("composition").innerHTML = parts.map(([name, value]) =>
    `<span class="${name}" style="width:${Math.max(0, value / total * 100)}%" title="${name}: ${money(value)}"></span>`
  ).join("");
  set("lp-principal", money(current.lpPrincipalValueUsd));
  set("fee-value", money(current.lpFeeValueUsd));
  set("revenue-value", money(current.hookBalanceValueUsd));
  set("adapter-value", money(current.adapterValueUsd));
  set("portfolio-total", money(current.strategyValueUsd));
  set("lp-weth", token(current.balances.lpPrincipalWeth, 9));
  set("lp-usdc", number(current.balances.lpPrincipalUsdc, 6));
  set("fee-weth", token(current.balances.lpFeeWeth, 9));
  set("fee-usdc", number(current.balances.lpFeeUsdc, 6));
}

function renderChart(history, trades) {
  const svg = $("pnl-chart");
  if (!history || history.length < 2) return;
  $("chart-empty").hidden = true;
  const width = 1000;
  const height = 340;
  const pad = { left: 70, right: 72, top: 22, bottom: 34 };
  const startTime = history[0].timestamp;
  const endTime = history[history.length - 1].timestamp;
  const timeRange = Math.max(endTime - startTime, 1);
  const values = history.map((point) => point.netPnlUsd);
  let min = Math.min(0, ...values);
  let max = Math.max(0, ...values);
  const range = Math.max(max - min, 0.5);
  min -= range * 0.12;
  max += range * 0.12;
  const plotRight = width - pad.right;
  const plotBottom = height - pad.bottom;
  const x = (timestamp) => pad.left + (timestamp - startTime) / timeRange * (plotRight - pad.left);
  const y = (value) => pad.top + (max - value) / (max - min) * (height - pad.top - pad.bottom);
  const visibleTrades = (trades || []).filter((trade) => trade.timestamp >= startTime && trade.timestamp <= endTime);
  const maxTradeProfit = Math.max(...visibleTrades.map((trade) => trade.profitUsd), 0.1) * 1.15;
  const tradeY = (value) => pad.top + (maxTradeProfit - value) / maxTradeProfit * (plotBottom - pad.top);
  const points = history.map((point) => `${x(point.timestamp).toFixed(2)},${y(point.netPnlUsd).toFixed(2)}`);
  const line = `M${points.join(" L")}`;
  const area = `${line} L${x(endTime)},${plotBottom} L${x(startTime)},${plotBottom} Z`;
  const zeroY = y(0);
  const grid = Array.from({ length: 5 }, (_, index) => {
    const value = min + (max - min) * index / 4;
    const gy = y(value);
    return `<line x1="${pad.left}" y1="${gy}" x2="${plotRight}" y2="${gy}" stroke="rgba(255,255,255,.08)" />
      <text x="${pad.left - 10}" y="${gy + 3}" fill="rgba(255,255,255,.44)" font-family="DM Mono, monospace" font-size="9" text-anchor="end">${value >= 0 ? "+" : ""}$${value.toFixed(2)}</text>`;
  }).join("");
  const tradeAxis = Array.from({ length: 5 }, (_, index) => {
    const value = maxTradeProfit * index / 4;
    const gy = tradeY(value);
    return `<line x1="${plotRight}" y1="${gy}" x2="${plotRight + 5}" y2="${gy}" stroke="rgba(238,106,75,.62)" />
      <text x="${plotRight + 9}" y="${gy + 3}" fill="rgba(238,106,75,.78)" font-family="DM Mono, monospace" font-size="9">$${value.toFixed(2)}</text>`;
  }).join("");
  const tradeMarks = visibleTrades.map((trade) => {
    const cx = x(trade.timestamp);
    const cy = tradeY(trade.profitUsd);
    const label = `${trade.controlled ? "Controlled test" : "Organic trade"}: ${money(trade.profitUsd, 4)} retained at ${clock(trade.timestamp)} / ${money(trade.triggerNotionalUsd, 2)} trigger`;
    const marker = trade.controlled
      ? `<rect x="${cx - 4.5}" y="${cy - 4.5}" width="9" height="9" transform="rotate(45 ${cx} ${cy})" fill="#ee6a4b" stroke="#11222d" stroke-width="1.5" vector-effect="non-scaling-stroke"><title>${label}</title></rect>`
      : `<circle cx="${cx}" cy="${cy}" r="5" fill="#ee6a4b" stroke="#11222d" stroke-width="1.5" vector-effect="non-scaling-stroke"><title>${label}</title></circle>`;
    return `<a href="https://basescan.org/tx/${trade.transaction}" target="_blank">
      <line x1="${cx}" y1="${plotBottom}" x2="${cx}" y2="${cy}" stroke="rgba(238,106,75,.32)" stroke-width="1.5" stroke-dasharray="3 4" vector-effect="non-scaling-stroke" />
      ${marker}</a>`;
  }).join("");
  const latest = history[history.length - 1];
  svg.innerHTML = `
    <defs>
      <linearGradient id="pnl-fill" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="#b7f34a" stop-opacity=".28" />
        <stop offset="1" stop-color="#b7f34a" stop-opacity="0" />
      </linearGradient>
      <filter id="line-glow"><feGaussianBlur stdDeviation="3" result="blur"/><feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
    </defs>
    ${grid}
    <line x1="${plotRight}" y1="${pad.top}" x2="${plotRight}" y2="${plotBottom}" stroke="rgba(238,106,75,.35)" />
    ${tradeAxis}
    <text x="${width - 5}" y="${pad.top - 8}" fill="rgba(238,106,75,.78)" font-family="DM Mono, monospace" font-size="8" text-anchor="end">TRADE PROFIT</text>
    <line x1="${pad.left}" y1="${zeroY}" x2="${plotRight}" y2="${zeroY}" stroke="rgba(255,255,255,.5)" stroke-dasharray="5 7" />
    <path d="${area}" fill="url(#pnl-fill)" />
    ${tradeMarks}
    <path d="${line}" fill="none" stroke="#b7f34a" stroke-width="3" vector-effect="non-scaling-stroke" filter="url(#line-glow)" />
    <circle cx="${x(latest.timestamp)}" cy="${y(latest.netPnlUsd)}" r="5" fill="#b7f34a" stroke="#11222d" stroke-width="3" vector-effect="non-scaling-stroke" />`;
  set("chart-start", `LAUNCH ${clock(history[0].timestamp)}`);
  set("chart-end", `NOW ${clock(latest.timestamp)}`);
  set("chart-range", `${history.length} STATES / ${visibleTrades.length} TRADES`);
}

function renderActivity(activity) {
  set("organic-volume", money(activity.organicVolumeUsd, 2));
  set("organic-count", `${activity.organicTransactions} transactions / ${activity.uniqueTargets} targets`);
  set("settlement-count", String(activity.organicSettlements));
  set("success-rate", `${number(activity.successRatePct, 1)}% hit rate`);
  set("average-profit", money(activity.averageOrganicProfitUsd, 3));
  set("minimum-hit", money(activity.minProfitableTriggerUsd, 2));
  set("noop-count", String(activity.noOpTransactions));

  const trades = activity.trades || [];
  renderTradeChart(activity.triggerObservations || []);

  if (!trades.length) return;
  $("trade-rows").innerHTML = trades.slice(0, 14).map((trade) => `
    <tr>
      <td><strong>${clock(trade.timestamp)}</strong><small><a class="tx-link" href="https://basescan.org/tx/${trade.transaction}" target="_blank" rel="noreferrer">${shortHash(trade.transaction)}</a>${trade.controlled ? '<span class="tag">TEST</span>' : ""}</small></td>
      <td><strong>${money(trade.triggerNotionalUsd, 2)}</strong><small>${trade.direction}</small></td>
      <td><strong>${shortHash(trade.buyPool)} -> ${shortHash(trade.sellPool)}</strong><small>${token(trade.totalSwappedToken, 7)} ${trade.profitSymbol} cycled</small></td>
      <td>${trade.iterations}</td>
      <td class="profit">+${money(trade.profitUsd, 4)}<small>${token(trade.profitToken, 9)} ${trade.profitSymbol}</small></td>
      <td>${compact(trade.gasUsed)}<small>${token(trade.txFeeEth, 7)} ETH paid by trigger</small></td>
    </tr>`).join("");
}

function renderTradeChart(observations) {
  const svg = $("trade-chart");
  if (!observations.length) {
    svg.innerHTML = '<text x="500" y="150" text-anchor="middle" fill="#53606b" font-family="DM Mono, monospace" font-size="12">Waiting for trigger observations...</text>';
    return;
  }
  const width = 1000;
  const height = 300;
  const pad = { left: 70, right: 24, top: 22, bottom: 46 };
  const maxX = Math.max(...observations.map((item) => item.triggerNotionalUsd), 10) * 1.08;
  const maxY = Math.max(...observations.map((item) => item.profitUsd), 0.1) * 1.14;
  const x = (value) => pad.left + value / maxX * (width - pad.left - pad.right);
  const y = (value) => pad.top + (maxY - value) / maxY * (height - pad.top - pad.bottom);
  const xTicks = Array.from({ length: 6 }, (_, index) => maxX * index / 5);
  const yTicks = Array.from({ length: 5 }, (_, index) => maxY * index / 4);
  const grid = [
    ...xTicks.map((value) => `<line x1="${x(value)}" y1="${pad.top}" x2="${x(value)}" y2="${height - pad.bottom}" stroke="rgba(16,26,36,.08)"/><text x="${x(value)}" y="${height - 19}" text-anchor="middle" fill="#68747d" font-family="DM Mono, monospace" font-size="9">$${value.toFixed(0)}</text>`),
    ...yTicks.map((value) => `<line x1="${pad.left}" y1="${y(value)}" x2="${width - pad.right}" y2="${y(value)}" stroke="rgba(16,26,36,.08)"/><text x="${pad.left - 10}" y="${y(value) + 3}" text-anchor="end" fill="#68747d" font-family="DM Mono, monospace" font-size="9">$${value.toFixed(2)}</text>`),
  ].join("");
  const points = observations.map((item, index) => {
    const cx = x(item.triggerNotionalUsd);
    const cy = item.settled ? y(item.profitUsd) : y(0) - (index % 4) * 2;
    const label = `${item.controlled ? "Controlled" : item.settled ? "Profitable" : "No-op"}: ${money(item.triggerNotionalUsd, 2)} trigger / ${money(item.profitUsd, 4)} profit / ${item.direction}`;
    if (item.controlled) {
      return `<a href="https://basescan.org/tx/${item.transaction}" target="_blank"><rect x="${cx - 5}" y="${cy - 5}" width="10" height="10" transform="rotate(45 ${cx} ${cy})" fill="#ee6a4b" stroke="#f2f0e9" stroke-width="2"><title>${label}</title></rect></a>`;
    }
    const fill = item.settled ? "#137a55" : "#95a0a6";
    const opacity = item.settled ? 0.9 : 0.38;
    const radius = item.settled ? 7 : 4;
    return `<a href="https://basescan.org/tx/${item.transaction}" target="_blank"><circle cx="${cx}" cy="${cy}" r="${radius}" fill="${fill}" fill-opacity="${opacity}" stroke="${item.settled ? "#f2f0e9" : "none"}" stroke-width="2"><title>${label}</title></circle></a>`;
  }).join("");
  svg.innerHTML = `${grid}
    <line x1="${pad.left}" y1="${y(0)}" x2="${width - pad.right}" y2="${y(0)}" stroke="#101a24" stroke-width="1.2"/>
    <text x="${(pad.left + width - pad.right) / 2}" y="${height - 2}" text-anchor="middle" fill="#53606b" font-family="DM Mono, monospace" font-size="9">TRIGGER NOTIONAL (USDC)</text>
    <text x="13" y="${height / 2}" text-anchor="middle" fill="#53606b" font-family="DM Mono, monospace" font-size="9" transform="rotate(-90 13 ${height / 2})">RETAINED PROFIT (USD)</text>
    ${points}`;
}

function renderHealth(health) {
  const badge = $("health-badge");
  badge.textContent = health.ok ? "NOMINAL" : "ATTENTION";
  badge.className = `health-badge ${health.ok ? "good" : "bad"}`;
  $("health-checks").innerHTML = (health.checks || []).map((check) => `
    <div class="health-check ${check.ok ? "ok" : ""}">
      <i></i><span>${check.label}</span><span>${check.value}</span>
    </div>`).join("");
}

function render(data) {
  const live = data.status === "live";
  $("live-dot").className = `live-dot ${live ? "live" : "error"}`;
  set("live-label", live ? "LIVE" : data.status.toUpperCase());
  set("last-updated", new Date(data.updatedAt * 1000).toLocaleTimeString());
  if (!live) {
    if (data.error) showError(data.error);
    return;
  }
  $("error-banner").hidden = true;
  set("head-block", new Intl.NumberFormat("en-US").format(data.chain.head));
  set("run-time", duration(data.deployment.elapsedSeconds));
  set("position-id", `POSITION #${data.deployment.positionTokenId}`);
  renderPnl(data.current);
  renderComposition(data.current);
  renderChart(data.history, data.activity.trades || []);
  renderActivity(data.activity);
  renderHealth(data.health);
  set("accounting-method", data.accounting.method);
  set("accounting-assumption", `${data.accounting.assumption} Reference: ${data.accounting.reference}.`);
}

function showError(message) {
  const banner = $("error-banner");
  banner.textContent = `Dashboard refresh failed: ${message}`;
  banner.hidden = false;
}

async function refresh() {
  try {
    const response = await fetch("/api/dashboard", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    render(await response.json());
  } catch (error) {
    $("live-dot").className = "live-dot error";
    set("live-label", "OFFLINE");
    showError(error.message);
  }
}

refresh();
setInterval(refresh, 8000);
