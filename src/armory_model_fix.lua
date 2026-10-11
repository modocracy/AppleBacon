-- The Armory's large armor model, shown again when the game leaves it hidden.
-- Some routes into the equipment picker leave the single view's model hidden
-- although it has a kit and a complete loadout (seen on every entry by those
-- routes). The game's own "show model" call is made only in exactly that
-- state. Addresses are for one game build and are used only after the
-- instruction bytes at the entry point and the API root match; any mismatch
-- makes M.new fail and nothing is ever called.
--
-- api.read(address, size) -> string|nil, api.module(name) -> base|nil,
-- api.calls overrides the native call (tests).
local M={}
M.SIGNATURE={name='show_model',module='game',rva=0x192b170,hex='40534881ecd0000000488bd98891b00d00004881c11001000084d274500f57c9'}
local function unhex(hex)return(hex:gsub('..',function(v)return string.char(tonumber(v,16))end))end
local function u32(s,o)
 o=o or 0;if type(s)~='string'or #s<o+4 then return nil end
 local a,b,c,d=s:byte(o+1,o+4);return a+b*256+c*65536+d*16777216
end
local function pointer(s,o)
 o=o or 0;local lo,hi=u32(s,o),u32(s,o+4)
 if not hi or hi>=32768 then return nil end
 local n=lo+hi*4294967296;return n>=65536 and n or nil
end
local function float(s,o)
 local a,b,c,d=s:byte(o+1,o+4)
 local sign=d>=128 and -1 or 1;local exponent=(d%128)*2+math.floor(c/128);local mantissa=(c%128)*65536+b*256+a
 if exponent==0 then return sign*mantissa*2^-149 end
 if exponent==255 then return 0/0 end
 return sign*(1+mantissa/8388608)*2^(exponent-127)
end
local function default_api()
 local ffi=require('ffi')
 pcall(ffi.cdef,[[
  void *GetModuleHandleA(const char *name);
  void *GetCurrentProcess(void);
  int ReadProcessMemory(void *process,const void *address,void *buffer,size_t size,size_t *read);
 ]])
 local kernel=ffi.load('kernel32');local process=kernel.GetCurrentProcess()
 local count=ffi.new('size_t[1]');local scratch=ffi.new('uint8_t[?]',4096)
 local api={ffi=ffi}
 function api.read(address,size)
  if type(address)~='number'or address<65536 or size<1 or size>4096 then return nil end
  if kernel.ReadProcessMemory(process,ffi.cast('const void *',address),scratch,size,count)==0 or count[0]~=size then return nil end
  return ffi.string(scratch,size)
 end
 function api.module(name)
  local handle=kernel.GetModuleHandleA(name);if handle==nil then return nil end
  return tonumber(ffi.cast('uintptr_t',handle))
 end
 return api
end
function M.new(api)
 api=api or default_api()
 local game=assert(api.module('game.dll'),'game.dll not loaded')
 local exe=assert(api.module(nil),'process module unavailable')
 local function read(address,size)
  local bytes=api.read(address,size);assert(bytes,'memory unreadable');return bytes
 end
 local function ptr(address)return pointer(read(address,8))end
 local s=M.SIGNATURE;local code=unhex(s.hex);local at=game+s.rva
 assert(api.read(at,#code)==code,'another game build: show_model differs')
 assert(ptr(game+0x3326308)==exe+0x27c8d80,'another game build: API root differs')
 local call=api.calls and api.calls.show_model or(function()
  local fn=api.ffi.cast('void (*)(void *,uint8_t)',at)
  return function(model)fn(api.ffi.cast('void *',model),0)end
 end)()
 local self={}
 -- The ship Armory's equipment picker, or nil: `detail` is the single-view
 -- detail widget, `mode` 0 single / 1 compare, `category` 0 armor, 1 helmet,
 -- 2 cape. Fixed offsets hold only while this controller is listed.
 function self:context()
  local sm=ptr(game+0x347ce28);if not sm then return nil end
  local stack=read(sm+0x429c,24);local depth=u32(stack,20)
  if depth<1 or depth>5 or u32(stack,(depth-1)*4)~=5 then return nil end
  local dispatch=ptr(game+0x3326e68);if not dispatch then return nil end
  local count=u32(read(dispatch+5740,4));assert(count<=64,'UI dispatch bounds changed')
  local entries=read(dispatch+5744,count*16);local owner
  for i=0,count-1 do
   if u32(entries,i*16+8)==224 then assert(not owner,'ambiguous Armory');owner=pointer(entries,i*16)end
  end
  if not owner then return nil end
  local ui=ptr(game+0x347cd90);local world=ui and ptr(ui+15432);if not world then return nil end
  local g=owner+523752;local manager=g-0x6d0
  -- The grid remains allocated after Back; its resolved alpha includes parent visibility.
  local alpha=float(read(g+272+84,4),0)
  if not(alpha>=.95 and alpha<=1.01)then return nil end
  if u32(read(g+602052,4))~=4 then return nil end
  local mode=u32(read(manager+0x178c88,4));if mode~=0 and mode~=1 then return nil end
  local category=u32(read(manager+0x178c88+12,4));if category>2 then return nil end
  return{owner=owner,world=world,detail=manager+0x99d70,mode=mode,category=category}
 end
 -- True when the model had to be shown. Compare hides the model itself.
 function self:show_model(c)
  if not c or c.mode~=0 then return false end
  local fresh=self:context()
  if not(fresh and fresh.owner==c.owner and fresh.world==c.world and fresh.mode==0
   and fresh.category==c.category and fresh.detail==c.detail)then return false end
  local model=c.detail+0x20640
  local state=read(model+0xdb0,0x58)
  if state:byte(1)~=1 or state:byte(2)~=0 then return false end
  local kind=u32(state,4);if kind<2 or kind>4 or u32(state,16)==0 then return false end
  for _,offset in ipairs({0x4c,0x50,0x54})do if u32(state,offset)==0 then return false end end
  if api.read(at,#code)~=code then return false end
  call(model)
  local after=read(model+0xdb0,2)
  return after:byte(1)==0 and after:byte(2)==1
 end
 -- One frame: the picker's model, if the game left it hidden.
 function self:step()
  local c=self:context();if not c then return false end
  return self:show_model(c)
 end
 return self
end
return M
