const fs = require("fs");
const vm = require("vm");

const source = fs.readFileSync("plugin/public/luatools.js", "utf8");
const stylesheet = fs.readFileSync("plugin/public/steamdb-webkit.css", "utf8");
const start = source.indexOf("// LUATOOLS RECOMMENDED VERSION MODAL START");
const end = source.indexOf("// LUATOOLS RECOMMENDED VERSION MODAL END");
if (start < 0 || end <= start) {
  console.error("FAIL recommended version modal implementation is missing");
  process.exit(1);
}

class ClassList {
  constructor(element) { this.element = element; }
  values() { return this.element.className.split(/\s+/).filter(Boolean); }
  contains(name) { return this.values().includes(name); }
  add(name) { if (!this.contains(name)) this.element.className += (this.element.className ? " " : "") + name; }
  remove(name) { this.element.className = this.values().filter((value) => value !== name).join(" "); }
}

class Element {
  constructor(tag, document) {
    this.tagName = tag.toUpperCase();
    this.ownerDocument = document;
    this.children = [];
    this.parentElement = null;
    this.className = "";
    this.classList = new ClassList(this);
    this.attributes = {};
    this.listeners = {};
    this.style = { cssText: "", setProperty(name, value) { this[name] = value; } };
    this.textContent = "";
    this.disabled = false;
    this.checked = false;
    this.isConnected = false;
  }
  appendChild(child) {
    child.parentElement = this;
    child.isConnected = this.isConnected;
    this.children.push(child);
    return child;
  }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] || null; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  removeEventListener(type, fn) {
    this.listeners[type] = (this.listeners[type] || []).filter((item) => item !== fn);
  }
  dispatchEvent(event) {
    event.target ||= this;
    event.preventDefault ||= function () {};
    event.stopPropagation ||= function () {};
    event.stopImmediatePropagation ||= function () {};
    for (const fn of this.listeners[event.type] || []) fn.call(this, event);
  }
  click() { this.dispatchEvent({ type: "click" }); }
  focus() {
    this.ownerDocument.activeElement = this;
    this.dispatchEvent({ type: "focus" });
  }
  remove() {
    if (this.parentElement) {
      this.parentElement.children = this.parentElement.children.filter((child) => child !== this);
    }
    this.isConnected = false;
  }
  matches(selector) {
    if (selector.startsWith(".")) return this.classList.contains(selector.slice(1));
    const data = selector.match(/^\[([^=]+)="([^"]+)"\]$/);
    if (data) return this.getAttribute(data[1]) === data[2];
    return this.tagName.toLowerCase() === selector.toLowerCase();
  }
  querySelector(selector) {
    for (const child of this.children) {
      if (child.matches(selector)) return child;
      const nested = child.querySelector(selector);
      if (nested) return nested;
    }
    return null;
  }
}

class Document {
  constructor() {
    this.listeners = {};
    this.body = new Element("body", this);
    this.body.isConnected = true;
    this.activeElement = null;
  }
  createElement(tag) { return new Element(tag, this); }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  removeEventListener(type, fn) {
    this.listeners[type] = (this.listeners[type] || []).filter((item) => item !== fn);
  }
  dispatch(type, event = {}) {
    event.type = type;
    event.preventDefault ||= function () {};
    event.stopPropagation ||= function () {};
    for (const fn of this.listeners[type] || []) fn(event);
  }
  querySelector(selector) { return this.body.querySelector(selector); }
}

let failures = 0;
function check(name, condition) {
  if (condition) console.log("ok   " + name);
  else { console.log("FAIL " + name); failures++; }
}

function makeHarness(rpcResult) {
  const document = new Document();
  const nav = { scans: 0, back: null,
    scanElements() { this.scans++; },
    setBackHandler(fn) { this.back = typeof fn === "function" ? fn : null; },
  };
  const window = { GamepadNav: nav };
  const context = {
    window, document, Promise,
    Millennium: { callServerMethod(_plugin, method) {
      if (method !== "GetLuaToolsAddRecommendation") {
        return Promise.reject(new Error("unexpected RPC " + method));
      }
      if (rpcResult instanceof Error) return Promise.reject(rpcResult);
      return Promise.resolve(JSON.stringify(rpcResult || {
        success: true, available: false, authRequired: false,
      }));
    } },
    setTimeout(fn) { fn(); return 1; },
    clearTimeout() {},
    ensureLuaToolsStyles() {}, ensureFontAwesome() {},
    lt(value) { return value; },
    getThemeColors() {
      return { modalBg: "#25282f", text: "#f3f5f7", textSecondary: "#aab2bd",
        border: "#414956", accent: "#66c0f4", shadowRgba: "rgba(0,0,0,.4)" };
    },
  };
  vm.runInNewContext(source.slice(start, end)
    + "\nthis.showModal=showLuaToolsVersionChoiceModal;"
    + "\nthis.showUnavailable=showLuaToolsRecommendedUnavailableModal;"
    + "\nthis.chooseFlow=chooseLuaToolsAddFlow;", context);
  return { document, nav, showModal: context.showModal,
    showUnavailable: context.showUnavailable, chooseFlow: context.chooseFlow };
}

