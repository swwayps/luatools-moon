const MILLENNIUM_IS_CLIENT_MODULE = false;
const pluginName = "luatools";
function InitializePlugins() {
    var _a, _b;
    (_a = (window.PLUGIN_LIST || (window.PLUGIN_LIST = {})))[pluginName] || (_a[pluginName] = {});
    (_b = (window.MILLENNIUM_PLUGIN_SETTINGS_STORE || (window.MILLENNIUM_PLUGIN_SETTINGS_STORE = {})))[pluginName] || (_b[pluginName] = {});
}
InitializePlugins()
const __call_server_method__ = (methodName, kwargs) => Millennium.callServerMethod(pluginName, methodName, kwargs)
const __wrapped_callable__ = (route) => MILLENNIUM_API.callable(__call_server_method__, route)
let PluginEntryPointMain = function() { var millennium_main=function(e){"use strict";return e.default=async function(){},Object.defineProperty(e,"__esModule",{value:!0}),e}({});
 return millennium_main; };
function ExecutePluginModule() {
    let MillenniumStore = window.MILLENNIUM_PLUGIN_SETTINGS_STORE[pluginName];
    function OnPluginConfigChange() {}
    MillenniumStore.OnPluginConfigChange = OnPluginConfigChange;
    let PluginModule = PluginEntryPointMain();
    Object.assign(window.PLUGIN_LIST[pluginName], {
        ...PluginModule,
        __millennium_internal_plugin_name_do_not_use_or_change__: pluginName,
    });
    PluginModule.default();
    if (MILLENNIUM_IS_CLIENT_MODULE) {
        MILLENNIUM_BACKEND_IPC.postMessage(1, { pluginName: pluginName });
    }
}
ExecutePluginModule()
const MILLENNIUM_IS_CLIENT_MODULE = false;
const pluginName = "steam-db";
function InitializePlugins() {
    var _a, _b;
    /**
     * This function is called n times depending on n plugin count,
     * Create the plugin list if it wasn't already created
     */
    (_a = (window.PLUGIN_LIST || (window.PLUGIN_LIST = {})))[pluginName] || (_a[pluginName] = {});
    (_b = (window.MILLENNIUM_PLUGIN_SETTINGS_STORE || (window.MILLENNIUM_PLUGIN_SETTINGS_STORE = {})))[pluginName] || (_b[pluginName] = {});
    /**
     * Accepted IPC message types from Millennium backend.
     */
    let IPCType;
    (function (IPCType) {
        IPCType[IPCType["CallServerMethod"] = 0] = "CallServerMethod";
    })(IPCType || (IPCType = {}));
    let MillenniumStore = window.MILLENNIUM_PLUGIN_SETTINGS_STORE[pluginName];
    let IPCMessageId = `Millennium.Internal.IPC.[${pluginName}]`;
    let isClientModule = MILLENNIUM_IS_CLIENT_MODULE;
    const ComponentTypeMap = {
        DropDown: ['string', 'number', 'boolean'],
        NumberTextInput: ['number'],
        StringTextInput: ['string'],
        FloatTextInput: ['number'],
        CheckBox: ['boolean'],
        NumberSlider: ['number'],
        FloatSlider: ['number'],
    };
    MillenniumStore.ignoreProxyFlag = false;
    function DelegateToBackend(pluginName, name, value) {
        console.log(`Delegating ${name} to backend`, value);
        // print stack trace
        const stack = new Error().stack?.split('\n').slice(2).join('\n');
        console.log(stack);
        return MILLENNIUM_BACKEND_IPC.postMessage(IPCType.CallServerMethod, {
            pluginName,
            methodName: '__builtins__.__update_settings_value__',
            argumentList: { name, value },
        });
    }
    async function ClientInitializeIPC() {
        /** Wait for the MainWindowBrowser to not be undefined */
        while (typeof MainWindowBrowserManager === 'undefined') {
            await new Promise((resolve) => setTimeout(resolve, 0));
        }
        MainWindowBrowserManager.m_browser.on('message', (messageId, data) => {
            if (messageId !== IPCMessageId) {
                return;
            }
            const { name, value } = JSON.parse(data);
            MillenniumStore.ignoreProxyFlag = true;
            MillenniumStore.settingsStore[name] = value;
            DelegateToBackend(pluginName, name, value);
            MillenniumStore.ignoreProxyFlag = false;
        });
    }
    function WebkitInitializeIPC() {
        SteamClient.BrowserView.RegisterForMessageFromParent((messageId, data) => {
            if (messageId !== IPCMessageId) {
                return;
            }
            const payload = JSON.parse(data);
            MillenniumStore.ignoreProxyFlag = true;
            MillenniumStore.settingsStore[payload.name] = payload.value;
            MillenniumStore.ignoreProxyFlag = false;
        });
    }
    isClientModule ? ClientInitializeIPC() : WebkitInitializeIPC();
    const StartSettingPropagation = (name, value) => {
        if (MillenniumStore.ignoreProxyFlag) {
            return;
        }
        if (isClientModule) {
            DelegateToBackend(pluginName, name, value);
            /** If the browser doesn't exist yet, no use sending anything to it. */
            if (typeof MainWindowBrowserManager !== 'undefined') {
                MainWindowBrowserManager?.m_browser?.PostMessage(IPCMessageId, JSON.stringify({ name, value }));
            }
        }
        else {
            /** Send the message to the SharedJSContext */
            SteamClient.BrowserView.PostMessageToParent(IPCMessageId, JSON.stringify({ name, value }));
        }
    };
    function clamp(value, min, max) {
        return Math.max(min, Math.min(max, value));
    }
    const DefinePluginSetting = (obj) => {
        return new Proxy(obj, {
            set(target, property, value) {
                if (!(property in target)) {
                    throw new TypeError(`Property ${String(property)} does not exist on plugin settings`);
                }
                const settingType = ComponentTypeMap[target[property].type];
                const range = target[property]?.range;
                /** Clamp the value between the given range */
                if (settingType.includes('number') && typeof value === 'number') {
                    if (range) {
                        value = clamp(value, range[0], range[1]);
                    }
                    value || (value = 0); // Fallback to 0 if the value is undefined or null
                }
                /** Check if the value is of the proper type */
                if (!settingType.includes(typeof value)) {
                    throw new TypeError(`Expected ${settingType.join(' or ')}, got ${typeof value}`);
                }
                target[property].value = value;
                StartSettingPropagation(String(property), value);
                return true;
            },
            get(target, property) {
                if (property === '__raw_get_internals__') {
                    return target;
                }
                if (property in target) {
                    return target[property].value;
                }
                return undefined;
            },
        });
    };
    MillenniumStore.DefinePluginSetting = DefinePluginSetting;
    MillenniumStore.settingsStore = DefinePluginSetting({});
}
InitializePlugins()
const __call_server_method__ = (methodName, kwargs) => Millennium.callServerMethod(pluginName, methodName, kwargs)
const __wrapped_callable__ = (route) => MILLENNIUM_API.callable(__call_server_method__, route)
let PluginEntryPointMain = function() { var millennium_main=function(t){"use strict";!function(){const t={};try{if(process)return process.env=Object.assign({},process.env),void Object.assign(process.env,t)}catch(t){}globalThis.process={env:t}}();const e="4.14",s=`https://cdn.jsdelivr.net/gh/SteamDatabase/BrowserExtension@${e}`;function o(t){return t.startsWith("/")?`${s}${t}`:`${s}/${t}`}async function c(t){return new Promise((e,s)=>{const o=document.createElement("script");o.setAttribute("type","text/javascript"),o.setAttribute("src",t),o.addEventListener("load",()=>{e()}),o.addEventListener("error",()=>{s(new Error("Failed to load script"))}),document.head.appendChild(o)})}async function n(t){return new Promise((e,s)=>{const o=document.createElement("link");o.setAttribute("rel","stylesheet"),o.setAttribute("type","text/css"),o.setAttribute("href",t),o.addEventListener("load",()=>{e()}),o.addEventListener("error",()=>{s(new Error("Failed to load style"))}),document.head.appendChild(o)})}const a=__wrapped_callable__("Logger.error"),i=__wrapped_callable__("Logger.warn"),r=(...t)=>{console.error("%c SteamDB plugin ","background: red; color: white",...t),a({message:t.join(" ")})},m=(...t)=>{console.log("%c SteamDB plugin ","background: purple; color: white",...t)},p=(...t)=>{console.warn("%c SteamDB plugin ","background: orange; color: white",...t),i({message:t.join(" ")})};window.steamDBBrowser={runtime:{id:"kdbmhfkmnlmbkgbabkdealhhbfhlmmon",getURL:t=>`${s}/${t}`,sendMessage:async function(t){const e=__wrapped_callable__(t.contentScriptQuery),s=await e(t);return JSON.parse(s)}},storage:{sync:{onChanged:{addListener(t){h.push(t)}},get:async function(t){const e=u(),s={};if(Array.isArray(t))t.forEach(t=>{t in e&&(s[t]=e[t])});else if("object"==typeof t)for(const o in t)s[o]=o in e?e[o]:t[o];return Promise.resolve(s)},set:async function(t){const e=u(),s=Object.keys(t)[0];if(void 0===s)return;return h.forEach(o=>{o({[s]:{oldValue:e[s],newValue:t[s]}})}),Object.assign(e,t),localStorage.setItem(l,JSON.stringify(e)),Promise.resolve()}}},permissions:{request(){},contains:(t,e)=>{e(!0)},onAdded:{addListener(){}},onRemoved:{addListener(){}}},i18n:{getMessage:function(t,s){if("@@bidi_dir"===t)return t;Array.isArray(s)||(s=[s]);const o=JSON.parse(localStorage.getItem(f+e)??"{}");if(null===o||0===Object.keys(o).length)return r("SteamDB lang file not loaded in."),t;const c=o[t];if(void 0===c)return r(`Unknown message key: ${t}`),t;let n=c.message;c.placeholders&&Object.entries(c.placeholders).forEach(([t,e],o)=>{const c=new RegExp(`\\$${t}\\$`,"g");n=n.replace(c,s[o]??e.content)});return n},getUILanguage:()=>"en-US"}};const l="steamdb-options";function u(){const t=localStorage.getItem(l);try{return null!==t?JSON.parse(t):{}}catch{throw new Error(`Failed to parse JSON for key: ${l}`)}}const h=[];const d="steamDB_";let f="";async function y(){const t=navigator.language.replace("-","_"),o=t.split("_")[0]??"en";f=d+o,"es_419"===t&&(f=`${d}es_419`);const c=d+t;if(null===localStorage.getItem(f+e)){if(null!==localStorage.getItem(c+e))return m(`using "${t}" lang`),void(f=c);async function n(t){return fetch(`${s}/_locales/${t}/messages.json`)}m(`fetching "${o}" lang`);let a=await n(o);if(a.ok||(p(`failed to fetch SteamDB lang file for "${o}". Trying "${t}"`),f=c,a=await n(t),a.ok||(p(`failed to fetch SteamDB lang file for "${t}". Falling back to EN.`),f=`${d}en`,a=await n("en"))),!a.ok)throw new Error("Failed to load any language file.");localStorage.setItem(f+e,JSON.stringify(await a.json()))}m(`using "${f.replace(d,"")}" lang`)}const g=document.createElement.bind(document),w=["pcgamingwiki.com"],_=["steamdb.info"];function $(t){const e=new MutationObserver(s=>{s.forEach(s=>{"attributes"===s.type&&"href"===s.attributeName&&(!function(t){w.forEach(e=>{t.href.includes(e)&&(t.href="steam://openurl_external/"+t.href)})}(t),function(t){_.forEach(e=>{t.href.includes(e)&&(t.onclick=e=>{if(e.ctrlKey)return;e.preventDefault();const s=new MouseEvent("click",{bubbles:!0,cancelable:!0,view:window,ctrlKey:!0});t.dispatchEvent(s)})})}(t),e.disconnect())})});e.observe(t,{attributes:!0})}function b(){let t={WEBAPI_BASE_URL:"https://api.steampowered.com/"};for(const e of document.querySelectorAll("script[src]")){const s=new URL(e.src).searchParams.get("l");if(null!==s){t.LANGUAGE=s;break}}const e=document.querySelector(".profile_small_header_additional .gameLogo img")?.src;if(void 0===e)return;const s=e.lastIndexOf("/apps/");s>0&&(t.STORE_ICON_BASE_URL=e.substring(0,s+6));for(const e of document.querySelectorAll(".achieveImgHolder > img")){const s=e.src.lastIndexOf("/images/apps/");if(s>0){t.MEDIA_CDN_COMMUNITY_URL=e.src.substring(0,s+1);break}}t={...t,COUNTRY:navigator.language.split("-")[1],STORE_ITEM_BASE_URL:"https://shared.fastly.steamstatic.com/store_item_assets/"};const o=document.createElement("div");o.id="application_config",o.dataset.config=JSON.stringify(t),o.dataset.loyalty_webapi_token="false",document.body.appendChild(o)}function v(){const t=document.querySelector(".two_column.left"),e=document.querySelector(".two_column.right");if(!t||!e)return;const a=document.createElement("div");a.setAttribute("id","steamdb-options"),a.classList.add("nav_item"),a.innerHTML=`<img class="ico16" src="${s}/icons/white.svg" alt="logo"> <span>SteamDB Options</span>`,t.appendChild(a),a.addEventListener("click",async()=>async function(t,e,a){t.querySelectorAll(".active").forEach(t=>{t.classList.remove("active")}),e.classList.toggle("active");const i=new URL(window.location.href);i.search="",i.searchParams.set("steamdb","true"),window.history.replaceState({},"",i.href),a.innerHTML=await(await fetch(`${s}/options/options.html`)).text(),await Promise.all([n(o("/options/options.css")),c(o("/options/options.js"))]);const r=document.createElement("div");r.onclick=()=>{window.confirm("Are you sure you want to reset all options?")&&(localStorage.removeItem(l),window.location.reload())},r.classList.add("store_header_btn"),r.classList.add("store_header_btn_gray"),r.style.position="fixed",r.style.bottom="1em",r.style.right="1em",r.style.cursor="pointer";const m=document.createElement("span");m.dataset.tooltipText="Will reset all options to their default values.",m.innerText="Reset options!",m.style.margin="1em",r.appendChild(m),a.appendChild(r)}(t,a,e));"true"===new URL(window.location.href).searchParams.get("steamdb")&&a.click()}async function j(t){const e=[];for(const s of t.filter(t=>t.includes(".css")))e.push(n(o(s)));await Promise.all(e)}async function k(){let t=await(await fetch(o("scripts/common.min.js"))).text();t=t.replaceAll("browser","steamDBBrowser"),function(t){const e=document.createElement("script");e.setAttribute("type","text/javascript"),e.innerHTML=t,document.head.appendChild(e)}(t)}document.createElement=function(t,e){const s=g(t,e);return"a"===t.toLowerCase()&&$(s),s};const E=[/steamcommunity\.com\/stats\//,/steamcommunity\.com\/id\/.+?\/stats\//];return t.default=async function(){const t=window.location.href;if(!t.includes("https://store.steampowered.com")&&!t.includes("https://steamcommunity.com"))return;m("plugin is running");const e=function(){const t=window.location.href,e=[];return t.match(/^https:\/\/store\.steampowered\.com\/app\/.*$/)&&(e.push("scripts/store/app_error.js"),e.push("scripts/store/app.js"),e.push("scripts/store/app_images.js")),t.match(/^https:\/\/store\.steampowered\.com\/news\/app\/.*$/)&&(e.push("scripts/store/app_error.js"),e.push("scripts/store/app_news.js")),t.match(/^https:\/\/store\.steampowered\.com\/account\/licenses.*$/)&&(e.push("scripts/store/account_licenses.js"),e.push("styles/account_licenses.css")),t.match(/^https:\/\/store\.steampowered\.com\/account\/registerkey.*$/)&&e.push("scripts/store/registerkey.js"),t.match(/^https:\/\/store\.steampowered\.com\/sub\/.*$/)&&e.push("scripts/store/sub.js"),t.match(/^https:\/\/store\.steampowered\.com\/bundle\/.*$/)&&e.push("scripts/store/bundle.js"),t.match(/^https:\/\/store\.steampowered\.com\/widget\/.*$/)&&e.push("scripts/store/widget.js"),(t.match(/^https:\/\/store\.steampowered\.com\/app\/.*\/agecheck$/)||t.match(/^https:\/\/store\.steampowered\.com\/agecheck\/.*$/))&&(e.push("scripts/store/app_error.js"),e.push("scripts/store/agecheck.js")),t.match(/^https:\/\/store\.steampowered\.com\/explore.*$/)&&e.push("scripts/store/explore.js"),(t.match(/^https:\/\/store\.steampowered\.com\/app\/.*$/)||t.match(/^https:\/\/steamcommunity\.com\/app\/.*$/)||t.match(/^https:\/\/steamcommunity\.com\/sharedfiles\/filedetails.*$/)||t.match(/^https:\/\/steamcommunity\.com\/workshop\/filedetails.*$/)||t.match(/^https:\/\/steamcommunity\.com\/workshop\/browse.*$/)||t.match(/^https:\/\/steamcommunity\.com\/workshop\/discussions.*$/))&&e.push("scripts/appicon.js"),(t.match(/^https:\/\/steamcommunity\.com\/id\/.*$/)||t.match(/^https:\/\/steamcommunity\.com\/profiles\/.*$/))&&e.push("scripts/community/profile.js"),(t.match(/^https:\/\/steamcommunity\.com\/id\/.*\/inventory.*$/)||t.match(/^https:\/\/steamcommunity\.com\/profiles\/.*\/inventory.*$/))&&(e.push("scripts/community/profile_inventory.js"),e.push("styles/inventory.css")),(t.match(/^https:\/\/steamcommunity\.com\/id\/.*\/stats.*$/)||t.match(/^https:\/\/steamcommunity\.com\/profiles\/.*\/stats.*$/))&&(e.push("scripts/community/achievements.js"),e.push("scripts/community/achievements_profile.js"),e.push("styles/achievements.css")),(t.match(/^https:\/\/steamcommunity\.com\/id\/.*\/stats\/CSGO.*$/)||t.match(/^https:\/\/steamcommunity\.com\/profiles\/.*\/stats\/CSGO.*$/))&&(e.push("scripts/community/achievements_cs2.js"),e.push("styles/achievements_cs2.css")),t.match(/^https:\/\/steamcommunity\.com\/stats\/.*\/achievements.*$/)&&(e.push("scripts/community/achievements.js"),e.push("scripts/community/achievements_global.js"),e.push("styles/achievements.css")),t.match(/^https:\/\/steamcommunity\.com\/tradeoffer\/.*$/)&&!t.match(/^https:\/\/steamcommunity\.com\/tradeoffer\/.*\/confirm.*$/)&&e.push("scripts/community/tradeoffer.js"),(t.match(/^https:\/\/steamcommunity\.com\/id\/.*\/recommended\/.*$/)||t.match(/^https:\/\/steamcommunity\.com\/profiles\/.*\/recommended\/.*$/))&&e.push("scripts/community/profile_recommended.js"),(t.match(/^https:\/\/steamcommunity\.com\/id\/.*\/badges.*$/)||t.match(/^https:\/\/steamcommunity\.com\/profiles\/.*\/badges.*$/))&&e.push("scripts/community/profile_badges.js"),(t.match(/^https:\/\/steamcommunity\.com\/id\/.*\/gamecards\/.*$/)||t.match(/^https:\/\/steamcommunity\.com\/profiles\/.*\/gamecards\/.*$/))&&e.push("scripts/community/profile_gamecards.js"),(t.match(/^https:\/\/steamcommunity\.com\/app\/.*$/)||t.match(/^https:\/\/steamcommunity\.com\/sharedfiles\/filedetails.*$/)||t.match(/^https:\/\/steamcommunity\.com\/workshop\/filedetails.*$/)||t.match(/^https:\/\/steamcommunity\.com\/workshop\/browse.*$/)||t.match(/^https:\/\/steamcommunity\.com\/workshop\/discussions.*$/))&&e.push("scripts/community/gamehub.js"),(t.match(/^https:\/\/steamcommunity\.com\/sharedfiles\/filedetails.*$/)||t.match(/^https:\/\/steamcommunity\.com\/workshop\/filedetails.*$/))&&(e.push("scripts/community/filedetails.js"),e.push("scripts/community/filedetails_guide.js")),t.match(/^https:\/\/steamcommunity\.com\/market\/multibuy.*$/)&&e.push("scripts/community/multibuy.js"),t.match(/^https:\/\/steamcommunity\.com\/market\/.*$/)&&(e.push("scripts/community/market.js"),e.push("styles/market.css")),(t.match(/^https:\/\/steamcommunity\.com\/app\/.*$/)||t.match(/^https:\/\/steamcommunity\.com\/games\/.*$/)||t.match(/^https:\/\/steamcommunity\.com\/sharedfiles\/.*$/)||t.match(/^https:\/\/steamcommunity\.com\/workshop\/.*$/))&&e.push("scripts/community/agecheck.js"),(t.match(/^https:\/\/steamcommunity\.com\/market\/.*$/)||t.match(/^https:\/\/steamcommunity\.com\/id\/.*\/inventory.*$/)||t.match(/^https:\/\/steamcommunity\.com\/profiles\/.*\/inventory.*$/))&&e.push("scripts/community/market_ssa.js"),e}();await Promise.all([k(),y(),j(e)]),await c(o("scripts/global.min.js"));for(const e of E)if(e.test(t)){b();break}await async function(t){const e=t.filter(t=>t.includes(".js"));for(const t of e)await c(o(t.replace(".js",".min.js")))}(e),function(){const t=document.evaluate('//a[contains(@class, "popup_menu_item") and contains(text(), "Preferences")]',document,null,XPathResult.FIRST_ORDERED_NODE_TYPE,null).singleNodeValue;if(null!==t){const e=t.cloneNode();e.href+="&steamdb=true",e.innerHTML=`\n            <img class="ico16" style="background: none" src="${o("/icons/white.svg")}" alt="logo">\n            <span>${window.steamDBBrowser.i18n.getMessage("steamdb_options")}</span>\n        `,t.after(e)}}(),window.location.href.includes("https://store.steampowered.com/account")&&v()},Object.defineProperty(t,"__esModule",{value:!0}),t}({},window.MILLENNIUM_API);
 return millennium_main; };
function ExecutePluginModule() {
    let MillenniumStore = window.MILLENNIUM_PLUGIN_SETTINGS_STORE[pluginName];
    function OnPluginConfigChange(key, __, value) {
        if (key in MillenniumStore.settingsStore) {
            MillenniumStore.ignoreProxyFlag = true;
            MillenniumStore.settingsStore[key] = value;
            MillenniumStore.ignoreProxyFlag = false;
        }
    }
    /** Expose the OnPluginConfigChange so it can be called externally */
    MillenniumStore.OnPluginConfigChange = OnPluginConfigChange;
    MILLENNIUM_BACKEND_IPC.postMessage(0, { pluginName: pluginName, methodName: '__builtins__.__millennium_plugin_settings_parser__' }).then((response) => {
        /**
         * __millennium_plugin_settings_parser__ will return false if the plugin has no settings.
         * If the plugin has settings, it will return a base64 encoded string.
         * The string is then decoded and parsed into an object.
         */
        if (typeof response.returnValue === 'string') {
            MillenniumStore.ignoreProxyFlag = true;
            /** Initialize the settings store from the settings returned from the backend. */
            MillenniumStore.settingsStore = MillenniumStore.DefinePluginSetting(Object.fromEntries(JSON.parse(atob(response.returnValue)).map((item) => [item.functionName, item])));
            MillenniumStore.ignoreProxyFlag = false;
        }
        /** @ts-ignore: call the plugin main after the settings have been parsed. This prevent plugin settings from being undefined at top level. */
        let PluginModule = PluginEntryPointMain();
        /** Assign the plugin on plugin list. */
        Object.assign(window.PLUGIN_LIST[pluginName], {
            ...PluginModule,
            __millennium_internal_plugin_name_do_not_use_or_change__: pluginName,
        });
        /** Run the rolled up plugins default exported function */
        PluginModule.default();
        /** If the current module is a client module, post message id=1 which calls the front_end_loaded method on the backend. */
        if (MILLENNIUM_IS_CLIENT_MODULE) {
            MILLENNIUM_BACKEND_IPC.postMessage(1, { pluginName: pluginName });
        }
    });
}
ExecutePluginModule()