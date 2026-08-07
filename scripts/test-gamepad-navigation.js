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
    this.attributes = {};
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
    if (child.parentElement) {
      const previousIndex = child.parentElement.children.indexOf(child);
      if (previousIndex >= 0) child.parentElement.children.splice(previousIndex, 1);
    }
    child.parentElement = this;
    child.isConnected = this.isConnected;
    this.children.push(child);
    return child;
  }

  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }

  getAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this.attributes, name)
      ? this.attributes[name]
      : null;
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
restartAction.id = "native-reference-id";
addAction.id = "native-reference-id";
protonAction.id = "native-reference-id";
restartAction.setAttribute("data-luatools-focus-key", "restart");
addAction.setAttribute("data-luatools-focus-key", "add");
protonAction.setAttribute("data-luatools-focus-key", "proton");

restartAction.rect = { left: 100, right: 250, top: 100, bottom: 140, width: 150, height: 40 };
addAction.rect = { left: 260, right: 410, top: 100, bottom: 140, width: 150, height: 40 };
followAction.rect = { left: 100, right: 250, top: 160, bottom: 200, width: 150, height: 40 };
ignoreAction.rect = { left: 260, right: 410, top: 160, bottom: 200, width: 150, height: 40 };
protonAction.rect = { left: 100, right: 410, top: 220, bottom: 260, width: 310, height: 40 };

interestRoot.appendChild(interestColumn);
// Steam's native row already exists; option A appends both LuaTools rows after it.
interestColumn.appendChild(nativeFollowRowElement);
interestColumn.appendChild(actionRow);
interestColumn.appendChild(protonRow);
actionRow.appendChild(restartAction);
actionRow.appendChild(addAction);
nativeFollowRowElement.appendChild(followAction);
nativeFollowRowElement.appendChild(ignoreAction);
protonRow.appendChild(protonAction);
let actionButtons = [restartAction, addAction];
actionRow.querySelectorAll = () => actionButtons;
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
  `${block}\nreturn { registerNativeHeaderNavigation, cleanupNativeHeaderNavigation, registerNativeStoreNavigation, cleanupNativeStoreNavigation, registerNativeOverlayNavigation, cleanupNativeOverlayNavigation, hasNativeOverlayNavigation, normalizeBigPictureStoreRows, reconcileBigPictureStoreRows, getMutationProcessingDelay, getMutationProcessingDeadline, hasPendingStoreRegistration: hasPendingNativeStoreRegistration, captureStoreFocus: captureNativeStoreFocus };`,
);
const scheduledRetries = [];
const canceledTimers = new Set();
let nextTimerId = 1;
const gamepadWindow = {
  FocusNavController: controller,
  getComputedStyle: (element) => element.style,
  setTimeout: (callback, delay) => {
    const id = nextTimerId++;
    scheduledRetries.push({ id, callback, delay });
    return id;
  },
  clearTimeout: (id) => canceledTimers.add(id),
};
const runNextScheduledRetry = () => {
  while (scheduledRetries.length > 0) {
    const retry = scheduledRetries.shift();
    if (!canceledTimers.has(retry.id)) {
      retry.callback();
      return retry;
    }
  }
  return null;
};
const api = factory(
  gamepadWindow,
  { documentElement: new FakeElement("document") },
  FakeMutationObserver,
);

