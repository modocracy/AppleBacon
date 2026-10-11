"""Exercise the shared accessory wizard end to end without loading the game."""
import pytest
from test_runtime import run_lua

FIXTURE=r'''
local S=dofile('src/state.lua')
local UI=dofile('src/accessory_ui.lua')
local now,commits,patches,builds=0,0,0,0
local full_previews,widget_refreshes=0,0
local files={};local latest;local native_category=CATEGORY
local A,B='armor:00000001','armor:00000002'
local selected=A;local worn=B;local applied_passive=2
local catalog={category=CATEGORY,catalog={
 [A]={appearance_id=A,stats_id='native-stats:00000001',passive_variant_id='perk:1'},
 [B]={appearance_id=B,stats_id='native-stats:00000002',passive_variant_id='perk:2'}},
 owned={[A]=true,[B]=true},records={},context={category=CATEGORY,labels={appearance_id={[A]='One',[B]='Two'},
 passive_variant_id={['perk:1']='First',['perk:2']='Second'}},stats_profiles={},passive_variants={['perk:1']={enum=1},['perk:2']={enum=2}}},
 capabilities={accessory_transmog_enabled=true,ownership_verified=true}}
for _,id in ipairs({A,B})do catalog.context.stats_profiles[catalog.catalog[id].stats_id]={category=CATEGORY,base_only=true,
 weight_profile_verified=true,body_weights={{body_type=3,pieces={{slot=CATEGORY-1,kind=2,weight=0}}}}}end
catalog.verify_owned=function(ids)for _,id in ipairs(ids)do if not catalog.owned[id]then return false end end;return true end
local grid={phase='ready'}
local custom=0
function grid:snapshot()return {kind=4,identity_mapping_verified=true,native_category=native_category,native_view_mode=0,
 selected_kit_id=selected,scroll=0,appearance_previews={},widgets={},logical_selected_index=0,item_count=2+custom}end
function grid:input_scope(category)return native_category==category end
function grid:consume_select()return true end
function grid:consume_creator()return true end
function grid:inspect_model()return {offers={{owned=true,kit_id=A},{owned=true,kit_id=B}},item_count=2}end
function grid:select_kit(id)selected=id;return {}end
function grid:preview_kit(id)selected=id;return {kit_id=id}end
-- As the real grid: the model is built from the record the focused card stands on.
function grid:preview_variant_details(id,stats,passive,actual,options)
 assert(actual==catalog and actual.context.passive_variants[passive])
 local model=options.model_kit_id or(options.focus_index~=nil and options.focus_kit_id or id)
 if options.widgets_only then widget_refreshes=widget_refreshes+1;assert(selected==model)
 else full_previews=full_previews+1;selected=model end
 return {kit_id=model,native_detail_view=true}
end
function grid:focus_index(_,id)selected=id;return {}end
function grid:detail_state()return {kit_id=selected}end
function grid:selection_index()return 0 end
function grid:presentation_bridge()return {}end
NativeGridPresentation={new=function()return {phase='idle',
 attempt=function(self,cards)builds=builds+1;custom=#cards;self.phase='active';return {phase='active'}end,
 restore=function(self)custom=0;self.phase='restored';return {phase='restored'}end,
 status=function(self)return {phase=self.phase}end}end}
local player={sample=function()
 local v={body_type=0,armor_id='armor:00000009',helmet_id='armor:00000008',cape_id='armor:00000007'}
 v[CATEGORY==1 and 'helmet_id'or 'cape_id']=worn
 return {request=v,current=v,request_armor_id=v.armor_id,cache_armor_id=v.armor_id,
 cache_helmet_passive_enum=applied_passive,verify=function()return true end}
end}
-- The real VariantSession prepares only on explicit Apply; the coordinator
-- fixture records the handoff and simulates the resulting equipment transition.
ArmorRefreshBridge={new=function()return {}end}
ArmorRefresh={new=function()local done;return {
 begin=function(_,r)assert(r.prepare_target());worn=r.target_id;applied_passive=r.passive_enum;commits=commits+1;done=true;return true end,
 step=function()return 'complete',{status='fixture'}end}end}
local panel={draw=function(_,sample,view)latest=view;return true end,clear=function()end,
 hit=function()return nil end,input_policy=function()return {}end}
local fs={read=function(name)return files[name],files[name]and nil or 'missing'end,
 write_atomic=function(name,value)files[name]=value;return true end,now=function()return now end}
local ui=UI.new{category=CATEGORY,state=S,fs=fs,panel=panel,engine={Gui={resolution=function()return 1920,1080 end}},
 catalog=function()return catalog end,grid=function()return grid end,
 screen=function()return 'armory' end,token=function()return 'ship' end,
 player=player,compatible=function()return true end,patch=function()
 local active=false;return {plan=function(_,_,r)return {request=r,target_id=r.appearance_id}end,
 apply=function()active=true;patches=patches+1;return true end,reset=function()active=false;return true end,is_active=function()return active end}
end}
local sample={kind='armory',token='ship'}
-- One frame as main.lua drives a tab: hidden while another list is up,
-- observed and framed while its own is.
local function draw()
 now=now+200
 if native_category~=CATEGORY or not ui:available()then ui:hide(now);return end
 ui:observe(now);ui:frame(now,sample,{x=0,y=0,down=false})
end
-- Capture the real workflow solely to drive semantic actions in this fixture.
local Real=dofile('src/ui_workflow.lua');local flow
UiWorkflow={new=function(...)flow=Real.new(...);return flow end}
'''

