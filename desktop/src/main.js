import { invoke } from "@tauri-apps/api/core";

const $ = (s) => document.querySelector(s);
const $$ = (s) => Array.from(document.querySelectorAll(s));

const isWindows = navigator.userAgent.includes("Windows");

// 防重入锁：同一类状态查询同时只允许一个在跑（PowerShell 进程排队会让窗口假死）
const inflight = new Set();

// ==================== 日志 ====================

function stamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

// 日志面板：每个功能一页，按 pane 名路由到各自的 <pre>
const LOG_PANES = {
  adapters: "#log-adapters",
  cm: "#log-cm",
  steam: "#log-steam",
  p2p: "#log-p2p",
};

function log(pane, text, level = "") {
  const el = $(LOG_PANES[pane] || "#log-adapters");
  if (!el) return;
  const cls = level ? ` class="l-${level}"` : "";
  for (const line of String(text).split("\n")) {
    if (!line.trim()) continue;
    el.insertAdjacentHTML(
      "beforeend",
      `<span${cls}>[${stamp()}] ${escapeHtml(line)}</span>\n`
    );
  }
  el.scrollTop = el.scrollHeight;
}

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function status(msg) {
  $("#status-msg").textContent = msg;
}

function busy(btn, on) {
  if (!btn) return;
  btn.disabled = on;
  btn.classList.toggle("busy", on);
}

// ==================== Tab ====================

$$(".tab").forEach((tab) => {
  tab.addEventListener("click", () => {
    $$(".tab").forEach((t) => t.classList.toggle("active", t === tab));
    $$(".pane").forEach((p) => p.classList.toggle("active", p.id === `pane-${tab.dataset.tab}`));
  });
});

// ==================== 平台 ====================

async function loadPlatform() {
  try {
    const p = await invoke("platform_info");
    $("#platform-tag").textContent = `${p.os} / ${p.arch}`;
    if (!p.caddy_present) {
      log("steam", "提示：未找到 caddy 可执行文件，Steam 社区直连需要它。", "warn");
    }
  } catch (e) {
    log("adapters", `平台信息读取失败：${e}`, "err");
  }
}

// ==================== 链路 ====================

function renderLinks(links) {
  const tbody = $("#links-body");
  $("#link-count").textContent = links.length;

  if (!links.length) {
    tbody.innerHTML = `<tr class="empty-row"><td colspan="7">没有检测到满足条件的链路（需 Up 状态 + 有 IPv4 + 有默认网关）</td></tr>`;
    $("#link-hint").textContent = "点「重新检测」重试";
    return;
  }

  tbody.innerHTML = links
    .map(
      (l) => `
      <tr>
        <td>${l.index}</td>
        <td>${escapeHtml(l.name)}</td>
        <td>${escapeHtml(l.ip)}</td>
        <td>${escapeHtml(l.gateway)}</td>
        <td>${l.metric}</td>
        <td><span class="tag ${l.physical ? "phys" : "virt"}">${l.physical ? "物理" : "虚拟"}</span></td>
        <td>${escapeHtml(l.egress)}</td>
      </tr>`
    )
    .join("");

  $("#link-hint").textContent =
    links.length >= 2
      ? `${links.length} 条链路，可叠加带宽`
      : "只有 1 条链路：分流器能跑，但带宽不会叠加";
}

async function detectLinks(btn) {
  busy(btn, true);
  status("正在枚举链路…");
  try {
    const links = await invoke("list_links");
    renderLinks(links);
    log("adapters", `检测到 ${links.length} 条链路`, links.length ? "ok" : "warn");
    links.forEach((l) =>
      log("adapters", `  [${l.index}] ${l.name}  ${l.ip}  网关 ${l.gateway}  度量 ${l.metric}  ${l.physical ? "物理" : "虚拟"} | 出口 ${l.egress}`)
    );
    status("就绪");
  } catch (e) {
    log("adapters", `枚举失败：${e}`, "err");
    status("枚举失败");
  } finally {
    busy(btn, false);
  }
}

