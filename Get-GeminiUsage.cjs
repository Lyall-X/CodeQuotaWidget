const fs = require("fs");
const path = require("path");
const childProcess = require("child_process");

const PORT = Number(process.env.CODEQUOTA_GEMINI_CDP_PORT || 9223);
const PROFILE_DIR = path.join(__dirname, "gemini-browser-profile");
const GEMINI_URL = "https://gemini.google.com/app";

function findBrowser() {
  const candidates = [
    "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
    "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
    "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
    "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  ];
  return candidates.find((file) => fs.existsSync(file));
}

function startBrowser() {
  const browser = findBrowser();
  if (!browser) throw new Error("Chrome or Edge was not found");
  fs.mkdirSync(PROFILE_DIR, { recursive: true });
  const child = childProcess.spawn(browser, [
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${PROFILE_DIR}`,
    "--no-first-run",
    "--new-window",
    GEMINI_URL,
  ], {
    detached: true,
    stdio: "ignore",
  });
  child.unref();
  return { browser, port: PORT, profile: PROFILE_DIR };
}

async function sleep(ms) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function cdpJson(pathname, options) {
  const response = await fetch(`http://127.0.0.1:${PORT}${pathname}`, options);
  if (!response.ok) throw new Error(`CDP ${response.status} ${response.statusText}`);
  return await response.json();
}

async function ensureBrowser() {
  try {
    await cdpJson("/json/version");
    return;
  } catch {
    startBrowser();
  }
  for (let i = 0; i < 30; i++) {
    try {
      await cdpJson("/json/version");
      return;
    } catch {
      await sleep(250);
    }
  }
  throw new Error("Gemini browser did not start");
}

async function getGeminiTarget() {
  const targets = await cdpJson("/json");
  let target = targets.find((item) => item.type === "page" && item.url.includes("gemini.google.com"));
  if (!target) {
    try {
      target = await cdpJson(`/json/new?${encodeURIComponent(GEMINI_URL)}`, { method: "PUT" });
    } catch {
      target = await cdpJson(`/json/new?${encodeURIComponent(GEMINI_URL)}`);
    }
  }
  if (!target.webSocketDebuggerUrl) throw new Error("Gemini tab has no debugger URL");
  return target;
}

function createCdpClient(wsUrl) {
  const ws = new WebSocket(wsUrl);
  let nextId = 1;
  const pending = new Map();

  ws.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (!message.id || !pending.has(message.id)) return;
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) reject(new Error(message.error.message || "CDP error"));
    else resolve(message.result);
  });

  return new Promise((resolve, reject) => {
    ws.addEventListener("open", () => {
      resolve({
        send(method, params = {}) {
          const id = nextId++;
          ws.send(JSON.stringify({ id, method, params }));
          return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
        },
        close() {
          ws.close();
        },
      });
    });
    ws.addEventListener("error", () => reject(new Error("CDP websocket failed")));
  });
}

const readExpression = `(() => {
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const collect = (root, out = []) => {
    for (const el of Array.from(root.querySelectorAll("*"))) {
      if (/^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|LINK|META)$/i.test(el.tagName)) continue;
      out.push(el);
      if (el.shadowRoot) collect(el.shadowRoot, out);
    }
    return out;
  };
  const visible = (el) => {
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
  };
  const textOf = (el) => [
    el.innerText,
    el.childElementCount === 0 ? el.textContent : "",
    el.getAttribute("aria-label"),
    el.getAttribute("title"),
  ].filter(Boolean).join(" ");
  const clickMatch = (patterns) => {
    const elements = collect(document).filter((el) =>
      el.matches("button,[role=button],a,div[tabindex],span[role=button],mat-icon")
    );
    const hit = elements.find((el) => visible(el) && patterns.some((pattern) => pattern.test(textOf(el))));
    if (!hit) return "";
    hit.click();
    return textOf(hit).slice(0, 100);
  };
  return (async () => {
    if (!location.href.includes("gemini.google.com")) {
      location.href = "${GEMINI_URL}";
      await sleep(2500);
    }
    await sleep(1000);
    const clickedSettings = clickMatch([/settings/i, /设置/, /設定/]);
    await sleep(900);
    const clickedUsage = clickMatch([/usage/i, /limit/i, /用量/, /限制/, /使用量/]);
    await sleep(1200);
    const text = collect(document)
      .filter(visible)
      .map(textOf)
      .filter(Boolean)
      .join("\\n");
    return {
      url: location.href,
      title: document.title,
      clickedSettings,
      clickedUsage,
      text,
    };
  })();
})()`;

