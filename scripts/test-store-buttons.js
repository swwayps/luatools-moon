#!/usr/bin/env node

const fs = require("fs");

const source = fs.readFileSync("plugin/public/luatools.js", "utf8");
if (
  !/\.luatools-gamepad-proton-button\s*>\s*span\s*>\s*span\s*\{[^}]*display:\s*flex\s*!important/s.test(
    source,
  )
) {
  throw new Error("Gamescope ProtonDB badge does not expose a flex label row");
}
if (
  !/data-action-count="3"[^}]*\{[^}]*padding-inline:\s*4px\s*!important;[^}]*font-size:\s*11px\s*!important;/s.test(
    source,
  )
) {
  throw new Error("three-button row does not keep long action labels visible");
}
const start = source.indexOf("function findBigPictureInterestLayout");
const end = source.indexOf("function addLuaToolsManageButtons", start);

if (start < 0 || end < 0) {
  throw new Error("Big Picture store controls are missing");
}

class FakeElement {
  constructor(tagName) {
    this.tagName = tagName.toUpperCase();
    this.children = [];
    this.parentElement = null;
    this.className = "";
    this.id = "";
    this.textContent = "";
    this.attributes = {};
    this.listeners = {};
    this.rectWidth = 0;
    this.style = {
      values: {},
      setProperty: (name, value) => {
        this.style.values[name] = value;
      },
    };
    this.classList = {
      contains: (name) => this.className.split(/\s+/).includes(name),
      add: (...names) => {
        const classes = new Set(this.className.split(/\s+/).filter(Boolean));
        names.forEach((name) => classes.add(name));
        this.className = [...classes].join(" ");
      },
      remove: (...names) => {
        const removed = new Set(names);
        this.className = this.className
          .split(/\s+/)
          .filter((name) => name && !removed.has(name))
          .join(" ");
      },
    };
  }

  get firstElementChild() {
    return this.children[0] || null;
  }

  get innerText() {
    return this.textContent + this.children.map((child) => child.innerText).join("");
  }

  set innerHTML(value) {
    if (value !== "") throw new Error("fixture only supports clearing innerHTML");
    this.replaceChildren();
  }

  appendChild(child) {
    if (child.parentElement) child.remove();
    child.parentElement = this;
    this.children.push(child);
    return child;
  }

  replaceChildren(...children) {
    this.children.forEach((child) => {
      child.parentElement = null;
    });
    this.children = [];
    children.forEach((child) => this.appendChild(child));
  }

  after(node) {
    const siblings = this.parentElement.children;
    if (node.parentElement) node.remove();
    const index = siblings.indexOf(this);
    node.parentElement = this.parentElement;
    siblings.splice(index + 1, 0, node);
  }

  remove() {
    if (!this.parentElement) return;
    const siblings = this.parentElement.children;
    siblings.splice(siblings.indexOf(this), 1);
    this.parentElement = null;
  }

  contains(node) {
    return node === this || this.children.some((child) => child.contains(node));
  }

  cloneNode(deep) {
    const clone = new FakeElement(this.tagName);
    clone.className = this.className;
    clone.id = this.id;
    clone.textContent = this.textContent;
    clone.attributes = { ...this.attributes };
    clone.rectWidth = this.rectWidth;
    clone.style.values = { ...this.style.values };
    if (deep) this.children.forEach((child) => clone.appendChild(child.cloneNode(true)));
    return clone;
  }

  getBoundingClientRect() {
    return { width: this.rectWidth };
  }

  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }

  removeAttribute(name) {
    delete this.attributes[name];
  }

  addEventListener(name, handler) {
    this.listeners[name] = handler;
  }

  querySelectorAll(selector) {
    const matches = [];
    const match = (node) => {
      if (selector === "button") return node.tagName === "BUTTON";
      if (selector === "span") return node.tagName === "SPAN";
      if (selector.startsWith(".")) return node.classList.contains(selector.slice(1));
      if (selector.startsWith("#")) return node.id === selector.slice(1);
      return false;
    };
    const visit = (node) => {
      node.children.forEach((child) => {
        if (match(child)) matches.push(child);
        visit(child);
      });
    };
    visit(this);
    return matches;
  }

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }
}

function makeNativeButton(label) {
  const button = new FakeElement("button");
  button.className = "NativeGreyButton Focusable";
  button.setAttribute("data-accent-color", "greyneutral");
  const outer = new FakeElement("span");
  outer.className = "NativeLabel";
  const inner = new FakeElement("span");
  inner.className = "NativeLabelState";
  inner.textContent = label;
  outer.appendChild(inner);
  button.appendChild(outer);
  return button;
}