@pytest.mark.parametrize('category', [1, 2])
def test_input_supplier_is_only_polled_in_visible_matching_picker(category):
    run_lua(f'local CATEGORY={category}\n'+FIXTURE+'''
local polls=0
local function input()
 polls=polls+1;return {x=0,y=0,down=false}
end
assert(ui:before(input));assert(polls==0)
draw();assert(ui:before(input));assert(polls==1)
native_category=0
assert(ui:before(input));assert(polls==1)
draw();native_category=CATEGORY
assert(ui:before(input));assert(polls==1) -- Remains hidden until drawn again.
draw();assert(ui:before(input));assert(polls==2)
ui:hide(now)
for i=1,1000 do assert(ui:before(input))end
assert(polls==2)
''')

@pytest.mark.parametrize('category,file',[(1,'helmets.state'),(2,'capes.state')])
def test_same_plus_create_save_select_and_apply_flow(category,file):
    run_lua(f'local CATEGORY={category}\n'+FIXTURE+f'''
draw();assert(builds==0);draw();assert(builds==1 and latest.section.tiles[1].kind=='add')
assert(flow:action{{type='open'}});assert(flow:action{{type='select_look',id=A}})
assert(flow:view().step==3 and flow:view().step_count==2)
assert(flow:action{{type='select_passive',id='perk:2'}})
assert(flow:action{{type='create'}});assert(patches==0 and commits==0 and worn==B)
-- Choosing a look in the creator is a full native preview of it, as on the armor tab.
local chosen=full_previews;assert(chosen==1)
assert(files['{file}'] and not files['applebacon.state'])
local saved=assert(S.decode(files['{file}']));assert(saved.presets['One - Second'])
draw();draw();assert(builds==2)
for i=1,4 do draw()end
assert(flow:view().can_apply)
assert(flow:action{{type='apply_variant',label='One - Second'}})
draw();assert(commits==1 and patches==1 and worn==A)
assert(flow:view().variant_phase=='equipped')
assert(full_previews==chosen+1 and widget_refreshes==1 and not flow:view().accessory_review)
native_category=0;assert(ui:before({{x=0,y=0,down=false}}));assert(ui:is_active())
''')


@pytest.mark.parametrize('category',[1,2])
def test_accessories_always_skip_stats_even_with_different_profiles(category):
    run_lua(f'local CATEGORY={category}\n'+FIXTURE+r'''

catalog.context.stats_profiles['native-stats:00000002'].body_weights[1].pieces[1].weight=2
draw();draw();assert(flow:action{type='open'})
assert(flow:action{type='select_look',id=A})
local view=flow:view();assert(view.step==3 and view.step_count==2 and view.selection.stats_id=='native-stats:00000001')
assert(flow:action{type='back'});assert(flow:view().step==1)
assert(flow:action{type='select_look',id=B});assert(flow:view().selection.stats_id=='native-stats:00000002')
assert(not flow:action{type='select_stats',id='weight:other'})
''')


@pytest.mark.parametrize('category',[1,2])
def test_unchanged_ownership_polls_do_not_rebuild_list_or_restart_selected_preview(category):
    run_lua(f'local CATEGORY={category}\n'+FIXTURE+r'''

local function replacement()catalog.owned={[A]=true,[B]=true}end
draw();draw();assert(builds==1)
assert(flow:action{type='open'} and flow:action{type='select_look',id=A})
for i=1,30 do replacement();draw()end
assert(builds==1 and flow:view().step==3)
assert(flow:action{type='select_passive',id='perk:2'} and flow:action{type='create'})
local chosen=full_previews
draw();draw();for i=1,4 do draw()end
assert(builds==2 and full_previews==chosen+1 and flow:view().can_apply)
for i=1,60 do replacement();draw()end
assert(builds==2 and full_previews==chosen+1 and widget_refreshes==0 and flow:view().can_apply)
assert(flow:view().selected_variant.label=='One - Second')
catalog.owned={[A]=true};for i=1,3 do draw()end
assert(builds==3 and not flow:view().can_apply)
for i=1,10 do draw()end;assert(builds==3,'one rebuild for one ownership change')
''')


