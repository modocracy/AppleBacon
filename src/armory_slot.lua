-- One description of how an Armory tab behaves, for body armor, helmets and
-- capes alike.
--
-- The three tabs run the same machinery -- a variant session, custom cards in
-- the game's list, the creator -- and were wired twice: body armor inline in
-- main.lua, helmets and capes in accessory_ui.lua. Every behaviour that lived
-- in only one of the two was a tab-specific bug waiting to be found (research
-- /106). What a tab does is described here once; a tab differs only by the
-- data it passes in: its slot, its catalog, its grid, its cards.
local M={}
-- category -> the slot it dresses and the record its worn variant is kept in.
-- `login`: the gear every account starts in, which the game dresses the actor
-- in before the saved profile arrives. `follow_look`: the slot has no stats of
-- its own to choose, so a variant's stats always follow its look.
-- `passive_cache`: whether the actor caches a passive for the slot that a
-- worn variant can be checked against.
M.SLOTS={[0]={category=0,name='armor',record='equipped.state',login='armor:61b31723',passive_cache=true},
 [1]={category=1,name='helmet',record='equipped-helmet.state',login='armor:261c4a52',follow_look=true,passive_cache=true},
 [2]={category=2,name='cape',record='equipped-cape.state',login='armor:4657cfb3',follow_look=true,passive_cache=false}}
-- The variant session's host for one tab.
--   o.slot       one of M.SLOTS
--   o.catalog()  that tab's catalog result
--   o.grid()     the native grid bridge
--   o.cards()    the custom cards on screen, or nil
--   o.session()  the tab's variant session, once made
--   o.equipped   the tab's EquippedState
--   o.native_patch()        a native composition patch
--   o.compatible(request)   whether a composition may be applied
--   o.before_preview(...)   optional, diagnostics only
-- The caller adds what only it can know: the player reading and the refresh.
function M.session_host(o)
 assert(type(o)=='table'and type(o.slot)=='table'and type(o.catalog)=='function'and type(o.grid)=='function'
  and type(o.cards)=='function'and type(o.session)=='function','armory slot host options required')
 -- The list position and record of a saved variant's card. The list focus and
 -- the large model come from the card's record; the stats and the passive come
 -- from the request.
 local function card_of(label)
  for i,card in ipairs(o.cards()or{})do
   if label and card.label==label then return i-1,card.kit_id end
  end
 end
 local function preview(request,requires_apply,label,index,widgets_only)
  local catalog=o.catalog()
  if o.before_preview then o.before_preview(request,label,widgets_only)end
  local at,focus_kit=card_of(label)
  if at then index=at end
  local function verified(method)
   return function(id,extra)local session=o.session();return session~=nil and session[method](session,id,extra)==true end
  end
  return o.grid():preview_variant_details(request.appearance_id,request.stats_id,request.passive_variant_id,catalog,{
   requires_apply=requires_apply,focus_index=index,focus_kit_id=focus_kit,
   model_kit_id=focus_kit,widgets_only=widgets_only,
   verify_appearance=verified('verify_appearance'),verify_composition=verified('verify_composition'),
   verify_base_stats=verified('verify_base_stats')})
 end
 return{
  catalog=o.catalog,report=o.report,
  persist_equipped=function(label,request)return o.equipped:remember(label,request)end,
  validate_composition=o.compatible,
  new_patch=function()return o.native_patch()end,
  detail_state=function()return o.grid():detail_state()end,
  preview_variant=preview,
  refresh_widgets=function(request,label,index)return preview(request,false,label,index,true)end,
  model_kit=function(request,label)local _,kit=card_of(label);return kit end,
  equipped_feedback=function(request,label)
   local _,kit=card_of(label)
   return o.grid():equipment_feedback(request.appearance_id,o.catalog(),kit)
  end,
  -- Back to an ordinary card after its Apply: only a card below the custom
  -- ones is an ordinary card.
  restore_focus=function(id,index)
   local cards=o.cards()
   if type(index)~='number'or not cards or index<#cards then return nil,'The original armor card changed during Apply.'end
   local focused,why=o.grid():focus_index(index,id,o.catalog())
   if focused and o.report then o.report('variant.original_focus',id..':'..index)end
   return focused~=nil,why
  end}
