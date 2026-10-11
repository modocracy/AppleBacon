"""AppleBacon's MODS-tab row: an applied, self-resetting log export."""
from test_runtime import run_lua


FIXTURE = r'''
local Menu=dofile('src/applebacon_options_menu.lua')
local specs,values,callbacks,events={},{},{},{}
local remembered={}
local exports=0
local result={path='C:/Desktop/AppleBacon-Logs.txt',unavailable=0}
local api={ready=function()return true end,get=function(id)return values[id]end,
 register_option=function(id,spec)
  assert(specs[id]==nil,'permanent spec registered twice')
  specs[id]=spec;values[id]=remembered[id]or spec.default;return true
 end,
 set=function(id,value)values[id]=value;return true end,
 on_change=function(id,callback)callbacks[id]=callback;return true end}
local menu=Menu.new{menu=api,export_logs=function()exports=exports+1;return result end,
 report=function(name,value)events[#events+1]={name,value}end}
local function apply(id,value)values[id]=value;callbacks[id](value);menu:step()end
local function said(name)for _,e in ipairs(events)do if e[1]==name then return e[2]end end end
'''


def test_the_row_registers_once_and_never_exports_a_remembered_request():
    run_lua(FIXTURE + r'''
remembered[Menu.EXPORT_ID]=2
assert(menu:step()=='ready' and menu:step()=='ready')
assert(specs[Menu.EXPORT_ID].mod=='AppleBacon' and menu:status().rows==1)
assert(values[Menu.EXPORT_ID]==1 and exports==0,'a request left from an earlier session is reset, not run')
''')


def test_export_now_saves_once_and_shows_the_result():
    run_lua(FIXTURE + r'''
assert(menu:step()=='ready')
apply(Menu.EXPORT_ID,2)
assert(exports==1 and values[Menu.EXPORT_ID]==3 and menu:status().export_path==result.path)
assert(said('applebacon.options.export_saved')==result.path)
result={path='C:/Desktop/x.txt',unavailable=2};apply(Menu.EXPORT_ID,2)
assert(exports==2 and values[Menu.EXPORT_ID]==5,'saved, some logs unavailable')
result=nil;apply(Menu.EXPORT_ID,2)
assert(values[Menu.EXPORT_ID]==4 and menu:status().export_error,'a failed export says so')
apply(Menu.EXPORT_ID,1);assert(exports==3,'choosing the idle row does nothing')
''')


def test_an_absent_waiting_or_refusing_host_does_not_escape():
    run_lua(r'''
local Menu=dofile('src/applebacon_options_menu.lua')
assert(Menu.new{}:step()=='absent')
assert(Menu.new{menu={ready=function()return false,'loading'end}}:step()=='waiting')
assert(Menu.new{menu={ready=function()error('boom')end}}:step()=='waiting')
local refused=Menu.new{menu={ready=function()return true end,register_option=function()return false,'full'end}}
assert(refused:step()=='ready' and refused:status().refused==1)
local text=Menu.format_status(refused:status())
assert(text:find('AB_OPTIONS 1',1,true)==1 and text:find('refused=1',1,true))
''')