function extractLines(text) {
  return text
    .split(/\r?\n/)
    .map((line) => line.replace(/\s+/g, " ").trim())
    .filter(Boolean)
    .filter((line) => line.length < 220)
    .filter((line) => /usage|limit|reset|refresh|used|remaining|quota|用量|限制|重置|刷新|已用|剩余|\d+(?:\.\d+)?\s*%|\d+(?:\.\d+)?\s*\/\s*\d+(?:\.\d+)?/i.test(line))
    .slice(0, 40);
}

function parseUsage(text) {
  const lines = extractLines(text);
  const joined = lines.join(" | ");
  const percents = Array.from(joined.matchAll(/(\d+(?:\.\d+)?)\s*%/g))
    .map((match) => Number(match[1]))
    .filter((value) => value >= 0 && value <= 100);
  const ratios = Array.from(joined.matchAll(/(\d+(?:\.\d+)?)\s*\/\s*(\d+(?:\.\d+)?)/g))
    .map((match) => {
      const used = Number(match[1]);
      const limit = Number(match[2]);
      return {
        used,
        limit,
        percent: limit > 0 ? (used / limit) * 100 : null,
        label: `${match[1]}/${match[2]}`,
      };
    })
    .filter((item) => item.percent !== null && item.percent >= 0 && item.percent <= 100);
  const derivedPercents = ratios.map((item) => item.percent);
  const allPercents = percents.length ? percents : derivedPercents;
  const resetMatch =
    joined.match(/(?:reset|refresh)(?:s|es)?(?:\s+in)?\s+([^|,;]{2,40})/i) ||
    joined.match(/(?:重置|刷新)[^|,;，。]{0,10}([0-9]+\s*(?:h|hr|hrs|hour|hours|m|min|分钟|小时)[^|,;，。]{0,30})/i);
  const resetLines = lines
    .map((line) => line.match(/(?:reset|refresh)(?:s|es)?(?:\s+in)?\s+([^|,;]{2,60})/i))
    .filter(Boolean)
    .map((match) => match[1].trim());

  return {
    status: allPercents.length ? "ok" : "unparsed",
    currentPercent: allPercents[0] ?? null,
    weeklyPercent: allPercents[1] ?? null,
    currentLabel: ratios[0] ? `${ratios[0].label} (${Math.round(ratios[0].percent)}%)` : "",
    weeklyLabel: ratios[1] ? `${ratios[1].label} (${Math.round(ratios[1].percent)}%)` : "",
    resetText: resetLines[0] || (resetMatch ? resetMatch[1].trim() : ""),
    currentResetText: resetLines[0] || "",
    weeklyResetText: resetLines[1] || "",
    lines,
  };
}

function textFromAccessibilityTree(tree) {
  if (!tree || !Array.isArray(tree.nodes)) return "";
  const fields = [];
  for (const node of tree.nodes) {
    for (const key of ["name", "value", "description"]) {
      const value = node[key] && node[key].value;
      if (typeof value === "string" && value.trim()) fields.push(value.trim());
    }
  }
  return fields.join("\n");
}

async function readUsage() {
  await ensureBrowser();
  const target = await getGeminiTarget();
  const client = await createCdpClient(target.webSocketDebuggerUrl);
  try {
    await client.send("Runtime.enable");
    let value = {};
    let parsed = { status: "unparsed", lines: [] };
    for (let attempt = 0; attempt < 5; attempt++) {
      const result = await client.send("Runtime.evaluate", {
        expression: readExpression,
        awaitPromise: true,
        returnByValue: true,
      });
      value = result.result && result.result.value ? result.result.value : {};
      let axText = "";
      try {
        axText = textFromAccessibilityTree(await client.send("Accessibility.getFullAXTree"));
      } catch {
        axText = "";
      }
      parsed = parseUsage(`${value.text || ""}\n${axText}`);
      if (parsed.status === "ok") break;
      await sleep(1200);
    }
    return {
      status: parsed.status,
      currentPercent: parsed.currentPercent,
      weeklyPercent: parsed.weeklyPercent,
      currentLabel: parsed.currentLabel,
      weeklyLabel: parsed.weeklyLabel,
      resetText: parsed.resetText,
      currentResetText: parsed.currentResetText,
      weeklyResetText: parsed.weeklyResetText,
      title: value.title || "",
      url: value.url || "",
      clickedSettings: value.clickedSettings || "",
      clickedUsage: value.clickedUsage || "",
      lines: parsed.lines,
    };
  } finally {
    client.close();
  }
}

(async () => {
  try {
    const command = process.argv[2] || "read";
    if (command === "login") {
      console.log(JSON.stringify({ status: "login", url: GEMINI_URL, ...startBrowser() }));
      return;
    }
    console.log(JSON.stringify(await readUsage()));
  } catch (error) {
    console.log(JSON.stringify({ status: "error", error: error.message }));
    process.exitCode = 1;
  }
})();