(async function () {
  const recommendation = { fixId: "fix", title: "Recommended", category: "voices38" };
  const first = makeHarness();
  const trigger = first.document.createElement("button");
  trigger.isConnected = true;
  const pending = first.showModal(10, recommendation, trigger);
  const overlay = first.document.querySelector(".luatools-version-choice-overlay");
  const recommended = overlay.querySelector('[data-version-action="recommended"]');
  const latest = overlay.querySelector('[data-version-action="latest"]');
  const checkbox = overlay.querySelector("input");
  const checkRow = overlay.querySelector("label");
  check("M0 modal controls inherit the active LuaTools accent",
    overlay.style["--lt-version-accent"] === "#66c0f4");
  check("M0b only the checkbox itself participates in focus navigation",
    checkbox.classList.contains("focusable")
      && !checkRow.classList.contains("focusable"));
  check("M1 recommended is the primary initial gamepad focus",
    recommended.classList.contains("primary") && first.document.activeElement === recommended);
  check("M2 modal registers every control for gamepad navigation", first.nav.scans === 1);
  latest.focus();
  check("M3 focusing latest clears and disables automatic fix",
    checkbox.checked === false && checkbox.disabled === true);
  recommended.focus();
  check("M4 returning to recommended restores the checked option",
    checkbox.checked === true && checkbox.disabled === false);
  checkbox.checked = false;
  recommended.click();
  const selected = await pending;
  check("M5 recommended returns the user's checkbox choice",
    selected.choice === "recommended" && selected.autoApply === false);
  check("M6 closing restores focus to Add via LuaTools",
    first.document.activeElement === trigger);

  const second = makeHarness();
  const latestPromise = second.showModal(10, recommendation, null);
  second.document.querySelector('[data-version-action="latest"]').click();
  const latestResult = await latestPromise;
  check("M7 latest can never queue the build-specific automatic fix",
    latestResult.choice === "latest" && latestResult.autoApply === false);

  const third = makeHarness();
  const cancelPromise = third.showModal(10, recommendation, null);
  third.nav.back();
  check("M8 native gamepad B cancels only the active modal",
    (await cancelPromise).choice === "cancel");

  const fourth = makeHarness();
  const escapePromise = fourth.showModal(10, recommendation, null);
  fourth.document.dispatch("keydown", { key: "Escape" });
  check("M9 Escape cancels and removes the overlay",
    (await escapePromise).choice === "cancel"
      && fourth.document.querySelector(".luatools-version-choice-overlay") === null);

  const unavailable = makeHarness({ success: true, available: false, authRequired: false });
  check("M10 signed-out or unindexed games preserve the conventional flow",
    (await unavailable.chooseFlow(20, null)).choice === "latest"
      && unavailable.document.querySelector(".luatools-version-choice-overlay") === null);

  const rpcFailure = makeHarness(new Error("offline"));
  check("M11 a local recommendation lookup failure fails open to conventional Add",
    (await rpcFailure.chooseFlow(20, null)).choice === "latest");

  const indexed = makeHarness({
    success: true, available: true, authRequired: false,
    recommendation: { fixId: "fix", title: "Recommended", category: "voices38" },
  });
  const indexedChoice = indexed.chooseFlow(10, null);
  await Promise.resolve();
  indexed.document.querySelector('[data-version-action="recommended"]').click();
  check("M12 an authenticated indexed manifest opens the choice modal",
    (await indexedChoice).choice === "recommended"
      && (await indexedChoice).recommendation.fixId === "fix");

  const checkRule = stylesheet.match(
    /\.luatools-version-choice-check\s*\{([^}]*)\}/,
  );
  const declarations = checkRule ? checkRule[1] : "";
  check("M13 the checkbox row has no surrounding card surface",
    /background:\s*transparent\s*;/.test(declarations)
      && /border:\s*0\s*;/.test(declarations)
      && /padding:\s*0\s*;/.test(declarations));

  const fallback = makeHarness();
  const fallbackChoice = fallback.showUnavailable(10, null);
  const fallbackOverlay = fallback.document.querySelector(".luatools-version-choice-overlay");
  const fallbackLatest = fallbackOverlay.querySelector('[data-version-action="latest"]');
  check("M14 unavailable recommended builds offer only Latest or cancel",
    fallbackLatest && fallbackLatest.classList.contains("primary")
      && fallbackOverlay.querySelector('[data-version-action="recommended"]') === null
      && fallbackOverlay.querySelector("input") === null);
  check("M15 unavailable copy explicitly disables automatic fix",
    fallbackOverlay.querySelector("p").textContent.includes("automatic fix will not be applied"));
  fallbackLatest.click();
  check("M16 unavailable fallback can only continue as Latest without auto-fix",
    (await fallbackChoice).choice === "latest" && (await fallbackChoice).autoApply === false);

  const pt = JSON.parse(fs.readFileSync("plugin/backend/locales/pt-BR.json", "utf8"));
  const approved = "Não foi possível preparar a versão recomendada devido à indisponibilidade do servidor de manifest. O jogo poderá ser adicionado usando a versão mais recente, o fix automático não será aplicado e o jogo pode não funcionar corretamente.";
  check("M17 Portuguese fallback copy matches the approved warning",
    Object.values(pt).some((section) => section && typeof section === "object"
      && Object.values(section).includes(approved)));

  check("M18 backend unavailability is routed back into the Latest/cancel modal",
    source.includes('payload.errorCode === "manifest_server_unavailable"')
      && source.includes("showLuaToolsRecommendedUnavailableModal"));

  process.exitCode = failures ? 1 : 0;
})();
