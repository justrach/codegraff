/** Popup: pairing form + connection status + appearance.
 *
 * The token is the only secret here: typed once, kept in
 * chrome.storage.local, never in a page. Theme (preset + mode) mirrors the
 * desktop GUI's themeStore (localStorage keys, data-theme + .dark) and the
 * preset chips mirror its ThemePresetCard swatches; theme.css is generated
 * from gui/src/styles/ by sync-theme.py. No network, no bundler. */

const $ = (id) => document.getElementById(id);

const PRESET_NAMES = {
  "warm-graphite": "Warm Graphite",
  slate: "Slate",
  nord: "Ocean",
  forest: "Forest",
  mono: "Mono",
  rose: "Rose",
};

async function getTheme() {
  const { themePreset, themeMode } = await chrome.storage.local.get(["themePreset", "themeMode"]);
  return {
    preset: typeof themePreset === "string" ? themePreset : "warm-graphite",
    mode: themeMode === "light" ? "light" : "dark",
  };
}

async function applyTheme() {
  const { preset, mode } = await getTheme();
  document.documentElement.dataset.theme = preset;
  document.documentElement.classList.toggle("dark", mode === "dark");
  document.documentElement.style.colorScheme = mode;
  $("mode").textContent = mode === "dark" ? "Light" : "Dark";
  for (const el of document.querySelectorAll("#themes .preset")) {
    el.setAttribute("aria-pressed", String(el.dataset.preset === preset));
  }
}

async function buildThemes() {
  // theme-presets.json ships the preset order + dark swatches (the GUI's
  // picker chips); fetched locally, never from the network.
  const { presets, swatches } = await fetch("theme-presets.json").then((r) => r.json());
  const host = $("themes");
  host.textContent = "";
  for (const pid of presets) {
    const s = swatches[pid];
    const b = document.createElement("button");
    b.className = "preset";
    b.dataset.preset = pid;
    b.setAttribute("aria-pressed", "false");
    b.title = PRESET_NAMES[pid] || pid;
    const chip = document.createElement("span");
    chip.className = "chip";
    chip.style.backgroundColor = s.bg;
    chip.setAttribute("aria-hidden", "true");
    const dot = document.createElement("span");
    dot.className = "a";
    dot.style.backgroundColor = s.accent;
    const bar = document.createElement("span");
    bar.className = "t";
    bar.style.backgroundColor = s.text;
    const surf = document.createElement("span");
    surf.className = "t";
    surf.style.backgroundColor = s.surface;
    chip.append(dot, bar, surf);
    const name = document.createElement("span");
    name.className = "n";
    name.textContent = PRESET_NAMES[pid] || pid;
    b.append(chip, name);
    b.onclick = async () => {
      await chrome.storage.local.set({ themePreset: pid });
      await applyTheme();
    };
    host.append(b);
  }
  await applyTheme();
}

async function status() {
  const { harnessUrl, token, lastPollMs } = await chrome.storage.local.get(["harnessUrl", "token", "lastPollMs"]);
  $("url").value = harnessUrl || "http://127.0.0.1:3000";
  if (!token) return `<span class="dot idle"></span>Not paired.`;
  const age = Date.now() - (lastPollMs || 0);
  if (lastPollMs && age < 90_000) return `<span class="dot ok"></span>Connected — last poll ${Math.round(age / 1000)}s ago.`;
  return `<span class="dot bad"></span>Token saved, harness not reached. Is graff running?`;
}

$("save").onclick = async () => {
  const harnessUrl = $("url").value.trim().replace(/\/+$/, "") || "http://127.0.0.1:3000";
  const token = $("token").value.trim();
  if (!token) { $("status").innerHTML = `<span class="dot bad"></span>Enter the pairing token first.`; return; }
  let host;
  try {
    host = new URL(harnessUrl).hostname;
  } catch { host = ""; }
  if (!["127.0.0.1", "localhost"].includes(host)) {
    $("status").innerHTML = `<span class="dot bad"></span>Only loopback URLs — this machine only.`;
    return;
  }
  await chrome.storage.local.set({ harnessUrl, token });
  $("token").value = "";
  await chrome.runtime.sendMessage({ cmd: "wake" }).catch(() => undefined);
  $("status").innerHTML = await status();
};

$("unpair").onclick = async () => {
  await chrome.storage.local.remove(["token", "lastPollMs"]);
  $("status").innerHTML = await status();
};

$("mode").onclick = async () => {
  const { mode } = await getTheme();
  await chrome.storage.local.set({ themeMode: mode === "dark" ? "light" : "dark" });
  await applyTheme();
};

// First paint with the stored theme before anything else, like the GUI's
// themeStore applying at import to avoid a flash.
getTheme().then(({ preset, mode }) => {
  document.documentElement.dataset.theme = preset;
  document.documentElement.classList.toggle("dark", mode === "dark");
});
buildThemes().catch(() => undefined);
status().then((html) => { $("status").innerHTML = html; });
