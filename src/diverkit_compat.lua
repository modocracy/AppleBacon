-- Optional, capability-checked Lua adapter. No DiverKit require, file dependency,
-- native offsets, or writes to its installation. Metadata lives in its normal
-- atomic preset snapshot; original equipment paths remain unchanged if absent.
local M={}
local fields={'label','appearance_id','stats_id','passive_variant_id'}
local function metadata(value,armor)
 if value==nil or value==false then return value end
 assert(type(value)=='table'and getmetatable(value)==nil and value.version==1,'Unsupported AppleBacon preset metadata')
 local out={version=1}
 for _,k in ipairs(fields)do
  local v=value[k];assert(type(v)=='string'and #v>0 and #v<=256 and not v:find('%c'),'Invalid AppleBacon preset field: '..k)
  out[k]=v
 end
 for k in pairs(value)do assert(k=='version'or out[k]~=nil,'Unknown AppleBacon preset field')end
 assert(type(armor)=='string'and out.appearance_id=='armor:'..armor:sub(3):lower(),'AppleBacon preset armor differs')
 return out
end
M.metadata=metadata
local function upvalue(fn,key)
 if type(fn)~='function'or not debug or type(debug.getupvalue)~='function'then return end
 for i=1,64 do local name,v=debug.getupvalue(fn,i);if not name then break end;if name==key then return v,i end end
end
-- Probe data-only behavior with isolated snapshots and an in-memory store. No
-- native binding, preflight, start, or equipment operation runs during discovery.
local function find_upvalue(fn,key,seen,depth)
 seen=seen or {};depth=depth or 0
 if type(fn)~='function'or seen[fn]or depth>6 then return end;seen[fn]=true
 local value,index=upvalue(fn,key);if index then return value,index,fn end
 for i=1,64 do
  local name,child=debug.getupvalue(fn,i);if not name then break end
  if type(child)=='function'then
   local found,slot,owner=find_upvalue(child,key,seen,depth+1);if slot then return found,slot,owner end
  end
 end
end
local function callable(api,names,label)
 assert(type(api)=='table',label..' interface missing')
 for _,name in ipairs(names)do assert(type(api[name])=='function',label..'.'..name..' is not callable')end
end
local function check_signature(fn,count,label)
 local ok,util=pcall(require,'jit.util')
 assert(ok,'Lua method inspection unavailable')
 local info=util.funcinfo(fn)
 assert(info.bytecodes and (info.isvararg or info.params==count),label..' calling convention changed')
end
local function probe_contract(model,apply)
 callable(model,{'copy_snapshot','validate_snapshot','compose','mask','new'},'Model')
 callable(apply,{'new','session','bind','preflight','profile_differences','differences'},'Apply')
 for name,count in pairs({new=3,session=1,bind=1,preflight=6,profile_differences=3,differences=3})do
  check_signature(apply[name],count,'Apply.'..name)
 end
 if apply.ownership~=nil then check_signature(apply.ownership,5,'Apply.ownership')end
 for _,field in ipairs({'fields','categories'})do
  assert(type(model[field])=='table','Model.'..field..' unavailable')
  local found={}
  for _,name in ipairs(model[field])do
   assert(type(name)=='string'and not found[name],'Invalid Model.'..field);found[name]=true
  end
  for _,name in ipairs({'primary','pistol','grenade','armor','helmet','cape'})do
   assert(found[name],'Model.'..field..' lacks '..name)
  end
 end
 local json=find_upvalue(model.copy_snapshot,'JSON')or find_upvalue(model.new,'JSON')
 callable(json,{'array','encode','decode'},'Snapshot JSON')
 local function sample(id)
  local s={schema_version=4,source_version='transmog_probe',stratagems=json.array()}
  for _,name in ipairs(model.categories)do if name~='stratagems'then s[name]=id end end
  for i=1,4 do s.stratagems[i]={slot=i,key='transmog_probe_'..i,enum=i}end
  return s
 end
 local saved,current=sample('0x00000001'),sample('0x00000002')
 local saved_bytes,current_bytes=json.encode(saved),json.encode(current)
 model.validate_snapshot(saved)
 local copy=model.copy_snapshot(saved)
 assert(copy~=saved and copy.stratagems~=saved.stratagems and copy.stratagems[1]~=saved.stratagems[1],
  'Model.copy_snapshot aliases its input')
 local function same_fields(a,b,excluded)
  for _,name in ipairs(model.categories)do
   if name~=excluded then assert(json.encode(a[name])==json.encode(b[name]),'Snapshot field changed: '..name)end
  end
 end
 same_fields(copy,saved)
 local mask=model.mask({armor=true},'apply')
 assert(mask.armor==true,'Armor mask unavailable')
 for name,value in pairs(mask)do assert(type(value)=='boolean'and (name=='armor'or not value),'Armor mask includes '..tostring(name))end
 local all=model.mask(nil,'apply');assert(all.armor==true,'Default mask excludes armor')
 local target=model.compose(saved,current,{armor=true})
 assert(target~=saved and target~=current and target.armor==saved.armor,'Armor composition failed')
 same_fields(target,current,'armor')
 target=model.compose(saved,current,{primary=true})
 assert(target.armor==current.armor and target.primary==saved.primary,'Partial mask changes armor')
 same_fields(model.compose(saved,current,nil),saved)
 assert(#apply.differences(saved,saved,{armor=true})==0 and #apply.differences(saved,current,{armor=true})>0,
  'Apply.differences cannot verify armor')
 assert(json.encode(saved)==saved_bytes and json.encode(current)==current_bytes,'Model mutates input snapshots')
 local instance=apply.new(setmetatable({}, {__index=function()error('Apply.new accessed native context during discovery')end}),
  function()error('Apply.new captured live equipment during discovery')end,function()end)
 callable(instance,{'start','poll','cancel'},'Apply instance')
 assert(not instance.busy,'Apply.new started an operation during discovery')
 for name,count in pairs({start=4,poll=2,cancel=2})do check_signature(instance[name],count,'Apply instance.'..name)end
 -- Test exactly the copy extension we will install, including saving/reloading
 -- two recipes sharing one carrier. Restore it even if the candidate rejects it.
 local original=model.copy_snapshot
 local wrapped=function(snapshot)
  local out=original(snapshot);out.transmog=metadata(snapshot.transmog,snapshot.armor);return out
 end
 model.copy_snapshot=wrapped
 local ok,why=pcall(function()
  local bytes,writes=nil,0
  local fs={read=function()return bytes,bytes and nil or 'missing'end,
   write_atomic=function(_,value)assert(type(value)=='string');bytes=value;writes=writes+1;return true end}
  local store=model.new(fs);callable(store,{'save'},'Preset store')
  saved.transmog={version=1,label='Probe A',appearance_id='armor:00000001',stats_id='probe_a',passive_variant_id='probe_a'}
  assert(store:save(saved,nil,1),'Preset store rejected recipe A')
  saved.transmog.label='Probe B';saved.transmog.stats_id='probe_b';saved.transmog.passive_variant_id='probe_b'
  assert(store:save(saved,nil,2),'Preset store rejected recipe B')
  assert(writes>0 and bytes,'Preset store did not persist')
  local reloaded=model.new(fs)
  local presets=assert(reloaded.db and reloaded.db.presets,'Preset reload unavailable')
  for i,expected in ipairs({{label='Probe A',value='probe_a'},{label='Probe B',value='probe_b'}})do
   local snapshot=presets[i]and presets[i].loadout
   local record=snapshot and metadata(snapshot.transmog,snapshot.armor)
   assert(record and record.label==expected.label and record.stats_id==expected.value
    and record.passive_variant_id==expected.value and record.appearance_id=='armor:00000001',
    'Preset store loses custom armor recipes')
  end
 end)
 model.copy_snapshot=original
 assert(ok,why)
 return 'snapshot, mask, persistence and apply contracts verified'
end
function M.supported(model,apply)
 local ok,reason=pcall(probe_contract,model,apply)
 return ok,reason
end

function M.find(root,state)
 local seen,queue={},{{fn=root,depth=0}};local at=1
 while at<=#queue and at<=128 do
  local node=queue[at];at=at+1
  if type(node.fn)=='function'and not seen[node.fn]then
   seen[node.fn]=true
   local s=upvalue(node.fn,'state')
   if s==state then
    local model,apply=upvalue(node.fn,'Model'),upvalue(node.fn,'Apply')
    local capture,index=upvalue(node.fn,'capture')
    if type(model)=='table'and type(apply)=='table'and type(capture)=='function'and index then
     return {tick=node.fn,state=state,model=model,apply=apply,raw_capture=capture,capture_index=index,
      context=function()return upvalue(node.fn,'context')end,gate=upvalue(node.fn,'transmog')}
    end
   end
   if node.depth<8 then
    for i=1,64 do
     local name,fn=debug.getupvalue(node.fn,i);if not name then break end
     if type(fn)=='function'and not seen[fn]and #queue<128 then queue[#queue+1]={fn=fn,depth=node.depth+1}end
    end
   end
  end
 end
end
-- Optional peer acknowledgement is discovered by its shared registration cell.
-- Prove its attached/ready behavior instead of checking release names or code hashes.
local function gate_registration(binding,host)
 local gate=binding.gate;if not gate then return end
 callable(gate,{'step','attached','ready'},'DiverKit acknowledgement')
 local old,index,owner=find_upvalue(gate.attached,'registered')
 local step_old,step_index,step_owner=find_upvalue(gate.step,'registered')
 assert(index and step_index and old==nil and step_old==nil and debug.upvalueid
  and debug.upvalueid(owner,index)==debug.upvalueid(step_owner,step_index),
  'DiverKit acknowledgement registration unavailable or already owned')
 assert(type(host.peer)=='table','AppleBacon runtime identity unavailable')
 local controller=binding.controller or {};local previous_status=controller.status
 local previous_adapter=host.peer.diverkit_compat
 local probe={peer=host.peer,adapter=controller}
 host.peer.diverkit_compat=controller
 debug.setupvalue(owner,index,probe)
 local ok,why=pcall(function()
  controller.status='attached'
  assert(gate:attached()==true and gate:ready()==true,'DiverKit acknowledgement rejected this session')
  controller.status='unsupported'
  assert(not gate:attached()and not gate:ready(),'DiverKit acknowledgement ignores adapter status')
  controller.status='attached';probe.peer={}
  assert(not gate:attached()and not gate:ready(),'DiverKit acknowledgement ignores runtime identity')
 end)
 debug.setupvalue(owner,index,old)
 controller.status=previous_status;host.peer.diverkit_compat=previous_adapter
 assert(ok,why)
 return {gate=gate,owner=owner,index=index,old=old}
end
function M.attach(binding,host)
 assert(upvalue(binding.tick,'capture')==binding.raw_capture,'DiverKit capture changed before attachment')
 local registration=gate_registration(binding,host)
 local model,apply=binding.model,binding.apply
 local originals={copy=model.copy_snapshot,validate=model.validate_snapshot,compose=model.compose,new=apply.new}
 local self={status='attached'};local restorations={};local operations={};local active_operations={}
 local function report(key,value)if host.report then host.report('diverkit.'..key,value)end end
 local function replace(t,k,fn)
  local old=t[k];t[k]=fn;restorations[#restorations+1]={t=t,k=k,old=old,fn=fn}
 end
 replace(model,'validate_snapshot',function(s)
  originals.validate(s);metadata(s.transmog,s.armor);return s
 end)
 replace(model,'copy_snapshot',function(s)
  local out=originals.copy(s);out.transmog=metadata(s.transmog,s.armor);return out
 end)
 replace(model,'compose',function(saved,current,mask)
  local out=originals.compose(saved,current,mask)
  local chosen=(mask==nil or mask.armor==true)and saved or current
  out.transmog=metadata(chosen.transmog,out.armor);return out
 end)
 local wrapped_capture=function()
  local sampled,snapshot=pcall(binding.raw_capture);if not sampled or not snapshot then return nil end
  local ok,value,why=pcall(host.capture,snapshot.armor)
  if not ok or value==nil then report('capture_blocked',ok and why or value);return nil end
  local valid,record=pcall(metadata,value,snapshot.armor)
  if not valid then report('capture_blocked',record);return nil end
  snapshot.transmog=record;return snapshot
 end
 assert(debug.setupvalue(binding.tick,binding.capture_index,wrapped_capture)=='capture','DiverKit capture binding changed')
 local function decorate(instance,context,raw_capture,reporter)
  if operations[instance]then return instance end
  local original_start,original_poll,original_cancel=instance.start,instance.poll,instance.cancel
  local state={};operations[instance]=state
  local methods={session=apply.session,preflight=apply.preflight,bind=apply.bind,profile_differences=apply.profile_differences,ownership=apply.ownership}
  local driver={model=model,apply=apply,context=context,capture=binding.raw_capture,report=reporter or function()end,
   current=function()
    for name,fn in pairs(methods)do if apply[name]~=fn then return false end end
    return true
   end}
  local function stop(message)
   if state.op then pcall(state.op.cancel,message)end
   state.op=nil;state.stage=nil;instance.busy=false;active_operations[instance]=nil
   report('apply_failed',message);return message
  end
  replace(instance,'start',function(_,snapshot,now,mask)
   if state.op or instance.busy then return false,'A preset is already being applied'end
   local ok,target=pcall(function()
    local current=assert(binding.raw_capture(),'Current equipment unavailable')
    return model.compose(snapshot,current,mask)
   end)
   if not ok then return false,'Cannot apply: '..tostring(target)end
   if mask~=nil and mask.armor~=true then return original_start(instance,snapshot,now,mask)end
   if not target.transmog then
    local checked,active=pcall(host.active)
    if not checked then return false,'Cannot verify AppleBacon equipment: '..tostring(active)end
    if not active then return original_start(instance,snapshot,now,mask)end
   end
   local allowed,op,why=pcall(host.prepare,target.transmog or false,target.armor,driver)
   if not allowed or not op then return false,'Cannot apply: '..tostring(allowed and why or op)end
   state.op=op;state.last_poll=now;state.started=now;state.native_notice=nil
   active_operations[instance]=state
   local others=model.mask(mask,'apply');others.armor=false
   local has_others=false;for k,v in pairs(others)do if v and target[k]~=nil then has_others=true end end
   if has_others then
    local ran,accepted,message=pcall(original_start,instance,snapshot,now,others)
    if not ran or not accepted then return false,stop('Apply incomplete: '..tostring(ran and message or accepted))end
    state.stage='equipment';instance.busy=true
   else state.stage='armor';instance.busy=true end
   report('apply_requested',target.transmog and target.transmog.label or 'original armor')
   return true,'Applying preset and AppleBacon armor...'
  end)
  replace(instance,'poll',function(_,now)
   if not state.op then return original_poll(instance,now)end
   state.last_poll=now
   local ok,message=pcall(function()
    if now<state.started or now-state.started>20000 then return stop('Apply incomplete: compatibility operation timed out')end
    if state.stage=='equipment'then
     local result=original_poll(instance,now)
     if instance.busy then return nil end
     if result~='Preset applied'and result~='Preset applied; booster in use - skipped'then
      return stop(result or 'Apply incomplete: native equipment was not verified')
     end
     state.native_notice=result;state.stage='armor';instance.busy=true
    end
    if state.stage=='armor'then
     local began,why=state.op.begin(now)
     if not began then return stop('Apply incomplete: '..tostring(why))end
     state.stage='verify'
    end
    local phase,why=state.op.poll(now)
    if phase=='complete'then
     state.op=nil;state.stage=nil;instance.busy=false;active_operations[instance]=nil;report('apply_verified',true)
     return state.native_notice or 'Preset applied'
    elseif phase=='failed'then return stop('Apply incomplete: '..tostring(why))end
   end)
   if not ok then return stop('Apply incomplete: '..tostring(message))end
   return message
  end)
  replace(instance,'cancel',function(_,message)
   if not state.op then return original_cancel(instance,message)end
   pcall(original_cancel,instance,message)
   return stop('Apply verification interrupted: '..tostring(message))
  end)
  return instance
 end
 replace(apply,'new',function(context,capture,reporter)
  return decorate(originals.new(context,capture,reporter),context,capture,reporter)
 end)
 local existing=upvalue(binding.tick,'activation')
 if existing then decorate(existing,binding.context(),binding.raw_capture,host.report)end
 local monitored={}
 for _,api in ipairs({model,apply})do
  for name,fn in pairs(api)do if type(fn)=='function'then monitored[#monitored+1]={api=api,name=name,fn=fn}end end
 end
 function self:healthy()
  for _,entry in ipairs(monitored)do if entry.api[entry.name]~=entry.fn then return false end end
  return upvalue(binding.tick,'capture')==wrapped_capture
 end
 function self:busy()return next(active_operations)~=nil end
 function self:watch(now)
  for instance,s in pairs(active_operations)do
   if s.op and (now<s.last_poll or now-s.last_poll>2000)then instance:cancel('DiverKit stopped polling')end
  end
 end
 function self:shutdown()
  if registration and upvalue(registration.owner,'registered')==registration.record then
   debug.setupvalue(registration.owner,registration.index,registration.old)
  end
  for instance in pairs(active_operations)do instance:cancel('AppleBacon stopped')end
  if upvalue(binding.tick,'capture')==wrapped_capture then debug.setupvalue(binding.tick,binding.capture_index,binding.raw_capture)end
  for i=#restorations,1,-1 do local r=restorations[i];if r.t[r.k]==r.fn then r.t[r.k]=r.old end end
  self.status='detached'
 end
 if registration then
  registration.record={peer=host.peer,adapter=binding.controller or self}
  assert(debug.setupvalue(registration.owner,registration.index,registration.record)=='registered')
  registration.gate.reason=nil
 end
 report('attached',(binding.version or 'verified')..' Lua adapter')
 return self
end
local unsupported_notice='Unsupported DiverKit interface: custom armor presets cannot be saved or restored. AppleBacon variants are unchanged.'
function M.new(host)
 local self={status='absent'};local attached,next_scan,last_state,guard=nil,0,nil,nil
 local function notify(reason,state)
  local changed=self.reason~=reason
  if type(state)=='table'and (reason or state.notice==self.reason)then state.notice=reason or ''end
  self.reason=reason
  if changed and host.notice then host.notice(reason)end
 end
 local function clear_guard()
  if guard and upvalue(guard.binding.tick,'capture')==guard.wrapper then
   debug.setupvalue(guard.binding.tick,guard.binding.capture_index,guard.binding.raw_capture)
  end
  guard=nil
 end
 local function unsupported(reason,state,binding)
  self.status='unsupported';self.detail=tostring(reason):gsub('^.-:%d+: ','');notify(unsupported_notice..' '..self.detail,state)
  if host.report then host.report('diverkit.unsupported',tostring(reason))end
  -- Do not call private Model/Apply methods in an unknown build. A discovered
  -- capture boundary can still refuse to export an incomplete custom variant.
  if binding then
   local capture_guard={binding=binding}
   local wrapper=function(...)
    local ok,active=pcall(host.active)
    if not ok or active then
     notify(unsupported_notice..' '..self.detail,state)
     if not capture_guard.blocked and host.report then host.report('diverkit.capture_blocked',unsupported_notice)end
     capture_guard.blocked=true
     return nil
    end
    return binding.raw_capture(...)
   end
   capture_guard.wrapper=wrapper;guard=capture_guard
   debug.setupvalue(binding.tick,binding.capture_index,wrapper)
  end
 end
 function self:step(now,root,state)
  if state~=last_state then
   if attached then attached:shutdown();attached=nil end
   clear_guard();notify(nil,last_state);self.status='absent';next_scan=0;last_state=state
  end
  if attached then
   if attached:healthy()then attached:watch(now);return end
   attached:shutdown();attached=nil;self.status='waiting';next_scan=0
   if host.report then host.report('diverkit.recheck','Lua interfaces changed; rechecking capabilities')end
  end
  if self.status=='unsupported'then
   if type(state)=='table'then state.notice=self.reason end
   return
  end
  if now<next_scan then return end;next_scan=now+1000
  if type(state)~='table'then self.status='absent';return end
  if not(debug and debug.getupvalue and debug.setupvalue)then
   unsupported('Lua interface inspection unavailable',state);return
  end
  local binding=M.find(root,state);if not binding then
   self.status='waiting';notify('DiverKit compatibility unavailable: waiting for a recognized preset interface.',state);return
  end
  local recognized,reason=M.supported(binding.model,binding.apply)
  if not recognized then unsupported('Unrecognized Lua interfaces: '..tostring(reason),state,binding);return end
  binding.version=reason;binding.controller=self
  local valid,why=pcall(gate_registration,binding,host)
  if not valid then unsupported(why,state,binding);return end
  attached=M.attach(binding,host);self.status='attached';notify(nil,state)
 end
 function self:after_update()
  if self.status=='unsupported'and type(last_state)=='table'then last_state.notice=self.reason end
 end
 function self:busy()return attached and attached:busy()or false end
 function self:shutdown()
  if attached then attached:shutdown();attached=nil end
  clear_guard();notify(nil,last_state);self.status='detached'
 end
 return self
end
return M