end
-- One Armory tab, for whichever slot the descriptor names: its variant
-- session, the custom cards in the game's list and the creator.
--   host.slot       one of M.SLOTS
--   host.lib        the modules a tab is made of, looked up when they are used
--   host.state      optional: the table the tab keeps its state in
--   host.report, host.fs, host.engine
--   host.catalog()  this tab's catalog result; host.grid() the native grid bridge
--   host.screen()   'armory' or 'deployment'; host.token() the menu's token
--   host.panel()    the creator's panel
-- The saved variants, which only the caller knows how to keep:
--   host.domain(), host.adopt(domain), host.write(encoded), host.locked()
-- The local player, which only the caller knows how to read:
--   host.probe()        the customization probe a new session reads through
--   host.actor(probe)   one reading of it, as this slot's request and cache
--   host.data_bridge(), host.startup_guard()   for a refresh outside the Armory
-- The composition: host.native_patch(), host.compatible(request)
-- Options: host.stats_follow_look, host.passive_preview_icons, host.hitbox()
-- ('root' or 'image'), host.automatic() (whether the cards go up by themselves)
-- What the caller knows about the rest of the screen:
--   host.armory_open()      whether the Armory is on screen
--   host.restore_pending()  whether any tab's startup restore is still to finish
-- Extensions, all optional: host.before_preview(probe,request,label,widgets_only),
-- host.session_guard() before a session is made, host.refresh_options(opts)
-- before an Armory refresh is made, host.stepped(session) after the session
-- is stepped, host.restore_ready() and host.ensure_catalog() for a restore
-- that runs before the caller has a catalog,
-- host.timed(name,seconds) for the caller's profile.
--
-- The caller drives a tab with one set of calls, the same for every tab:
--   before(input)                 ahead of the game's own input, every frame
--   restore_startup(now)
--   observe(now), frame(now,sample,input)   while its list is on screen
--   hide(now)                     when another list took the screen
--   away(now,left,exited,departed) while the Armory cannot be read or is gone
--   leave(), drop_flow(), reset_catalog()   when the menu or the catalog is replaced
function M.new(host)
 assert(type(host)=='table'and type(host.slot)=='table'and type(host.lib)=='table'and type(host.fs)=='table'
  and type(host.catalog)=='function'and type(host.grid)=='function'and type(host.domain)=='function','armory tab host required')
 local slot,lib,fs=host.slot,host.lib,host.fs
 local st=host.state or{}
 local report=host.report or function()end
 local State=lib.State
 local equipped=(lib.EquippedState or require('src.equipped_state')).new(fs,State,report,slot.record)
 st.startup={record=equipped:record(),next_sample=0}
 st.startup.finished=st.startup.record==nil
 -- Body armor keeps the keys its log always had; the other tabs say which one.
 local function say(key,value)
  if slot.category==0 then report(key,value)else report('accessory.'..key,slot.category..':'..tostring(value))end
 end
 local self={slot=slot,state=st,equipped=equipped}
 st.revision=st.revision or 0
 self.section=(lib.ArmorySection or require('src.armory_section')).new()
 local section=self.section
 local function flow()return st.flow end
 local function session()return st.session end
 local function busy()local s=st.session;return s~=nil and type(s.busy)=='function'and s:busy()==true end
 local function screen()return host.screen and host.screen()or'armory'end
 -- Any native refresh in flight -- another tab's apply, the profile reconcile,
 -- a headless redraw -- is a reason to wait, never to commit alongside it.
 local function native_busy()
  local run=rawget(_G,'APPLEBACON_NATIVE_BUSY');if type(run)~='function'then return false end
  local ok,value=pcall(run);return ok and value==true
 end
 -- This tab's list is the one on screen, and its cards are told apart.
 local function visible(observed)
  return observed~=nil and observed.kind==4 and observed.native_view_mode==0
   and(observed.native_category or 0)==slot.category and observed.identity_mapping_verified==true
 end
 function self:session()return st.session end
 -- The saved variants of this tab's slot.
 function self:domain()return host.domain()end
 function self:catalog()return host.catalog()end
 function self:flow()return st.flow end
 -- One reading of the local player for this slot, outside any session.
 local function reading()
  st.probe=st.probe or host.probe()
  return host.actor(st.probe)
 end
 -- The whole loadout, not only this slot: a refresh started while another
 -- slot is still streaming is refused by the game.
 local function settled(actor)
  return actor~=nil and actor.settled~=false and actor.request_armor_id==actor.cache_armor_id
 end
 -- The tab's variant session, made when first needed.
 function self:ensure_session()
  if st.session then return st.session end
  local Session,Refresh,Bridge=lib.VariantSession,lib.ArmorRefresh,lib.ArmorRefreshBridge
  assert(Session and Bridge and Refresh,'Variant equipment modules are unavailable')
  if host.session_guard then host.session_guard()end
  local probe=host.probe()
  local o=M.session_host{slot=slot,report=report,equipped=equipped,catalog=host.catalog,grid=host.grid,
   cards=function()return st.custom_cards end,session=function()return st.session end,
   native_patch=host.native_patch,compatible=host.compatible,
   before_preview=host.before_preview and function(...)return host.before_preview(probe,...)end or nil}
  o.player=function()return host.actor(probe)end
  o.before_apply=function(background,external)
   if not background or external then st.startup.finished=true end
   -- Durable intent changes only after native completion, through
   -- persist_equipped. A failed cold restore or Apply preserves the last save.
   return true
  end
  o.equipped_matches=function(actor,id,passive)
   return actor and passive and actor.request_armor_id==id and actor.cache_armor_id==id
    and(slot.passive_cache==false or actor.cache_passive_enum==passive.enum)or false
  end
  -- `external` is a caller's own bridge (a loadout mod driving the change).
  o.new_refresh=function(background,external,opts)
   if external then return Refresh.new(external,report)end
   local bridge,why
   if background then
    bridge,why=host.grid():player_refresh_bridge(probe,host.catalog(),host.data_bridge(),host.startup_guard)
   else
    if host.refresh_options then host.refresh_options(opts)end
    bridge,why=Bridge.new(host.grid(),probe,host.catalog(),opts)
   end
   if not bridge then return nil,why end
   return Refresh.new(bridge,report)
  end
  st.session=Session.new(o)
  return st.session
 end
 local function first_owned(model)
  for _,offer in ipairs(model and model.offers or{})do if offer.owned then return offer end end
 end
 local function drop_cards()
  st.presentation=nil;st.custom_cards=nil;st.navigation_group=nil;st.navigation_pending=nil;st.navigation_cleared=nil
  st.browse_native_index=nil
 end
 function self:cards()return st.custom_cards end
 -- The game's own list back, with nothing of ours in it.
 function self:restore_list()
  if not st.presentation then return true end
  local grid,catalog=host.grid(),host.catalog()
  if grid and grid.custom_headers then grid:custom_headers(0,false)end
  st.snapshot=nil;st.next_sample=0
  if catalog then catalog.context.appearance_previews={}end
  local creator=flow();if creator then creator:clear()end
  local result=st.presentation:restore()
  say('presentation.restore',result.phase..':'..tostring(result.error or''))
  if result.phase=='restored'or result.phase=='retired'then drop_cards();st.next_sample=0;return true end
  return nil,result.error or result.phase
 end
 -- The custom cards into the list: the saved variants and the create card.
 function self:build_list()
  local grid,catalog=host.grid(),host.catalog()
  local Presentation=lib.NativeGridPresentation
  assert(Presentation and catalog and grid,'Custom presentation is not ready')
  assert(not st.presentation,'Custom presentation already active')
  local model,why=grid:inspect_model(catalog);assert(model,why)
  local by_kit={};for _,offer in ipairs(model.offers)do if offer.owned then by_kit[offer.kit_id]=offer end end
  local allow_create=screen()~='deployment'
  local donor=first_owned(model)
  local card_api=lib.VariantCards or require('src.variant_cards')
  local cards,reason=card_api.build(host.domain().presets,by_kit,allow_create,donor and donor.kit_id)
  assert(cards,reason)
  do
   local saved,shown=0,0
   for _ in pairs(host.domain().presets)do saved=saved+1 end
   for _,card in ipairs(cards)do if card.kind=='variant'then shown=shown+1 end end
   say('presentation.saved','stored='..saved..':shown='..shown..':unavailable='..(saved-shown))
  end
  -- Reserve space for every known unlock of the slot, not just the owned
  -- subset, so unlocking one cannot crowd saved cards out later.
  local known=catalog.counts and catalog.counts.verified_armors
  if not known then known=0;for _ in pairs(catalog.catalog or{})do known=known+1 end end
  catalog.context.variant_capacity=card_api.capacity(math.max(model.item_count,known),true)
  if #cards==0 then return nil,'No saved variants available',{phase='blocked',error='No saved variants available'}end
  st.revision=st.revision+1
  local native=grid:presentation_bridge(catalog,tostring(host.token and host.token())..':'..slot.category..':'..st.revision)
  local coordinator=Presentation.new(native,{allow_create=allow_create})
  local started=fs.now()
  say('presentation.build.begin',screen()..':revision='..st.revision..':native='..model.item_count..':custom='..#cards..':create='..tostring(allow_create))
  -- Clear releases native thumbnail leases and reconstructs the widgets.
  -- Neither a successful rebuild nor rollback preserves the old sample.
  st.snapshot=nil;st.next_sample=0
  catalog.context.appearance_previews={}
  local creator=flow();if creator then creator:clear()end
  local result=coordinator:attempt(cards)
  st.built_at=fs.now()
  say('presentation.build.returned','revision='..st.revision..':elapsed_ms='..(fs.now()-started)..':phase='..tostring(result.phase))
  say('presentation.attempt',result.phase..':'..tostring(result.error or''))
  if result.phase~='active'then return nil,result.error or result.phase,result end
  drop_cards()
  st.presentation=coordinator;st.custom_cards=cards;st.custom_expected_count=model.item_count+#cards;st.next_sample=0
  if creator then
   local removed=st.removed_appearance
   if removed then
    -- Removal does not rewrite worn equipment. Give the player a ready
    -- ordinary card whose explicit Apply releases and resets it.
    local chosen,at
    local visible=grid:snapshot(catalog)
    if visible and visible.identity_mapping_verified then
     for _,widget in ipairs(visible.widgets or{})do
      local index=widget.logical_index
      local offer=type(index)=='number'and model.offers[index-#cards+1]
      if offer and offer.owned and offer.kit_id==widget.bound_owned_kit_id
       and(not chosen or chosen.kit_id==removed and offer.kit_id~=removed)then
       chosen,at=offer,index
      end
     end
    end
    st.removed_appearance=nil
    if chosen then
     local shown,error=creator:action{type='select_native_look',id=chosen.kit_id,index=at}
     if not shown then say('creator.remove_recovery_wait',error)end
    end
    -- A large saved section can fill every visible row. Leave the
    -- selection clear until the player scrolls to an ordinary card.
    return true
   end
   local label=st.last_created_label or st.resume_label
   -- The card to select again is a saved variant of this list.
   local listed=false
   for _,card in ipairs(cards)do
    if label and card.label==label and card.kind=='variant'then listed=true;break end
   end
   if not listed then label=cards[1].kind=='variant'and cards[1].label or nil end
   st.last_created_label=nil
   if label then
    say('presentation.auto_preview',label)
    local shown,why=creator:action{type='select_variant',label=label}
    if not shown then say('creator.preview_unavailable',why)end
   end
  end
  return true
 end
 -- The game rebuilt its list under the cards (another category, another view,
 -- another item count, a new model): they are gone, never restored into the
 -- list that replaced theirs.
 function self:retire(observed,now)
  if not(st.presentation and observed)then return false end
  local elsewhere=observed.kind~=4 or(observed.native_category or 0)~=slot.category
  local lifecycle=st.presentation.status and st.presentation:status()
  if not(elsewhere or observed.native_view_mode~=0 or observed.item_count~=st.custom_expected_count
   or lifecycle and lifecycle.phase=='retired')then return false end
  local why=elsewhere and'category changed'or observed.native_view_mode~=0 and'view mode changed'
   or observed.item_count~=st.custom_expected_count and'item count changed'
   or lifecycle and lifecycle.error or'native model changed'
  say('presentation.retired',why..':screen='..screen()
   ..':kind='..tostring(observed.kind)..':mode='..tostring(observed.native_view_mode)
   ..':items='..tostring(observed.item_count)..':expected='..tostring(st.custom_expected_count)
   ..':revision='..st.revision)
  drop_cards();st.custom_expected_count=nil;st.selected_label=nil;st.native_browse_index=nil
  local creator,current=flow(),session()
  if creator then creator:leave()end
  if current then
   local left,reason=current:leave();if not left then report('variant.leave_failed',reason)end
  end
  section:invalidate(now,'Native list rebuilt')
  return true
 end
 -- Put the cards back after a change: the list is restored, the first owned
 -- card selected, and once that selection has settled at the top the cards are
 -- built again. One step a frame, while the tab is shown and its creator closed.
 function self:rebuild(now)
  local creator=flow();if not creator then return end
  local grid,catalog=host.grid(),host.catalog()
  if st.ownership_changed and not creator:is_open()and not busy()then
   -- What is selected may no longer be owned, or may stand on a record that
   -- shows another look. The build selects it again when it still can be.
   if st.session then st.session:cancel_preview()end
   creator:clear_selected_variant();st.selected_label=nil;st.native_browse_index=nil
   local restored,reason=self:restore_list()
   st.ownership_changed=false
   if restored then st.custom_rows_dirty=true;section:request(now)
   else say('ownership.presentation_wait',reason);section:pause('Reopen Armor after ownership changed')end
  end
  if st.custom_rows_dirty and not creator:is_open()and not busy()then
   -- The rebuild deliberately focuses a vanilla row. Retire only the old UI
   -- preview before that temporary selection, retaining committed equipment.
   if st.session and st.selected_label~=nil then
    local cancelled,why=st.session:cancel_preview()
    if not cancelled then section:defer(now,why);return end
   end
   st.custom_rows_dirty=false
   -- The full build needs the native list back first.
   local cleared,held=true,nil
   if st.presentation then cleared,held=self:restore_list()end
   local model,why
   if cleared then model,why=grid:inspect_model(catalog)else why=held end
   local first=first_owned(model)
   if first then
    local selected,reason=grid:select_kit(first.kit_id,catalog)
    if selected then st.rebuild_pending={deadline=now+2000}else section:defer(now,reason)end
   else section:defer(now,why or'Native list is not ready')end
  elseif st.rebuild_pending and not st.custom_rows_dirty then
   local pending=st.rebuild_pending
   local observed=grid:snapshot(catalog)
   if observed and observed.scroll==0 and observed.logical_selected_index and observed.logical_selected_index<3 then
    st.rebuild_pending=nil
    local called,rebuilt,reason,result=pcall(self.build_list,self)
    section:complete(now,called and(result or{phase=rebuilt and'active'or'waiting',error=reason})
     or{phase='waiting',error=rebuilt,retryable=true})
    if not called or not rebuilt then say('presentation.rebuild_failed',called and reason or rebuilt)end
   elseif now>pending.deadline then
    st.rebuild_pending=nil;section:defer(now,'Native first-row selection is not ready')
   end
  end
 end
 -- What the panel draws over the cards: a cell per custom card the list shows,
 -- and a passive badge on each ordinary card that has one.
 function self:prefix(sample,observed)
  if not(st.presentation and st.presentation.phase=='active'and observed and st.custom_cards)then return end
  local grid,catalog=host.grid(),host.catalog()
  local Layout=lib.UiLayout or require('src.ui_layout')
  local w,h=host.engine.Gui.resolution()
  local prefix={verified=true,clip=Layout.resolve(w,h).prefix,headers={},cells={},original_badges={}}
  if grid.custom_headers then
   -- The game's own names say its language; read once per catalog.
   if st.korean_catalog~=catalog then
    st.korean_catalog,st.korean=catalog,false
    local labels=catalog and catalog.context and catalog.context.labels or {}
    for _,field in ipairs({'appearance_id','passive_variant_id'})do
     for _,name in pairs(type(labels[field])=='table'and labels[field]or{})do
      if type(name)=='string'and name:find('[\234-\237][\128-\191][\128-\191]')then st.korean=true;break end
     end
    end
   end
   local ok,why=grid:custom_headers(#st.custom_cards,st.selected_label~=nil,st.custom_cards,'variant',st.korean)
   if not ok and st.header_error~=why then say('presentation.header',why);st.header_error=why end
  end
  for _,widget in ipairs(observed.widgets or{})do
   local card=widget.logical_index and st.custom_cards[widget.logical_index+1]
   if card and widget.root_viewport_rect and widget.bound_owned_kit_id==card.kit_id then
    local request=card.request
    prefix.cells[#prefix.cells+1]={rect=widget.root_viewport_rect,image_rect=widget.image_viewport_rect,key=card.key,kind=card.kind,label=card.label,
     passive=request and catalog.context.passive_variants[request.passive_variant_id],selected=st.selected_label==card.label}
    -- For the log: how long the create card's cell showed the armor it
    -- borrows before the plus was first drawn over it.
    if card.kind=='create'and st.create_drawn~=st.revision then
     st.create_drawn=st.revision
     say('presentation.create_drawn','revision='..tostring(st.revision)..':after_ms='..tostring(st.built_at and fs.now()-st.built_at))
    end
   elseif widget.root_viewport_rect and widget.bound_owned_kit_id then
    local kit=catalog.catalog[widget.bound_owned_kit_id]
    local passive=kit and catalog.context.passive_variants[kit.passive_variant_id]
    if passive then prefix.original_badges[#prefix.original_badges+1]={rect=widget.root_viewport_rect,
     image_rect=widget.image_viewport_rect,passive=passive}end
   end
  end
  sample.native_prefix=prefix
 end
 -- The creator and the saved-card workflow of this tab, made when first needed.
 function self:ensure_flow()
  if st.flow then return st.flow end
  local Wizard,Workflow=lib.VariantWizard,lib.UiWorkflow
  assert(Wizard and Workflow and type(host.panel)=='function','Creator modules are unavailable')
  local function layout()
   local w,h=host.engine.Gui.resolution()
   return(lib.UiLayout or require('src.ui_layout')).resolve(w,h)
  end
  local function contains(rect,x,y)return(lib.UiLayout or require('src.ui_layout')).contains(rect,x,y)end
  local function snapshot()
   local grid=host.grid();if not grid then return nil end
   return grid:snapshot(host.catalog())
  end
  st.flow=Workflow.new(State,Wizard,host.panel(),{
   native_picker=true,controller_native_looks=true,
   stats_follow_look=slot.follow_look==true or host.stats_follow_look==true,
   now=fs.now,report=report,
   allow_create=screen()~='deployment',
   current=function()local catalog=host.catalog();return host.domain(),catalog and catalog.context or{}end,
   input_scope=function()
    local grid=host.grid()
    if not(grid and grid.phase=='ready')then return false end
    local active,why=grid:input_scope(slot.category)
    assert(active~=nil,why)
    return active
   end,
   consume_select=function()
    local grid=host.grid()
    if not(grid and grid.phase=='ready')then return nil,'Native grid is not ready'end
    return grid:consume_select()
   end,
   consume_creator=function()
    local grid=host.grid()
    if not(grid and grid.consume_creator)then return nil,'Controller menu capture unavailable'end
    return grid:consume_creator(slot.category)
   end,
   -- The custom cards give way to the game's own list while the creator is open.
   begin_creation=function()
    if st.session then local ok,why=st.session:cancel_preview();if not ok then return nil,why end end
    st.selected_label=nil;st.removed_appearance=nil
    st.rebuild_after_creator=st.presentation~=nil
    local restored,why=self:restore_list()
    if not restored then return restored,why end
    local catalog=host.catalog()
    local model=host.grid():inspect_model(catalog)
    st.creator_look_order={}
    for _,offer in ipairs(model and model.offers or{})do
     if offer.owned then st.creator_look_order[#st.creator_look_order+1]=offer.kit_id end
    end
    return true
   end,
   controller_look_order=function()return st.creator_look_order end,
   focus_look=function(id)
    return host.grid():select_kit(id,host.catalog())
   end,
   end_creation=function()
    if st.rebuild_after_creator then st.rebuild_after_creator=false;st.custom_rows_dirty=true end
   end,
   native_navigation_at=function(x,y)
    if busy()then return false end
    return contains(layout().navigation,x,y)
   end,
   should_capture=function(input)
    if st.rebuild_pending or st.custom_rows_dirty or st.navigation_pending then return true end
    if st.session and st.session:view().native_override then return true end
    local grid=host.grid()
    if not(st.presentation and st.custom_cards and grid)then return false end
    if st.selected_label then return true end
    if input and input.down and contains(layout().picker,input.x,input.y)then return true end
    local index=grid:selection_index()
    if st.native_browse_index~=nil and index==st.native_browse_index then return false end
    st.native_browse_index=nil
    return index==nil or index<#st.custom_cards
   end,
   browse_look_at=function(x,y)
    if not(st.presentation and st.custom_cards)then return nil end
    local observed=snapshot()
    if not visible(observed)then return nil end
    if not contains(layout().picker,x,y)then return nil end
    for _,widget in ipairs(observed.widgets)do
     local r=widget.root_viewport_rect
     if widget.logical_index and widget.logical_index>=#st.custom_cards
      and widget.bound_owned_kit_id and r and x>=r.x and y>=r.y and x<r.x+r.w and y<r.y+r.h then
      return widget.bound_owned_kit_id,widget.logical_index
     end
    end
   end,
   preview_native_look=function(id,index)
    if type(index)~='number'or index%1~=0 or not st.custom_cards
     or index<#st.custom_cards then return nil,'The original armor card changed.'end
    -- Capture Apply for every original card while duplicate offers exist.
    -- The game's ordinary Apply handler highlights the first matching offer,
    -- which can be a custom prefix card.
    local current=self:ensure_session()
    local ready,reason=current:cancel_preview();if not ready then return nil,reason end
    local ok,why=current:browse(id,fs.now(),index);if not ok then return nil,why end
    st.selected_label=nil;st.resume_label=nil;st.native_browse_index=index;st.native_browse_id=id;st.next_sample=0
    return true
   end,
   -- The original card the player is looking at, so a new variant starts from it.
   selected_look=function()
    if st.native_browse_index~=nil and st.native_browse_id~=nil then return st.native_browse_id end
    local grid=host.grid()
    if not(grid and st.custom_cards and grid.selection_index)then return nil end
    local index=grid:selection_index()
    if type(index)~='number'or index<#st.custom_cards then return nil end
    local observed=snapshot()
    for _,widget in ipairs(observed and observed.widgets or{})do
     if widget.logical_index==index and widget.bound_owned_kit_id then return widget.bound_owned_kit_id end
    end
   end,
   preview_look=function(id)
    local grid,catalog=host.grid(),host.catalog()
    if not(grid and catalog)then return nil,'Owned look preview is not ready'end
    local kit=catalog.catalog[id]
    if not kit then for _,entry in pairs(catalog.catalog)do
     if entry.appearance_id==id then kit=entry;break end
    end end
    if not kit then return nil,'Owned look preview is not ready'end
    local options={
     verify_appearance=function(look)return st.session~=nil and st.session:verify_appearance(look)==true end,
     verify_composition=function(look)return st.session~=nil and st.session:verify_composition(look)==true end}
    local result,reason=grid:preview_variant_details(id,kit.stats_id,kit.passive_variant_id,catalog,options)
    return result~=nil,reason
   end,
   look_at=function(x,y)
    local source=host.hitbox and host.hitbox()or'root'
    if source~='root'and source~='image'then return nil end
    local observed=snapshot()
    if not(observed and observed.identity_mapping_verified)then return nil end
    for _,widget in ipairs(observed.widgets)do
     local r=widget[source..'_viewport_rect']
     if widget.bound_owned_kit_id and r and x>=r.x and y>=r.y and x<r.x+r.w and y<r.y+r.h then
      local card=type(widget.logical_index)=='number'and st.custom_cards and st.custom_cards[widget.logical_index+1]
      if card and widget.bound_owned_kit_id~=card.kit_id then return nil end
      return widget.bound_owned_kit_id
     end
    end
   end,
   verify_create=function(tx)
    local catalog=host.catalog()
    if not catalog then return nil,'Current ownership is unavailable'end
    local capacity=catalog.context.variant_capacity
    if type(capacity)~='number'then return nil,'Native variant capacity is unavailable'end
    local count=0;for _ in pairs(tx.candidate.presets)do count=count+1 end
    if count>capacity then return nil,'The saved variant limit is reached.'end
    local request=tx.candidate.presets[tx.label];local donors={}
    if host.compatible then
     local valid,why=host.compatible(request)
     if not valid then return nil,why end
    end
    for _,field in ipairs({'appearance_id','stats_id','passive_variant_id'})do
     local selected
     for id,kit in pairs(catalog.catalog)do
      if catalog.owned[id]and kit[field]==request[field]then selected=id;break end
     end
     if not selected then return nil,'A chosen component is no longer owned'end
     donors[#donors+1]=selected
    end
    return catalog.verify_owned(donors)==true,'Current ownership changed'
   end,
   persist=function(tx)
    if host.locked()then return nil,'Saved state needs recovery'end
    local written,why=host.write(tx.encoded)
    if not written then return nil,why end
    host.adopt(tx.candidate);say('creator.saved',tx.label)
    return true,tx.candidate
   end,
   created=function(label)
    say('creator.created',label);st.last_created_label=label;st.custom_rows_dirty=true;st.rebuild_after_creator=false
   end,
   -- An edited variant keeps its id but not its old definition: a worn
   -- record of the old definition is cleared, since it no longer matches.
   -- Like removal, this never changes what the diver wears right now.
   edited=function(tx)
    local old=tx.edited
    local remembered=equipped:record()
    local worn=remembered and(remembered.id~=nil and remembered.id==old.id or remembered.id==nil and remembered.label==old.label)
    if worn then
     local cleared,why=equipped:clear();if not cleared then report('variant.persistence_failed',why)end
    end
    say('creator.edited',old.label..' -> '..tx.label..(worn and ' (worn)'or''))
    if worn then return 'Saved. Equip this variant again to wear the changes.'end
   end,
   remove_variant=function(label)
    if screen()=='deployment'then return nil,'Remove variants in the ship Armory.'end
    if host.locked()then return nil,'Saved state needs recovery'end
    local domain=host.domain()
    if label~=st.selected_label or not domain.presets[label]then return nil,'The selected variant changed.'end
    if busy()then return nil,'Wait for the armor change to finish.'end
    -- Clone through the state codec; removal never edits equipment or composition.
    local removed=domain.presets[label].appearance_id
    local candidate,why=State.decode(State.encode(domain));if not candidate then return nil,why end
    candidate.presets[label]=nil
    local encoded,reason=State.encode(candidate);if not encoded then return nil,reason end
    local written,error=host.write(encoded)
    if not written then return nil,error end
    domain.presets=candidate.presets
    local remembered=equipped:record()
    if remembered and remembered.label==label then
     local cleared,why=equipped:clear();if not cleared then report('variant.persistence_failed',why)end
    end
    if st.session then st.session:browse()end
    st.selected_label=nil;st.resume_label=nil;st.last_created_label=nil;st.native_browse_index=nil
    st.removed_appearance=removed
    local restored,why=self:restore_list()
    st.custom_rows_dirty=restored==true;st.next_sample=0
    if not restored then
     say('presentation.remove_restore_failed',why)
     section:pause('Reopen Armor after removing a variant')
    end
    say('creator.removed',label)
    return true
   end,
   intent=function(tx)
    if tx.kind~='select_variant'then return false,'Unknown saved variant action'end
    local selected,reason=self:ensure_session():select(tx.label,tx.request,fs.now())
    if not selected then return nil,reason end
    st.selected_label=tx.label;st.resume_label=tx.label;st.native_browse_index=nil;st.next_sample=0;st.removed_appearance=nil
    return true
   end,
   variant_view=function()
    local state=st.session and st.session:view()or{}
    if host.domain().ownership_verified~=true then state.can_apply=false end
    return state
   end,
   controller_action=function()
    if screen()=='deployment'or st.rebuild_pending or st.custom_rows_dirty
     or not(st.presentation and st.custom_cards and host.grid())then return end
    local native=snapshot()
    if not visible(native)then return end
    local index=native.logical_selected_index
    local card=type(index)=='number'and st.custom_cards[index+1]
    if card and card.kind=='create'then return{type='open',index=index,revision=st.revision}end
   end,
   validate_confirm=function(action)
    local native=snapshot()
    if not(visible(native)and st.custom_cards)then return false end
    local index=native.logical_selected_index
    if type(index)~='number'then return false end
    local card=st.custom_cards[index+1]
    if action.type=='open'then
     return screen()~='deployment'and not st.rebuild_pending and not st.custom_rows_dirty
      and card and card.kind=='create'and action.index==index and action.revision==st.revision or false
    end
    if action.label then return card and card.kind=='variant'and card.label==action.label or false end
    if index<#st.custom_cards or index~=st.native_browse_index then return false end
    for _,widget in ipairs(native.widgets or{})do
     if widget.logical_index==index and widget.bound_owned_kit_id==action.id then return true end
    end
    return false
   end,
   apply_variant=function()
    if native_busy()then return nil,'Wait for the armor change to finish.'end
    return self:ensure_session():apply(fs.now())
   end,
   controller_confirmed=function(source)report('variant.controller_confirm',source)end,
   notice=function(reason)say('creator.notice',reason)end,
  })
  return st.flow
 end
 -- The input guard, before the game reads this frame's input. A guard that
 -- fails takes the creator down and pauses the tab until the Armory is left:
 -- never a failing guard every frame. Nil tells the caller to cancel the press.
 function self:before(input)
  local creator=st.flow;if not creator or not st.shown then return true end
  local started=os.clock()
  local guarded,ready,reason=pcall(creator.before,creator,input)
  if host.timed then host.timed('guard',os.clock()-started)end
  if guarded and ready then return true end
  reason=guarded and reason or ready
  say('creator.input_error',reason)
  st.flow=nil
  pcall(creator.leave,creator)
  pcall(self.restore_list,self)
  st.custom_rows_dirty=false;st.rebuild_pending=nil;st.rebuild_after_creator=false
  st.creator_failed=true
  section:pause('Native input capture unavailable')
  return nil,reason
 end
 -- Category keys change the selected group without a click. Adopt the card
 -- the game moved to before a queued preview of the old one is stepped.
 function self:navigate(observed)
  local creator=st.flow
  if not(creator and st.presentation and st.custom_cards and observed
   and observed.identity_mapping_verified and not creator:is_open()
   and type(observed.logical_selected_group)=='number')then return end
  local group=observed.logical_selected_group
  if st.navigation_group~=nil and group~=st.navigation_group then st.navigation_pending=true;st.navigation_cleared=nil end
  st.navigation_group=group
  if not st.navigation_pending or busy()then return end
  local index=observed.logical_selected_index
  local card=index and st.custom_cards[index+1]
  local id
  if index and index>=#st.custom_cards then
   for _,widget in ipairs(observed.widgets or{})do
    if widget.logical_index==index and widget.bound_owned_kit_id then id=widget.bound_owned_kit_id;break end
   end
  end
  if not st.navigation_cleared then
   local ready=not st.session or st.session:cancel_preview()
   if ready then
    creator:clear_selected_variant()
    st.selected_label=nil;st.resume_label=nil;st.native_browse_index=nil
    st.navigation_cleared=true
   end
  end
  if st.navigation_cleared and(card or id)then
   local ok,why=true,nil
   if card and card.kind=='variant'then ok,why=creator:action{type='select_variant',label=card.label}
   elseif id then ok,why=creator:action{type='select_native_look',id=id,index=index}end
   st.navigation_pending=nil;st.navigation_cleared=nil
   if not ok then report('variant.navigation_unavailable',why)end
  end
 end
 -- A controller moves the game's own cursor over the cards. Adopt that focus
 -- before a confirm can act on it. A connected idle pad never reclaims a card
 -- the mouse selected: the pad owns the cursor through its own gesture and
 -- loses it on a mouse press, on pointer movement and when the list goes.
 function self:browse(now,input)
  local shown=visible(st.snapshot)
  local moved=input and st.input_x~=nil and(input.x~=st.input_x or input.y~=st.input_y)
  local creator=st.flow
  local eligible=creator and shown and st.presentation and st.custom_cards and not creator:is_open()and not busy()
  local grid,catalog=host.grid(),host.catalog()
  local index=eligible and type(grid.selection_index)=='function'and grid:selection_index()or nil
  -- A short native key tap can move the cursor during a long frame without
  -- ever being observed held. Follow an actual verified cursor transition,
  -- not merely a disagreement with the last mouse-selected recipe. Mouse
  -- movement/press still owns its gesture, and rebuilds seed a new baseline.
  local changed=index~=nil and st.browse_native_index~=nil and index~=st.browse_native_index
  if eligible then st.browse_native_index=index elseif not shown or not st.presentation then st.browse_native_index=nil end
  if not input or input.down or moved or not shown then
   st.controller_browse=nil
  elseif changed or input.controller_source and(input.confirm_down or math.abs(input.nav_x or 0)>.55 or math.abs(input.nav_y or 0)>.55
   or input.page_prev_down or input.page_next_down)then
   st.controller_browse=true
  end
  st.input_x=input and input.x;st.input_y=input and input.y
  if not(st.controller_browse and eligible)then return end
  -- The list sample is throttled; a confirm and a direction change are not.
  -- Read it again when the cursor has moved, so a quick confirm cannot act
  -- on the previous card.
  if index~=st.snapshot.logical_selected_index then
   local fresh=grid:snapshot(catalog)
   if visible(fresh)then st.snapshot=fresh;st.next_sample=now+100 end
  end
  local index=st.snapshot.logical_selected_index
  local card=type(index)=='number'and st.custom_cards[index+1]
  local action
  if card and card.kind=='variant'and st.selected_label~=card.label then
   action={type='select_variant',label=card.label}
  elseif type(index)=='number'and index>=#st.custom_cards and st.native_browse_index~=index then
   for _,widget in ipairs(st.snapshot.widgets or{})do
    if widget.logical_index==index and widget.bound_owned_kit_id then
     action={type='select_native_look',id=widget.bound_owned_kit_id,index=index};break
    end
   end
  end
  if action then
   local ready,why=true,nil
   if st.session then ready,why=st.session:cancel_preview()end
   if ready then
    creator:clear_selected_variant()
    ready,why=creator:action(action)
   end
   if not ready then report('variant.controller_selection',why)end
  elseif card and card.kind~='variant'and(st.selected_label
   or st.session and st.session:view().native_override)then
   if not st.session or st.session:cancel_preview()then
    creator:clear_selected_variant();st.selected_label=nil;st.native_browse_index=nil
   end
  end
 end
 -- What the catalog owns now against what it owned the last time that could
 -- be verified. A change of what is owned rebuilds the list; a reading that
 -- merely stopped being verified only stops Apply until it is back.
 local function ownership(catalog)
  local verified=not(catalog.capabilities and catalog.capabilities.ownership_verified==false)
  if st.owned_source==catalog.owned and st.owned_verified==verified then return end
  local turned=st.owned_verified~=verified
  st.owned_source=catalog.owned;st.owned_verified=verified
  local owned=st.owned_signature
  if verified then
   local ids={};for id,value in pairs(catalog.owned)do if value==true then ids[#ids+1]=id end end
   table.sort(ids);owned=table.concat(ids,'|')
  end
  -- The first reading is the catalog arriving, which builds the list anyway.
  local first=st.owned_signature==nil
  local changed=owned~=st.owned_signature
  st.owned_signature=owned
  if not(changed or turned)then return end
  State.reconcile_owned(host.domain(),catalog.catalog,verified and(catalog.state_owned or catalog.owned)or nil)
  say('ownership.changed',tostring(verified))
  if changed and not first then st.ownership_changed=true end
 end
 -- Whether this tab has anything to do on the screen that is up: body armor
 -- always, the others in the ship Armory when their slot can be transmogged.
 function self:available()
  if slot.category==0 then return true end
  local catalog=host.catalog()
  return catalog~=nil and screen()=='armory'and catalog.capabilities~=nil
   and catalog.capabilities.accessory_transmog_enabled==true
 end
 -- The list as this tab's catalog reads it: on every frame while its cards
 -- are up, ten times a second otherwise. Nil while it cannot be read.
 function self:observe(now)
  local grid,catalog=host.grid(),host.catalog()
  if not(catalog and grid and grid.phase=='ready')then return st.snapshot end
  if st.presentation or now>=(st.next_sample or 0)then
   st.next_sample=now+100
   -- The observation held from the last frame, while the grid says it still
   -- describes the list; a new one otherwise. Asking costs the same checks a
   -- new snapshot makes, without a fresh copy of every decoded row each frame.
   local observed,reason=st.snapshot
   if not(observed and grid.still_current and grid:still_current(observed,catalog))then
    observed,reason=grid:snapshot(catalog,false)
   end
   st.snapshot=observed
   self:retire(observed,now)
   if observed then
    local picker=observed.kind==4 and observed.native_view_mode==0
    if st.was_picker and not picker and st.session then st.session:leave()end
    st.was_picker=picker
   end
   local context=catalog.context
   context.current_kit_id=observed and observed.identity_mapping_verified and observed.selected_kit_id or nil
   context.appearance_previews=observed and observed.appearance_previews or{}
   for _,preview in pairs(context.appearance_previews)do preview.native_handle_verified=st.thumbnail_verified==true end
   if host.passive_preview_icons~=nil then context.passive_preview_icons=host.passive_preview_icons~=false end
   if not observed and st.grid_wait~=reason then st.grid_wait=reason;say('grid.wait',reason)end
   if observed and st.grid_wait then say('grid.recovered',st.grid_wait);st.grid_wait=nil end
  end
  return st.snapshot
 end
 -- One frame of the tab while its list is the one on screen, or cannot be
 -- read for the moment. The caller has observed the list for this frame.
 function self:frame(now,sample,input)
  st.shown=true
  local catalog,observed=host.catalog(),st.snapshot
  -- A catalog read again under the tab: nothing made against the old one is
  -- kept, unless a composition of this tab is still worn through it.
  if catalog~=st.catalog_seen then
   if st.catalog_seen~=nil and not self:is_active()then self:reset_catalog()end
   st.catalog_seen=catalog
  end
  if catalog then ownership(catalog)end
  self:navigate(observed);self:browse(now,input)
  if st.session and observed and observed.kind==4 and observed.identity_mapping_verified then
   st.session:step(now)
   if host.stepped then host.stepped(st.session)end
  end
  if not input then return end
  local picker
  if observed then picker=observed.kind==4 and observed.native_view_mode==0 end
  section:observe(now,{token=host.token and host.token(),armor=picker,ready=visible(observed)and catalog~=nil})
  if observed and not picker then st.creator_failed=false end
  if(host.automatic==nil or host.automatic())and visible(observed)and catalog
   and section:due(now)and not st.creator_failed and not st.presentation then
   section:begin(now);self:ensure_flow();st.custom_rows_dirty=true
  end
  local creator=st.flow;if not creator then return end
  self:rebuild(now)
  -- A build or a restore drops the sample it was made from: nothing is drawn
  -- over a list that has not been read again.
  observed=st.snapshot
  if not(observed and observed.kind==4 and observed.identity_mapping_verified)then
   if observed and(observed.kind~=4 or observed.native_view_mode~=0)then creator:leave()else creator:clear()end
   return
  end
  self:prefix(sample,observed)
  local started=os.clock()
  creator:draw(sample,input)
  if host.timed then host.timed('draw',os.clock()-started)end
 end
 -- The Armory menu was left or replaced. Nothing of this tab is on screen any
 -- more, and nothing is restored into a list that is gone.
 function self:leave()
  st.shown=false
  if st.flow then st.flow:leave()end
  -- A startup restore runs outside the Armory: leaving the Armory is not its
  -- to end, and ending it would leave the saved item off.
  if st.session and not st.startup.active then
   local left,reason=st.session:leave();if not left then report('variant.leave_failed',reason)end
  end
  drop_cards();st.custom_expected_count=nil;st.selected_label=nil;st.native_browse_index=nil
  st.custom_rows_dirty=false;st.rebuild_pending=nil;st.rebuild_after_creator=false;st.creator_failed=false
  st.controller_browse=nil
 end
 -- Another list took the screen (another tab, another view). Leaving is an
 -- event: it is not repeated on every frame spent elsewhere.
 function self:hide(now)
  if st.shown then self:leave();section:observe(now,{armor=false})end
  -- A whole-profile commit may finish while another equipment category is
  -- visible. Its bridge obtains the current view dynamically and still checks
  -- owner, actor, profile and every protected field on every observation.
  local current=st.session
  if current and type(current.reconciling)=='function'and current:reconciling()then
   current:step(now);if host.stepped then host.stepped(current)end
  end
 end
 -- A frame on which the Armory could not be sampled. `departed`: it is known
 -- to be gone; `left`: and this is the frame that found out; `exited`: the
 -- first frame without a sample. An unreadable Armory is not a departure:
 -- the cards and the input guard stay.
 function self:away(now,left,exited,departed)
  section:observe(now,departed and{armor=false}or{})
  if left then self:leave()
  elseif exited and st.flow then st.flow:clear()end
  st.snapshot=nil;st.next_sample=0
  local current=st.session
  if current and type(current.reconciling)=='function'and current:reconciling()then
   -- Real owner/world loss is rejected by the native snapshot guard; this
   -- does not retry an uncertain commit or authorize a replacement menu.
   current:step(now);if host.stepped then host.stepped(current)end
  end
 end
 -- The screen changed kind: what the creator may do was decided when it was made.
 function self:drop_flow()
  if st.flow then st.flow:leave();st.flow=nil end
 end
 -- The catalog was read again: a session and a reading made against the old
 -- one are not kept. A session that is still driving a change is.
 function self:reset_catalog()
  if not(st.startup.active or busy())then st.session=nil;st.probe=nil end
  st.owned_source=nil;st.owned_verified=nil;st.owned_signature=nil
 end
 -- Take everything of this tab off the screen and keep it off until `resume`.
 function self:suspend()
  local ok,why=self:restore_list();if not ok then return nil,why end
  self:drop_flow()
  if st.session then ok,why=st.session:cancel_preview();if not ok then return nil,why end end
  st.selected_label=nil;st.custom_rows_dirty=false;st.rebuild_pending=nil;st.rebuild_after_creator=false
  return true
 end
 function self:resume(now)section:request(now)end
 -- Whether something of this tab is worn or on its way through the catalog
 -- as it is: a composition, a restore that is running, an Apply in flight.
 function self:is_active()
  return st.startup.active==true or busy()or(st.session~=nil and st.session:is_active())or false
 end
 -- True while this tab's native Apply is in flight.
 function self:busy()return busy()end
 function self:automation_snapshot()return st.flow and st.flow:automation_snapshot()end
 function self:shutdown()
  if st.flow then pcall(st.flow.leave,st.flow)end
  if st.session then pcall(st.session.shutdown,st.session)end
 end
 -- The variant worn when the game was closed goes back on once the ship has
 -- loaded, outside the Armory and through the live player only. True when
 -- nothing is left to do (restored, skipped or failed), false while pending.
 local function restore_step(now)
  local startup=st.startup
  if startup.active then
   st.session:step(now)
   if host.stepped then host.stepped(st.session)end
   if st.session:restoring()then return false end
   startup.active=false;startup.finished=true
   if st.session.restore_status=='complete'then st.resume_label=startup.record.label end
   say('restore.result',st.session.restore_status or'failed')
   return true
  end
  if startup.finished then return true end
  local function skip(why)startup.finished=true;say('restore.skipped',why);return true end
  local record=startup.record
  if not record then startup.finished=true;return true end
  if host.locked()then return skip('saved state needs recovery')end
  if now<startup.next_sample then return false end
  startup.next_sample=now+500
  local grid=host.grid()
  if not(grid and grid.phase=='ready')then return false end
  -- Nothing is timed before the caller can read a catalog at all.
  if host.restore_ready and not host.restore_ready()then return false end
  if not(host.startup_guard and host.startup_guard())or grid:idle_menu()~=true then return false end
  -- Another refresh in flight (the redraw after an earlier tab's restore) is
  -- a reason to wait, never to give up.
  if native_busy()then return false end
  startup.deadline=startup.deadline or now+30000
  if now>startup.deadline then return skip('startup evidence timed out')end
  local catalog,failed=host.catalog(),nil
  if not catalog and host.ensure_catalog then catalog,failed=host.ensure_catalog()end
  if not catalog then
   if failed then return skip(failed)end
   startup.next_sample=now;return false
  end
  local Equipped=lib.EquippedState or require('src.equipped_state')
  local context,domain=catalog.context,host.domain()
  if not Equipped.definition_matches(record,domain)then
   return skip('saved variant removed or changed')
  end
  local actor,why=reading()
  if not settled(actor)then
   startup.stable_since=nil;startup.other=nil
   if startup.wait~=why then startup.wait=why;say('restore.wait',why or'equipment is transitioning')end
   return false
  end
  local current=actor.request_armor_id
  if not Equipped.startup_matches(record,domain,current,context)then
   startup.stable_since=nil
   if startup.wait~=current then startup.wait=current;say('restore.wait','native equipment settling: '..tostring(current))end
   -- The login gear is the game still dressing the actor: wait for it.
   -- Anything else that stays on is the player's own choice, and waiting on
   -- it would hold every later equipment change behind this restore.
   if current==slot.login then startup.other=nil;return false end
   if startup.other~=current then startup.other=current;startup.other_since=now;return false end
   if now-startup.other_since<3000 then return false end
   return skip('another item is worn ('..tostring(current)..')')
  end
  startup.other=nil
  if startup.observed_id~=current or not startup.stable_since then
   startup.observed_id=current;startup.stable_since=now;return false
  end
  if now-startup.stable_since<1000 then return false end
  if host.compatible then
   local allowed,error=host.compatible(record.request)
   if not allowed then return skip(error)end
  end
  local restored,reason=self:ensure_session():restore(record.label,record.request,now)
  if not restored then return skip(reason)end
  startup.active=true;say('restore.started',record.label)
  return false
 end
 -- A restore that raises is given up once; it never takes the frame with it
 -- and never resets data an uncertain native outcome may have left worn.
 function self:restore_startup(now)
  local ok,done=pcall(restore_step,now)
  if ok then return done end
  st.startup.finished=true;st.startup.active=false
  if st.session then st.session:abandon_restore(done)end
  say('restore.skipped',done)
  return true
 end
 -- Run the startup restore once more from the record as it is now.
 function self:restore_again()
  local startup=st.startup
  if startup.active then return nil,'startup restoration is running'end
  local record=equipped:record();if not record then return nil,'no saved variant to restore'end
  startup.record=record;startup.finished=false;startup.deadline=nil;startup.stable_since=nil
  startup.observed_id=nil;startup.next_sample=0;startup.other=nil;startup.wait=nil
  return true
 end
 return self
end
return M
