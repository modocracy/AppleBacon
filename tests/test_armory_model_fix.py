"""The Armory's large model is shown again only in the hidden state the game leaves it in."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
local F=dofile('src/armory_model_fix.lua')
local ffi=require('ffi')
local GAME,EXE=0x180000000,0x140000000
local mem,ranges={},{}
local function map(base,size)ranges[#ranges+1]={base,size}end
local function poke(at,bytes)for i=1,#bytes do mem[at+i-1]=bytes:byte(i)end end
local function u32le(v)return string.char(v%256,math.floor(v/256)%256,math.floor(v/65536)%256,math.floor(v/16777216)%256)end
local function u64le(v)return u32le(v%4294967296)..u32le(math.floor(v/4294967296))end
local function f32le(v)return ffi.string(ffi.new('float[1]',v),4)end
local function put(at,bytes)map(at,#bytes);poke(at,bytes)end
local function unhex(h)return(h:gsub('..',function(v)return string.char(tonumber(v,16))end))end
local shown=0
local api={module=function(name)return name=='game.dll'and GAME or EXE end,
 calls={show_model=function(model)shown=shown+1;poke(model+0xdb0,'\0\1')end}}
function api.read(at,size)
 for _,r in ipairs(ranges)do
  if at>=r[1]and at+size<=r[1]+r[2]then
   local out={};for i=0,size-1 do out[i+1]=string.char(mem[at+i]or 0)end
   return table.concat(out)
  end
 end
end
put(GAME+F.SIGNATURE.rva,unhex(F.SIGNATURE.hex)..string.rep('\0',8))
put(GAME+0x3326308,u64le(EXE+0x27c8d80))
local SM,DISPATCH,UI,WORLD,OWNER=0x300000,0x310000,0x320000,0x330000,0x1000000
put(GAME+0x347ce28,u64le(SM));map(SM+0x429c,24);poke(SM+0x429c,u32le(5));poke(SM+0x429c+20,u32le(1))
put(GAME+0x3326e68,u64le(DISPATCH));put(DISPATCH+5740,u32le(1));put(DISPATCH+5744,u64le(OWNER)..u32le(224)..u32le(0))
put(GAME+0x347cd90,u64le(UI));put(UI+15432,u64le(WORLD))
local G=OWNER+523752;local MANAGER=G-0x6d0;local DETAIL=MANAGER+0x99d70
put(G+602052,u32le(4));put(G+272+84,f32le(1));map(MANAGER+0x178c88,16)
local model=DETAIL+0x20640;map(model+0xdb0,0x58)
local function state(hidden,active,kind,kit,loadout)
 poke(model+0xdb0,string.char(hidden,active,0,0)..u32le(kind)..string.rep('\0',8)..u32le(kit))
 for _,o in ipairs({0x4c,0x50,0x54})do poke(model+0xdb0+o,u32le(loadout))end
end
local n=F.new(api)
'''


def run(body):
    result = subprocess.run(['luajit', '-'], input=FIXTURE + body, text=True,
                            capture_output=True, cwd=ROOT, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr


def test_another_game_build_is_refused_and_named():
    run(r'''
poke(GAME+F.SIGNATURE.rva,'\0')
local ok,why=pcall(F.new,api)
assert(not ok and tostring(why):find('another game build: show_model differs',1,true),tostring(why))
poke(GAME+F.SIGNATURE.rva,unhex(F.SIGNATURE.hex):sub(1,1));poke(GAME+0x3326308,u64le(EXE+0x27c8d88))
ok,why=pcall(F.new,api);assert(not ok and tostring(why):find('API root differs',1,true),tostring(why))
''')


def test_the_picker_is_found_only_while_the_ship_armory_shows_equipment():
    run(r'''
local c=assert(n:context())
assert(c.owner==OWNER and c.world==WORLD and c.detail==DETAIL and c.mode==0 and c.category==0)
poke(MANAGER+0x178c88,u32le(1));poke(MANAGER+0x178c88+12,u32le(2))
c=n:context();assert(c.mode==1 and c.category==2)
poke(SM+0x429c,u32le(3));assert(n:context()==nil,'another screen is on top')
poke(SM+0x429c,u32le(5));poke(G+602052,u32le(2));assert(n:context()==nil,'not the equipment grid')
poke(G+602052,u32le(4));poke(DISPATCH+5744+8,u32le(229));assert(n:context()==nil,'the briefing picker is not this one')
''')


def test_the_hidden_model_is_shown_only_in_the_state_the_game_leaves_it_in():
    run(r'''
local c=n:context()
state(1,0,3,0x1369b95b,7);assert(n:show_model(c)==true and shown==1)
assert(n:show_model(c)==false and shown==1,'already visible')
state(1,0,3,0,7);assert(n:show_model(c)==false,'no kit yet')
state(1,0,9,0x1369b95b,7);assert(n:show_model(c)==false,'not a cosmetic model')
state(1,0,3,0x1369b95b,0);assert(n:show_model(c)==false,'the loadout is incomplete')
state(1,1,3,0x1369b95b,7);assert(n:show_model(c)==false,'not the hidden and inactive state')
state(1,0,3,0x1369b95b,7);c.mode=1;assert(n:show_model(c)==false,'Compare hides the model itself')
assert(shown==1)
state(1,0,3,0x1369b95b,7);assert(n:step()==true and shown==2,'one frame shows it')
poke(SM+0x429c,u32le(3));state(1,0,3,0x1369b95b,7);assert(n:step()==false and shown==2,'not outside the picker')
''')
