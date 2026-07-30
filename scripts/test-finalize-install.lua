#!/usr/bin/env luajit
local merge = dofile("plugin/backend/smart_merge.lua")
local fails = 0
local function check(name, cond)
  if cond then print("ok   - " .. name) else print("FAIL - " .. name); fails = fails + 1 end
end

local function u32(n)
  local b1=n%256; n=math.floor(n/256); local b2=n%256; n=math.floor(n/256)
  local b3=n%256; n=math.floor(n/256); return string.char(b1,b2,b3,n%256)
end
local function divdec(text, divisor)
  local out, carry = {}, 0
  for digit in text:gmatch("%d") do
    local value=carry*10+tonumber(digit); local q=math.floor(value/divisor); carry=value%divisor
    if #out>0 or q>0 then out[#out+1]=tostring(q) end
  end
  return #out==0 and "0" or table.concat(out), carry
end
local function varint(value)
  local out, text = {}, tostring(value)
  repeat
    local quotient, remainder = divdec(text,128)
    out[#out+1]=string.char(remainder+(quotient~="0" and 128 or 0)); text=quotient
  until text=="0"
  return table.concat(out)
end
local function manifest(depot,gid,created)
  local meta=string.char(8)..varint(depot)..string.char(16)..varint(gid)..string.char(24)..varint(created)
  return u32(0x71F617D0)..u32(0)..u32(0x1F4812BE)..u32(#meta)..meta
end

local function harness(initial)
  local files, dirs = {}, {}
  for path, content in pairs(initial or {}) do files[path]=content end
  local fail_destination, crash_destination
  local function list_recursive(root)
    local out={}
    for path in pairs(files) do
      if path:sub(1,#root+1)==root.."/" then
        out[#out+1]={name=path:match("[^/]+$"),path=path,is_directory=false}
      end
    end
    table.sort(out,function(a,b) return a.path<b.path end); return out
  end
  local opts={home="/home/test",steam_root="/steam",read_file=function(p) return files[p] end,
    write_file=function(p,c) files[p]=c; return true end,exists=function(p) return files[p]~=nil or dirs[p] end,
    list_recursive=list_recursive,mkdir=function(p) dirs[p]=true; return true end,
    remove=function(p) files[p]=nil; return true end,
    rename=function(src,dst)
      if dst==crash_destination then crash_destination=nil; error("simulated process death") end
      if dst==fail_destination then fail_destination=nil; return false end
      if files[src]==nil then return false end; files[dst]=files[src]; files[src]=nil; return true
    end}
  return files,opts,function(path) fail_destination=path end,
    function(path) crash_destination=path end
end
local APP=250900; local G11="3238948344654627795"; local G12="9223372036854770000"
local K1=string.rep("a",64); local K2=string.rep("b",64); local KX=string.rep("c",64)
local root="/collect"
local files,opts,fail_on=harness({
  [root.."/source_0000/.source-name"]="Hubcap", [root.."/source_0000/.source-priority"]="0\n",
  [root.."/source_0000/"..APP..".lua"]='addappid('..APP..')\naddappid(11,1,"'..K1..'")\n',
  [root.."/source_0000/11_"..G11..".manifest"]=manifest(11,G11,100),
  [root.."/source_0001/.source-name"]="Ryuu", [root.."/source_0001/.source-priority"]="1\n",
  [root.."/source_0001/"..APP..".lua"]='addappid(11,1,"'..KX..'")\naddappid(12,1,"'..K2..'")\n',
  [root.."/source_0001/12_"..G12..".manifest"]=manifest(12,G12,200),
  [root.."/source_0001/99_1.manifest"]="bad",
})
opts.appinfo_text='"appinfo" { "depots" { "11" { "manifests" { "public" { "gid" "'..G11..'" } } } } }'
local preview,preview_err=merge.preview(APP,root,opts)
check("preview validates without publishing",preview~=nil and preview_err==nil
  and files["/steam/config/stplug-in/"..APP..".lua"]==nil)
check("preview exposes source contributors",preview and preview.contributors[1]=="Hubcap"
  and preview.contributors[2]=="Ryuu")
check("preview exposes editable keys",preview and preview.depots[1].key==K1
  and preview.depots[2].key==K2)
check("preview pre-fills gid only from a real package manifest",preview
  and preview.depots[1].gid==G11 and preview.depots[1].has_manifest==true)
local installed,err=merge.install(APP,root,opts)
check("transaction installs merged result",installed~=nil and err==nil)
local target=files["/steam/config/stplug-in/"..APP..".lua"] or ""
check("exact-current source resolves conflict",target:find(K1,1,true)~=nil and target:find(KX,1,true)==nil)
check("complementary key included",target:find(K2,1,true)~=nil)
check("windows manifest archived",files["/home/test/.config/SLSsteam/manifests/11_"..G11..".manifest"]~=nil)
check("linux manifest archived",files["/home/test/.config/SLSsteam/manifests/12_"..G12..".manifest"]~=nil)
check("invalid manifest rejected",files["/home/test/.config/SLSsteam/manifests/99_1.manifest"]==nil)
check("nothing written to depotcache",files["/steam/depotcache/11_"..G11..".manifest"]==nil)
check("exact gid marked preferred",files["/home/test/.config/SLSsteam/manifests/.preferred_11"]==G11.."\n")
check("conflict recorded without prompt",#installed.conflicts==1)

local edited_files,edited_opts=harness({
  ["/home/test/.config/SLSsteam/config.yaml"]="AdditionalApps:\nManifestPins:\n  "..APP..":\n    locked: true\n    depots:\n      11: \"old\"\nLogLevel: 2\n",
  ["/home/test/.config/SLSsteam/lumen_lua_imports.txt"]="123\n",
  [root.."/source_0000/.source-name"]="Hubcap", [root.."/source_0000/.source-priority"]="0\n",
  [root.."/source_0000/"..APP..".lua"]='addappid('..APP..')\naddappid(11,1,"'..K1..'")\n',
  [root.."/source_0000/11_"..G11..".manifest"]=manifest(11,G11,100),
})
edited_opts.sync_pins=true
edited_opts.config_path="/home/test/.config/SLSsteam/config.yaml"
edited_opts.imports_path="/home/test/.config/SLSsteam/lumen_lua_imports.txt"
local edited_result,edited_err=merge.commit(APP,root,{
  dlc_appids={401920}, depots={
    {depot=11,key=K1,gid=""},
    {depot=12,key=K2,gid=G12},
  },
},edited_opts)
local edited_lua=edited_files["/steam/config/stplug-in/"..APP..".lua"] or ""
check("edited commit publishes only after confirmation",edited_result~=nil and edited_err==nil)
check("edited commit keeps a user-entered gid without a local manifest",
  edited_lua:find('setManifestid(12, "'..G12..'")',1,true)~=nil)
check("cleared packaged gid means latest",edited_lua:find("setManifestid(11",1,true)==nil)
check("edited commit retains downloaded manifest archive",
  edited_files["/home/test/.config/SLSsteam/manifests/11_"..G11..".manifest"]~=nil)
local edited_config=edited_files[edited_opts.config_path] or ""
check("edited commit synchronizes ManifestPins in the same transaction",
  edited_config:find('12: "'..G12..'"',1,true)~=nil
  and edited_config:find('11: "old"',1,true)==nil)
check("edited commit marks the source-created game in the same transaction",
  (edited_files[edited_opts.imports_path] or ""):find(tostring(APP),1,true)~=nil)

local oldlua='addappid('..APP..')\n-- old\n'
local empty_files,empty_opts=harness({["/steam/config/stplug-in/"..APP..".lua"]=oldlua,
  [root.."/source_0000/.source-name"]="Empty",[root.."/source_0000/.source-priority"]="0",
  [root.."/source_0000/11_"..G11..".manifest"]=manifest(11,G11,100)})
local no_result=merge.install(APP,root,empty_opts)
check("missing source lua fails",no_result==nil)
check("old target cannot mask failed collection",empty_files["/steam/config/stplug-in/"..APP..".lua"]==oldlua)
check("failed collection publishes no manifest",empty_files["/home/test/.config/SLSsteam/manifests/11_"..G11..".manifest"]==nil)

local garbage_files,garbage_opts=harness({
  [root.."/source_0000/.source-name"]="Broken",
  [root.."/source_0000/.source-priority"]="0",
  [root.."/source_0000/"..APP..".lua"]='<html>temporary upstream error</html>',
  [root.."/source_0000/11_"..G11..".manifest"]=manifest(11,G11,100),
})
local garbage_result=merge.install(APP,root,garbage_opts)
check("unrecognized lua cannot produce success",garbage_result==nil and
  garbage_files["/steam/config/stplug-in/"..APP..".lua"]==nil)

local no_manifest_files,no_manifest_opts=harness({
  [root.."/source_0000/.source-name"]="Keys only",
  [root.."/source_0000/.source-priority"]="0",
  [root.."/source_0000/"..APP..".lua"]='addappid('..APP..')\naddappid(11,1,"'..K1..'")\n',
})
local lua_only_result=merge.install(APP,root,no_manifest_opts)
check("valid lua without manifests is accepted",lua_only_result~=nil and
  (no_manifest_files["/steam/config/stplug-in/"..APP..".lua"] or ""):find(K1,1,true)~=nil and
  lua_only_result.manifest_count==0)

local partial_files,partial_opts=harness({
  [root.."/source_0000/.source-name"]="Partial",
  [root.."/source_0000/.source-priority"]="0",
  [root.."/source_0000/"..APP..".lua"]='addappid('..APP..')\naddappid(11,1,"'..K1..'")\n'
    ..'setManifestid(11,"'..G11..'")\naddappid(12,1,"'..K2..'")\n'
    ..'setManifestid(12,"'..G12..'")\n',
  [root.."/source_0000/11_"..G11..".manifest"]=manifest(11,G11,100),
})
local partial_result=merge.install(APP,root,partial_opts)
check("lua remains valid when referenced manifests are unavailable",partial_result~=nil and
  (partial_files["/steam/config/stplug-in/"..APP..".lua"] or ""):find(K2,1,true)~=nil)

local dlc_only_files,dlc_only_opts=harness({
  [root.."/source_0000/.source-name"]="DLC only",
  [root.."/source_0000/.source-priority"]="0",
  [root.."/source_0000/"..APP..".lua"]='addappid('..APP..')\naddappid(12,1,"'..K2..'")\n',
})
dlc_only_opts.appinfo_text='"appinfo" { "depots" {'
  ..' "11" { "config" { "oslist" "windows" }'
  ..' "manifests" { "public" { "gid" "'..G11..'" } } }'
  ..' "12" { "config" { "oslist" "windows" } "dlcappid" "1200"'
  ..' "manifests" { "public" { "gid" "'..G12..'" } } }'
  ..'} }'
local dlc_only_result,dlc_only_error=merge.install(APP,root,dlc_only_opts)
check("DLC-only key set cannot masquerade as a usable base game",
  dlc_only_result==nil and dlc_only_error=="no_usable_base_key"
  and dlc_only_files["/steam/config/stplug-in/"..APP..".lua"]==nil)

local rollback_files,rollback_opts,set_fail=harness({
  ["/steam/config/stplug-in/"..APP..".lua"]=oldlua,
  ["/home/test/.config/SLSsteam/config.yaml"]="ManifestPins:\n  "..APP..":\n    locked: true\n    depots:\n      11: \"old\"\n",
  ["/home/test/.config/SLSsteam/lumen_lua_imports.txt"]="123\n",
  ["/home/test/.config/SLSsteam/manifests/11_"..G11..".manifest"]="old-manifest",
  [root.."/source_0000/.source-name"]="Hubcap",[root.."/source_0000/.source-priority"]="0",
  [root.."/source_0000/"..APP..".lua"]='addappid('..APP..')\naddappid(11,1,"'..K1..'")\n',
  [root.."/source_0000/11_"..G11..".manifest"]=manifest(11,G11,100),
})
rollback_opts.sync_pins=true
rollback_opts.config_path="/home/test/.config/SLSsteam/config.yaml"
rollback_opts.imports_path="/home/test/.config/SLSsteam/lumen_lua_imports.txt"
local old_config=rollback_files[rollback_opts.config_path]
set_fail(rollback_opts.config_path)
local rolled=merge.install(APP,root,rollback_opts)
check("publication failure reports failure",rolled==nil)
check("publication failure restores target lua",rollback_files["/steam/config/stplug-in/"..APP..".lua"]==oldlua)
check("publication failure restores manifest",rollback_files["/home/test/.config/SLSsteam/manifests/11_"..G11..".manifest"]=="old-manifest")
check("publication failure restores ManifestPins",rollback_files[rollback_opts.config_path]==old_config)
check("publication failure does not mark the game",
  rollback_files[rollback_opts.imports_path]=="123\n")

local crash_files,crash_opts,_,crash_on=harness({
  ["/steam/config/stplug-in/"..APP..".lua"]=oldlua,
  ["/home/test/.config/SLSsteam/config.yaml"]="ManifestPins:\n  "..APP..":\n    locked: true\n    depots:\n      11: \"old\"\n",
  ["/home/test/.config/SLSsteam/lumen_lua_imports.txt"]="123\n",
  ["/home/test/.config/SLSsteam/manifests/11_"..G11..".manifest"]="old-manifest",
  [root.."/source_0000/.source-name"]="Hubcap",[root.."/source_0000/.source-priority"]="0",
  [root.."/source_0000/"..APP..".lua"]='addappid('..APP..')\naddappid(11,1,"'..K1..'")\n',
  [root.."/source_0000/11_"..G11..".manifest"]=manifest(11,G11,100),
})
crash_opts.sync_pins=true
crash_opts.config_path="/home/test/.config/SLSsteam/config.yaml"
crash_opts.imports_path="/home/test/.config/SLSsteam/lumen_lua_imports.txt"
crash_on(crash_opts.config_path)
local survived=pcall(merge.install,APP,root,crash_opts)
check("simulated process death interrupts publication",survived==false)
check("interrupted publication leaves a durable recovery journal",
  crash_files["/home/test/.config/SLSsteam/.luatools-publish.journal"]~=nil)
local recovered_preview,recovery_error=merge.preview(APP,root,crash_opts)
check("next operation recovers an interrupted publication",
  recovered_preview~=nil and recovery_error==nil)
check("crash recovery restores target lua",
  crash_files["/steam/config/stplug-in/"..APP..".lua"]==oldlua)
check("crash recovery restores manifest",
  crash_files["/home/test/.config/SLSsteam/manifests/11_"..G11..".manifest"]=="old-manifest")
check("crash recovery restores ManifestPins",
  crash_files[crash_opts.config_path]:find('11: "old"',1,true)~=nil)
check("crash recovery restores import marker",
  crash_files[crash_opts.imports_path]=="123\n")
check("crash recovery consumes its journal",
  crash_files["/home/test/.config/SLSsteam/.luatools-publish.journal"]==nil)

-- Filesystem traversal order must not affect source metadata. Deliberately
-- enumerate source_0000's manifest before its priority/name metadata.
local ordered_files,ordered_opts=harness({
  [root.."/source_0000/.source-name"]="Preferred",
  [root.."/source_0000/.source-priority"]="0\n",
  [root.."/source_0000/"..APP..".lua"]='addappid('..APP..')\naddappid(11,1,"'..K1..'")\n',
  [root.."/source_0000/11_"..G11..".manifest"]=manifest(11,G11,100),
  [root.."/source_0001/.source-name"]="Fallback",
  [root.."/source_0001/.source-priority"]="1\n",
  [root.."/source_0001/"..APP..".lua"]='addappid('..APP..')\naddappid(11,1,"'..K1..'")\n',
  [root.."/source_0001/11_"..G11..".manifest"]=manifest(11,G11,200),
})
ordered_opts.list_recursive=function()
  local function item(path) return {name=path:match("[^/]+$"),path=path,is_directory=false} end
  return {
    item(root.."/source_0001/.source-name"), item(root.."/source_0001/.source-priority"),
    item(root.."/source_0001/"..APP..".lua"), item(root.."/source_0001/11_"..G11..".manifest"),
    item(root.."/source_0000/11_"..G11..".manifest"), item(root.."/source_0000/"..APP..".lua"),
    item(root.."/source_0000/.source-name"), item(root.."/source_0000/.source-priority"),
  }
end
local ordered=merge.install(APP,root,ordered_opts)
check("source priority is independent of traversal order",ordered~=nil and
  ordered_files["/home/test/.config/SLSsteam/manifests/11_"..G11..".manifest"]==manifest(11,G11,100))

if fails==0 then print("\nALL TESTS OK") else print("\n"..fails.." FAILED"); os.exit(1) end