# 2026-09-30: the helmet restore raced the body redraw that follows the armor
# restore and was skipped for the whole session ("finish pending native
# non-armor changes first"). A native refresh in flight is a reason to wait,
# never to give up.
def test_accessory_restore_waits_for_an_in_flight_native_refresh_instead_of_skipping():
    fixture=FIXTURE.replace('local ui=UI.new{','local host={').replace('end}\nlocal sample=', 'end}\nlocal ui=UI.new(host)\nlocal sample=')
    run_lua('local CATEGORY=1\n'+fixture+'''
local E=dofile('src/equipped_state.lua')
local label='Saved';local saved=S.new();saved.presets[label]=catalog.catalog[A]
files['helmets.state']=assert(S.encode(saved));local request=assert(S.decode(files['helmets.state'])).presets[label]
files['equipped-helmet.state']=assert(E.encode(S,label,request))
host.startup_guard=function()return true end;host.data_bridge={}
function grid:idle_menu()return true end
function grid:player_refresh_bridge(p,c,b,g)assert(c==catalog and g());return {}end
ui=UI.new(host)
worn=A
local busy=true
rawset(_G,'APPLEBACON_NATIVE_BUSY',function()return busy end)
for i=1,10 do now=now+200;ui:restore_startup(now)end
assert(commits==0,'the restore must not be attempted while a native refresh is in flight')
busy=false
for i=1,10 do now=now+200;ui:restore_startup(now)end
assert(commits==1,'the restore must proceed once the refresh has landed, not stay skipped')
''')


# Live 2026-10-01: the player logged in wearing a helmet that was neither the
# saved one nor the login gear. The restore waited on it for the whole session
# and held the profile reconcile behind it, so the next helmet Apply failed and
# re-dressed the armor. A stable other item is the player's choice: give up.
def test_accessory_restore_gives_up_when_the_player_wears_something_else():
    fixture=FIXTURE.replace('local ui=UI.new{','local host={').replace('end}\nlocal sample=', 'end}\nlocal ui=UI.new(host)\nlocal sample=')
    run_lua('local CATEGORY=1\n'+fixture+'''
local E=dofile('src/equipped_state.lua')
local label='Saved';local saved=S.new();saved.presets[label]=catalog.catalog[A]
files['helmets.state']=assert(S.encode(saved));local request=assert(S.decode(files['helmets.state'])).presets[label]
files['equipped-helmet.state']=assert(E.encode(S,label,request))
host.startup_guard=function()return true end;host.data_bridge={}
function grid:idle_menu()return true end
function grid:player_refresh_bridge(p,c,b,g)assert(c==catalog and g());return {}end
local said={};host.report=function(k,v)said[#said+1]=k..'='..tostring(v)end
ui=UI.new(host)
worn=B
local done
for i=1,10 do now=now+200;done=ui:restore_startup(now)end
assert(not done and commits==0,'a helmet seen for two seconds is not yet a choice')
for i=1,10 do now=now+200;done=ui:restore_startup(now)end
assert(done==true and commits==0,'the restore kept waiting on a helmet the player chose')
assert(table.concat(said,';'):find('accessory.restore.skipped=1:another item is worn',1,true),table.concat(said,';'))
''')


def test_accessory_apply_waits_while_another_native_refresh_is_in_flight():
    run_lua('local CATEGORY=1\n'+FIXTURE+'''
draw();draw();assert(builds==1)
assert(flow:action{type='open'});assert(flow:action{type='select_look',id=A})
assert(flow:action{type='select_passive',id='perk:2'});assert(flow:action{type='create'})
draw();draw();for i=1,4 do draw()end
assert(flow:view().can_apply)
local busy=true
rawset(_G,'APPLEBACON_NATIVE_BUSY',function()return busy end)
local ok,why=flow:action{type='apply_variant',label='One - Second'}
assert(not ok and tostring(why):find('armor change'),'apply must wait for the other refresh: '..tostring(why))
draw();assert(commits==0)
busy=false
assert(flow:action{type='apply_variant',label='One - Second'})
draw();assert(commits==1)
''')
