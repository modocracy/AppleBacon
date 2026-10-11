-- Join independently verified Armory commit and player-cache observations.
-- Native writes and observation layouts remain in their existing adapters.
local M={}
-- `opts.reconcile` builds the bridge for a profile reconcile: the actor is
-- protected whole (nothing it wears may change) and the commit brings every
-- field of the Armory's committed profile to what the actor already wears.
-- `opts.view` (a catalog, or a function returning the catalog of the tab the
-- Armory is showing) is what the grid view is verified against.
function M.new(grid,player,catalog,opts)
 local category=catalog.category or 0
 local reconcile=type(opts)=='table'and opts.reconcile==true
 local function shown()
  local view=type(opts)=='table'and opts.view or nil
  if type(view)=='function'then view=view()end
  return view
 end
 assert(not reconcile or category==0,'a profile reconcile is an armor-category commit')
 local field=category==1 and 'helmet_id' or category==2 and 'cape_id' or 'armor_id'
 local caps=grid:commit_capabilities()
 if not(caps and caps.commit_verified)then return nil,'Native equipment commit is unavailable.'end
 local first,why=player:sample();if not first then return nil,why end
 local observations=setmetatable({},{__mode='k'})
 local bridge={capabilities={commit_verified=true,cache_layout_verified=true,passive_cache_available=category~=2}}
 function bridge.snapshot()
  local view=shown()
  local native,reason=grid:commit_snapshot(catalog,(reconcile or view)and {reconcile=reconcile,view=view}or nil);if not native then return nil,reason end
  local actor,error=player:sample();if not actor then return nil,error end
  if native.local_player_id~=actor.local_player_id then return nil,'Local player changed.'end
  local other={native.other_key}
  for _,value in ipairs({actor.request,actor.current})do
   local parts={value.body_type}
   for _,key in ipairs({'armor_id','helmet_id','cape_id'})do if reconcile or key~=field then parts[#parts+1]=value[key]end end
   other[#other+1]=table.concat(parts,'|')
  end
  local out={session=tostring(native.session)..':'..tostring(actor.session_key),other_key=table.concat(other,'|'),
   pending_nonarmor=native.pending_nonarmor,controller_armor_id=native.controller_armor_id,
   profile_armor_id=native.profile_armor_id,request_armor_id=category==0 and actor.request_armor_id or actor.request[field],
   cache_armor_id=category==0 and actor.cache_armor_id or actor.current[field],cache_passive=category==0 and actor.cache_passive_enum or category==1 and actor.cache_helmet_passive_enum or nil}
  local expected={};for key,value in pairs(out)do expected[key]=value end
  observations[out]={native=native,actor=actor,expected=expected};return out
 end
 function bridge.verify(snapshot)
  local value=observations[snapshot]
  if not value then return false end
  for key,expected in pairs(value.expected)do if snapshot[key]~=expected then return false end end
  for key,actual in pairs(snapshot)do if value.expected[key]~=actual then return false end end
  return grid:verify_commit(value.native)==true and value.actor.verify()==true
 end
 function bridge.verify_owned(ids)return catalog.verify_owned(ids)==true end
 function bridge.owned_armors()
  local ids={}
  for id,owned in pairs(catalog.owned)do
   local record=catalog.records and catalog.records[id]
   if owned==true and type(id)=='string'and id:match('^armor:%x%x%x%x%x%x%x%x$')
    and (record and record.category==category or not catalog.records)then
    ids[#ids+1]=id
   end
  end
  table.sort(ids);return ids
 end
 function bridge.commit_owned(id,snapshot)
  if not bridge.verify(snapshot)then return nil,'Equipment changed before Apply.'end
  if catalog.owned[id]~=true or catalog.verify_owned({id})~=true then return nil,'Armor ownership changed before Apply.'end
  local seen=observations[snapshot]
  if reconcile then
   local request=seen.actor.request
   if id~=request.armor_id then return nil,'A reconcile commits only the worn armor.'end
   return grid:commit_worn(seen.native,catalog,{armor_id=request.armor_id,helmet_id=request.helmet_id,cape_id=request.cape_id})
  end
  return grid:commit_owned(id,seen.native,catalog)
 end
 return bridge
end
return M
