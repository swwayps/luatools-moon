#!/usr/bin/env node

const fs = require("fs");

const source = fs.readFileSync("plugin/public/luatools.js", "utf8");
const start = source.indexOf("// NATIVE STEAM FOCUS NAVIGATION START");
const end = source.indexOf("// NATIVE STEAM FOCUS NAVIGATION END", start);

if (start < 0 || end < 0) {
  throw new Error("native Steam focus navigation helpers are missing");
}

class FakeElement {
  constructor(name, tagName = "DIV") {
    this.name = name;
    this.tagName = tagName;
    this.parentElement = null;
    this.children = [];
    this.listeners = new Map();
    this.clickCount = 0;
    this.isConnected = true;
    this.classes = new Set();
    this.classList = {
      add: (...names) => names.forEach((className) => this.classes.add(className)),
      remove: (...names) => names.forEach((className) => this.classes.delete(className)),
      contains: (className) => this.classes.has(className),
    };
    this.rect = { left: 0, right: 10, top: 0, bottom: 10, width: 10, height: 10 };
    this.style = { display: "", visibility: "", opacity: "" };
  }

  appendChild(child) {
    child.parentElement = this;
    child.isConnected = this.isConnected;
    this.children.push(child);
    return child;
  }

  contains(candidate) {
    return (
      candidate === this ||
      this.children.some((child) => child.contains(candidate))
    );
  }

  querySelectorAll() {
    const descendants = [];
    const visit = (element) => {
      for (const child of element.children) {
        descendants.push(child);
        visit(child);
      }
    };
    visit(this);
    return descendants;
  }

  closest() {
    return null;
  }

  addEventListener(type, callback) {
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type).add(callback);
  }

  removeEventListener(type, callback) {
    this.listeners.get(type)?.delete(callback);
  }

  dispatch(type, detail) {
    const event = {
      detail,
      preventDefaultCalled: false,
      stopPropagationCalled: false,
      stopImmediatePropagationCalled: false,
      preventDefault() {
        this.preventDefaultCalled = true;
      },
      stopPropagation() {
        this.stopPropagationCalled = true;
      },
      stopImmediatePropagation() {
        this.stopImmediatePropagationCalled = true;
      },
    };
    for (const callback of this.listeners.get(type) || []) callback(event);
    return event;
  }

  click() {
    this.clickCount += 1;
  }

  getBoundingClientRect() {
    return this.rect;
  }
}

class FakeNode {
  constructor(tree, parent, focusRing = null) {
    this.m_Tree = tree;
    this.m_Parent = parent;
    this.m_rgChildren = [];
    this.m_element = null;
    this.m_FocusRing = focusRing;
    this.m_Properties = {};
    this.properties = this.m_Properties;
    this.focused = false;
    this.m_ActiveChild = null;
    if (parent) parent.m_rgChildren.push(this);
  }

  SetProperties(properties) {
    this.m_Properties = properties || {};
    this.properties = this.m_Properties;
  }

  BHasFocus() {
    return this.focused;
  }

  GetFocusable() {
    if (this.m_Properties.focusable) return "self";
    if (this.m_rgChildren.length) return "children";
    return "none";
  }

  GetBoundingRect() {
    return this.m_element?.getBoundingClientRect();
  }

  GetActiveChild() {
    return this.m_ActiveChild;
  }

  GetActiveDescendant() {
    return this.m_ActiveChild?.GetActiveDescendant() || this;
  }

  BTakeFocus(source, direction) {
    this.m_Tree.clearFocus();
    this.focused = true;
    this.focusSource = source;
    this.focusDirection = direction;

    let node = this;
    while (node.m_Parent) {
      node.m_Parent.m_ActiveChild = node;
      node = node.m_Parent;
    }
    this.m_Tree.lastFocusedNode = this;
    this.m_element?.dispatch("focus");
    return true;
  }
}

