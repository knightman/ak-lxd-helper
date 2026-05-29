"use strict";

// ---------------------------------------------------------------------------
// Tiny helpers
// ---------------------------------------------------------------------------

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v;
    else if (k === "html") node.innerHTML = v;
    else if (k.startsWith("on") && typeof v === "function") node.addEventListener(k.slice(2), v);
    else if (v !== null && v !== undefined) node.setAttribute(k, v);
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined) continue;
    node.append(c.nodeType ? c : document.createTextNode(c));
  }
  return node;
}

let toastTimer;
function toast(msg, kind = "") {
  const t = $("#toast");
  t.textContent = msg;
  t.className = "show " + kind;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (t.className = ""), kind === "error" ? 6000 : 3000);
}

async function api(path, opts = {}) {
  const res = await fetch("/api" + path, {
    headers: { "Content-Type": "application/json" },
    ...opts,
  });
  let body;
  try { body = await res.json(); } catch { body = {}; }
  if (!res.ok || body.ok === false) {
    throw new Error(body.error || `HTTP ${res.status}`);
  }
  return body.data;
}

function fmtBytes(n) {
  if (!n && n !== 0) return "—";
  const u = ["B", "KiB", "MiB", "GiB", "TiB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(i ? 1 : 0)} ${u[i]}`;
}

function statusBadge(status) {
  const s = (status || "").toLowerCase();
  const cls = s === "running" ? "running" : s === "stopped" ? "stopped"
            : s === "frozen" ? "frozen" : "other";
  return el("span", { class: `badge ${cls}` }, status || "unknown");
}

// ---------------------------------------------------------------------------
// Overlay panel
// ---------------------------------------------------------------------------

function openPanel(node, wide = false) {
  const panel = $("#panel");
  panel.className = wide ? "wide" : "";
  panel.replaceChildren(node);
  $("#overlay").classList.remove("hidden");
}
function closePanel() {
  $("#overlay").classList.add("hidden");
  $("#panel").replaceChildren();
}
$("#overlay").addEventListener("mousedown", (e) => {
  if (e.target.id === "overlay") closePanel();
});

function panelHeader(title, ...extra) {
  return el("div", { class: "panel-head" },
    el("h2", {}, title),
    ...extra,
    el("button", { class: "close", onclick: closePanel }, "✕ Close"),
  );
}

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

$$("nav button").forEach((btn) => {
  btn.addEventListener("click", () => {
    $$("nav button").forEach((b) => b.classList.toggle("active", b === btn));
    const tab = btn.dataset.tab;
    $$(".tab").forEach((s) => s.classList.toggle("active", s.id === "tab-" + tab));
    if (tab === "dashboard") loadDashboard();
    if (tab === "instances") loadInstances();
    if (tab === "images") loadImages();
  });
});

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------

async function loadDashboard() {
  try {
    const info = await api("/server");
    const env = info.environment || {};
    $("#server-summary").textContent =
      `${env.server_name || "lxd"} · LXD ${env.server_version || "?"} · ${env.kernel_architecture || ""}`;

    const cards = $("#dashboard-cards");
    cards.replaceChildren();
    const add = (label, value) => cards.append(
      el("div", { class: "card" }, el("div", { class: "label" }, label), el("div", { class: "value" }, value)));

    add("Server", env.server_name || "—");
    add("LXD version", env.server_version || "—");
    add("Kernel", env.kernel_version || "—");
    add("Architecture", env.kernel_architecture || "—");

    try {
      const r = await api("/resources");
      if (r.cpu) add("CPU cores", String(r.cpu.total ?? (r.cpu.sockets || []).reduce((a, s) => a + (s.cores?.length || 0), 0)));
      if (r.memory) {
        add("Memory used", `${fmtBytes(r.memory.used)} / ${fmtBytes(r.memory.total)}`);
      }
      if (r.gpu && r.gpu.cards) add("GPUs", String(r.gpu.cards.length));
    } catch { /* resources optional */ }
  } catch (e) {
    $("#server-summary").textContent = "LXD unreachable";
    toast(e.message, "error");
  }

  try {
    const instances = await api("/instances");
    const box = $("#dashboard-instances");
    box.replaceChildren();
    if (!instances.length) { box.append(el("p", { class: "muted" }, "No instances yet.")); return; }
    const counts = instances.reduce((a, i) => (a[i.status] = (a[i.status] || 0) + 1, a), {});
    box.append(el("p", { class: "muted" },
      Object.entries(counts).map(([k, v]) => `${v} ${k.toLowerCase()}`).join(" · ")));
  } catch { /* handled above */ }
}

// ---------------------------------------------------------------------------
// Instances
// ---------------------------------------------------------------------------

async function loadInstances() {
  const tbody = $("#instances-table tbody");
  tbody.replaceChildren(el("tr", {}, el("td", { colspan: "6", class: "muted" }, "Loading…")));
  let instances;
  try {
    instances = await api("/instances");
  } catch (e) {
    tbody.replaceChildren(el("tr", {}, el("td", { colspan: "6", class: "muted" }, "Error: " + e.message)));
    return;
  }
  if (!instances.length) {
    tbody.replaceChildren(el("tr", {}, el("td", { colspan: "6", class: "muted" }, "No instances.")));
    return;
  }
  tbody.replaceChildren(...instances.map(renderInstanceRow));
}

function instanceIPv4(inst) {
  const addrs = inst.state?.network
    ? Object.values(inst.state.network).flatMap((n) => n.addresses || [])
    : [];
  const v4 = addrs.find((a) => a.family === "inet" && a.scope === "global");
  return v4 ? v4.address : "—";
}

function renderInstanceRow(inst) {
  const running = inst.status === "Running";
  const st = inst.state || {};
  const cpuMem = st.memory
    ? `${fmtBytes(st.memory.usage)}` : "—";

  const actions = el("div", { class: "actions" },
    el("button", { class: "sm", onclick: () => openInstance(inst.name) }, "Open"),
    running
      ? el("button", { class: "sm", onclick: () => instanceAction(inst.name, "stop") }, "Stop")
      : el("button", { class: "sm", onclick: () => instanceAction(inst.name, "start") }, "Start"),
    el("button", { class: "sm", onclick: () => instanceAction(inst.name, "restart"), disabled: !running || null }, "Restart"),
    el("button", { class: "sm danger", onclick: () => deleteInstance(inst.name) }, "Delete"),
  );

  return el("tr", {},
    el("td", {}, el("strong", {}, inst.name)),
    el("td", {}, inst.type === "virtual-machine" ? "VM" : "container"),
    el("td", {}, statusBadge(inst.status)),
    el("td", { class: "mono" }, instanceIPv4(inst)),
    el("td", { class: "mono" }, cpuMem),
    el("td", {}, actions),
  );
}

async function instanceAction(name, action) {
  try {
    toast(`${action}ing ${name}…`);
    await api(`/instances/${name}/state`, {
      method: "POST",
      body: JSON.stringify({ action, force: action === "stop" }),
    });
    toast(`${name}: ${action} done`, "success");
    loadInstances();
  } catch (e) {
    toast(e.message, "error");
  }
}

async function deleteInstance(name) {
  if (!confirm(`Delete instance "${name}"? This cannot be undone.`)) return;
  try {
    await api(`/instances/${name}`, { method: "DELETE" });
    toast(`Deleted ${name}`, "success");
    loadInstances();
  } catch (e) {
    toast(e.message, "error");
  }
}

// -- Instance detail panel --------------------------------------------------

async function openInstance(name) {
  let inst;
  try { inst = await api(`/instances/${name}`); }
  catch (e) { return toast(e.message, "error"); }

  const running = inst.status === "Running";
  const content = el("div", {});
  content.append(panelHeader(name, statusBadge(inst.status)));

  // subtabs
  const subtabs = el("div", { class: "subtabs" });
  const body = el("div", {});
  const tabs = {
    Overview: () => overviewTab(inst),
    Devices: () => devicesTab(inst),
    Config: () => configTab(inst),
    Run: () => runTab(name),
    Terminal: () => terminalTab(name, "exec"),
    Console: () => terminalTab(name, "console"),
  };
  Object.keys(tabs).forEach((label, i) => {
    const b = el("button", { class: i === 0 ? "active" : "", onclick: () => {
      $$("button", subtabs).forEach((x) => x.classList.toggle("active", x === b));
      body.replaceChildren(tabs[label]());
    } }, label);
    subtabs.append(b);
  });
  content.append(subtabs, body);
  body.append(tabs.Overview());
  openPanel(content, true);
}

function overviewTab(inst) {
  const st = inst.state || {};
  const rows = [
    ["Name", inst.name],
    ["Type", inst.type],
    ["Status", inst.status],
    ["Architecture", inst.architecture],
    ["Created", inst.created_at],
    ["Last used", inst.last_used_at],
    ["Profiles", (inst.profiles || []).join(", ")],
    ["Image", inst.config?.["image.description"] || "—"],
    ["PID", st.pid || "—"],
    ["Processes", st.processes || "—"],
    ["Memory", st.memory ? `${fmtBytes(st.memory.usage)} (peak ${fmtBytes(st.memory.usage_peak)})` : "—"],
  ];
  const kv = el("div", { class: "kv" });
  rows.forEach(([k, v]) => kv.append(el("div", { class: "k" }, k), el("div", { class: "mono" }, String(v ?? "—"))));

  const nets = st.network ? Object.entries(st.network) : [];
  const netList = el("div", {});
  if (nets.length) {
    netList.append(el("h2", {}, "Network"));
    nets.forEach(([iface, n]) => {
      (n.addresses || []).filter((a) => a.scope === "global").forEach((a) => {
        netList.append(el("div", { class: "mono" }, `${iface}: ${a.address}/${a.netmask} (${a.family})`));
      });
    });
  }
  return el("div", {}, kv, netList);
}

function dataTable(headers) {
  const tbody = el("tbody", {});
  const t = el("table", {}, el("thead", {}, el("tr", {}, ...headers.map((h) => el("th", {}, h)))), tbody);
  t._body = tbody;
  return t;
}
function addRow(t, cells) {
  t._body.append(el("tr", {}, ...cells.map((c) =>
    el("td", { class: "mono" }, c === null || c === undefined || c === "" ? "—" : String(c)))));
}

function devicesTab(inst) {
  const wrap = el("div", {});
  // expanded_devices includes devices inherited from profiles (root disk, eth0).
  const devices = inst.expanded_devices || inst.devices || {};
  const netState = (inst.state || {}).network || {};

  const disks = [], nics = [], others = [];
  for (const [n, d] of Object.entries(devices)) {
    (d.type === "disk" ? disks : d.type === "nic" ? nics : others).push([n, d]);
  }

  // Attached drives
  wrap.append(el("h2", {}, "Attached drives"));
  if (disks.length) {
    const t = dataTable(["Device", "Source", "Pool", "Path", "Size", "Read-only", "Boot prio"]);
    disks.forEach(([n, d]) => addRow(t, [n, d.source, d.pool, d.path, d.size || "(pool default)", d.readonly || "no", d["boot.priority"]]));
    wrap.append(t);
  } else wrap.append(el("p", { class: "muted" }, "No disk devices."));

  // Configured NICs
  wrap.append(el("h2", {}, "Network interfaces (configured)"));
  if (nics.length) {
    const t = dataTable(["Device", "Network / bridge", "Parent", "Type", "HW addr"]);
    nics.forEach(([n, d]) => addRow(t, [n, d.network, d.parent, d.nictype || (d.network ? "managed" : ""), d.hwaddr || "(auto)"]));
    wrap.append(t);
  } else wrap.append(el("p", { class: "muted" }, "No NIC devices."));

  // Live interfaces (from runtime state)
  const live = Object.entries(netState).filter(([k]) => k !== "lo");
  if (live.length) {
    wrap.append(el("h2", {}, "Live interfaces"));
    const t = dataTable(["Interface", "State", "MAC", "MTU", "Host veth", "Addresses"]);
    live.forEach(([iface, n]) => {
      const addrs = (n.addresses || []).filter((a) => a.scope !== "link")
        .map((a) => `${a.address}/${a.netmask}`).join(", ");
      addRow(t, [iface, n.state, n.hwaddr, n.mtu, n.host_name, addrs]);
    });
    wrap.append(t);
  }

  // Bridge / managed-network details (fetched async)
  const netNames = [...new Set(nics.map(([, d]) => d.network).filter(Boolean))];
  if (netNames.length) {
    const box = el("div", {});
    wrap.append(el("h2", {}, "Bridge / network details"), box);
    netNames.forEach(async (netName) => {
      try {
        const net = await api(`/networks/${encodeURIComponent(netName)}`);
        const c = net.config || {};
        const t = dataTable(["Network", "Type", "IPv4 (NAT)", "IPv6 (NAT)", "DNS domain", "Managed"]);
        addRow(t, [net.name, net.type,
          `${c["ipv4.address"] || "—"} (${c["ipv4.nat"] || "?"})`,
          `${c["ipv6.address"] || "—"} (${c["ipv6.nat"] || "?"})`,
          c["dns.domain"], String(net.managed)]);
        box.append(t);
      } catch (e) {
        box.append(el("p", { class: "muted" }, `${netName}: ${e.message}`));
      }
    });
  }

  // Other devices (gpu, proxy, etc.)
  if (others.length) {
    wrap.append(el("h2", {}, "Other devices"));
    const t = dataTable(["Device", "Type", "Properties"]);
    others.forEach(([n, d]) => {
      const props = Object.entries(d).filter(([k]) => k !== "type").map(([k, v]) => `${k}=${v}`).join("  ");
      addRow(t, [n, d.type, props]);
    });
    wrap.append(t);
  }

  return wrap;
}

function configTab(inst) {
  const wrap = el("div", {});
  wrap.append(el("p", { class: "muted" },
    "Edit instance config keys (e.g. limits.cpu, limits.memory) as JSON. Saved via PATCH (merge)."));
  const editable = {
    config: inst.config || {},
    description: inst.description || "",
    profiles: inst.profiles || [],
  };
  const ta = el("textarea", { rows: "16" }, JSON.stringify(editable, null, 2));
  ta.style.minHeight = "300px";
  const save = el("button", { class: "primary", onclick: async () => {
    let payload;
    try { payload = JSON.parse(ta.value); }
    catch (e) { return toast("Invalid JSON: " + e.message, "error"); }
    try {
      await api(`/instances/${inst.name}`, { method: "PATCH", body: JSON.stringify(payload) });
      toast("Config saved", "success");
    } catch (e) { toast(e.message, "error"); }
  } }, "Save config");
  wrap.append(ta, el("div", { style: "margin-top:12px" }, save));
  return wrap;
}

function runTab(name) {
  const wrap = el("div", {});
  wrap.append(el("p", { class: "muted" }, "Run a one-off command (non-interactive) and capture output."));
  const input = el("input", { placeholder: "e.g. uname -a", value: "uname -a" });
  const out = el("pre", { class: "output" }, "");
  const run = async () => {
    out.textContent = "running…";
    try {
      const r = await api(`/instances/${name}/exec`, {
        method: "POST", body: JSON.stringify({ command: input.value }),
      });
      out.textContent =
        (r.stdout || "") + (r.stderr ? "\n[stderr]\n" + r.stderr : "") + `\n[exit ${r.return}]`;
    } catch (e) { out.textContent = "Error: " + e.message; }
  };
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") run(); });
  wrap.append(
    el("div", { class: "row" }, input, el("button", { class: "primary", onclick: run, style: "flex:0 0 auto" }, "Run")),
    out,
  );
  return wrap;
}

// -- Interactive terminal (exec / console) ----------------------------------

function terminalTab(name, mode) {
  const wrap = el("div", {});
  const isExec = mode === "exec";
  wrap.append(el("p", { class: "muted" },
    isExec ? "Interactive shell inside the instance (must be running)."
           : "Serial console of the instance (boot/login prompt)."));

  let cmdInput;
  if (isExec) {
    cmdInput = el("input", { value: "/bin/bash", placeholder: "command, e.g. /bin/bash" });
  }
  const status = el("div", { class: "term-status" }, "disconnected");
  const termWrap = el("div", { class: "terminal-wrap" });
  const connectBtn = el("button", { class: "primary" }, "Connect");
  const disconnectBtn = el("button", { disabled: true }, "Disconnect");

  let term, fit, ws;

  function cleanup() {
    if (ws) { try { ws.close(); } catch {} ws = null; }
    connectBtn.disabled = false;
    disconnectBtn.disabled = true;
    status.textContent = "disconnected";
  }

  connectBtn.addEventListener("click", () => {
    if (ws) return;
    term = new window.Terminal({ cursorBlink: true, fontSize: 13, theme: { background: "#000000" } });
    fit = new window.FitAddon.FitAddon();
    term.loadAddon(fit);
    term.open(termWrap);
    fit.fit();
    term.focus();
    // Refocus when the user clicks anywhere in the terminal area.
    termWrap.addEventListener("mousedown", () => term && term.focus());

    const proto = location.protocol === "https:" ? "wss" : "ws";
    let url = `${proto}://${location.host}/ws/${mode}/${name}`;
    if (isExec) url += `?cmd=${encodeURIComponent(cmdInput.value || "/bin/bash")}`;
    ws = new WebSocket(url);
    ws.binaryType = "arraybuffer";
    status.textContent = "connecting…";

    ws.onopen = () => {
      status.textContent = "connected";
      connectBtn.disabled = true;
      disconnectBtn.disabled = false;
      const send = () => ws.readyState === 1 &&
        ws.send(JSON.stringify({ type: "resize", width: term.cols, height: term.rows }));
      send();
      // Keystrokes go to LXD as BINARY frames (the console data channel expects
      // raw bytes; text frames are dropped). Resize stays a JSON text frame.
      const enc = new TextEncoder();
      term.onData((d) => ws.readyState === 1 && ws.send(enc.encode(d)));
      term.onResize(send);
      term.focus();
      // A serial console doesn't repaint on attach. Nudge full-screen TUIs
      // (the installer, a login prompt) to redraw: resize-wiggle + Ctrl+L.
      setTimeout(() => {
        if (ws.readyState !== 1) return;
        ws.send(JSON.stringify({ type: "resize", width: term.cols + 1, height: term.rows }));
        ws.send(JSON.stringify({ type: "resize", width: term.cols, height: term.rows }));
        ws.send(enc.encode("\x0c"));
      }, 400);
    };
    ws.onmessage = (ev) => {
      if (ev.data instanceof ArrayBuffer) term.write(new Uint8Array(ev.data));
      else term.write(ev.data);
    };
    ws.onclose = () => { term.write("\r\n[disconnected]\r\n"); cleanup(); };
    ws.onerror = () => { status.textContent = "error"; };
  });

  disconnectBtn.addEventListener("click", cleanup);
  window.addEventListener("resize", () => fit && fit.fit());

  const redrawBtn = el("button", { onclick: () => {
    if (ws && ws.readyState === 1) {
      ws.send(JSON.stringify({ type: "resize", width: term.cols + 1, height: term.rows }));
      ws.send(JSON.stringify({ type: "resize", width: term.cols, height: term.rows }));
      ws.send(new TextEncoder().encode("\x0c"));
      term.focus();
    }
  } }, "Redraw");

  const controls = el("div", { class: "row", style: "align-items:flex-end" });
  if (isExec) controls.append(el("label", { class: "field", style: "flex:1" },
    el("span", {}, "Command"), cmdInput));
  const btns = el("div", { style: "flex:0 0 auto" }, connectBtn, " ", disconnectBtn);
  if (!isExec) btns.append(" ", redrawBtn);
  controls.append(btns);

  wrap.append(controls, status, termWrap);
  return wrap;
}

// -- Create instance --------------------------------------------------------

$("#btn-new-instance").addEventListener("click", openCreateInstance);
$("#btn-refresh-instances").addEventListener("click", loadInstances);

function openCreateInstance() {
  const f = {};
  const field = (key, label, node) => { f[key] = node; return el("label", { class: "field" }, el("span", {}, label), node); };

  const localImages = el("select", {});
  localImages.append(el("option", { value: "" }, "— pull from remote (below) —"));
  api("/images").then((imgs) => {
    imgs.forEach((im) => {
      const alias = (im.aliases || [])[0]?.name || im.fingerprint.slice(0, 12);
      localImages.append(el("option", { value: im.fingerprint }, `${alias} (${im.properties?.description || im.type})`));
    });
  }).catch(() => {});

  const content = el("div", {});
  content.append(panelHeader("New instance"));
  content.append(
    field("name", "Name", el("input", { placeholder: "my-vm" })),
    el("div", { class: "row" },
      field("type", "Type", (() => {
        const s = el("select", {});
        s.append(el("option", { value: "container" }, "Container"),
                 el("option", { value: "virtual-machine" }, "Virtual machine"));
        return s;
      })()),
      field("start", "Start after create", (() => {
        const s = el("select", {});
        s.append(el("option", { value: "true" }, "Yes"), el("option", { value: "false" }, "No"));
        return s;
      })()),
    ),
    field("local", "Local image", localImages),
    el("p", { class: "muted" }, "…or pull a remote image:"),
    el("div", { class: "row" },
      field("server", "Remote server", el("input", { value: "https://cloud-images.ubuntu.com/releases" })),
      field("protocol", "Protocol", (() => {
        const s = el("select", {});
        s.append(el("option", { value: "simplestreams" }, "simplestreams"),
                 el("option", { value: "lxd" }, "lxd"));
        return s;
      })()),
    ),
    field("alias", "Remote alias", el("input", { placeholder: "e.g. 24.04 or jammy" })),
    el("div", { class: "row" },
      field("cpu", "limits.cpu", el("input", { placeholder: "2" })),
      field("memory", "limits.memory", el("input", { placeholder: "4GiB" })),
    ),
  );

  const submit = el("button", { class: "primary", onclick: async () => {
    const name = f.name.value.trim();
    if (!name) return toast("Name is required", "error");
    const config = {};
    if (f.cpu.value.trim()) config["limits.cpu"] = f.cpu.value.trim();
    if (f.memory.value.trim()) config["limits.memory"] = f.memory.value.trim();
    const payload = {
      name,
      type: f.type.value,
      start: f.start.value === "true",
      config,
      image: f.local.value
        ? { fingerprint: f.local.value }
        : { server: f.server.value.trim(), protocol: f.protocol.value, alias: f.alias.value.trim() },
    };
    if (!payload.image.fingerprint && !payload.image.alias) return toast("Pick a local image or a remote alias", "error");
    submit.disabled = true;
    submit.textContent = "Creating… (may take a while)";
    try {
      await api("/instances", { method: "POST", body: JSON.stringify(payload) });
      toast(`Created ${name}`, "success");
      closePanel();
      loadInstances();
    } catch (e) {
      toast(e.message, "error");
      submit.disabled = false;
      submit.textContent = "Create instance";
    }
  } }, "Create instance");
  content.append(el("div", { style: "margin-top:12px" }, submit));
  openPanel(content);
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

$("#btn-refresh-images").addEventListener("click", loadImages);
$("#btn-import-image").addEventListener("click", openImportImage);

async function loadImages() {
  const tbody = $("#images-table tbody");
  tbody.replaceChildren(el("tr", {}, el("td", { colspan: "7", class: "muted" }, "Loading…")));
  let images;
  try { images = await api("/images"); }
  catch (e) { return tbody.replaceChildren(el("tr", {}, el("td", { colspan: "7", class: "muted" }, "Error: " + e.message))); }
  if (!images.length) return tbody.replaceChildren(el("tr", {}, el("td", { colspan: "7", class: "muted" }, "No images.")));

  tbody.replaceChildren(...images.map((im) => {
    const aliases = (im.aliases || []).map((a) => a.name).join(", ") || "—";
    const actions = el("div", { class: "actions" },
      el("button", { class: "sm", onclick: () => openAddAlias(im.fingerprint) }, "Add alias"),
      el("button", { class: "sm", onclick: () => openEditImage(im) }, "Edit"),
      el("button", { class: "sm danger", onclick: () => deleteImage(im.fingerprint) }, "Delete"),
    );
    return el("tr", {},
      el("td", {}, aliases),
      el("td", {}, im.properties?.description || "—"),
      el("td", {}, im.type === "virtual-machine" ? "VM" : "container"),
      el("td", {}, im.architecture || "—"),
      el("td", { class: "mono" }, fmtBytes(im.size)),
      el("td", { class: "mono" }, im.fingerprint.slice(0, 12)),
      el("td", {}, actions),
    );
  }));
}

async function deleteImage(fp) {
  if (!confirm(`Delete image ${fp.slice(0, 12)}…?`)) return;
  try { await api(`/images/${fp}`, { method: "DELETE" }); toast("Image deleted", "success"); loadImages(); }
  catch (e) { toast(e.message, "error"); }
}

function openAddAlias(fingerprint) {
  const nameI = el("input", { placeholder: "alias name" });
  const descI = el("input", { placeholder: "description (optional)" });
  const content = el("div", {}, panelHeader("Add image alias"),
    el("label", { class: "field" }, el("span", {}, "Alias"), nameI),
    el("label", { class: "field" }, el("span", {}, "Description"), descI),
    el("button", { class: "primary", onclick: async () => {
      if (!nameI.value.trim()) return toast("Alias name required", "error");
      try {
        await api("/images/aliases", { method: "POST", body: JSON.stringify({
          fingerprint, name: nameI.value.trim(), description: descI.value.trim() }) });
        toast("Alias added", "success"); closePanel(); loadImages();
      } catch (e) { toast(e.message, "error"); }
    } }, "Add alias"),
  );
  openPanel(content);
}

function openEditImage(im) {
  const ta = el("textarea", { rows: "12" },
    JSON.stringify({ properties: im.properties || {}, public: im.public || false }, null, 2));
  ta.style.minHeight = "240px";
  const content = el("div", {}, panelHeader("Edit image"),
    el("p", { class: "muted" }, `Fingerprint: ${im.fingerprint.slice(0, 24)}…`),
    ta,
    el("button", { class: "primary", style: "margin-top:12px", onclick: async () => {
      let payload;
      try { payload = JSON.parse(ta.value); } catch (e) { return toast("Invalid JSON", "error"); }
      try {
        await api(`/images/${im.fingerprint}`, { method: "PATCH", body: JSON.stringify(payload) });
        toast("Image updated", "success"); closePanel(); loadImages();
      } catch (e) { toast(e.message, "error"); }
    } }, "Save"),
  );
  openPanel(content);
}

function openImportImage() {
  const serverI = el("input", { value: "https://cloud-images.ubuntu.com/releases" });
  const aliasI = el("input", { placeholder: "e.g. 24.04" });
  const localI = el("input", { placeholder: "optional local alias, e.g. ubuntu-noble" });
  const protoS = el("select", {});
  protoS.append(el("option", { value: "simplestreams" }, "simplestreams"), el("option", { value: "lxd" }, "lxd"));
  const typeS = el("select", {});
  typeS.append(el("option", { value: "" }, "any"), el("option", { value: "container" }, "container"),
               el("option", { value: "virtual-machine" }, "virtual-machine"));

  const submit = el("button", { class: "primary" }, "Import image");
  const content = el("div", {}, panelHeader("Import image"),
    el("p", { class: "muted" }, "Pull an image from a remote simplestreams/lxd server into the local store."),
    el("label", { class: "field" }, el("span", {}, "Remote server"), serverI),
    el("div", { class: "row" },
      el("label", { class: "field" }, el("span", {}, "Protocol"), protoS),
      el("label", { class: "field" }, el("span", {}, "Image type"), typeS)),
    el("label", { class: "field" }, el("span", {}, "Remote alias"), aliasI),
    el("label", { class: "field" }, el("span", {}, "Local alias (optional)"), localI),
    el("div", { style: "margin-top:12px" }, submit),
  );
  submit.addEventListener("click", async () => {
    if (!aliasI.value.trim()) return toast("Remote alias required", "error");
    submit.disabled = true; submit.textContent = "Importing… (downloads in background)";
    try {
      await api("/images/import", { method: "POST", body: JSON.stringify({
        server: serverI.value.trim(), protocol: protoS.value, alias: aliasI.value.trim(),
        alias_local: localI.value.trim() || null, image_type: typeS.value || null }) });
      toast("Image imported", "success"); closePanel(); loadImages();
    } catch (e) { toast(e.message, "error"); submit.disabled = false; submit.textContent = "Import image"; }
  });
  openPanel(content);
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

document.addEventListener("keydown", (e) => { if (e.key === "Escape") closePanel(); });
loadDashboard();
