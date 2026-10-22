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

  <form class="type" id="type">
    <input id="text" type="text" placeholder="Type on TV" autocomplete="off" autocorrect="off" autocapitalize="off" enterkeyhint="send">
    <button type="button" data-key="backspace" data-repeat aria-label="Delete"><svg viewBox="0 0 24 24"><path d="M9 5h11v14H9l-6-7z"/><path d="m12 9 5 6M17 9l-5 6"/></svg></button>
    <button class="send" type="submit" aria-label="Send"><svg viewBox="0 0 24 24"><path d="M5 12h14M13 6l6 6-6 6"/></svg></button>
  </form>
</main>
<script>
  const base = location.pathname.replace(/\/$/, "");
  const status = document.getElementById("status");
  function post(path, body) {
    fetch(base + path, { method: "POST", body, keepalive: true })
      .then(r => { status.textContent = r.ok ? "Connected" : "Error " + r.status; })
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

  document.getElementById("type").addEventListener("submit", e => {
    e.preventDefault();
    const input = document.getElementById("text");
    if (input.value) { post("/text", input.value); input.value = ""; }
  });
</script>
</body>
</html>
"""#
}