class FakeTree {
  constructor(id, parent, properties) {
    this.m_ID = id;
    this.m_ParentNavTree = parent;
    this.m_Properties = properties;
    this.properties = properties;
    this.m_Root = new FakeNode(this, null);
    this.registered = [];
    this.unregistered = [];
    this.enabled = false;
    this.activated = false;
    this.lastFocusedNode = null;
  }

  get Root() {
    return this.m_Root;
  }

  CreateNode(parent, focusRing) {
    return new FakeNode(this, parent, focusRing);
  }

  RegisterNavigationItem(node, element) {
    node.m_element = element;
    node.m_bMounted = true;
    this.registered.push({ node, element });
    return () => {
      node.m_bMounted = false;
      node.focused = false;
      this.unregistered.push(element);
    };
  }

  clearFocus() {
    const clear = (node) => {
      if (node.focused) node.m_element?.dispatch("blur");
      node.focused = false;
      node.m_rgChildren.forEach(clear);
    };
    clear(this.Root);
  }

  SetIsEnabled(value) {
    this.enabled = value;
  }

  Activate(value) {
    this.activated = value;
  }

  TakeFocus(source) {
    this.focusTaken = true;
    this.focusSource = source;
    this.Root.m_rgChildren[0]?.BTakeFocus(source);
  }

  GetLastFocusedNode() {
    return this.lastFocusedNode;
  }
}

const header = new FakeElement("header");
const nativeRow = new FakeElement("native-row");
const headerButton = new FakeElement("luatools-header", "BUTTON");
header.appendChild(nativeRow);
nativeRow.appendChild(headerButton);

const storeTree = new FakeTree("StoreMenu", null, {});
storeTree.Root.m_element = header;
const nativeRowNode = storeTree.CreateNode(storeTree.Root);
nativeRowNode.m_element = nativeRow;

const interestRoot = new FakeElement("interest-root");
const interestColumn = new FakeElement("interest-column");
const actionRow = new FakeElement("luatools-gamepad-actions");
const nativeFollowRowElement = new FakeElement("native-follow-row");
const protonRow = new FakeElement("luatools-gamepad-protondb");
const restartAction = new FakeElement("restart-steam", "BUTTON");
const addAction = new FakeElement("add-via-luatools", "BUTTON");
const followAction = new FakeElement("follow", "BUTTON");
const ignoreAction = new FakeElement("ignore", "BUTTON");
const protonAction = new FakeElement("protondb", "BUTTON");

restartAction.rect = { left: 100, right: 250, top: 100, bottom: 140, width: 150, height: 40 };
addAction.rect = { left: 260, right: 410, top: 100, bottom: 140, width: 150, height: 40 };
followAction.rect = { left: 100, right: 250, top: 160, bottom: 200, width: 150, height: 40 };
ignoreAction.rect = { left: 260, right: 410, top: 160, bottom: 200, width: 150, height: 40 };
protonAction.rect = { left: 100, right: 410, top: 220, bottom: 260, width: 310, height: 40 };

interestRoot.appendChild(interestColumn);
interestColumn.appendChild(actionRow);
interestColumn.appendChild(nativeFollowRowElement);
interestColumn.appendChild(protonRow);
actionRow.appendChild(restartAction);
actionRow.appendChild(addAction);
nativeFollowRowElement.appendChild(followAction);
nativeFollowRowElement.appendChild(ignoreAction);
protonRow.appendChild(protonAction);
actionRow.querySelectorAll = () => [restartAction, addAction];
protonRow.querySelectorAll = () => [protonAction];