async function probeLinks(btn) {
  busy(btn, true);
  status("正在自检…");
  log("adapters", "--- 链路自检（下载 500KB / 条）---", "dim");
  try {
    const out = await invoke("probe_links");
    log("adapters", out);
    status("自检完成");
  } catch (e) {
    log("adapters", `自检失败：${e}`, "err");
    status("自检失败");
  } finally {
    busy(btn, false);
  }
}

// ==================== 分流器 ====================

function renderSplit(st) {
  const dot = $("#split-dot");
  dot.className = "dot " + (st.running ? "on" : "off");
  $("#split-state").textContent = st.running ? "运行中" : "未运行";
  $("#split-meta").textContent = st.pid
    ? `端口 ${st.port} · PID ${st.pid}`
    : `端口 ${st.port} · 模式 split`;
}

async function refreshSplit() {
  try {
    renderSplit(await invoke("split_status"));
  } catch (e) {
    log("adapters", `状态读取失败：${e}`, "err");
  }
}

async function startSplit(btn) {
  busy(btn, true);
  status("正在启动分流器…");
  try {
    const msg = await invoke("split_start", { port: 1080 });
    log("adapters", msg, "ok");
    renderSplit({ running: true, port: 1080 });
    status("分流器已启动");
  } catch (e) {
    log("adapters", `启动失败：${e}`, "err");
    status("启动失败");
  } finally {
    busy(btn, false);
  }
}

async function stopSplit(btn) {
  busy(btn, true);
  status("正在停止分流器…");
  try {
    const msg = await invoke("split_stop");
    log("adapters", msg, "ok");
    renderSplit({ running: false, port: 1080 });
    status("分流器已停止");
  } catch (e) {
    log("adapters", `停止失败：${e}`, "err");
    status("停止失败");
  } finally {
    busy(btn, false);
  }
}

// ==================== Steam ====================

function mark(id, ok, label) {
  const el = $(id);
  el.textContent = `${label}：${ok ? "就绪" : "未就绪"}`;
  el.parentElement.className = ok ? "ok" : "off";
}

function renderSteam(st) {
  mark("#st-caddy", st.caddy, "Caddy");
  mark("#st-hosts", st.hosts, "hosts");
  mark("#st-ca", st.ca, "根证书");
  mark("#st-port", st.port443, "443 端口");

  const dot = $("#steam-dot");
  if (st.enabled) {
    dot.className = "dot on";
    $("#steam-state").textContent = "已开启";
    $("#steam-meta").textContent = "社区门户已指向本机反代";
  } else if (st.caddy || st.hosts) {
    dot.className = "dot warn";
    $("#steam-state").textContent = "部分就绪";
    $("#steam-meta").textContent = "状态不一致，可再点一次「开启」修正";
  } else {
    dot.className = "dot off";
    $("#steam-state").textContent = "未开启";
    $("#steam-meta").textContent = "本机终结 TLS，再转发到 Valve 白名单域名";
  }
}

async function refreshSteam() {
  try {
    renderSteam(await invoke("steam_status"));
  } catch (e) {
    log("steam", `状态读取失败：${e}`, "err");
  }
}

async function steamAction(btn, cmd, arg, label) {
  busy(btn, true);
  status(`正在${label}…`);
  log("steam", `--- ${label} ---`, "dim");
  try {
    const out = await invoke(cmd, arg);
    if (out && out.trim()) log("steam", out);
    log("steam", `${label}完成`, "ok");
    status(`${label}完成`);
    await refreshSteam();
  } catch (e) {
    log("steam", `${label}失败：${e}`, "err");
    status(`${label}失败`);
  } finally {
    busy(btn, false);
  }
}

// ==================== CM 直连中继 ====================

