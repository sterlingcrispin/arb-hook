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
  set("hold-value", `Hold benchmark ${money(current.holdValueUsd)}`);
  set("hook-revenue", money(current.hookRevenueValueUsd));
  set("hook-weth", `${token(current.balances.hookWeth, 9)} WETH`);
  set("lp-fees", money(current.lpFeeValueUsd));
  set("lp-range", `Range ${current.inRange ? "active" : "out"} / tick ${current.tick}`);
  set("reference-price", money(current.referencePrice, 2));
  set("pool-price", money(current.poolPrice, 2));
  const delta = current.referencePrice ? (current.poolPrice / current.referencePrice - 1) * 10000 : 0;
  set("price-delta", `${delta >= 0 ? "+" : ""}${number(delta, 2)} bps`);
}

function renderComposition(current) {
  const parts = [
    ["wallet", current.walletValueUsd],
    ["lp", current.lpPrincipalValueUsd],
    ["fees", current.lpFeeValueUsd],
    ["revenue", current.hookRevenueValueUsd],
  ];
  const total = parts.reduce((sum, item) => sum + item[1], 0) || 1;
  $("composition").innerHTML = parts.map(([name, value]) =>
    `<span class="${name}" style="width:${Math.max(0, value / total * 100)}%" title="${name}: ${money(value)}"></span>`
  ).join("");
  set("wallet-value", money(current.walletValueUsd));
  set("lp-principal", money(current.lpPrincipalValueUsd));
  set("fee-value", money(current.lpFeeValueUsd));
  set("revenue-value", money(current.hookRevenueValueUsd));
  set("portfolio-total", money(current.strategyValueUsd));
  set("lp-weth", token(current.balances.lpPrincipalWeth, 9));
  set("lp-usdc", number(current.balances.lpPrincipalUsdc, 6));
  set("fee-weth", token(current.balances.lpFeeWeth, 9));
  set("fee-usdc", number(current.balances.lpFeeUsdc, 6));
}

function renderChart(history) {
  const svg = $("pnl-chart");
  if (!history || history.length < 2) return;
  $("chart-empty").hidden = true;
  const width = 1000;
  const height = 340;
  const pad = { left: 70, right: 18, top: 22, bottom: 34 };
  const values = history.map((point) => point.netPnlUsd);
  let min = Math.min(0, ...values);
  let max = Math.max(0, ...values);
  const range = Math.max(max - min, 0.5);
  min -= range * 0.12;
  max += range * 0.12;
  const x = (index) => pad.left + index / (history.length - 1) * (width - pad.left - pad.right);
  const y = (value) => pad.top + (max - value) / (max - min) * (height - pad.top - pad.bottom);
  const points = history.map((point, index) => `${x(index).toFixed(2)},${y(point.netPnlUsd).toFixed(2)}`);
  const line = `M${points.join(" L")}`;
  const area = `${line} L${x(history.length - 1)},${height - pad.bottom} L${x(0)},${height - pad.bottom} Z`;
  const zeroY = y(0);
  const grid = Array.from({ length: 5 }, (_, index) => {
    const value = min + (max - min) * index / 4;
    const gy = y(value);
    return `<line x1="${pad.left}" y1="${gy}" x2="${width - pad.right}" y2="${gy}" stroke="rgba(255,255,255,.08)" />
      <text x="${pad.left - 10}" y="${gy + 3}" fill="rgba(255,255,255,.44)" font-family="DM Mono, monospace" font-size="9" text-anchor="end">${value >= 0 ? "+" : ""}$${value.toFixed(2)}</text>`;
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
    <line x1="${pad.left}" y1="${zeroY}" x2="${width - pad.right}" y2="${zeroY}" stroke="rgba(255,255,255,.5)" stroke-dasharray="5 7" />
    <path d="${area}" fill="url(#pnl-fill)" />
    <path d="${line}" fill="none" stroke="#b7f34a" stroke-width="3" vector-effect="non-scaling-stroke" filter="url(#line-glow)" />
    <circle cx="${x(history.length - 1)}" cy="${y(latest.netPnlUsd)}" r="5" fill="#b7f34a" stroke="#11222d" stroke-width="3" vector-effect="non-scaling-stroke" />`;
  set("chart-start", `LAUNCH ${clock(history[0].timestamp)}`);
  set("chart-end", `NOW ${clock(latest.timestamp)}`);
  set("chart-range", `${history.length} STATE SAMPLES`);
}

function renderActivity(activity) {
  set("organic-volume", money(activity.organicVolumeUsd, 2));
  set("organic-count", `${activity.organicTransactions} transactions / ${activity.uniqueTargets} targets`);
  set("settlement-count", String(activity.organicSettlements));
  set("success-rate", `${number(activity.successRatePct, 1)}% hit rate`);
  set("average-profit", money(activity.averageOrganicProfitUsd, 3));
  set("noop-count", String(activity.noOpTransactions));

  const trades = activity.trades || [];
  const recent = trades.slice(0, 18).reverse();
  const maxProfit = Math.max(...recent.map((trade) => trade.profitUsd), 0.01);
  $("profit-bars").innerHTML = recent.map((trade) => {
    const height = 12 + Math.sqrt(trade.profitUsd / maxProfit) * 52;
    return `<span class="profit-bar ${trade.controlled ? "controlled" : ""}" style="height:${height}px" data-label="${money(trade.profitUsd, 3)}"></span>`;
  }).join("");

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
  renderPnl(data.current);
  renderComposition(data.current);
  renderChart(data.history);
  renderActivity(data.activity);
  renderHealth(data.health);
  set("accounting-method", data.accounting.method);
  const flows = data.accounting.externalFlows;
  const flowNote = flows && flows.count
    ? ` Excluded external flow: ${flows.native >= 0 ? "+" : ""}${token(flows.native, 9)} ETH, ${flows.weth >= 0 ? "+" : ""}${token(flows.weth, 9)} WETH, ${flows.usdc >= 0 ? "+" : ""}${number(flows.usdc, 6)} USDC.`
    : " No external cash flows detected.";
  set("accounting-assumption", `${data.accounting.assumption} Reference: ${data.accounting.reference}.${flowNote}`);
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