const interestTree = new FakeTree("FeatureTarget_interest-buttons", null, {});
interestTree.Root.m_element = interestRoot;
const interestColumnNode = interestTree.CreateNode(interestTree.Root);
interestColumnNode.m_element = interestColumn;
const nativeFollowRowNode = interestTree.CreateNode(interestColumnNode);
nativeFollowRowNode.m_element = nativeFollowRowElement;
const nativeFollowNode = interestTree.CreateNode(nativeFollowRowNode);
nativeFollowNode.m_element = followAction;
nativeFollowNode.SetProperties({ focusable: true });
const nativeIgnoreNode = interestTree.CreateNode(nativeFollowRowNode);
nativeIgnoreNode.m_element = ignoreAction;
nativeIgnoreNode.SetProperties({ focusable: true });
const nativeStoreFocusRing = { type: "steam-native-focus-ring" };
nativeFollowNode.m_FocusRing = nativeStoreFocusRing;
nativeIgnoreNode.m_FocusRing = nativeStoreFocusRing;

const context = {
  m_rgGamepadNavigationTrees: new Set([storeTree, interestTree]),
};
const createdTrees = [];
const controller = {
  m_ActiveContext: context,
  m_LastActiveContext: context,
  GetActiveContext: () => controller.m_ActiveContext,
  FindAnActiveContext: () => context,
  GetDefaultContext: () => context,
  GetActiveNavTree: () => storeTree,
  NewGamepadNavigationTree(ctx, id, parent, properties) {
    if (ctx !== context) throw new Error("wrong navigation context");
    const tree = new FakeTree(id, parent, properties);
    createdTrees.push(tree);
    context.m_rgGamepadNavigationTrees.add(tree);
    return tree;
  },
  RegisterGamepadNavigationTree(tree) {
    tree.controllerRegistered = true;
    return () => {
      tree.controllerUnregistered = true;
      context.m_rgGamepadNavigationTrees.delete(tree);
    };
  },
};

class FakeMutationObserver {
  constructor(callback) {
    this.callback = callback;
    FakeMutationObserver.instances.push(this);
  }

  observe(target, options) {
    this.target = target;
    this.options = options;
  }

  disconnect() {
    this.disconnected = true;
  }

  trigger() {
    this.callback([]);
  }
}
FakeMutationObserver.instances = [];

const block = source.slice(start, end);
const factory = new Function(
  "window",
  "document",
  "MutationObserver",
  `${block}\nreturn { registerNativeHeaderNavigation, cleanupNativeHeaderNavigation, registerNativeStoreNavigation, cleanupNativeStoreNavigation, registerNativeOverlayNavigation, cleanupNativeOverlayNavigation, hasNativeOverlayNavigation };`,
);
const api = factory(
  {
    FocusNavController: controller,
    getComputedStyle: (element) => element.style,
  },
  { documentElement: new FakeElement("document") },
  FakeMutationObserver,
);

if (!api.registerNativeHeaderNavigation(headerButton)) {
  throw new Error("header button was not registered");
}
const headerEntry = storeTree.registered.at(-1);
if (headerEntry.node.m_Parent !== nativeRowNode) {
  throw new Error("header button was not attached to the native header row");
}
if (!headerEntry.node.properties.focusable) {
  throw new Error("header button was not marked focusable");
}

headerButton.dispatch("vgp_onbuttondown", { button: 1, is_repeat: true });
headerButton.dispatch("vgp_onbuttondown", { button: 2, is_repeat: false });
if (headerButton.clickCount !== 0) {
  throw new Error("repeat or non-confirm gamepad input activated the header button");
}
const confirmEvent = headerButton.dispatch("vgp_onbuttondown", {
  button: 1,
  is_repeat: false,
});
if (headerButton.clickCount !== 1) {
  throw new Error("gamepad confirm did not activate the header button");
}
if (!confirmEvent.preventDefaultCalled || !confirmEvent.stopPropagationCalled) {
  throw new Error("handled gamepad input propagated back to Steam");
}

