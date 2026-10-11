-- THROWAWAY INVESTIGATION PROBE -- not part of the shipped feature set.
-- Read-only hex dump of the native customization manager's per-player region so
-- the unmapped request/cache bytes can be attributed offline. Never writes, never
-- exports pointers: every address is emitted relative to the manager base.
-- Delete this module and its debug command once the field map is recorded.
local M={}
local function u32(s,o)
 if type(s)~='string' or #s<o+4 then return nil end
 local a,b,c,d=s:byte(o+1,o+4);return a+b*256+c*65536+d*16777216
end
local function ptr(s,o)
 o=o or 0;local lo,hi=u32(s,o),u32(s,o+4)
 if not hi or hi>=32768 then return nil end
 local n=lo+hi*4294967296;return n>=65536 and n or nil
end
local function hex(s)return(s:gsub('.',function(c)return string.format('%02x',c:byte())end))end

-- Region covering the slot-info array (+0x948), the cache array (+0x96c, 4x68)
-- and the request array (+0xa7c, 4x64), with margin on both sides.
local BASE,SPAN,CHUNK=0x900,0x300,128
local MAX_SPAN=0x1000

function M.new(bridge)
 assert(type(bridge)=='table' and type(bridge.read)=='function' and type(bridge.verify)=='function','verified read bridge required')
 local self={}
 -- args: optional '<root> <hexbase> <hexspan>', root one of manager|players|player.
 function self:sample(args)
  local root,base,span='manager',BASE,SPAN
  if type(args)=='string' and args~='' then
   local r,b,sp=args:match('^(%a+)%s+(%x+)%s+(%x+)$')
   assert(r and (r=='manager' or r=='players' or r=='player'),'window root must be manager, players or player')
   base,span=tonumber(b,16),tonumber(sp,16)
   assert(base and span and span>0 and span<=MAX_SPAN,'window span rejected')
   root=r
  end
  -- A live session mutates peer records while we read. Retry a bounded number of
  -- times so a moving peer yields a coherent snapshot instead of a hard failure;
  -- the stability assertion itself is never relaxed.
  local ok,result
  for attempt=1,12 do
   ok,result=self:attempt(root,base,span)
   if ok then result.attempts=attempt;break end
   if not tostring(result):find('during observation',1,true) then break end
  end
  if not ok then return nil,tostring(result) end
  return result
 end
 function self:attempt(root,base,span)
  local ok,result=pcall(function()
   assert(bridge.verify(),'customization compatibility changed')
   assert(type(bridge.players)=='number','local-player signature unavailable')
   local watches={};local reads=0
   local function watch(at,n)
    reads=reads+1;assert(reads<=64,'customization read budget exceeded')
    assert(type(at)=='number' and at%1==0 and at>=65536 and at+n<140737488355328 and n>0 and n<=CHUNK,'customization read bounds rejected')
    local s=bridge.read(at,n);assert(type(s)=='string' and #s==n,'customization data unavailable')
    watches[#watches+1]={at=at,bytes=s};return s
   end
   local manager=assert(ptr(watch(bridge.armor_catalog,8)),'customization manager unavailable')
   local players=assert(ptr(watch(bridge.players,8)),'players manager unavailable')
   local counts=watch(players+0x84,8);local total,locals=u32(counts,0),u32(counts,4)
   assert(total>=1 and total<=4,'implausible player count')
   local player=assert(ptr(watch(players+0xe8,8)),'local player unavailable')
   local local_id=u32(watch(player+8,4),0)

   -- Slot occupancy, read through the same +0x948 info array the local probe uses.
   local slots={}
   for index=0,3 do
    local info=ptr(watch(manager+0x948+index*8,8))
    local entity=info and u32(watch(info+0x10,4),0) or nil
    slots[index]={present=info~=nil,entity=entity,live=entity~=nil and entity~=0x7fff}
   end

   -- Player id -> slot map, so remote slots can be attributed once peers exist.
   local map=watch(manager+0x930,20)
   local entries,capacity,empty=ptr(map),u32(map,8),u32(map,12)
   local pairs_found={}
   if entries and capacity and capacity>=1 and capacity<=4096 then
    for i=0,math.min(capacity,64)-1 do
     local row=watch(entries+i*8,8);local key,value=u32(row,0),u32(row,4)
     if key~=empty then pairs_found[#pairs_found+1]={key=key,slot=value} end
    end
   end

   local anchor=manager
   if root=='players' then anchor=players elseif root=='player' then anchor=player end
   local region={}
   for offset=0,span-1,CHUNK do
    region[#region+1]=watch(anchor+base+offset,math.min(CHUNK,span-offset))
   end
   region=table.concat(region)

   for _,w in ipairs(watches)do
    assert(bridge.read(w.at,#w.bytes)==w.bytes,'customization changed during observation')
   end
   assert(bridge.verify(),'customization compatibility changed during observation')
   return {total=total,locals=locals,local_id=local_id,slots=slots,map=pairs_found,
    root=root,base=base,region=hex(region)}
  end)
  return ok,result
 end
 return self
end

-- THROWAWAY WRITE EXPERIMENT. Local player's slot only, and only the offsets that
-- were observed zero for both a local modded player and a remote vanilla player.
-- Refuses to touch a field that is not currently zero, so real state is never clobbered.
local FREE={[0x14]=true,[0x18]=true,[0x1c]=true,[0x20]=true}
local CACHE_BASE,CACHE_STRIDE=0x96c,68
function M.poke(bridge,writer,mode)
 assert(type(writer)=='table' and type(writer.write)=='function','writer required')
 assert(mode=='marker' or mode=='restore','mode must be marker or restore')
 local ok,result=pcall(function()
  assert(bridge.verify(),'customization compatibility changed')
  local manager=assert(ptr(bridge.read(bridge.armor_catalog,8),0),'customization manager unavailable')
  local players=assert(ptr(bridge.read(bridge.players,8),0),'players manager unavailable')
  local counts=bridge.read(players+0x84,8)
  assert(u32(counts,4)==1,'exactly one local player required')
  local player=assert(ptr(bridge.read(players+0xe8,8),0),'local player unavailable')
  local player_id=u32(bridge.read(player+8,4),0)
  -- Resolve the local player's own slot through the same hash the read path uses.
  local map=bridge.read(manager+0x930,20)
  local entries,capacity,empty,multiplier=ptr(map),u32(map,8),u32(map,12),u32(map,16)
  assert(entries and capacity>=1 and capacity<=4096,'player lookup capacity rejected')
  local start=((player_id%capacity)*(multiplier%capacity))%capacity
  local slot
  for probe=0,math.min(capacity,64)-1 do
   local row=bridge.read(entries+((start+probe)%capacity)*8,8)
   local key=u32(row,0)
   if key==player_id then slot=u32(row,4);break end
   if key==empty then break end
  end
  assert(slot and slot<4,'local customization slot unavailable')
  local base=manager+CACHE_BASE+slot*CACHE_STRIDE
  local lines={}
  local markers={[0x14]='5a5a5a5a',[0x18]='a5a5a5a5',[0x1c]='3c3c3c3c',[0x20]='c3c3c3c3'}
  for offset in pairs(FREE) do
   local before=bridge.read(base+offset,4)
   local want
   if mode=='marker' then
    assert(before=='\0\0\0\0',string.format('offset 0x%02x is not zero; refusing to overwrite real state',offset))
    want=(markers[offset]:gsub('..',function(x)return string.char(tonumber(x,16))end))
   else
    want='\0\0\0\0'
   end
   local wrote=writer.write(base+offset,want)
   local after=bridge.read(base+offset,4)
   lines[#lines+1]=string.format('slot=%d offset=0x%02x wrote=%s readback=%s',slot,offset,
    tostring(wrote==true),hex(after))
  end
  table.sort(lines)
  return 'mode='..mode..'\n'..table.concat(lines,'\n')
 end)
 if not ok then return nil,tostring(result) end
 return result
end

function M.format(r)
 if type(r)~='table' then return 'AB_CUSTOMIZATION_RAW 1\nstatus=unavailable\n' end
 local out={'AB_CUSTOMIZATION_RAW 1',
  'players_total='..r.total,'players_local='..r.locals,'local_player_id='..r.local_id,
  'window_root='..tostring(r.root),'read_attempts='..tostring(r.attempts or 1)}
 for index=0,3 do
  local s=r.slots[index]
  out[#out+1]=string.format('slot%d present=%s live=%s entity=%s',index,
   tostring(s.present),tostring(s.live),s.entity and string.format('%08x',s.entity) or 'none')
 end
 for _,m in ipairs(r.map) do
  out[#out+1]=string.format('map player_id=%08x slot=%d',m.key,m.slot)
 end
 -- 32 bytes per line, offsets relative to the manager base only.
 for i=0,#r.region/2-1,32 do
  out[#out+1]=string.format('+%04x %s',r.base+i,r.region:sub(i*2+1,i*2+64))
 end
 out[#out+1]='status=observed'
 return table.concat(out,'\n')..'\n'
end
return M