function renderCm(c) {
  const dot = $("#cm-dot");
  if (c.enabled) {
    dot.className = "dot on";
    $("#cm-state").textContent = "中继运行中";
    $("#cm-meta").textContent = "CM 流量经本机分片中继直连，不经过代理";
  } else {
    dot.className = "dot off";
    $("#cm-state").textContent = "未开启";
    $("#cm-meta").textContent = "TLS ClientHello 分片，绕过按段匹配的 DPI";
  }
  $("#cm-listeners").textContent = `监听 ${c.listeners}`;
  $("#cm-dcs").textContent = `DC ${c.dcs}`;
  $("#cm-hosts").textContent = c.hosts ? "hosts 已写入" : "hosts 未写入";
  $("#cm-pid").textContent = c.pid ? `PID ${c.pid}` : "PID —";
}

async function refreshCm() {
  try {
    renderCm(await invoke("cm_status"));
  } catch (_) {
    /* 非 Windows 或尚未初始化，忽略 */
  }
}

async function cmAction(btn, cmd, label) {
  busy(btn, true);
  status(`正在${label}…`);
  log("cm", `--- ${label} ---`, "dim");
  try {
    const out = await invoke(cmd);
    if (out && out.trim()) log("cm", out);
    log("cm", `${label}完成`, "ok");
    status(`${label}完成`);
    await refreshCm();
  } catch (e) {
    log("cm", `${label}失败：${e}`, "err");
    status(`${label}失败`);
  } finally {
    busy(btn, false);
  }
}

// ==================== 日志 / 下载 ====================

async function pullLog(kind) {
  try {
    const text = await invoke("read_log", { kind, tail: 200 });
    if (!text) {
      log(kind === "split" ? "adapters" : "steam", "日志为空", "dim");
      return;
    }
    log(kind === "split" ? "adapters" : "steam", text);
  } catch (e) {
    log("adapters", `读日志失败：${e}`, "err");
  }
}

async function openLog(kind) {
  try {
    await invoke("open_path", { kind });
  } catch (e) {
    log("adapters", `打开失败：${e}`, "err");
  }
}

async function runDownload(btn) {
  const url = prompt(
    "多线程下载测试\n\n留空则用默认镜像（约 20MB）：",
    "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ls-lR.gz"
  );
  if (!url) return;
  const threads = Number($("#threads").value) || 16;
  const chunk = Number($("#chunk").value) || 4;
  busy(btn, true);
  status("正在下载…");
  log("adapters", `--- 下载 ${url}（${threads} 线程 / ${chunk} MB 分片）---`, "dim");
  try {
    const out = await invoke("download_test", { url, threads, chunkMb: chunk });
    log("adapters", out);
    status("下载完成");
  } catch (e) {
    log("adapters", `下载失败：${e}`, "err");
    status("下载失败");
  } finally {
    busy(btn, false);
  }
}

// ==================== P2P 直连 ====================

// p2p-ctl.ps1 的 status 输出是纯 KEY=VALUE 文本，在这里解析成对象
function parseKv(text) {
  const out = {};
  for (const line of String(text || "").split(/\r?\n/)) {
    const m = line.match(/^([A-Z][A-Z0-9_]*)=(.*)$/);
    if (m) out[m[1]] = m[2].trim();
  }
  return out;
}

const HOLE_TEXT = {
  idle: "未启用",
  waiting: "等待对端",
  punching: "正在打洞",
  connected: "已连通",
  error: "出错",
};
const RELAY_TEXT = {
  idle: "未启用",
  connecting: "连接中",
  connected: "已连接",
  closed: "已断开",
  error: "出错",
};
const TUNNEL_TEXT = {
  idle: "未启用",
  starting: "启动中",
  running: "已启动",
  connected: "已连通",
  stopped: "已停止",
  error: "出错",
};