if (!api.registerNativeStoreNavigation([actionRow, protonRow])) {
  throw new Error("game store action rows were not registered");
}
const actionRowEntry = interestTree.registered.find(
  (entry) => entry.element === actionRow,
);
const protonRowEntry = interestTree.registered.find(
  (entry) => entry.element === protonRow,
);
if (
  actionRowEntry?.node.m_Parent !== interestColumnNode ||
  protonRowEntry?.node.m_Parent !== interestColumnNode
) {
  throw new Error("game store rows were not attached to the native interest column");
}
for (const action of [restartAction, addAction, protonAction]) {
  const entry = interestTree.registered.find(
    (item) => item.element === action,
  );
  if (!entry || !entry.node.properties.focusable) {
    throw new Error(action.name + " was not registered as a focusable store action");
  }
  if (entry.node.m_FocusRing !== nativeStoreFocusRing) {
    throw new Error(action.name + " did not reuse the native Steam focus ring");
  }
}
if (actionRowEntry.node.properties.navEntryPreferPosition !== 2) {
  throw new Error("LuaTools action row does not preserve the horizontal focus position");
}
if (typeof actionRowEntry.node.properties.onMoveDown !== "function") {
  throw new Error("LuaTools action row has no deterministic down-navigation handler");
}

// Model the DOM order Steam uses after the injected action row is mounted.
interestColumnNode.m_rgChildren = [
  actionRowEntry.node,
  nativeFollowRowNode,
  protonRowEntry.node,
];
const addEntry = interestTree.registered.find(
  (entry) => entry.element === addAction,
);
addEntry.node.BTakeFocus(0, 10);
const movedDown = actionRowEntry.node.properties.onMoveDown(
  { button: 10, source: 1 },
  actionRowEntry.node,
);
if (!movedDown || !nativeIgnoreNode.focused) {
  throw new Error("down from Add via LuaTools did not preserve the right-hand column");
}

const restartEntry = interestTree.registered.find(
  (entry) => entry.element === restartAction,
);
restartEntry.node.BTakeFocus(0, 12);
if (restartAction.classList.contains("active-focus")) {
  throw new Error("game store action used the LuaTools overlay focus style");
}
restartAction.dispatch("vgp_onbuttondown", { button: 1, is_repeat: false });
if (restartAction.clickCount !== 1) {
  throw new Error("gamepad confirm did not activate the game store action");
}

// The controller can temporarily have no active OS focus while the Big Picture
// page is visible. Registration must use Steam's discoverable context fallback.
api.cleanupNativeHeaderNavigation();
controller.m_ActiveContext = undefined;
const fallbackHeaderButton = new FakeElement("fallback-header", "BUTTON");
nativeRow.appendChild(fallbackHeaderButton);
if (!api.registerNativeHeaderNavigation(fallbackHeaderButton)) {
  throw new Error("navigation registration failed without m_ActiveContext");
}
controller.m_ActiveContext = context;
api.cleanupNativeHeaderNavigation();

const overlayParent = new FakeElement("body");
const overlay = new FakeElement("overlay");
const firstAction = new FakeElement("first-action", "BUTTON");
const secondAction = new FakeElement("second-action", "BUTTON");
const lowerLeftAction = new FakeElement("lower-left-action", "BUTTON");
const lowerRightAction = new FakeElement("lower-right-action", "BUTTON");
firstAction.rect = { left: 700, right: 740, top: 250, bottom: 290, width: 40, height: 40 };
secondAction.rect = { left: 760, right: 800, top: 250, bottom: 290, width: 40, height: 40 };
lowerLeftAction.rect = { left: 450, right: 675, top: 335, bottom: 410, width: 225, height: 75 };
lowerRightAction.rect = { left: 680, right: 910, top: 335, bottom: 410, width: 230, height: 75 };
overlayParent.appendChild(overlay);
overlay.appendChild(firstAction);
overlay.appendChild(secondAction);
overlay.appendChild(lowerLeftAction);
overlay.appendChild(lowerRightAction);