function makeInterestFixture() {
  const root = new FakeElement("div");
  root.id = "FeatureTarget_interest-buttons";
  const panel = new FakeElement("div");
  const column = new FakeElement("div");
  const wishlistRow = new FakeElement("div");
  const wishlistPanel = new FakeElement("div");
  const wishlist = makeNativeButton("Add to your wishlist");
  const followRow = new FakeElement("div");
  followRow.className = "NativeRow";
  followRow.style.setProperty("--direction", "row");
  const followCell = new FakeElement("div");
  followCell.className = "NativeCell";
  followCell.rectWidth = 179;
  followCell.style.setProperty("--flex-grow", "1");
  const ignoreCell = followCell.cloneNode(false);
  ignoreCell.rectWidth = 172;

  root.appendChild(panel);
  panel.appendChild(column);
  column.appendChild(wishlistRow);
  wishlistRow.appendChild(wishlistPanel);
  wishlistPanel.appendChild(wishlist);
  column.appendChild(followRow);
  followRow.appendChild(followCell);
  followCell.appendChild(makeNativeButton("Follow"));
  followRow.appendChild(ignoreCell);
  ignoreCell.appendChild(makeNativeButton("Ignore"));

  return { root, column, wishlistRow, followRow };
}

const block = source.slice(start, end);
const factory = new Function(
  "document",
  "window",
  "Millennium",
  "lt",
  "t",
  "askRestartConfirmation",
  "showLuaToolsConfirm",
  "ShowLuaToolsAlert",
  "showFixesLoadingPopupAndCheck",
  "backendLog",
  "ltpLooksNative",
  "LTP_TIERS",
  `${block}\nreturn { findBigPictureInterestLayout, renderBigPictureStoreButtons };`,
);

const fixture = makeInterestFixture();
const document = {
  createElement: (tagName) => new FakeElement(tagName),
  getElementById: (id) => (fixture.root.id === id ? fixture.root : fixture.root.querySelector(`#${id}`)),
};
const api = factory(
  document,
  {},
  { callServerMethod: () => Promise.resolve({ success: true }) },
  (text) => text,
  (_key, fallback) => fallback,
  () => {},
  () => {},
  () => {},
  () => {},
  () => {},
  () => true,
  {
    native: { color: "green", glow: "green", text: "white", label: "Native" },
    pending: { color: "grey", glow: "none", text: "white", label: "Pending" },
  },
);

const layout = api.findBigPictureInterestLayout(fixture.root);
if (!layout || layout.column !== fixture.column) throw new Error("interest layout was not resolved structurally");

api.renderBigPictureStoreButtons(638510, false, layout);
let order = fixture.column.children.map((node) => node.id || node.className);
if (order.join("|") !== "|luatools-gamepad-actions|NativeRow|luatools-gamepad-protondb") {
  throw new Error(`unexpected row order: ${order.join("|")}`);
}

let actionLabels = document
  .getElementById("luatools-gamepad-actions")
  .querySelectorAll("button")
  .map((button) => button.innerText);
if (actionLabels.join("|") !== "Restart Steam|Add via LuaTools") {
  throw new Error(`unexpected not-added actions: ${actionLabels.join("|")}`);
}

const notAddedButtons = document
  .getElementById("luatools-gamepad-actions")
  .querySelectorAll("button");
if (
  notAddedButtons.some(
    (button) => button.querySelector("span").firstElementChild.style.values.visibility !== "visible",
  )
) {
  throw new Error("cloned native state left a LuaTools label hidden");
}

const notAddedCells = document.getElementById("luatools-gamepad-actions").children;
const actionGrowth = notAddedCells.map(
  (cell) => cell.style.values["--luatools-flex-grow"],
);
if (actionGrowth.join("|") !== "179|172") {
  throw new Error(`two-button row does not mirror Follow/Ignore: ${actionGrowth.join("|")}`);
}

api.renderBigPictureStoreButtons(638510, true, layout);
actionLabels = document
  .getElementById("luatools-gamepad-actions")
  .querySelectorAll("button")
  .map((button) => button.innerText);
if (actionLabels.join("|") !== "Restart Steam|Remove via LuaTools|Fixes Menu") {
  throw new Error(`unexpected added actions: ${actionLabels.join("|")}`);
}

if (fixture.column.querySelectorAll("#luatools-gamepad-actions").length !== 1) {
  throw new Error("action row was duplicated");
}
if (fixture.column.querySelectorAll("#luatools-gamepad-protondb").length !== 1) {
  throw new Error("ProtonDB row was duplicated");
}

const nativeClass = layout.referenceButton.className.split(/\s+/)[0];
const customButtons = [
  ...document.getElementById("luatools-gamepad-actions").querySelectorAll("button"),
  ...document.getElementById("luatools-gamepad-protondb").querySelectorAll("button"),
];
if (!customButtons.every((button) => button.classList.contains(nativeClass))) {
  throw new Error("custom controls did not inherit the native button visual");
}

console.log("ok - Gamescope store controls follow the new native interest layout");