// 三种状态 → 三种点：已连通=绿、进行中=黄闪、未启用=灰、出错=红
function dotFor(dot, state, live) {
  if (!dot) return;
  if (state === "error") dot.className = "dot err";
  else if (live.includes(state)) dot.className = "dot on";
  else if (state === "idle" || state === "closed" || state === "stopped" || !state)
    dot.className = "dot off";
  else dot.className = "dot busy";
}

function renderP2p(kv) {
  const nat = kv.HOLE_NAT || "";
  $("#p2p-nat").textContent = nat === "symmetric" ? "对称（symmetric）" : nat === "cone" ? "锥形（cone）" : "—";

  // A
  const hs = kv.HOLE_STATE || "idle";
  dotFor($("#hole-dot"), hs, ["connected"]);
  $("#hole-state").textContent = HOLE_TEXT[hs] || hs;
  const rtt = Number(kv.HOLE_RTT || 0);
  $("#hole-meta").textContent =
    `NAT ${nat || "—"} · 延迟 ${rtt ? rtt + " ms" : "—"} · 收 ${kv.HOLE_RX || 0} / 发 ${kv.HOLE_TX || 0}`;

  if (kv.HOLE_INVITE) {
    const detail = kv.HOLE_MAPPING ? `本机映射 ${kv.HOLE_MAPPING}` : "本机映射未知";
    $("#hole-invite").textContent = `邀请码 ${kv.HOLE_INVITE} · ${detail} · 端口 ${kv.HOLE_PORT || "—"}`;
  } else {
    $("#hole-invite").textContent =
      kv.HOLE_ERROR ? `邀请码 — · 错误：${kv.HOLE_ERROR}` : "邀请码 —";
  }

  // B
  const rs = kv.RELAY_STATE || "idle";
  dotFor($("#relay-dot"), rs, ["connected"]);
  $("#relay-state").textContent = RELAY_TEXT[rs] || rs;
  $("#relay-meta").textContent =
    `房间 ${kv.RELAY_ROOM || "—"} · 对端 ${kv.RELAY_PEERS || 0} · 收 ${kv.RELAY_RX || 0} / 发 ${kv.RELAY_TX || 0}`;

  // 账号状态：wrangler 装没装、有没有授权，直接决定 B 能不能用
  const cfLogin = kv.CF_LOGIN === "yes";
  const cfWrangler = kv.CF_WRANGLER === "yes";
  const acct = $("#relay-account");
  if (cfLogin) {
    acct.textContent = `账号 已连接 Cloudflare${kv.CF_WORKER ? ` · Worker ${kv.CF_WORKER}` : " · 还没部署 Worker"}`;
  } else {
    acct.textContent = `账号 未连接 · 点启动会自动打开浏览器授权${cfWrangler ? "" : "（本机还没有 wrangler，会先装）"}`;
  }
  // 一键部署成功后把地址回填到输入框，用户不用复制粘贴
  const workerInput = $("#relay-worker");
  if (kv.CF_WORKER && !workerInput.value) workerInput.value = kv.CF_WORKER;

  // C
  const ts = kv.TUNNEL_STATE || "idle";
  dotFor($("#tunnel-dot"), ts, ["running", "connected"]);
  $("#tunnel-state").textContent = TUNNEL_TEXT[ts] || ts;
  $("#tunnel-meta").textContent = kv.TUNNEL_PUBLIC
    ? `公网地址 ${kv.TUNNEL_PUBLIC}`
    : kv.TUNNEL_ERROR
    ? `公网地址 — · 错误：${kv.TUNNEL_ERROR}`
    : "公网地址 —";
  $("#tunnel-public").textContent = kv.TUNNEL_PUBLIC ? `公网地址 ${kv.TUNNEL_PUBLIC}` : "公网地址 —";
}

async function refreshP2p() {
  try {
    renderP2p(parseKv(await invoke("p2p_status")));
  } catch (e) {
    log("p2p", `状态读取失败：${e}`, "err");
  }
}