if (
  !api.registerNativeOverlayNavigation(overlay, [
    firstAction,
    secondAction,
    lowerLeftAction,
    lowerRightAction,
  ])
) {
  throw new Error("overlay was not registered as a Steam navigation tree");
}
const modalTree = createdTrees.at(-1);
if (!modalTree.properties.modal || modalTree.m_ParentNavTree !== storeTree) {
  throw new Error("overlay tree is not modal or does not belong to the active tree");
}
if (modalTree.Root.properties.layout !== 6) {
  throw new Error("overlay root did not install explicit geometric navigation");
}
if (!modalTree.enabled || !modalTree.activated) {
  throw new Error("overlay tree was not enabled and activated");
}
if (!modalTree.focusTaken || modalTree.focusSource !== 0 || !modalTree.Root.m_rgChildren[0].focused) {
  throw new Error("overlay tree did not establish initial gamepad focus");
}
if (!api.hasNativeOverlayNavigation(overlay)) {
  throw new Error("active native overlay was not tracked");
}
if (!firstAction.classList.contains("active-focus")) {
  throw new Error("initially focused overlay action has no visible indicator");
}
const modalObserver = FakeMutationObserver.instances.at(-1);
if (modalObserver.target !== overlay || !modalObserver.options.subtree) {
  throw new Error("overlay navigation does not observe dynamic descendants");
}

const dynamicAction = new FakeElement("dynamic-action", "BUTTON");
dynamicAction.rect = { left: 820, right: 880, top: 250, bottom: 290, width: 60, height: 40 };
overlay.appendChild(dynamicAction);
modalObserver.trigger();
const dynamicEntry = modalTree.registered.find(
  (entry) => entry.element === dynamicAction,
);
if (!dynamicEntry || !dynamicEntry.node.properties.focusable) {
  throw new Error("button inserted after modal registration was not made focusable");
}

const rightEvent = firstAction.dispatch("vgp_onbuttondown", {
  button: 12,
  source: 1,
  is_repeat: false,
});
if (!modalTree.Root.m_rgChildren[1].focused) {
  throw new Error("Steam right navigation did not focus the adjacent overlay action");
}
if (
  firstAction.classList.contains("active-focus") ||
  !secondAction.classList.contains("active-focus")
) {
  throw new Error("visible focus indicator did not follow Steam navigation");
}
if (modalTree.Root.m_rgChildren[1].focusSource !== 0 || modalTree.Root.m_rgChildren[1].focusDirection !== 12) {
  throw new Error("overlay navigation used the wrong Steam focus source or direction");
}
if (!rightEvent.preventDefaultCalled || !rightEvent.stopImmediatePropagationCalled) {
  throw new Error("handled Steam direction input escaped the LuaTools overlay");
}

secondAction.dispatch("vgp_onbuttondown", { button: 10, source: 1 });
if (!modalTree.Root.m_rgChildren[3].focused) {
  throw new Error("Steam down navigation did not preserve the action column");
}
lowerRightAction.dispatch("vgp_onbuttondown", { button: 11, source: 1 });
if (!modalTree.Root.m_rgChildren[2].focused) {
  throw new Error("Steam left navigation preferred a diagonal action over its row");
}

secondAction.dispatch("vgp_onbuttondown", { button: 1, is_repeat: false });
if (secondAction.clickCount !== 1) {
  throw new Error("gamepad confirm did not activate an overlay action");
}

overlay.isConnected = false;
modalObserver.trigger();
if (api.hasNativeOverlayNavigation(overlay)) {
  throw new Error("removed overlay kept its native navigation tree active");
}
if (!modalTree.controllerUnregistered) {
  throw new Error("removed overlay did not unregister from Steam navigation");
}
if (lowerLeftAction.classList.contains("active-focus")) {
  throw new Error("removed overlay kept its visible focus indicator");
}

api.cleanupNativeStoreNavigation();
for (const element of [
  actionRow,
  protonRow,
  restartAction,
  addAction,
  protonAction,
]) {
  if (!interestTree.unregistered.includes(element)) {
    throw new Error(element.name + " store navigation item was not cleaned up");
  }
}
if (restartAction.classList.contains("active-focus")) {
  throw new Error("cleaned game store action kept its visible focus indicator");
}

console.log("gamepad navigation tests passed");
