-- Saved-card browsing never changes live kit records. A selection retains
-- original catalog metadata; only explicit Apply may compose a carrier.
local M={}
local fields={'appearance_id','stats_id','passive_variant_id'}
local function copy(value)
 local out={};for _,key in ipairs(fields)do
  assert(type(value[key])=='string'and #value[key]>0,'complete variant required');out[key]=value[key]
 end;return out
end
local function same(a,b)
 if not(a and b)then return false end
 for _,key in ipairs(fields)do if a[key]~=b[key]then return false end end;return true
end
function M.new(host)
 local self={phase='idle'}
 local patch,applied_plan,selected,committed,preview,pending,refresh,refresh_previous,notice,left,detail_binding
 local timing=host.preview_timing or {}
 local delay=timing.selection_delay_ms or 180
 local settle=timing.settle_ms or 150
 local samples=timing.stable_samples or 2
 assert(type(delay)=='number'and delay>=0 and delay<=2000,'invalid preview selection delay')
 assert(type(settle)=='number'and settle>=0 and settle<=2000,'invalid preview settling delay')
 assert(type(samples)=='number'and samples%1==0 and samples>=1 and samples<=10,'invalid preview observation count')
 local next_preview_at=0
 local background,reconciling=false,false
 local external_bridge,external=false,false
 local function report(key,value)if host.report then host.report(key,value)end end
 local function reset()
  if not patch then return true end
  local ok,why=patch:reset();if not ok then return nil,why end
  patch=nil;applied_plan=nil;return true
 end
 local function compose(request,label,expected_target)
  -- A composition is its name as well as its three ids: two saved looks of
  -- one modded piece share the ids and differ in the look stored under the
  -- name, which the patch composes. Skipping it left the old look on the
  -- record until the reconciler caught up after the equip (live 2026-10-01).
  if applied_plan and same(applied_plan.request,request)and applied_plan.label==label
   and(not expected_target or applied_plan.target_id==expected_target)
   and patch and patch:is_active()==true then return true end
  report('variant.patch.begin',request.stats_id..':'..request.appearance_id)
  local ok,why=reset();if not ok then return nil,why end
  patch=host.new_patch()
  local plan,reason=patch:plan(host.catalog(),request,label);if not plan then return nil,reason end
  if expected_target and plan.target_id~=expected_target then return nil,'The appearance carrier changed during Apply.'end
  local applied,evidence=patch:apply(plan);if not applied then return nil,evidence end
  plan.label=label;applied_plan=plan;report('variant.patch.end',plan.target_id);return true
 end
 local function restore_previous(previous)
  if previous then return compose(previous.request,previous.label)end
  return reset()
 end
 local function metadata(request)
  local ok,plan=pcall(function()
   local wanted=copy(request);local catalog=host.catalog();local ids={}
   for id in pairs(catalog.catalog or {})do if catalog.owned[id]then ids[#ids+1]=id end end;table.sort(ids)
   local source,target,passive
   for _,id in ipairs(ids)do local kit=catalog.catalog[id]
    if kit.appearance_id==wanted.appearance_id then source=source or id end
    if kit.stats_id==wanted.stats_id then target=target or id end
    if kit.passive_variant_id==wanted.passive_variant_id then passive=passive or id end
   end
   assert(source and target and passive,'A selected component is no longer owned.')
   -- The look's own armor carries the composition unless the host names another.
   local carrier=host.target_for and host.target_for(wanted)or source
   assert(carrier and catalog.owned[carrier]and catalog.catalog[carrier],'The appearance carrier is unavailable.')
   return {source_id=source,target_id=carrier,stats_source_id=target,passive_source_id=passive,request=wanted}
  end)
  if not ok then return nil,tostring(plan)end;return plan
 end
 -- The record the large preview is built from for a selection: the card's
 -- own record, else the appearance itself.
 local function model_of(selection)
  if host.model_kit and not selection.native_override then
   local id=host.model_kit(selection.request,selection.label)
   if id then return id end
  end
  return selection.request.appearance_id
 end
 local function queue(selection,now)
  selected=selection
  detail_binding=nil
  preview={deadline=now+5000,samples=0}
  self.phase='previewing';notice=nil
  report('variant.selected',selection.label or selection.plan.target_id)
 end
 local function details_match(state,id)
  if not state or state.kit_id~=id then return false end
  for _,key in ipairs({'stats_offer_id','passive_offer_id'})do
   if detail_binding and detail_binding[key]~=nil and state[key]~=detail_binding[key]then return false end
  end
  return true
 end
 local function remember(selection)
  if selection.native_override then committed=nil
  else committed={label=selection.label,request=copy(selection.request),target_id=selection.plan.target_id}end
 end
 local function currently_equipped(selection)
  -- A saved variant is its name as well as its three ids: two saved looks of
  -- one modded piece differ only in the look stored under the name, and each
  -- has to be applicable while the other is on.
  if not(selection and not selection.native_override and committed and same(selection.request,committed.request)
   and selection.label==committed.label and patch and patch:is_active()==true and host.player)then return false end
  local actor=host.player();local passive=host.catalog().context.passive_variants[selection.request.passive_variant_id]
  if host.equipped_matches then return host.equipped_matches(actor,committed.target_id,passive)end
  return actor and passive and actor.request_armor_id==committed.target_id
   and actor.cache_armor_id==committed.target_id and actor.cache_passive_enum==passive.enum or false
 end
 function self:busy()return refresh~=nil end
 function self:has_committed()return committed~=nil end
 function self:is_active()return patch and patch:is_active()~=false or false end
 function self:restoring()return background end
 function self:reconciling()
  if not(reconciling and refresh and self.phase~='apply_failed')then return false end
  local phase,evidence=refresh:status()
  return phase=='wait_target'and evidence~=nil and evidence.commits>0
 end
 function self:abandon_restore(reason)
  if not background then return end
  -- Never reset possibly worn data after an uncertain native outcome. Keep
  -- any patch journal for the next explicit, guarded equipment change.
  background=false;refresh=nil;refresh_previous=nil;selected=nil;preview=nil;pending=nil
  self.phase='idle';self.restore_status='failed';notice=tostring(reason)
 end
 function self:verify_composition(id)
  return applied_plan~=nil and applied_plan.target_id==id and patch~=nil and patch:is_active()==true
 end
 function self:verify_base_stats(id,stats_id)
  return self:verify_composition(id)and applied_plan.request.stats_id==stats_id
 end
 function self:verify_appearance(id)
  return applied_plan~=nil and applied_plan.source_id==id
   and self:verify_composition(id)
 end
 function self:view()
  return {native_details=not pending and selected~=nil and(self.phase=='ready'or self.phase=='applying'or self.phase=='equipped'),
   native_override=selected~=nil and selected.native_override==true,
   native_override_id=selected and selected.native_override and selected.plan.target_id or nil,
   can_apply=not pending and selected~=nil and not selected.block_reason and self.phase=='ready',
   apply_pending=refresh~=nil or preview~=nil or pending~=nil,
   apply_notice=notice,variant_phase=self.phase}
 end
 function self:select(label,request,now)
  if refresh then return nil,'Wait for the armor change to finish.'end
  assert(type(now)=='number'and now==now and now>=0,'valid preview clock required')
  local plan,why=metadata(request);if not plan then notice=why;return nil,why end
  if not pending and selected and selected.label==label and same(selected.request,plan.request)
   and selected.plan.target_id==plan.target_id
   and(self.phase=='ready'or self.phase=='equipped')then return true end
  left=false;notice=nil
  local block_reason
  if host.validate_composition then
   local valid,why=host.validate_composition(plan.request)
   if valid~=true then block_reason=why or 'This composition is unavailable.'end
  end
  pending={selection={label=label,request=plan.request,plan=plan,block_reason=block_reason},at=now+delay}
  self.phase='previewing';report('variant.selection_queued',label)
  if delay==0 and not preview and now>=next_preview_at then
   local wanted=pending;pending=nil;queue(wanted.selection,now)
  end
  return true
 end
 function self:apply(now)
  -- Apply refusals were the one path that never reached the log, so a session
  -- that silently would not equip looked identical to one doing nothing. The
  -- phase and the selected target are what tell the two apart.
  local function reject(reason)
   notice=tostring(reason)
   report('variant.apply_rejected',notice..' phase='..tostring(self.phase)
    ..' target='..tostring(selected and selected.plan and selected.plan.target_id)
    ..' preview='..tostring(preview~=nil)..' pending='..tostring(pending~=nil)
    ..' refresh='..tostring(refresh~=nil))
   return nil,notice
  end
  -- A preview is our own machinery and must never gate the player's apply: the
  -- hard rule is that nothing we do prevents switching armor. An apply that
  -- arrives mid-preview abandons the preview and goes straight through, and the
  -- phase we happen to be in is ours to reconcile, not a precondition on them.
  if not selected then return reject('Select a look first.')end
  -- An apply already driving the native coordinator is the one thing that must
  -- finish first; it is the game's transition, not a gate of ours. Checked
  -- before anything is cleared, so a refusal leaves the session untouched.
  if refresh then return reject('An armor change is already in progress.')end
  preview=nil;pending=nil;next_preview_at=0
  if self.phase~='ready'and self.phase~='equipped'then self.phase='ready'end
  if selected.block_reason then return reject(selected.block_reason)end
  if host.validate_composition and not selected.native_override then
   local allowed,why=host.validate_composition(selected.request)
   if allowed~=true then return reject(why or 'This composition is unavailable.')end
  end
  local catalog=host.catalog();local passive=catalog.context.passive_variants[selected.request.passive_variant_id]
  if not(passive and type(passive.enum)=='number')then return reject('The selected passive is unavailable.')end
  local coordinator,reason=host.new_refresh(background,external_bridge);if not coordinator then return reject(reason or 'Native armor Apply is unavailable.')end
  local plan=selected.plan
  local previous=applied_plan and {request=copy(applied_plan.request),label=applied_plan.label}
  local needs_preparation=not selected.native_override or patch~=nil
  local target_unchanged=selected.native_override==true and applied_plan~=nil and applied_plan.target_id~=plan.target_id
  local mutations=needs_preparation and not target_unchanged and {plan.target_id}or {}
  if applied_plan and applied_plan.target_id~=plan.target_id then mutations[#mutations+1]=applied_plan.target_id end
  local prepare_target
  if needs_preparation then prepare_target=function()
    -- The coordinator calls this only after the requested and cached armor
    -- have left every carrier we may reset or rewrite. Begin stays read-only.
    local done,error
    if selected.native_override then done,error=reset()
    else done,error=compose(selected.request,selected.label,plan.target_id)end
    if done then return true end
    local restored,recovery=restore_previous(previous)
    return nil,tostring(error)..(not restored and '; previous composition restoration failed: '..tostring(recovery)or '')
   end end
  local began,why=coordinator:begin({target_id=plan.target_id,passive_enum=passive.enum,
   donor_ids={plan.source_id,
    plan.stats_source_id,plan.passive_source_id},timeout_ms=background and not external and 30000 or 5000,mutation_ids=mutations,
   prepare_target=prepare_target,target_unchanged=target_unchanged,accept_current=not needs_preparation},now)
  if not began then return reject(why or 'Native armor Apply could not begin.')end
  if host.before_apply then
   local ok,error=host.before_apply(background,external);if not ok then return reject(error)end
  end
  refresh=coordinator;refresh_previous=previous;self.phase='applying';notice=nil
  report('variant.apply_kind',selected.native_override and 'original'or 'saved')
  report('variant.apply',selected.label or plan.target_id);return true
 end
 -- The compatibility adapter owns polling and context verification. It passes
 -- a loadout bridge; the existing release/compose/re-equip protocol is reused.
 function self:external_begin(label,request,now,bridge,original)
  if refresh or background then return nil,'Wait for the current armor change to finish.'end
  if type(now)~='number'or now~=now or now<0 then return nil,'Invalid equipment clock'end
  local plan,why=metadata(request);if not plan then return nil,why end
  pending=nil;preview=nil;detail_binding=nil;next_preview_at=0
  selected={label=label,request=plan.request,plan=plan,native_override=original==true}
  external_bridge=bridge;external=true;background=true;left=false;self.phase='ready'
  self.external_status='applying';self.external_error=nil
  local called,ok,error=pcall(self.apply,self,now)
  if not called then error=ok;ok=nil end
  if not ok then
   external_bridge=nil;external=false;background=false;selected=nil;self.phase='idle'
   self.external_status='failed';self.external_error=error
  end
  return ok,error
 end
 function self:external_cancel(reason)
  if not external then return end
  self:abandon_restore(reason)
  external_bridge=nil;external=false;self.external_status='failed';self.external_error=tostring(reason)
 end
 function self:export_equipped(id)
  if refresh or background then return nil,'Armor application is pending'end
  if not host.player then return nil,'Player evidence unavailable'end
  local actor,why=host.player();if not actor then return nil,why end
  if actor.request_armor_id~=id or actor.cache_armor_id~=id then return nil,'Armor is transitioning'end
  if not patch then return false end
  if not applied_plan then return nil,'Armor composition needs recovery'end
  if applied_plan.target_id~=id then return false end
  if not committed or not same(committed.request,applied_plan.request)or not currently_equipped(committed)then
   return nil,'Equipped variant has not been verified'
  end
  return {label=committed.label,request=copy(committed.request),target_id=committed.target_id}
 end
 function self:restore(label,request,now)
  if refresh or selected or pending or preview then return nil,'startup restoration requires an idle session'end
  local plan,why=metadata(request);if not plan then return nil,why end
  -- A worn patch of the very request being restored is not a busy session: a
  -- session change took the carrier off the actor while its composition stayed
  -- on and committed here, and compose() is idempotent for it. Anything else
  -- composed needs the idle session the login restore always finds.
  if patch and not(applied_plan and same(applied_plan.request,plan.request))then return nil,'startup restoration requires an idle session'end
  selected={label=label,request=plan.request,plan=plan};self.phase='ready';left=false;background=true;self.restore_status='applying'
  local ok,error=self:apply(now)
  if not ok then background=false;selected=nil;self.phase='idle';self.restore_status='failed' end
  return ok,error
 end
 -- Profile reconcile. The Armory's committed profile disagrees with what the
 -- actor already wears -- the state every startup restore leaves behind -- and
 -- the game's next commit of any slot would re-dress the actor with the stale
 -- fields. Re-commit the worn kit through the Armory once, before anything else
 -- commits. Nothing is selected, remembered or persisted; a queued preview
 -- waits for it. `profile` is the Armory's committed {armor_id,helmet_id,cape_id};
 -- false means it already agrees and there is nothing to do.
 function self:reconcile(profile,now)
  if refresh or background then return nil,'Wait for the armor change to finish.'end
  if type(now)~='number'or now~=now or now<0 then return nil,'Invalid reconcile clock'end
  if type(profile)~='table'then return nil,'The committed profile is unavailable.'end
  if not host.player then return nil,'Player evidence unavailable'end
  local actor,why=host.player();if not actor then return nil,why end
  local worn=actor.request
  if type(worn)~='table'then return nil,'The worn equipment is unavailable.'end
  local differs=false
  for _,key in ipairs({'armor_id','helmet_id','cape_id'})do
   if type(profile[key])~='string'or type(worn[key])~='string'then return nil,'The committed '..key..' is unavailable.'end
   if profile[key]~=worn[key]then differs=true end
  end
  if not differs then return false end
  if actor.settled==false or actor.request_armor_id~=actor.cache_armor_id then return nil,'native armor is still transitioning'end
  local passive=actor.cache_passive_enum
  if type(passive)~='number'then return nil,'the worn armor passive cache is unavailable'end
  local coordinator,reason=host.new_refresh(false,nil,{reconcile=true})
  if not coordinator then return nil,reason or 'Native armor Apply is unavailable.'end
  local began,error=coordinator:begin({target_id=actor.request_armor_id,passive_enum=passive,timeout_ms=5000,reconcile=true},now)
  if not began then return nil,error end
  refresh=coordinator;refresh_previous=nil;reconciling=true;notice=nil
  report('variant.reconcile',actor.request_armor_id);return true
 end
 function self:step(now)
  if refresh then
   if self.phase=='apply_failed'then return end
   local phase,evidence=refresh:step(now)
   if reconciling then
    if phase=='complete'then
     refresh=nil;reconciling=false;report('variant.reconciled',evidence and evidence.status or 'complete')
    elseif phase=='failed'or phase=='blocked'or phase=='cancelled'then
     notice=evidence and evidence.reason or 'Armor profile reconcile could not be verified.'
     report('variant.reconcile_failed',notice)
     if refresh.needs_recovery then self.phase='apply_failed'else refresh=nil;reconciling=false end
    end
    return
   end
   if phase=='complete'then
    remember(selected);refresh=nil;refresh_previous=nil;self.phase='equipped';notice=nil
    if host.persist_equipped then
     local called,ok,why=pcall(host.persist_equipped,selected.native_override and nil or selected.label,
      selected.native_override and nil or selected.request)
     if not called or not ok then report('variant.persistence_failed',called and why or ok)end
    end
    if background then
     if external then self.external_status='complete';external_bridge=nil;external=false end
     background=false;selected=nil;self.phase='idle';self.restore_status='complete'
     report('variant.restored',evidence.status);return
    end
    if selected.native_override and host.restore_focus then
     local restored,why=host.restore_focus(selected.request.appearance_id,selected.focus_index)
     if not restored then
      self.phase='preview_failed';notice=tostring(why);report('variant.focus_failed',notice)
      report('variant.equipped',evidence.status);return
     end
    end
    -- The selected card already rendered its native preview. Cache completion
    -- must not restart model streaming with another full native detail call.
    if host.refresh_widgets then
     local done,why=host.refresh_widgets(selected.request,selected.label,selected.focus_index)
     if done then detail_binding=type(done)=='table'and done or nil
     else self.phase='preview_failed';notice=tostring(why);report('variant.widgets_failed',notice)end
    end
    if self.phase=='equipped'and host.equipped_feedback then
     local called,done,why=pcall(host.equipped_feedback,selected.request,selected.label)
     if called and done then report('variant.feedback',type(done)=='table'and done.status or 'complete')
     else report('variant.feedback_failed',called and why or done)end
    end
    report('variant.equipped',evidence.status)
   elseif phase=='failed'or phase=='blocked'or phase=='cancelled'then
    if evidence and evidence.commits==0 and evidence.target_prepared then
     local restored,why=restore_previous(refresh_previous)
     if not restored then report('variant.restore_failed',why)end
    else
     local player=host.player and host.player()
     if evidence and evidence.target_prepared and player and player.request_armor_id==selected.plan.target_id
      and(not selected.native_override or not refresh.needs_recovery)then remember(selected)end
    end
    notice=evidence and evidence.reason or 'Armor refresh could not be verified.'
    self.phase='apply_failed';report('variant.apply_failed',notice)
    if background then
     if external then self.external_status='failed';self.external_error=notice;external_bridge=nil;external=false end
     background=false;refresh=nil;refresh_previous=nil;selected=nil;self.phase='idle';self.restore_status='failed'
     report('variant.restore_failed',notice);return
    end
    if not refresh.needs_recovery then refresh=nil;refresh_previous=nil end
   end
   return
  end
  if pending and not preview and now>=pending.at and now>=next_preview_at then
   local wanted=pending;pending=nil;queue(wanted.selection,now)
  end
  if preview then
   if now>preview.deadline then
    preview=nil;pending=nil;self.phase='preview_failed';notice='Armor preview timed out.'
    report('variant.preview_failed',notice);return
   end
   local id=model_of(selected)
   if not preview.sent_at then
    report('variant.preview.begin',id..':target')
    local done,why=host.preview_variant(selected.request,not currently_equipped(selected),selected.label,selected.focus_index)
    -- The preview may have put the look on another record (a card left on
    -- its home is modelled by one that shows it): what is waited for is the
    -- record the model was built from.
    id=model_of(selected)
    report('variant.preview.end',id..':target:'..tostring(done and 'ok'or why))
    if not done then
     preview=nil;pending=nil;self.phase='preview_failed';notice=tostring(why)
     report('variant.preview_failed',notice);return
    end
    detail_binding=type(done)=='table'and done or nil
    preview.sent_at=now;preview.deadline=now+5000
   end
   -- This bounds call rate; stable IDs do not prove resource streaming finished.
   if preview.sample_at==now then return end
   preview.sample_at=now
   local state=host.detail_state()
   if details_match(state,id)then
    preview.samples=preview.samples+1;preview.stable_at=preview.stable_at or now
   else preview.samples=0;preview.stable_at=nil end
   if preview.samples<samples or not preview.stable_at or now-preview.stable_at<settle then return end
   preview=nil;next_preview_at=now+settle;self.phase=pending and 'previewing'or currently_equipped(selected)and 'equipped'or 'ready'
   notice=not pending and selected.block_reason or nil
   report('variant.native_details',selected.label or selected.plan.target_id)
  elseif not pending and selected and(self.phase=='ready'or self.phase=='equipped')then
   -- Once a variant is on, its own record holds the look as well: the game
   -- showing that one is the same preview.
   local state=host.detail_state()
   if state and not details_match(state,model_of(selected))
    and not(self.phase=='equipped'and details_match(state,selected.request.appearance_id))then
    self.phase='preview_failed';notice='The native preview changed. Select the variant again.'
    next_preview_at=now+settle;report('variant.preview_failed',notice)
   end
  end
 end
 -- Native category navigation supersedes UI-only queued previews, never Apply.
 function self:cancel_preview()
  if refresh then return nil,'Wait for the armor change to finish.'end
  preview=nil;pending=nil;selected=nil;detail_binding=nil;notice=nil
  next_preview_at=0;left=false;self.phase='idle'
  return true
 end
 function self:browse(id,now,focus_index)
  if refresh then return nil,'Wait for the armor change to finish.'end
  if preview or pending then return nil,'Wait for the current armor preview to finish.'end
  left=false;selected=nil;notice=nil;self.phase='idle'
  if id and(focus_index~=nil or committed and id==committed.target_id)then
   local catalog=host.catalog();local original=catalog.catalog and catalog.catalog[id]
   if not(original and catalog.owned[id])then return nil,'The original armor is unavailable.'end
   if type(now)~='number'or now~=now or now<0 then return nil,'The original armor preview clock is unavailable.'end
   local plan,why=metadata(original);if not plan then return nil,why end
   if focus_index~=nil and(type(focus_index)~='number'or focus_index%1~=0 or focus_index<0 or focus_index>255)then
    return nil,'The original armor card changed.'
   end
   queue({native_override=true,request=plan.request,plan=plan,focus_index=focus_index},now)
   report('variant.original_selected',id)
  end
  return true
 end
 function self:leave()
  if left and not refresh then return true end
  preview=nil;pending=nil;next_preview_at=0
  if refresh then
   local refresh_phase,evidence=refresh:status()
   if reconciling and self.phase~='apply_failed'and refresh_phase=='wait_target'and evidence and evidence.commits>0 then
    -- Only an already committed profile reconcile may outlive this tab.
    -- Continue observing its verified native view; never issue a new commit
    -- because a category/menu changed. The coordinator rejects owner loss.
    selected=nil;left=true;return true
   end
   reconciling=false
   if evidence and evidence.commits==0 then
    refresh:cancel();refresh=nil
    refresh_previous=nil -- Preparation has not run; there is nothing to undo.
   else
    local player=host.player and host.player()
    if evidence and evidence.target_prepared and selected and player
     and player.request_armor_id==selected.plan.target_id then remember(selected)end
    self.phase='apply_failed';notice='Armory closed before the armor refresh completed.'
    report('variant.apply_failed',notice);refresh=nil;refresh_previous=nil;selected=nil;left=true;return true
   end
  end
  -- Ordinary browsing did not change the applied patch, so leaving it requires
  -- no data writes. A different native equipment choice retires its old patch.
  if committed then
   local player=host.player and host.player()
   if player and player.request_armor_id and player.cache_armor_id
    and player.request_armor_id~=committed.target_id and player.cache_armor_id~=committed.target_id then
    local ok,why=reset();if not ok then return nil,why end
    committed=nil
    if host.persist_equipped then
     local ok,why=host.persist_equipped(nil);if not ok then report('variant.persistence_failed',why)end
    end
   end
  end
  selected=nil;self.phase='idle';left=true;return true
 end
 function self:shutdown()
  refresh=nil;refresh_previous=nil;selected=nil;committed=nil;preview=nil;pending=nil;return reset()
 end
 return self
end
return M