// 三通道的开关都走同一个命令，只是 action 不同。
// stateKey 用来看动作结束后通道是不是进了 error —— 否则按钮失败了界面还说「完成」。
async function p2pAction(btn, action, extra, label, stateKey) {
  busy(btn, true);
  status(`正在${label}…`);
  log("p2p", `--- ${label} ---`, "dim");
  try {
    const out = await invoke("p2p_run", { action, ...(extra || {}) });
    if (out && out.trim()) log("p2p", out);
    const kv = parseKv(await invoke("p2p_status"));
    renderP2p(kv);
    if (stateKey && kv[stateKey] === "error") {
      const err = kv[stateKey.replace("_STATE", "_ERROR")] || "未说明原因";
      log("p2p", `${label}失败：${err}`, "err");
      status(`${label}失败`);
    } else {
      log("p2p", `${label}完成`, "ok");
      status(`${label}完成`);
    }
  } catch (e) {
    log("p2p", `${label}失败：${e}`, "err");
    status(`${label}失败`);
    await refreshP2p();
  } finally {
    busy(btn, false);
  }
}

function holeArgs() {
  return {
    port: Number($("#hole-port").value) || 26999,
    peer: $("#hole-peer").value.trim(),
    spray: Number($("#hole-spray").value),
    localUdp: Number($("#hole-local-udp").value) || 0,
    peerUdp: Number($("#hole-peer-udp").value) || 0,
  };
}

// 诊断：问 STUN + 测中继可达性，约 10–20 秒
async function p2pProbe(btn) {
  busy(btn, true);
  status("正在做网络诊断…");
  log("p2p", "--- 网络诊断 ---", "dim");
  try {
    const out = await invoke("p2p_probe");
    log("p2p", out);
    status("诊断完成");
    await refreshP2p();
  } catch (e) {
    log("p2p", `诊断失败：${e}`, "err");
    status("诊断失败");
  } finally {
    busy(btn, false);
  }
}

async function copyInvite(btn) {
  busy(btn, true);
  try {
    const kv = parseKv(await invoke("p2p_status"));
    const inv = kv.HOLE_INVITE;
    if (!inv) {
      log("p2p", "还没有邀请码：先点「启动」，等 A 通道拿到本机映射。", "warn");
      status("暂无邀请码");
      return;
    }
    // 邀请码就是 base64("公网IP:端口|本地端口")，解出来给人看
    let decoded = "";
    try {
      decoded = atob(inv);
    } catch (_) {
      /* 解不开就只给原文 */
    }
    const text = decoded ? `${inv}（${decoded}）` : inv;
    try {
      await navigator.clipboard.writeText(inv);
      log("p2p", `邀请码已复制：${text}`, "ok");
      status("邀请码已复制");
    } catch (_) {
      log("p2p", `邀请码：${text}`, "dim");
      status("复制失败，已打印到日志");
    }
  } catch (e) {
    log("p2p", `读取邀请码失败：${e}`, "err");
  } finally {
    busy(btn, false);
  }
}

async function showWorkerCode(btn) {
  busy(btn, true);
  log("p2p", "--- B 通道部署说明 ---", "dim");
  try {
    const out = await invoke("p2p_worker");
    log("p2p", out);
    status("已打印部署说明");
  } catch (e) {
    log("p2p", `读取失败：${e}`, "err");
  } finally {
    busy(btn, false);
  }
}

async function listTunnels(btn) {
  busy(btn, true);
  status("正在检测本机隧道工具…");
  log("p2p", "--- 隧道工具检测 ---", "dim");
  try {
    const out = await invoke("p2p_tunnels");
    log("p2p", out);
    status("检测完成");
  } catch (e) {
    log("p2p", `检测失败：${e}`, "err");
    status("检测失败");
  } finally {
    busy(btn, false);
  }
}

