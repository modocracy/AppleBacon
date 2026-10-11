-- Headless equipment control. Drives an ArmorRefresh coordinator directly, with
-- no Armory UI, no preview and no variant session: the preview state machine is
-- only stepped by the Armory loop and never resolves headlessly. Every ownership
-- and progression guard stays with the coordinator; nothing here writes kit data,
-- invents catalog identities, or retries an uncertain native outcome.
local M={}
local DONE={complete=true,failed=true,cancelled=true}
local function identity(value)
 if type(value)~='string'then return nil end
 local hex=value:match('^armor:(%x+)$')or value:match('^(%x+)$')
 if not hex or #hex~=8 then return nil end
 return 'armor:'..hex:lower()
end
local function clock(value)
 return type(value)=='number'and value==value and value>=0 and value<9007199254740992
end
local function timeout_of(opts)
 local value=opts and opts.timeout_ms or 5000
 if not(clock(value)and value>=250 and value<=20000)then return nil end
 return value
end
function M.new(host)
 assert(type(host)=='table'and type(host.catalog)=='function'and type(host.player)=='function'
  and type(host.new_refresh)=='function','headless refresh host required')
 local report=host.report or function()end
 local self={phase='idle'}
 local coordinator,intent,target,alternate=nil,nil,nil,nil
 local outcome,reason,commits='idle',nil,0
 local function observe()
  local value,why=host.player()
  if type(value)~='table'then return nil,tostring(why or 'local player state unavailable')end
  return value
 end
 local function worn_armor(value)
  if value.settled==false then return nil,'native armor is still transitioning'end
  local worn=identity(value.request_armor_id)
  if not worn then return nil,'the worn armor identity is unavailable'end
  if identity(value.cache_armor_id)~=worn then return nil,'native armor is still transitioning'end
  return worn
 end
 -- An in-flight transition is reported before anything observes the player: mid
 -- cycle the request and cache carriers legitimately differ, and that must never
 -- be mistaken for a native change nobody here started.
 local function busy()
  if not coordinator then return nil end
  -- The coordinator marks recovery from the first attempted commit onwards, so
  -- only a stuck phase means the outstanding commit still has to be returned.
  return coordinator.phase=='blocked'and 'a native refresh needs recovery'
   or 'a native refresh is already in flight'
 end
 local function start(kind,id,passive,now,opts)
  local pending=busy();if pending then return nil,pending end
  if not clock(now)then return nil,'invalid refresh clock'end
  local limit=timeout_of(opts);if not limit then return nil,'refresh timeout outside bounds'end
  local catalog=host.catalog()
  if type(catalog)~='table'or type(catalog.catalog)~='table'or type(catalog.owned)~='table'
   or type(catalog.verify_owned)~='function'then return nil,'the armor catalog is not ready'end
  local kit=catalog.catalog[id]
  if not kit then return nil,'no armor record for '..id end
  if catalog.owned[id]~=true or catalog.verify_owned({id})~=true then return nil,id..' is not owned'end
  if not passive then
   local variants=catalog.context and catalog.context.passive_variants
   local variant=variants and variants[kit.passive_variant_id]
   if not(variant and type(variant.enum)=='number')then return nil,'the target armor passive is unavailable'end
   passive=variant.enum
  end
  local made,why=host.new_refresh()
  if not made then return nil,tostring(why or 'headless native refresh bridge unavailable')end
  local began,evidence=made:begin({target_id=id,passive_enum=passive,timeout_ms=limit},now)
  if not began then return nil,tostring(evidence)end
  coordinator,intent,target=made,kind,id
  alternate=type(evidence)=='table'and evidence.alternate_id or nil
  outcome,reason,commits='pending',nil,0;self.phase=made.phase
  report('refresh_direct.'..kind,id..(alternate and ' via '..alternate or ' direct'))
  return true
 end
 function self:equip(value,now,opts)
  local pending=busy();if pending then return nil,pending end
  local id=identity(value);if not id then return nil,'expected an 8-hex armor id'end
  local player,why=observe();if not player then return nil,why end
  local worn,transitioning=worn_armor(player);if not worn then return nil,transitioning end
  -- Re-committing what is already worn is the redraw cycle: the coordinator
  -- releases the carrier to an alternate owned armor and commits it straight back.
  local passive
  if worn==id then
   passive=player.cache_passive_enum
   if type(passive)~='number'then return nil,'the worn armor passive cache is unavailable'end
  elseif type(opts)=='table'and opts.passive_enum~=nil then
   -- A composed carrier carries its variant's passive, not the catalog's
   -- static metadata for the placeholder: the caller says what to verify.
   if type(opts.passive_enum)~='number'then return nil,'a passive enum must be a number'end
   passive=opts.passive_enum
  end
  return start('equip',id,passive,now,opts)
 end
 function self:redraw(now,opts)
  local pending=busy();if pending then return nil,pending end
  local player,why=observe();if not player then return nil,why end
  local worn,transitioning=worn_armor(player);if not worn then return nil,transitioning end
  -- Equipment must end where it started, so the passive to verify is the one the
  -- native cache already holds rather than the catalog's static metadata.
  local passive=player.cache_passive_enum
  if type(passive)~='number'then return nil,'the worn armor passive cache is unavailable'end
  return start('redraw',worn,passive,now,opts)
 end
 function self:step(now)
  if not coordinator or not clock(now)then return self.phase end
  local ok,phase,evidence=pcall(coordinator.step,coordinator,now)
  if not ok then
   -- A raised step is a coordinator guard failing outside its own handling.
   -- Stop driving rather than race the native records.
   outcome,reason,self.phase='failed',tostring(phase),'failed';coordinator=nil
   report('refresh_direct.error',reason);return self.phase
  end
  self.phase=phase or self.phase
  if type(evidence)=='table'then
   commits=evidence.commits or commits;reason=evidence.reason or reason
  end
  if DONE[phase]then
   outcome=phase;coordinator=nil;report('refresh_direct.'..phase,tostring(target))
  elseif phase=='blocked'then
   outcome='blocked';report('refresh_direct.blocked',tostring(reason))
  end
  return self.phase
 end
 -- Recovery is never automatic: an uncertain native commit stays visible and the
 -- return to the real target is an explicit request, exactly as the coordinator
 -- requires. Nothing else may start while a blocked refresh is held here.
 function self:recover(now)
  if not coordinator then return nil,'no pending native recovery'end
  if not clock(now)then return nil,'invalid refresh clock'end
  local ok,why=coordinator:recover_target()
  if not ok then return nil,tostring(why)end
  self.phase=coordinator.phase;outcome='pending';report('refresh_direct.recover',tostring(target))
  return true
 end
 -- Scheduling needs only the coordinator state, not a native player sample or
 -- a formatted diagnostic report. A blocked coordinator is still outstanding.
 function self:is_busy()return coordinator~=nil end
 function self:status()
  local evidence;if coordinator then local _,value=coordinator:status();evidence=value end
  local player,why=observe()
  return {phase=coordinator and coordinator.phase or self.phase,intent=intent,target_id=target,
   alternate_id=alternate,outcome=outcome,reason=reason or evidence and evidence.reason or nil,
   commits=evidence and evidence.commits or commits,
   needs_recovery=coordinator~=nil and coordinator.needs_recovery==true,
   native=player and {request_armor_id=player.request_armor_id,cache_armor_id=player.cache_armor_id,
    cache_passive=player.cache_passive_enum,settled=player.settled}or nil,
   native_unavailable=not player and why or nil}
 end
 return self
end
function M.format(status)
 local native=status.native
 local parts={'phase='..tostring(status.phase),'outcome='..tostring(status.outcome),
  'intent='..tostring(status.intent),'target='..tostring(status.target_id),
  'alternate='..tostring(status.alternate_id),'commits='..tostring(status.commits),
  'needs_recovery='..tostring(status.needs_recovery),
  'native='..(native and table.concat({tostring(native.request_armor_id),tostring(native.cache_armor_id),
   tostring(native.cache_passive),tostring(native.settled)},'/')or tostring(status.native_unavailable))}
 if status.reason then parts[#parts+1]='reason='..(tostring(status.reason):gsub('[\r\n]',' '))end
 return table.concat(parts,' ')
end
return M
