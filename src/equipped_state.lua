-- Mod-private startup intent. Never persist a native pointer or a custom game
-- item ID. The native save continues to contain the ordinary appearance armor.
local M={}
local HEADER='AB_EQUIPPED 1\n'
local OFF=HEADER..'none\n'
local function native_id(value)
 return type(value)=='string'and value:match('^armor:%x%x%x%x%x%x%x%x$')~=nil
end
local FIELDS={'appearance_id','stats_id','passive_variant_id'}
local function same(a,b)
 if not(a and b)then return false end
 for _,k in ipairs(FIELDS)do if a[k]~=b[k]then return false end end
 return true
end
function M.encode(S,label,request)
 if not label then return OFF end
 if not native_id(request.appearance_id)then return nil,'native armor identity required'end
 local state=S.new();state.presets[label]=request;state.requested=request
 local raw,why=S.encode(state);if not raw then return nil,why end
 raw=HEADER..raw
 if #raw>4096 then return nil,'equipped record exceeds bounds'end
 return raw
end
function M.decode(S,raw)
 if raw==OFF then return false end
 if type(raw)~='string'or #raw>4096 or raw:sub(1,#HEADER)~=HEADER then return nil,'invalid equipped record'end
 local state,why=S.decode(raw:sub(#HEADER+1));if not state then return nil,why end
 if next(state.catalog)or next(state.owned)then return nil,'equipped record contains catalog data'end
 local label,request=next(state.presets)
 if not label or next(state.presets,label)or not same(request,state.requested)
  or not native_id(request.appearance_id)then return nil,'invalid equipped variant'end
 return {label=label,request=request,target_id=request.appearance_id,id=request.id,version=state.decoded_version}
end
function M.resolve_target(record)
 if not record then return nil end
 return native_id(record.target_id)and record.target_id or nil
end
-- The saved variant a record names, and the label it goes by now: by its id,
-- so that a variant renamed since is still the one that was on.
-- Unsaved in-memory requests can have only labels. An id never retargets a
-- deleted variant to a different one that later reused its name.
function M.saved_of(record,domain)
 local id=record.request and record.request.id
 if id then
  for label,request in pairs(domain.presets)do if request.id==id then return request,label end end
  local candidate=domain.presets[record.label]
  if candidate and candidate.id then return nil end
 end
 return domain.presets[record.label],record.label
end
function M.definition_matches(record,domain)
 if not(record and domain)then return false end
 local request,label=M.saved_of(record,domain)
 -- What is restored and selected again is asked for by label: the one the
 -- variant has today.
 if request then record.label=label end
 return same(request,record.request)
end
function M.matches(record,domain,armor)
 local target=M.resolve_target(record)
 return target~=nil and target==armor and M.definition_matches(record,domain)or false
end
M.startup_matches=M.matches
function M.new(fs,S,report,filename)
 filename=filename or 'equipped.state'
 assert(filename=='equipped.state'or filename=='equipped-helmet.state'or filename=='equipped-cape.state','invalid equipment slot file')
 report=report or function()end
 local writer=S.writer(fs,filename)
 local raw,reason=fs.read(filename)
 local record,locked
 if raw then
  record,reason=M.decode(S,raw);locked=record==nil
  if record then writer.loaded(raw,record.version)end
 elseif reason and reason~='missing'then locked=true end
 if locked then report('restore.record_unavailable',reason)end
 local self={}
 function self:record()return record or nil end
 function self:clear()
  -- Invalid/unreadable records cannot authorize startup restoration. Preserve
  -- them for diagnosis; do not turn a storage failure into an equipment lock.
  if not record then return true end
  local ok,why=writer.write(OFF)
  if not ok then return nil,'Could not clear startup restoration: '..tostring(why)end
  record=false;return true
 end
 function self:remember(label,request)
  if not label then return self:clear()end
  if locked then return nil,'equipped record needs recovery'end
  local value,why=M.encode(S,label,request);if not value then return nil,why end
  local ok,err=writer.write(value);if not ok then return nil,err end
  record=assert(M.decode(S,value));return true
 end
 return self
end
return M