if (typeof api.normalizeBigPictureStoreRows !== "function") {
  throw new Error("store row normalization helper is missing");
}
if (typeof api.getMutationProcessingDelay !== "function") {
  throw new Error("mutation processing delay helper is missing");
}
if (typeof api.captureStoreFocus !== "function") {
  throw new Error("store focus capture helper is missing");
}
if (api.getMutationProcessingDelay(1000, 900, 1000) !== 1200) {
  throw new Error("throttled mutation did not schedule a trailing pass");
}
if (api.getMutationProcessingDelay(2000, 0, 1000) !== 300) {
  throw new Error("unthrottled mutation did not retain debounce delay");
}
if (typeof api.getMutationProcessingDeadline !== "function") {
  throw new Error("mutation processing deadline helper is missing");
}
if (api.getMutationProcessingDeadline(1000, 0, 300) !== 1300) {
  throw new Error("mutation processing deadline was not initialized");
}
if (api.getMutationProcessingDeadline(1100, 1300, 300) !== 1300) {
  throw new Error("mutation processing deadline was extended by a burst");
}
interestColumn.appendChild(actionRow);
if (
  interestColumn.children[0] !== nativeFollowRowElement ||
  interestColumn.children[1] !== protonRow ||
  interestColumn.children[2] !== actionRow
) {
  throw new Error("fake appendChild does not model moving an existing row");
}
if (!api.normalizeBigPictureStoreRows(interestColumn, actionRow, protonRow)) {
  throw new Error("store row normalization did not detect reordered rows");
}
if (
  interestColumn.children[0] !== nativeFollowRowElement ||
  interestColumn.children[1] !== actionRow ||
  interestColumn.children[2] !== protonRow
) {
  throw new Error("store row normalization did not restore native order");
}
if (api.normalizeBigPictureStoreRows(interestColumn, actionRow, protonRow)) {
  throw new Error("already normalized store rows were moved unnecessarily");
}
const lateNativeRowElement = new FakeElement("late-native-row");
interestColumn.appendChild(lateNativeRowElement);
if (!api.normalizeBigPictureStoreRows(interestColumn, actionRow, protonRow)) {
  throw new Error("store row normalization ignored a later native row");
}
if (
  interestColumn.children[interestColumn.children.length - 3] !==
    lateNativeRowElement ||
  interestColumn.children[interestColumn.children.length - 2] !== actionRow ||
  interestColumn.children[interestColumn.children.length - 1] !== protonRow
) {
  throw new Error("store rows were not restored after a later native row");
}
const registrationEvents = [];
const fakeGamepadNav = {
  cleanupStoreRows: () => registrationEvents.push("cleanup"),
  registerStoreRows: (rows) => registrationEvents.push(["register", rows]),
};
interestColumn.appendChild(lateNativeRowElement);
if (
  !api.reconcileBigPictureStoreRows(
    interestColumn,
    actionRow,
    protonRow,
    fakeGamepadNav,
  )
) {
  throw new Error("store row reconciliation did not detect a moved native row");
}
if (
  registrationEvents.length !== 2 ||
  registrationEvents[0] !== "cleanup" ||
  registrationEvents[1][0] !== "register"
) {
  throw new Error("store row reconciliation did not rebuild native focus registration");
}
if (
  api.reconcileBigPictureStoreRows(
    interestColumn,
    actionRow,
    protonRow,
    fakeGamepadNav,
  )
) {
  throw new Error("normalized store rows triggered unnecessary focus rebuilding");
}
if (registrationEvents.length !== 2) {
  throw new Error("normalized store rows changed focus registration");
}
if (api.hasPendingStoreRegistration()) {
  throw new Error("successful store registration remained pending");
}

let retryAttempts = 0;
const retryGamepadNav = {
  cleanupStoreRows: () => {},
  registerStoreRows: () => {
    retryAttempts += 1;
    return retryAttempts > 1;
  },
};
interestColumn.appendChild(lateNativeRowElement);
if (
  api.reconcileBigPictureStoreRows(
    interestColumn,
    actionRow,
    protonRow,
    retryGamepadNav,
  )
) {
  throw new Error("failed store registration was reported as successful");
}
if (!api.hasPendingStoreRegistration()) {
  throw new Error("failed store registration did not remain pending");
}
if (
  !api.reconcileBigPictureStoreRows(
    interestColumn,
    actionRow,
    protonRow,
    retryGamepadNav,
  )
) {
  throw new Error("pending store registration was not retried successfully");
}
if (retryAttempts !== 2 || api.hasPendingStoreRegistration()) {
  throw new Error("successful store registration did not clear pending state");
}

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
for (const rowEntry of [actionRowEntry, protonRowEntry]) {
  if (
    typeof rowEntry.node.properties.onMoveUp === "function" ||
    typeof rowEntry.node.properties.onMoveDown === "function"
  ) {
    throw new Error("LuaTools store rows still override Steam vertical navigation");
  }
}
const storeRowOrder = interestColumnNode.m_rgChildren;
if (
  storeRowOrder[0] !== nativeFollowRowNode ||
  storeRowOrder[1] !== actionRowEntry.node ||
  storeRowOrder[2] !== protonRowEntry.node
) {
  throw new Error("LuaTools rows are not ordered after native store rows");
}

const addEntry = interestTree.registered.find(
  (entry) => entry.element === addAction,
);
addEntry.node.BTakeFocus(0, 10);
if (!addEntry.node.focused || interestColumnNode.m_ActiveChild !== actionRowEntry.node) {
  throw new Error("Add via LuaTools did not receive native focus in its row");
}
const nativeGamepadNav = {
  cleanupStoreRows: api.cleanupNativeStoreNavigation,
  registerStoreRows: api.registerNativeStoreNavigation,
};
interestColumn.appendChild(nativeFollowRowElement);
if (
  !api.reconcileBigPictureStoreRows(
    interestColumn,
    actionRow,
    protonRow,
    nativeGamepadNav,
  )
) {
  throw new Error("native row reorder was not reconciled");
}
const restoredAddEntry = interestTree.registered
  .filter((entry) => entry.element === addAction)
  .at(-1);