// 手动触发 bore 的下载安装：不等用户点启动，也能先把工具备齐
async function installBore(btn) {
  busy(btn, true);
  status("正在安装 bore…");
  log("p2p", "--- 安装 bore ---", "dim");
  try {
    const out = await invoke("p2p_run", { action: "tunnel-install", provider: "bore" });
    if (out && out.trim()) log("p2p", out);
    log("p2p", "bore 安装完成", "ok");
    status("bore 安装完成");
    await listTunnelsSilent();
  } catch (e) {
    log("p2p", `安装 bore 失败：${e}`, "err");
    status("安装 bore 失败");
  } finally {
    busy(btn, false);
  }
}

async function listTunnelsSilent() {
  try {
    log("p2p", await invoke("p2p_tunnels"));
  } catch (_) {
    /* 静默 */
  }
}

// Cloudflare 登录 / 部署：都不是通道开关，动作完只要刷新状态即可
async function cfAction(btn, action, label) {
  busy(btn, true);
  status(`正在${label}…`);
  log("p2p", `--- ${label} ---`, "dim");
  try {
    const out = await invoke("p2p_run", { action });
    if (out && out.trim()) log("p2p", out);
    // 授权/部署都可能要等一会儿，刷新一次看新状态
    await refreshP2p();
    log("p2p", `${label}完成`, "ok");
    status(`${label}完成`);
  } catch (e) {
    log("p2p", `${label}失败：${e}`, "err");
    status(`${label}失败`);
    await refreshP2p();
  } finally {
    busy(btn, false);
  }
}

// ==================== 事件绑定 ====================

$("#btn-detect").addEventListener("click", (e) => detectLinks(e.currentTarget));
$("#btn-probe").addEventListener("click", (e) => probeLinks(e.currentTarget));
$("#btn-split-start").addEventListener("click", (e) => startSplit(e.currentTarget));
$("#btn-split-stop").addEventListener("click", (e) => stopSplit(e.currentTarget));
$("#btn-download").addEventListener("click", (e) => runDownload(e.currentTarget));

$("#btn-steam-enable").addEventListener("click", (e) =>
  steamAction(e.currentTarget, "steam_enable", undefined, "开启社区直连")
);
$("#btn-steam-disable").addEventListener("click", (e) =>
  steamAction(e.currentTarget, "steam_disable", undefined, "关闭社区直连")
);
$("#btn-steam-test").addEventListener("click", (e) =>
  steamAction(e.currentTarget, "steam_test", undefined, "自检")
);

$("#btn-cm-enable").addEventListener("click", (e) =>
  cmAction(e.currentTarget, "cm_enable", "开启 CM 直连")
);
$("#btn-cm-disable").addEventListener("click", (e) =>
  cmAction(e.currentTarget, "cm_disable", "关闭 CM 直连")
);
$("#btn-cm-test").addEventListener("click", (e) =>
  cmAction(e.currentTarget, "cm_test", "测速")
);
$("#btn-cm-log").addEventListener("click", () => openLog("cm"));
$("#btn-clear-cm-log").addEventListener("click", () => ($("#log-cm").textContent = ""));

$("#btn-steam-log").addEventListener("click", () => openLog("steam"));
$("#btn-clear-log").addEventListener("click", () => ($("#log-adapters").textContent = ""));
$("#btn-clear-steam-log").addEventListener("click", () => ($("#log-steam").textContent = ""));
$("#btn-clear-p2p-log").addEventListener("click", () => ($("#log-p2p").textContent = ""));

// ---------- P2P 直连 ----------
$("#btn-p2p-probe").addEventListener("click", (e) => p2pProbe(e.currentTarget));
$("#btn-p2p-refresh").addEventListener("click", (e) => {
  busy(e.currentTarget, true);
  once("p2p-manual", async () => {
    await refreshP2p();
    status("P2P 状态已刷新");
  }).finally(() => busy(e.currentTarget, false));
});
$("#btn-p2p-dir").addEventListener("click", () => openLog("dir"));

