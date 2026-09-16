/* Interaction prototype. No microphone, screen capture, or filesystem access. */
(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const icon = (name, cls = "") => '<svg class="icon ' + cls + '" aria-hidden="true"><use href="#i-' + name + '"/></svg>';
  const escape = (value) => String(value).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const pad = (n) => String(Math.floor(n)).padStart(2, "0");
  const shortTime = (s) => pad(s / 60) + ":" + pad(s % 60);
  const fullTime = (s) => pad(s / 3600) + ":" + pad((s % 3600) / 60) + ":" + pad(s % 60);
  const load = (key, fallback) => { try { return JSON.parse(localStorage.getItem(key)) || fallback; } catch { return fallback; } };
  const persist = (key, value) => { try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* Private/file preview may disable persistence. */ } };
  const initialSettings = { audioPath: "~/Movies/Scriber/录音", videoPath: "~/Movies/Scriber/录屏" };
  const settings = Object.assign({}, initialSettings, load("scriber-prototype-settings-v1", {}));
  const seeds = [
    { id: "sample-1", name: "产品方案讨论", mode: "video", seconds: 1938, date: "今天 15:00", path: initialSettings.videoPath, size: "126.4 MB", audioSize: "15.8 MB" },
    { id: "sample-2", name: "周三随手记", mode: "audio", seconds: 548, date: "今天 10:24", path: initialSettings.audioPath, size: "4.6 MB" },
    { id: "sample-3", name: "界面走查", mode: "video", seconds: 766, date: "昨天 17:32", path: initialSettings.videoPath, size: "48.2 MB", audioSize: "6.3 MB" }
  ];
  let history = load("scriber-prototype-history-v1", seeds);
  if (!Array.isArray(history)) history = seeds;
  const state = {
    mode: "audio", view: "recorder", opened: true, recording: false, saved: false,
    name: "产品例会", system: true, mic: true, startedAt: 0, baseSeconds: 0,
    activePath: "", captureType: "region", targetSize: "", selecting: false,
    selection: null, detailId: null, playing: false, playSeconds: 0
  };
  let toastTimer, dragging = null, pulse = 0;
  const meterBars = {};
  ["system", "mic"].forEach((kind) => {
    $(kind + "-meter").innerHTML = "<i></i>".repeat(27);
    meterBars[kind] = [...$(kind + "-meter").children];
  });
  const seconds = () => state.baseSeconds + (state.recording ? Math.floor((Date.now() - state.startedAt) / 1000) : 0);
  const sourceCount = () => Number(state.system) + Number(state.mic);
  const targetName = () => ({ region: "自选区域", window: "单个窗口", display: "整块屏幕" })[state.captureType];
  const targetIcon = () => ({ region: "region", window: "window", display: "screen" })[state.captureType];
  const currentPath = () => state.recording ? state.activePath : settings[state.mode + "Path"];
  const showToast = (message) => {
    clearTimeout(toastTimer);
    $("toast-text").textContent = message;
    $("toast").hidden = false;
    toastTimer = setTimeout(() => { $("toast").hidden = true; }, 2700);
  };
  function setOpened(value) {
    state.opened = value;
    $("popover").hidden = !value;
    $("menu-trigger").setAttribute("aria-expanded", String(value));
  }
  function showView(view) {
    state.view = view;
    if (view !== "detail") state.playing = false;
    ["recorder", "settings", "history", "detail"].forEach((name) => { $(name + "-view").hidden = name !== view; });
    if (view === "settings") {
      $("audio-path").value = settings.audioPath;
      $("video-path").value = settings.videoPath;
      $("path-recording-note").hidden = !state.recording;
    }
    if (view === "history") renderHistory();
    $("toast").hidden = true;
    setOpened(true);
  }
  function renderTimer() {
    const time = fullTime(seconds());
    $("timer").innerHTML = time.slice(0, 5) + "<span>" + time.slice(5) + "</span>";
    $("menu-time").textContent = state.recording ? shortTime(seconds()) : "";
    $("menu-rec-dot").hidden = !state.recording;
    alignPopover();
  }
  function alignPopover() {
    const trigger = $("menu-trigger").getBoundingClientRect();
    const width = Math.min(390, window.innerWidth - 24);
    const center = trigger.left + trigger.width / 2;
    const right = Math.max(12, Math.min(window.innerWidth - width - 12, window.innerWidth - center - 28));
    $("popover").style.right = right + "px";
    $("popover").style.setProperty("--arrow-right", Math.max(16, Math.min(width - 30, window.innerWidth - right - center - 7)) + "px");
  }
  function render() {
    document.querySelectorAll(".mode-tab").forEach((tab) => {
      const active = tab.dataset.mode === state.mode;
      tab.classList.toggle("active", active);
      tab.setAttribute("aria-selected", String(active));
      tab.disabled = state.recording;
    });
    $("capture-target").hidden = state.mode !== "video";
    $("capture-type").value = state.captureType;
    $("capture-type").disabled = state.recording;
    $("target-label").textContent = targetName();
    $("target-icon").setAttribute("href", "#i-" + targetIcon());
    $("target-dimensions").textContent = state.recording ? state.targetSize : "开始前选择";
    $("recording-status").className = "recording-status" + (state.recording ? " recording" : state.saved ? " saved" : "");
    $("status-text").textContent = state.recording ? (state.mode === "audio" ? "正在录音" : "正在录屏") : state.saved ? "已保存到本地" : (state.mode === "audio" ? "准备录音" : "准备录屏");
    $("record-button").classList.toggle("is-recording", state.recording);
    $("record-button").disabled = !state.recording && sourceCount() === 0;
    $("record-button-label").textContent = state.recording ? "停止并保存" : state.mode === "audio" ? (state.saved ? "再次录音" : "开始录音") : "选择范围并录屏";
    $("output-note").textContent = !sourceCount() && !state.recording ? "请至少开启一个声音来源" : state.mode === "audio" ? "保存为 M4A 音频" : "同时保存 MP4 视频和 M4A 音频";
    $("output-note").classList.toggle("warning", !sourceCount() && !state.recording);
    $("source-count").textContent = sourceCount() + " 路已开启";
    ["system", "mic"].forEach((kind) => {
      $(kind + "-toggle").classList.toggle("on", state[kind]);
      $(kind + "-toggle").setAttribute("aria-checked", String(state[kind]));
      $(kind + "-row").classList.toggle("off", !state[kind]);
      $(kind + "-status").textContent = state[kind] ? "已检测到声音" : "已关闭";
    });
    $("destination-path").textContent = currentPath().replace(/^~\//, "").replace(/\//g, " / ");
    $("destination-button").title = currentPath();
    if (document.activeElement !== $("filename")) $("filename").value = state.name;
    renderTimer();
    renderRecent();
  }
  function validateName(value) {
    if (!value.trim()) return "请输入文件名";
    if (/[\/:\u0000-\u001f]/.test(value)) return "文件名不能包含 / 或 :";
    return "";
  }
  function commitName() {
    const value = $("filename").value.trim();
    const error = validateName(value);
    $("filename-error").textContent = error;
    $("filename-error").hidden = !error;
    if (error) return false;
    state.name = value;
    return true;
  }
  $("filename").addEventListener("input", () => {
    const value = $("filename").value.trim();
    if (!validateName(value)) { state.name = value; $("filename-error").hidden = true; }
  });
  $("filename").addEventListener("blur", commitName);
  $("filename").addEventListener("keydown", (event) => { if (event.key === "Enter" && commitName()) $("filename").blur(); });
  document.querySelectorAll(".mode-tab").forEach((button) => button.addEventListener("click", () => {
    if (state.recording) return;
    state.mode = button.dataset.mode; state.saved = false; state.baseSeconds = 0;
    render();
  }));
  ["system", "mic"].forEach((kind) => $(kind + "-toggle").addEventListener("click", () => {
    if (state.recording && sourceCount() === 1 && state[kind]) {
      showToast("录制中请保留至少一个声音来源");
      return;
    }
    state[kind] = !state[kind];
    render(); updateMeters();
  }));
  function startRecording(baseSeconds = 0) {
    state.recording = true; state.saved = false; state.baseSeconds = baseSeconds;
    state.startedAt = Date.now(); state.activePath = settings[state.mode + "Path"];
    state.selecting = false; $("selection-overlay").hidden = true;
    showView("recorder"); render(); updateSceneButtons(state.mode);
  }
  function stopRecording() {
    const elapsed = seconds();
    if (!commitName()) { $("filename").value = state.name; $("filename-error").hidden = true; }
    const now = new Date();
    history.unshift({
      id: "record-" + Date.now(), name: state.name, mode: state.mode, seconds: elapsed,
      date: "今天 " + pad(now.getHours()) + ":" + pad(now.getMinutes()), path: state.activePath,
      size: state.mode === "video" ? "18.6 MB" : "2.4 MB", audioSize: "2.4 MB"
    });
    history = history.slice(0, 30); persist("scriber-prototype-history-v1", history);
    state.recording = false; state.saved = true; state.baseSeconds = elapsed;
    render(); updateSceneButtons("saved");
    showToast(state.mode === "video" ? "视频和音频已保存" : "音频已保存");
  }
  $("record-button").addEventListener("click", () => {
    if (state.recording) return stopRecording();
    if (!commitName() || !sourceCount()) return;
    if (state.mode === "video") enterSelection();
    else startRecording();
  });
  $("capture-type").addEventListener("change", (event) => { state.captureType = event.target.value; render(); });
  $("menu-trigger").addEventListener("click", () => {
    if (state.selecting) cancelSelection();
    else setOpened(!state.opened);
  });
  $("settings-button").addEventListener("click", () => showView("settings"));
  $("destination-button").addEventListener("click", () => showView("settings"));
  $("history-button").addEventListener("click", () => { $("history-search").value = ""; showView("history"); });
  $("all-history").addEventListener("click", () => { $("history-search").value = ""; showView("history"); });
  document.querySelectorAll(".back-button").forEach((button) => button.addEventListener("click", () => { showView("recorder"); render(); }));
  $("settings-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const audio = $("audio-path").value.trim(), video = $("video-path").value.trim();
    if (!audio || !video || !/^(\/|~\/)/.test(audio) || !/^(\/|~\/)/.test(video)) {
      showToast("请输入以 / 或 ~/ 开头的文件夹路径"); return;
    }
    settings.audioPath = audio.replace(/\/+$/, "") || "/";
    settings.videoPath = video.replace(/\/+$/, "") || "/";
    persist("scriber-prototype-settings-v1", settings);
    showView("recorder"); render();
    showToast(state.recording ? "保存位置已更新，下次录制生效" : "保存位置已更新");
  });
  function recordMarkup(record) {
    return '<button class="record-item" data-record-id="' + escape(record.id) + '" aria-label="查看 ' + escape(record.name) + '">' +
      '<span class="record-item-icon ' + record.mode + '">' + icon(record.mode === "video" ? "screen" : "mark") + '</span>' +
      '<span class="record-item-text"><span class="record-item-title">' + escape(record.name) + '</span><span class="record-item-meta">' +
      escape(record.date) + ' · ' + (record.mode === "video" ? "视频 + 音频" : "音频") + '</span></span>' +
      '<span class="record-item-duration">' + shortTime(record.seconds) + '</span>' + icon("chevron", "record-item-arrow") + '</button>';
  }
  function attachRecordButtons(container) {
    container.querySelectorAll("[data-record-id]").forEach((button) => button.addEventListener("click", () => showDetail(button.dataset.recordId)));
  }
  function renderRecent() {
    $("recent-list").innerHTML = history.slice(0, 1).map(recordMarkup).join("");
    attachRecordButtons($("recent-list"));
  }
  function renderHistory() {
    const search = $("history-search").value.toLowerCase().trim();
    const entries = history.filter((record) => record.name.toLowerCase().includes(search));
    $("history-count").textContent = history.length + " 条";
    $("history-list").innerHTML = entries.length ? entries.map(recordMarkup).join("") : '<p class="empty-history">没有找到匹配的录制</p>';
    attachRecordButtons($("history-list"));
  }
  $("history-search").addEventListener("input", renderHistory);
  const detailRecord = () => history.find((record) => record.id === state.detailId);
  function showDetail(id) {
    state.detailId = id; state.playing = false; state.playSeconds = 0;
    showView("detail"); renderDetail();
  }
  function renderDetail() {
    const record = detailRecord(); if (!record) return;
    $("detail-name").value = record.name;
    $("detail-meta").textContent = record.date + " · " + shortTime(record.seconds) + " · " + (record.mode === "video" ? "2 个文件" : "1 个文件");
    $("player-mode-icon").innerHTML = '<use href="#i-' + (record.mode === "video" ? "screen" : "mark") + '"/>';
    $("player-label").textContent = record.mode === "video" ? "视频预览" : "音频预览";
    $("player-duration").textContent = shortTime(record.seconds);
    const formats = record.mode === "video" ? ["mp4", "m4a"] : ["m4a"];
    $("detail-files").innerHTML = formats.map((ext) =>
      '<div class="detail-file">' + icon(ext === "mp4" ? "screen" : "mic") +
      '<span>' + escape(record.name) + '.' + ext + '<small>' + (ext === "mp4" ? "含电脑声音与麦克风 · " + record.size : "独立音频 · " + (record.audioSize || record.size)) + '</small></span>' +
      '<button class="icon-button" data-reveal-ext="' + ext + '" aria-label="查看 ' + ext + ' 文件位置" title="查看文件位置">' + icon("folder") + '</button></div>'
    ).join("");
    $("detail-files").querySelectorAll("[data-reveal-ext]").forEach((button) => button.addEventListener("click", () => {
      const old = $("detail-files").querySelector(".file-path-note"); if (old) old.remove();
      const path = document.createElement("div"); path.className = "file-path-note";
      path.textContent = record.path + "/" + record.name + "." + button.dataset.revealExt;
      $("detail-files").appendChild(path);
    }));
    renderPlayer();
  }
  function renderPlayer() {
    const record = detailRecord(); if (!record) return;
    $("player-time").textContent = shortTime(state.playSeconds);
    $("player-progress").value = record.seconds ? state.playSeconds / record.seconds * 100 : 0;
    $("player-play-icon").setAttribute("href", state.playing ? "#i-pause" : "#i-play");
    $("player-play").setAttribute("aria-label", state.playing ? "暂停演示" : "播放演示");
    $("demo-player").classList.toggle("is-playing", state.playing);
  }
  $("detail-name").addEventListener("change", () => {
    const record = detailRecord(), name = $("detail-name").value.trim();
    if (validateName(name)) { $("detail-name").value = record.name; showToast(validateName(name)); return; }
    record.name = name; persist("scriber-prototype-history-v1", history);
    renderDetail(); renderRecent(); showToast(record.mode === "video" ? "视频和音频名称已一起更新" : "名称已更新");
  });
  $("detail-name").addEventListener("keydown", (event) => { if (event.key === "Enter") $("detail-name").blur(); });
  $("detail-back").addEventListener("click", () => showView("history"));
  $("player-play").addEventListener("click", () => {
    const record = detailRecord();
    if (state.playSeconds >= record.seconds) state.playSeconds = 0;
    state.playing = !state.playing; renderPlayer();
  });
  $("player-progress").addEventListener("input", (event) => {
    const record = detailRecord(); state.playSeconds = Math.round(Number(event.target.value) / 100 * record.seconds); renderPlayer();
  });
  function updateMeters() {
    pulse += 0.24;
    ["system", "mic"].forEach((kind, index) => {
      const wave = Math.sin(pulse * (index ? 1.37 : .81) + index * 2);
      const level = state[kind] ? Math.round(13 + wave * (index ? 8 : 5)) : 0;
      meterBars[kind].forEach((bar, i) => {
        bar.classList.toggle("lit", i < level);
        bar.classList.toggle("strong", i < Math.max(0, level - 5));
      });
      $(kind + "-db").textContent = state[kind] ? "−" + Math.round(44 - level * 1.3) + " dB" : "—";
    });
  }
  function enterSelection() {
    state.selecting = true; state.selection = null;
    setOpened(false); $("selection-overlay").hidden = false;
    setSelectionType(state.captureType);
  }
  function cancelSelection() {
    state.selecting = false; dragging = null; $("selection-overlay").hidden = true;
    showView("recorder"); render();
  }
  function setSelectionType(type) {
    state.captureType = type;
    document.querySelectorAll("[data-select-type]").forEach((button) => button.classList.toggle("active", button.dataset.selectType === type));
    $("selection-instruction").textContent = ({ region: "拖动鼠标，框选要录制的区域", window: "点击窗口，选择要录制的内容", display: "将录制整个屏幕" })[type];
    const area = $("selection-overlay").getBoundingClientRect();
    state.selection = null;
    if (type === "display") state.selection = { x: 12, y: 12, w: area.width - 24, h: area.height - 24 };
    drawSelection();
  }
  function drawSelection() {
    const rect = state.selection;
    $("selection-rect").hidden = !rect;
    $("selection-confirm").hidden = !rect || rect.w < 40 || rect.h < 40;
    $("selection-audio-label").textContent = sourceCount() + " 路声音";
    if (!rect) return;
    Object.assign($("selection-rect").style, { left: rect.x + "px", top: rect.y + "px", width: rect.w + "px", height: rect.h + "px" });
    $("selection-size").textContent = Math.round(rect.w) + " × " + Math.round(rect.h);
  }
  const selectionPoint = (event) => {
    const area = $("selection-overlay").getBoundingClientRect();
    return { x: Math.max(0, Math.min(area.width, event.clientX - area.left)), y: Math.max(0, Math.min(area.height, event.clientY - area.top)) };
  };
  $("selection-overlay").addEventListener("pointerdown", (event) => {
    if (event.target.closest("button, .selection-confirm, .selection-types")) return;
    if (state.captureType === "window") {
      const windowRect = $("sample-window").getBoundingClientRect(), area = $("selection-overlay").getBoundingClientRect();
      if (event.clientX < windowRect.left || event.clientX > windowRect.right || event.clientY < windowRect.top || event.clientY > windowRect.bottom) return;
      const x = Math.max(8, windowRect.left), y = Math.max(8, windowRect.top - area.top);
      state.selection = { x, y, w: Math.min(area.width - x - 8, windowRect.right - x), h: Math.min(area.height - y - 8, windowRect.bottom - area.top - y) };
      drawSelection(); return;
    }
    if (state.captureType !== "region") return;
    dragging = selectionPoint(event);
    $("selection-overlay").setPointerCapture(event.pointerId);
    state.selection = { x: dragging.x, y: dragging.y, w: 0, h: 0 }; drawSelection();
  });
  $("selection-overlay").addEventListener("pointermove", (event) => {
    if (!dragging) return;
    const point = selectionPoint(event);
    state.selection = { x: Math.min(dragging.x, point.x), y: Math.min(dragging.y, point.y), w: Math.abs(point.x - dragging.x), h: Math.abs(point.y - dragging.y) };
    drawSelection();
  });
  $("selection-overlay").addEventListener("pointerup", () => { dragging = null; });
  $("selection-overlay").addEventListener("pointercancel", () => { dragging = null; });
  document.querySelectorAll("[data-select-type]").forEach((button) => button.addEventListener("click", () => setSelectionType(button.dataset.selectType)));
  $("cancel-selection").addEventListener("click", cancelSelection);
  $("confirm-selection").addEventListener("click", () => {
    if (!state.selection || state.selection.w < 40 || state.selection.h < 40) return;
    state.targetSize = Math.round(state.selection.w) + " × " + Math.round(state.selection.h);
    startRecording();
  });
  function updateSceneButtons(scene) {
    document.querySelectorAll("[data-scene]").forEach((button) => button.classList.toggle("selected", button.dataset.scene === scene));
  }
  function showScene(scene, requestedMode) {
    state.recording = false; state.selecting = false; $("selection-overlay").hidden = true;
    state.system = true; state.mic = true; state.name = "产品例会";
    $("filename-error").hidden = true; state.baseSeconds = 0; state.saved = false;
    if (scene === "audio" || scene === "video") {
      state.mode = scene; state.targetSize = "1280 × 720"; startRecording(754);
    } else if (scene === "saved") {
      state.mode = "video"; state.baseSeconds = 1938; state.saved = true; showView("recorder"); render();
    } else {
      state.mode = requestedMode || "audio"; showView("recorder"); render();
    }
    updateSceneButtons(scene); updateMeters();
  }
  document.querySelectorAll("[data-scene]").forEach((button) => button.addEventListener("click", () => showScene(button.dataset.scene)));
  document.addEventListener("click", (event) => {
    if (!state.selecting && state.opened && !event.target.closest(".popover,.menu-trigger,.prototype-toolbar,.selection-overlay")) setOpened(false);
  });
  document.addEventListener("keydown", (event) => {
    if (event.altKey && event.code === "KeyR") {
      event.preventDefault();
      if (state.selecting) cancelSelection(); else setOpened(!state.opened);
    }
    if (event.key === "Escape") {
      if (state.selecting) cancelSelection(); else setOpened(false);
    }
    if (event.key === "Enter" && state.selecting && state.selection && state.selection.w >= 40 && state.selection.h >= 40) $("confirm-selection").click();
  });
  window.addEventListener("resize", () => { alignPopover(); if (state.selecting) cancelSelection(); });
  setInterval(() => {
    renderTimer();
    if (state.playing && state.view === "detail") {
      const record = detailRecord();
      state.playSeconds = Math.min(record.seconds, state.playSeconds + 1);
      if (state.playSeconds >= record.seconds) state.playing = false;
      renderPlayer();
    }
  }, 1000);
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (!reducedMotion) setInterval(updateMeters, 190);
  updateMeters();
  const query = new URLSearchParams(location.search);
  showScene(query.get("state") === "recording" ? (query.get("mode") === "video" ? "video" : "audio") : query.get("state") === "saved" ? "saved" : "idle", query.get("mode") === "video" ? "video" : "audio");
})();
