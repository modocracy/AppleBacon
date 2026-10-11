-- Helmets and capes: one Armory tab each, the same tab body armor has
-- (ArmorySlot). This file supplies what only it knows: where a slot's saved
-- variants are kept and how the local player reads for that slot.
local M={}
-- The modules a tab is made of, looked up when the tab uses them.
local Lib=setmetatable({},{__index=function(_,name)
 if name=='ArmorySection'then return ArmorySection or require('src.armory_section')end
 if name=='EquippedState'then return EquippedState or require('src.equipped_state')end
 if name=='VariantCards'then return VariantCards or require('src.variant_cards')end
 if name=='UiLayout'then return UiLayout or require('src.ui_layout')end
 if name=='NativeGridPresentation'then return NativeGridPresentation or require('src.native_grid_presentation')end
 if name=='VariantSession'then return VariantSession or require('src.variant_session')end
 if name=='ArmorRefresh'then return ArmorRefresh or require('src.armor_refresh')end
 if name=='ArmorRefreshBridge'then return ArmorRefreshBridge or require('src.armor_refresh_bridge')end
 if name=='VariantWizard'then return VariantWizard or require('src.variant_wizard')end
 if name=='UiWorkflow'then return UiWorkflow or require('src.ui_workflow')end
end})
-- host.category (1 helmets, 2 capes), host.state (the State module), host.fs,
-- host.engine, host.panel, host.report, host.player (the customization probe),
-- host.catalog() and host.grid() for the slot, host.patch(catalog) and
-- host.compatible(catalog,request) for its composition; the rest is handed to
-- the tab as it is. Returns the tab.
function M.new(host)
 local category=assert(host.category);assert(category==1 or category==2)
 local Slot=ArmorySlot or require('src.armory_slot')
 local S=host.state;local field=category==1 and 'helmet_id'or 'cape_id'
 local file=category==1 and 'helmets.state'or 'capes.state'
 local domain=S.new();local blocked
 local writer=S.writer(host.fs,file)
 local raw,why=host.fs.read(file)
 if raw then
  domain,blocked=S.decode(raw)
  if domain then
   writer.loaded(raw,domain.decoded_version)
   local count=0;for _ in pairs(domain.presets)do count=count+1 end
   if host.report then host.report('state.loaded',file..':schema='..domain.decoded_version..':current='..S.SCHEMA_VERSION..':variants='..count)end
  end
  domain=domain or S.new()
 elseif why~='missing'then blocked=why or 'Saved variants are unreadable'end
 return Slot.new{slot=Slot.SLOTS[category],lib=setmetatable({State=S},{__index=Lib}),
  fs=host.fs,engine=host.engine,report=host.report,passive_preview_icons=host.passive_preview_icons,
  hitbox=host.hitbox,automatic=host.automatic,
  catalog=host.catalog,grid=host.grid,screen=host.screen,token=host.token,
  panel=function()return host.panel end,
  domain=function()return domain end,adopt=function(candidate)domain=candidate end,
  locked=function()return blocked~=nil end,
  write=function(encoded)return writer.write(encoded)end,
  probe=function()return host.player end,
  -- One reading of the local player, as this slot's request and cache.
  actor=function(probe)
   local a,why=probe:sample();if not a then return nil,why end
   local out={};for k,v in pairs(a)do out[k]=v end
   out.request_armor_id=a.request[field];out.cache_armor_id=a.current[field]
   out.cache_passive_enum=category==1 and a.cache_helmet_passive_enum or nil
   return out
  end,
  data_bridge=function()return host.data_bridge end,startup_guard=host.startup_guard,
  armory_open=host.armory_open,restore_pending=host.restore_pending,
  native_patch=function()return host.patch(host.catalog())end,
  compatible=function(request)return host.compatible(host.catalog(),request)end}
end
return M
