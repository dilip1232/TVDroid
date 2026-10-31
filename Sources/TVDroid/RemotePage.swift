/// The phone remote web page. It has no external files, so it works without internet.
enum RemotePage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="TV Remote">
<meta name="theme-color" content="#0b0f1a">
<title>TVDroid Remote</title>
<style>
  :root { --bg:#0b0f1a; --key:#1c2236; --key-hi:#2a3250; --text:#e8ebf5; --dim:#8a93ad; --accent:#6d5cff; }
  * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; -webkit-user-select:none; user-select:none; }
  html,body { margin:0; height:100%; background:var(--bg); color:var(--text);
    font:16px -apple-system, system-ui, Roboto, sans-serif; touch-action:manipulation; }
  main { min-height:100%; display:flex; flex-direction:column; align-items:center; gap:22px;
    padding:calc(env(safe-area-inset-top) + 18px) 20px calc(env(safe-area-inset-bottom) + 18px); }
  header { width:100%; max-width:380px; display:flex; align-items:center; justify-content:space-between; }
  header b { font-size:18px; letter-spacing:.3px }
  #status { font-size:12px; color:var(--dim) }
  .row { width:100%; max-width:380px; display:flex; gap:14px; justify-content:space-between; }
  button { flex:1; height:58px; border:0; border-radius:18px; background:var(--key); color:var(--text);
    font-size:15px; font-weight:600; display:flex; align-items:center; justify-content:center; gap:6px;
    transition:transform .06s linear, background .06s linear; }
  button:active, button.on { background:var(--key-hi); transform:scale(.96); }
  svg { width:24px; height:24px; fill:none; stroke:currentColor; stroke-width:2.2; stroke-linecap:round; stroke-linejoin:round; }
  .pad { position:relative; width:min(300px, 78vw); aspect-ratio:1; border-radius:50%;
    background:radial-gradient(circle at 50% 40%, #232a42, #161b2c); box-shadow:0 10px 30px #0008, inset 0 1px 0 #ffffff14; }
  .pad button { position:absolute; width:34%; height:34%; border-radius:50%; background:transparent; }
  .pad button:active, .pad button.on { background:#ffffff12; }
  .pad .up { top:2%; left:33% } .pad .down { bottom:2%; left:33% }
  .pad .left { left:2%; top:33% } .pad .right { right:2%; top:33% }
  .pad .ok { top:30%; left:30%; width:40%; height:40%; background:linear-gradient(160deg,#7b6cff,#4a3fd6);
    box-shadow:0 6px 18px #4a3fd680; font-size:18px }
  .pad .ok:active, .pad .ok.on { background:linear-gradient(160deg,#6a5cf0,#3d33bb) }
  .type { width:100%; max-width:380px; display:flex; gap:10px; }
  .type input { flex:1; min-width:0; height:52px; border-radius:16px; border:1px solid #2a3250; background:#12172a;
    color:var(--text); padding:0 16px; font-size:16px; -webkit-user-select:text; user-select:text; outline:none; }
  .type input:focus { border-color:var(--accent) }
  .type button { flex:0 0 64px; height:52px; border-radius:16px }
  .type .send { background:var(--accent) }
  .tabs { width:100%; max-width:380px; display:flex; padding:4px; gap:4px; border-radius:16px; background:#12172a; }
  .tabs button { height:40px; border-radius:12px; background:transparent; color:var(--dim); font-size:14px; }
  .tabs button.sel { background:var(--key-hi); color:var(--text); }
  .tabs button:active { transform:none; }
  .panel { width:100%; display:flex; flex-direction:column; align-items:center; gap:22px; }
  .hidden { display:none !important; }
  .touch { width:100%; max-width:380px; display:flex; gap:10px; }
  #surface { position:relative; flex:1; height:min(56vh, 420px); border-radius:22px; touch-action:none;
    background:linear-gradient(160deg,#1a2035,#12172a); border:1px solid #2a3250;
    display:flex; align-items:center; justify-content:center; color:var(--dim); font-size:13px; text-align:center; line-height:1.6; }
  #surface.drag { border-color:var(--accent); }
  #wheel { flex:0 0 54px; height:min(56vh, 420px); border-radius:22px; touch-action:none; background:#12172a;
    border:1px solid #2a3250; display:flex; align-items:center; justify-content:center; color:var(--dim); }
  #wheel svg { width:20px; height:20px }
  .speed { width:100%; max-width:380px; display:flex; align-items:center; gap:12px; color:var(--dim); font-size:13px; }
  .speed input { flex:1; accent-color:var(--accent); }
</style>
</head>
<body>
<main>
  <header><b>TVDroid</b><span id="status">Connected</span></header>

  <div class="row">
    <button data-key="back"><svg viewBox="0 0 24 24"><path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/></svg>Back</button>
    <button data-key="home"><svg viewBox="0 0 24 24"><path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V20h14V9.5"/></svg>Home</button>
    <button data-key="search"><svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>Search</button>
  </div>

  <div class="tabs">
    <button type="button" data-tab="remote" class="sel">Remote</button>
    <button type="button" data-tab="trackpad">Trackpad</button>
  </div>

  <section class="panel" id="remote">
  <div class="pad">
    <button class="up" data-key="up" data-repeat><svg viewBox="0 0 24 24"><path d="m6 15 6-6 6 6"/></svg></button>
    <button class="left" data-key="left" data-repeat><svg viewBox="0 0 24 24"><path d="m15 6-6 6 6 6"/></svg></button>
    <button class="ok" data-key="ok">OK</button>
    <button class="right" data-key="right" data-repeat><svg viewBox="0 0 24 24"><path d="m9 6 6 6-6 6"/></svg></button>
    <button class="down" data-key="down" data-repeat><svg viewBox="0 0 24 24"><path d="m6 9 6 6 6-6"/></svg></button>
  </div>

  <div class="row">
    <button data-key="rewind" data-repeat><svg viewBox="0 0 24 24"><path d="M11 18 4 12l7-6z"/><path d="M20 18l-7-6 7-6z"/></svg></button>
    <button data-key="playpause"><svg viewBox="0 0 24 24"><path d="M5 5v14l8-7z"/><path d="M16 6v12M20 6v12"/></svg></button>
    <button data-key="forward" data-repeat><svg viewBox="0 0 24 24"><path d="M13 18l7-6-7-6z"/><path d="M4 18l7-6-7-6z"/></svg></button>
  </div>

  <div class="row">
    <button data-key="voldown" data-repeat><svg viewBox="0 0 24 24"><path d="M4 9v6h4l5 4V5L8 9z"/><path d="M17 12h4"/></svg></button>
    <button data-key="mute"><svg viewBox="0 0 24 24"><path d="M4 9v6h4l5 4V5L8 9z"/><path d="m17 9 4 6M21 9l-4 6"/></svg></button>
    <button data-key="volup" data-repeat><svg viewBox="0 0 24 24"><path d="M4 9v6h4l5 4V5L8 9z"/><path d="M17 12h4M19 10v4"/></svg></button>
  </div>
  </section>

  <section class="panel hidden" id="trackpad">
    <div class="touch">
      <div id="surface">Move: 1 finger · Click: tap<br>Scroll: 2 fingers · Back: 2-finger tap<br>Drag: hold, then move</div>
      <div id="wheel" aria-label="Scroll"><svg viewBox="0 0 24 24"><path d="m7 9 5-5 5 5M7 15l5 5 5-5"/></svg></div>
    </div>
    <div class="row">
      <button type="button" id="lclick">Click</button>
      <button type="button" id="rclick">Right click</button>
    </div>
    <label class="speed">Speed <input id="speed" type="range" min="1" max="5" step="0.5" value="2.5"></label>
  </section>

  <form class="type" id="type">
    <input id="text" type="text" placeholder="Type on TV" autocomplete="off" autocorrect="off" autocapitalize="off" enterkeyhint="send">
    <button type="button" data-key="backspace" data-repeat aria-label="Delete"><svg viewBox="0 0 24 24"><path d="M9 5h11v14H9l-6-7z"/><path d="m12 9 5 6M17 9l-5 6"/></svg></button>
    <button class="send" type="submit" aria-label="Send"><svg viewBox="0 0 24 24"><path d="M5 12h14M13 6l6 6-6 6"/></svg></button>
  </form>
</main>
<script>
  const base = location.pathname.replace(/\/$/, "");
  const status = document.getElementById("status");
  function show(r) { status.textContent = r.ok ? "Connected" : r.status === 409 ? "TV is off" : "Error " + r.status; }
  function post(path, body) {
    return fetch(base + path, { method: "POST", body, keepalive: true })
      .then(r => { show(r); return r; })
      .catch(() => { status.textContent = "Not connected"; });
  }
  function press(key) { post("/key/" + key); if (navigator.vibrate) navigator.vibrate(8); }

  document.querySelectorAll("[data-key]").forEach(btn => {
    let delay, timer;
    const stop = () => { clearTimeout(delay); clearInterval(timer); btn.classList.remove("on"); };
    btn.addEventListener("pointerdown", e => {
      e.preventDefault();
      btn.classList.add("on");
      press(btn.dataset.key);
      if (btn.hasAttribute("data-repeat")) {
        delay = setTimeout(() => { timer = setInterval(() => press(btn.dataset.key), 110); }, 380);
      }
    });
    ["pointerup", "pointerleave", "pointercancel"].forEach(ev => btn.addEventListener(ev, stop));
    btn.addEventListener("contextmenu", e => e.preventDefault());
  });

  // ── Tabs ──
  function showTab(name) {
    document.querySelectorAll("[data-tab]").forEach(b => b.classList.toggle("sel", b.dataset.tab === name));
    document.getElementById("remote").classList.toggle("hidden", name !== "remote");
    document.getElementById("trackpad").classList.toggle("hidden", name !== "trackpad");
    try { localStorage.setItem("tab", name); } catch (e) {}
  }
  document.querySelectorAll("[data-tab]").forEach(b => b.addEventListener("click", () => showTab(b.dataset.tab)));
  try { if (localStorage.getItem("tab") === "trackpad") showTab("trackpad"); } catch (e) {}

  // ── Trackpad: sends mouse events. Moves and scrolls are added up and sent one request at a time. ──
  const mouse = { dx: 0, dy: 0, sv: 0, sh: 0, cmds: [], busy: false };
  function flushMouse() {
    if (mouse.busy) return;
    const lines = [];
    const mx = Math.trunc(mouse.dx), my = Math.trunc(mouse.dy);
    if (mx || my) { lines.push("m " + mx + " " + my); mouse.dx -= mx; mouse.dy -= my; }
    if (mouse.sv || mouse.sh) { lines.push("s " + mouse.sv + " " + mouse.sh); mouse.sv = 0; mouse.sh = 0; }
    lines.push(...mouse.cmds); mouse.cmds = [];
    if (!lines.length) return;
    mouse.busy = true;
    fetch(base + "/mouse", { method: "POST", body: lines.join("\n") })
      .then(show)
      .catch(() => { status.textContent = "Not connected"; })
      .finally(() => { mouse.busy = false; setTimeout(flushMouse, 12); });
  }
  function mouseCmd(cmd) { mouse.cmds.push(cmd); flushMouse(); }

  const surface = document.getElementById("surface");
  const speedInput = document.getElementById("speed");
  try { const s = localStorage.getItem("speed"); if (s) speedInput.value = s; } catch (e) {}
  speedInput.addEventListener("change", () => { try { localStorage.setItem("speed", speedInput.value); } catch (e) {} });

  const SCROLL_STEP = 22;   // finger pixels for one wheel step
  let touch = null;          // state of the current gesture
  function center(list) {
    let x = 0, y = 0;
    for (const t of list) { x += t.clientX; y += t.clientY; }
    return { x: x / list.length, y: y / list.length };
  }
  surface.addEventListener("touchstart", e => {
    e.preventDefault();
    const c = center(e.touches);
    if (!touch) {
      touch = { start: performance.now(), x: c.x, y: c.y, moved: 0, fingers: e.touches.length, maxFingers: e.touches.length,
                accV: 0, accH: 0, dragging: false, holdTimer: null };
      touch.holdTimer = setTimeout(() => {
        if (touch && touch.maxFingers === 1 && touch.moved < 8) {
          touch.dragging = true; surface.classList.add("drag"); mouseCmd("d left");
          if (navigator.vibrate) navigator.vibrate(15);
        }
      }, 380);
    } else {
      touch.x = c.x; touch.y = c.y;
      touch.fingers = e.touches.length;
      touch.maxFingers = Math.max(touch.maxFingers, e.touches.length);
    }
  }, { passive: false });
  surface.addEventListener("touchmove", e => {
    e.preventDefault();
    if (!touch) return;
    const c = center(e.touches);
    if (e.touches.length !== touch.fingers) { touch.fingers = e.touches.length; touch.x = c.x; touch.y = c.y; return; }
    const dx = c.x - touch.x, dy = c.y - touch.y;
    touch.x = c.x; touch.y = c.y;
    touch.moved += Math.abs(dx) + Math.abs(dy);
    if (e.touches.length >= 2) {
      // Natural scrolling: content follows the fingers.
      touch.accV += dy; touch.accH -= dx;
      const v = Math.trunc(touch.accV / SCROLL_STEP), h = Math.trunc(touch.accH / SCROLL_STEP);
      if (v || h) { mouse.sv += v; mouse.sh += h; touch.accV -= v * SCROLL_STEP; touch.accH -= h * SCROLL_STEP; flushMouse(); }
    } else {
      // Pointer acceleration: fast moves go further.
      const speed = parseFloat(speedInput.value);
      const accel = 1 + Math.min(Math.hypot(dx, dy) / 12, 2);
      mouse.dx += dx * speed * accel; mouse.dy += dy * speed * accel;
      flushMouse();
    }
  }, { passive: false });
  function endTouch(e) {
    e.preventDefault();
    if (!touch || e.touches.length > 0) { if (touch) touch.fingers = e.touches.length; return; }
    clearTimeout(touch.holdTimer);
    const quick = performance.now() - touch.start < 250 && touch.moved < 10;
    if (touch.dragging) { mouseCmd("u left"); surface.classList.remove("drag"); }
    else if (quick && touch.maxFingers >= 2) { mouseCmd("c right"); }
    else if (quick) { mouseCmd("c left"); if (navigator.vibrate) navigator.vibrate(6); }
    touch = null;
  }
  surface.addEventListener("touchend", endTouch, { passive: false });
  surface.addEventListener("touchcancel", endTouch, { passive: false });

  // Scroll strip: one finger up and down scrolls.
  const wheel = document.getElementById("wheel");
  let wheelY = null, wheelAcc = 0;
  wheel.addEventListener("touchstart", e => { e.preventDefault(); wheelY = e.touches[0].clientY; wheelAcc = 0; }, { passive: false });
  wheel.addEventListener("touchmove", e => {
    e.preventDefault();
    if (wheelY === null) return;
    const y = e.touches[0].clientY;
    wheelAcc += y - wheelY; wheelY = y;
    const v = Math.trunc(wheelAcc / SCROLL_STEP);
    if (v) { mouse.sv += v; wheelAcc -= v * SCROLL_STEP; flushMouse(); }
  }, { passive: false });
  wheel.addEventListener("touchend", () => { wheelY = null; });

  // Mouse on a computer browser: drag on the surface to move, wheel to scroll.
  surface.addEventListener("pointermove", e => {
    if (e.pointerType !== "mouse" || !e.buttons) return;
    mouse.dx += e.movementX * 1.5; mouse.dy += e.movementY * 1.5; flushMouse();
  });
  surface.addEventListener("wheel", e => {
    e.preventDefault();
    mouse.sv += -Math.sign(e.deltaY) * Math.max(1, Math.round(Math.abs(e.deltaY) / 60));
    flushMouse();
  }, { passive: false });

  document.getElementById("lclick").addEventListener("click", () => mouseCmd("c left"));
  document.getElementById("rclick").addEventListener("click", () => mouseCmd("c right"));

  // ── Connection check: shows when the Mac or the TV app is not reachable, and recovers by itself. ──
  function ping() {
    fetch(base + "/ping", { cache: "no-store" })
      .then(show)
      .catch(() => { status.textContent = "Not connected"; });
  }
  setInterval(() => { if (!document.hidden) ping(); }, 5000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) ping(); });

  document.getElementById("type").addEventListener("submit", e => {
    e.preventDefault();
    const input = document.getElementById("text");
    if (!input.value) return;
    post("/text", input.value).then(r => {
      if (r && r.status === 200) r.text().then(t => { if (t) status.textContent = "Cannot type: " + t; });
    });
    input.value = "";
  });
</script>
</body>
</html>
"""#
}