if (!restoredAddEntry || !restoredAddEntry.node.focused) {
  throw new Error("store row reconciliation lost the focused LuaTools action");
}
if (api.captureStoreFocus() !== addAction) {
  throw new Error("store focus capture did not identify the focused action");
}
restoredAddEntry.node.focused = false;

const rerenderedAddAction = new FakeElement("add-via-luatools-rerender", "BUTTON");
rerenderedAddAction.id = addAction.id;
rerenderedAddAction.setAttribute(
  "data-luatools-focus-key",
  addAction.getAttribute("data-luatools-focus-key"),
);
rerenderedAddAction.rect = addAction.rect;
rerenderedAddAction.parentElement = actionRow;
addAction.isConnected = false;
addAction.parentElement = null;
actionRow.children[1] = rerenderedAddAction;
actionButtons = [restartAction, rerenderedAddAction];
if (!api.registerNativeStoreNavigation([actionRow, protonRow])) {
  throw new Error("store navigation did not register after a button rerender");
}
const rerenderedAddEntry = interestTree.registered
  .filter((entry) => entry.element === rerenderedAddAction)
  .at(-1);
if (!rerenderedAddEntry || !rerenderedAddEntry.node.focused) {
  throw new Error("store button rerender lost the focused LuaTools action");
}

api.cleanupNativeStoreNavigation();
context.m_rgGamepadNavigationTrees.delete(interestTree);
if (api.registerNativeStoreNavigation([actionRow, protonRow])) {
  throw new Error("store registration succeeded without an owner tree");
}
if (!api.hasPendingStoreRegistration()) {
  throw new Error("direct store registration failure did not remain pending");
}
context.m_rgGamepadNavigationTrees.add(interestTree);
const directRetry = runNextScheduledRetry();
if (!directRetry || directRetry.delay !== 300) {
  throw new Error("direct store registration failure did not schedule a retry");
}
if (api.hasPendingStoreRegistration()) {
  throw new Error("successful direct store retry remained pending");
}

protonRow.isConnected = false;
if (api.registerNativeStoreNavigation([actionRow, protonRow])) {
  throw new Error("partial store rows were registered as complete");
}
if (!api.hasPendingStoreRegistration()) {
  throw new Error("partial store registration did not remain pending");
}
protonRow.isConnected = true;
const partialRetry = runNextScheduledRetry();
if (!partialRetry || api.hasPendingStoreRegistration()) {
  throw new Error("partial store registration was not retried after reinsertion");
}

api.cleanupNativeStoreNavigation();
context.m_rgGamepadNavigationTrees.delete(interestTree);
if (api.registerNativeStoreNavigation([actionRow, protonRow])) {
  throw new Error("persistent store registration failure succeeded");
}
let persistentRetryCount = 0;
while (scheduledRetries.length > 0) {
  const retry = runNextScheduledRetry();
  if (!retry) break;
  persistentRetryCount += 1;
  if (persistentRetryCount > 8) {
    throw new Error("store registration retry limit was not enforced");
  }
}
if (persistentRetryCount !== 8 || !api.hasPendingStoreRegistration()) {
  throw new Error("store registration did not exhaust the bounded retry window");
}
context.m_rgGamepadNavigationTrees.add(interestTree);
if (
  !api.reconcileBigPictureStoreRows(
    interestColumn,
    actionRow,
    protonRow,
    nativeGamepadNav,
  )
) {
  throw new Error("bounded store retry state was not recoverable");
}

const storeRemovalObserver = FakeMutationObserver.instances
  .filter((observer) => observer.target === interestColumn)
  .at(-1);
if (!storeRemovalObserver) {
  throw new Error("store navigation did not install its removal observer");
}
actionRow.isConnected = false;
storeRemovalObserver.trigger();
if (!api.hasPendingStoreRegistration()) {
  throw new Error("store removal did not schedule registration retry");
}
actionRow.isConnected = true;
const removalRetry = runNextScheduledRetry();
if (!removalRetry || removalRetry.delay !== 300) {
  throw new Error("store removal did not schedule a retry callback");
}
if (api.hasPendingStoreRegistration()) {
  throw new Error("store reinsertion retry remained pending");
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