// A · UDP 打洞
$("#btn-hole-start").addEventListener("click", (e) =>
  p2pAction(e.currentTarget, "hole-start", holeArgs(), "启动 A 通道", "HOLE_STATE")
);
$("#btn-hole-stop").addEventListener("click", (e) =>
  p2pAction(e.currentTarget, "hole-stop", {}, "停止 A 通道", "HOLE_STATE")
);
$("#btn-hole-copy").addEventListener("click", (e) => copyInvite(e.currentTarget));

// B · Cloudflare 中继
$("#btn-relay-start").addEventListener("click", (e) => {
  const worker = $("#relay-worker").value.trim();
  // 没填 Worker 也放行：后端会先看账号——没连 Cloudflare 就自动把浏览器拉起来，
  // 已连则提示去点「一键部署」。在这里拦下来反而让用户不知道下一步该干什么。
  p2pAction(
    e.currentTarget,
    "relay-start",
    { worker, room: $("#relay-room").value.trim() },
    "启动 B 通道",
    "RELAY_STATE"
  );
});
$("#btn-relay-stop").addEventListener("click", (e) =>
  p2pAction(e.currentTarget, "relay-stop", {}, "停止 B 通道", "RELAY_STATE")
);
$("#btn-relay-worker").addEventListener("click", (e) => showWorkerCode(e.currentTarget));

// C · 免费 TCP 隧道
$("#btn-tunnel-start").addEventListener("click", (e) =>
  p2pAction(
    e.currentTarget,
    "tunnel-start",
    {
      provider: $("#tunnel-provider").value,
      localPort: Number($("#tunnel-local-port").value) || 25565,
    },
    "启动 C 通道",
    "TUNNEL_STATE"
  )
);
$("#btn-tunnel-stop").addEventListener("click", (e) =>
  p2pAction(e.currentTarget, "tunnel-stop", {}, "停止 C 通道", "TUNNEL_STATE")
);
$("#btn-tunnel-list").addEventListener("click", (e) => listTunnels(e.currentTarget));
$("#btn-tunnel-install").addEventListener("click", (e) => installBore(e.currentTarget));

// B · Cloudflare 账号
$("#btn-cf-login").addEventListener("click", (e) =>
  cfAction(e.currentTarget, "cf-login", "登录 Cloudflare")
);
$("#btn-cf-deploy").addEventListener("click", (e) =>
  cfAction(e.currentTarget, "cf-deploy", "部署 Worker")
);

$$("[data-open-log]").forEach((b) =>
  b.addEventListener("click", () => openLog(b.dataset.openLog))
);

$("#btn-refresh-all").addEventListener("click", async () => {
  await once("manual", async () => {
    await refreshSplit();
    await refreshCm();
    await refreshSteam();
    await refreshP2p();
  });
  status("状态已刷新");
});

// ==================== 防重入 ====================
// 状态查询要起 PowerShell 进程（0.3~2s）。若上一次还没回来就再发一次，
// 命令会排队堆积，界面表现为「未响应」。这里保证同一类查询同时只有一个在跑。

async function once(key, fn) {
  if (inflight.has(key)) return;
  inflight.add(key);
  try {
    await fn();
  } finally {
    inflight.delete(key);
  }
}

// ==================== 启动 ====================

(async function init() {
  log("adapters", `平台：${isWindows ? "Windows" : "macOS / Unix"}`, "dim");
  await loadPlatform();
  await detectLinks($("#btn-detect"));
  await refreshSplit();
  await refreshCm();
  await refreshSteam();
  await refreshP2p();
  status("就绪");

  // 状态轮询：间隔拉长 + 防重入，避免 PowerShell 进程排队把界面拖死
  setInterval(() => once("split", refreshSplit), 8000);
  setInterval(() => once("cm", refreshCm), 15000);
  setInterval(() => once("steam", refreshSteam), 15000);
  // P2P 三条通道的变化比别的快（打洞几秒内就可能连通），轮询密一点
  setInterval(() => once("p2p", refreshP2p), 4000);
})();
