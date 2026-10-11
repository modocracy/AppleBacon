"""The real main.lua frame loop drives every Armory tab with one set of calls
(research/106, stage 5): the tab whose list is on screen has the frame, the
others are hidden, and each guards its own cards."""
from test_creator_failure_main import run

# Body armor and helmets side by side on the harness grid: both lists hold the
# same two owned items, and `nav_category` says which list is on screen.
TABS = r'''
-- The helmet tab is the real accessory_ui.lua: it sees the harness's modules as globals.
_G.NativeGridPresentation=NativeGridPresentation;_G.UiWorkflow=UiWorkflow;_G.VariantWizard=VariantWizard
ArmorRefresh={};ArmorRefreshBridge={}
PlayerCustomizationProbe={new=function()return {}end}
AppearancePatch={compatible=function()return true end}
session_created=0
VariantSession={new=function()
 session_created=session_created+1
 return {select=function()return true end,
 view=function()return {native_details=true,can_apply=true,variant_phase='ready'}end,
 is_active=function()return false end,busy=function()return false end,
 cancel_preview=function()return true end,browse=function()return true end,
 leave=function()return true end,step=function()end,shutdown=function()return true end}
end}
local hats=State.new{catalog=catalog,owned={a=true,b=true}};hats.presets.Hat=triple_a
files['helmets.state']=assert(State.encode(hats))
result.helmets={category=1,catalog=catalog,owned={a=true,b=true},verify_owned=function()return true end,
 context={labels={appearance_id={},stats_id={},passive_variant_id={}},passive_variants={},stats_profiles=result.context.stats_profiles},
 capabilities={accessory_transmog_enabled=true,ownership_verified=true}}
nav_category=0
local snapshot=grid.snapshot
function grid:snapshot(...)
 local s=snapshot(self,...);if s then s.native_category=nav_category end;return s
end
local function switch(category)nav_category=category;presentation_active=false end
'''


def test_the_tab_whose_list_is_up_has_the_frame_and_the_others_are_hidden():
    run(r'''
assert(presentation_builds==1 and presentation_active and flow:view().selected_variant.label=='Existing')
local armor_flow,armor_leaves=flow,leave_count
switch(1);for _=1,6 do advance()end
assert(logged_count('presentation.retired=category changed')==1,'the armor cards were not retired with their list')
assert(leave_count>armor_leaves and not armor_flow:view().selected_variant)
assert(presentation_builds==2 and presentation_active and flow~=armor_flow,'the helmet tab did not build its own cards')
assert(flow:view().selected_variant.label=='Hat' and logged_count('accessory.presentation.auto_preview=1:Hat')==1)
assert(session_created==2,'each tab has its own session')
-- Frames spent on the helmet tab do nothing more to body armor.
local left=leave_count;for _=1,30 do advance()end
assert(leave_count==left and presentation_builds==2)
-- Back on body armor: the helmet tab is hidden, the armor cards go up again.
local helmet_flow=flow
switch(0);for _=1,6 do advance()end
assert(presentation_builds==3 and presentation_active and not helmet_flow:view().selected_variant)
assert(armor_flow:view().selected_variant.label=='Existing')
assert(logged_count('runtime.error=')==0 and save_count==0)
''', automatic=True, helmet_transmog=True, setup=TABS)


def test_debug_ui_status_exports_the_visible_helmet_flow_instead_of_hidden_armor():
    run(r'''
local armor_flow=flow
switch(1);for _=1,6 do advance()end
assert(flow~=armor_flow and flow:view().selected_variant.label=='Hat')
local active=flow
active.automation_snapshot=function()return {view={step=0,open=false,
 selected_variant={label='Hat'},native_details=true,can_apply=true,variant_phase='ready'},
 regions={{x=10,y=20,w=30,h=40,action={type='select_variant',label='Hat'}}}}end
armor_flow.automation_snapshot=function()error('queried hidden armor flow')end
local ok,why=command('ui_status');assert(ok,why)
local raw=assert(files['debug-ui-status.txt'])
assert(raw:find('slot=helmet',1,true)and raw:find('selected_variant=Hat',1,true))
assert(raw:find('region\tselect_variant\tHat\t10\t20\t30\t40',1,true))
assert(logged_count('runtime.error=')==0)
''', automatic=True, helmet_transmog=True, setup=TABS)


# Review of stage 3: the helmet tab's failed guard was undone in the same frame
# and came back every frame or two. Every tab pauses the way body armor does.
def test_a_failed_guard_on_the_helmet_tab_pauses_it_like_body_armor():
    run(r'''
switch(1);for _=1,6 do advance()end
assert(presentation_builds==2 and presentation_active and flow:view().selected_variant.label=='Hat')
local native=native_updates
consume_mode='refuse';advance()
assert(native_updates==native,'the failed press must be cancelled once')
assert(logged_count('accessory.creator.input_error=1:')==1 and runtime.status:find('CREATOR PAUSED',1,true))
assert(not presentation_active,'the helmet cards must be taken down')
consume_mode='ok'
local builds,guards=presentation_builds,before_count
for _=1,100 do advance()end
assert(presentation_builds==builds and before_count==guards,'the helmet creator came back while paused')
assert(logged_count('accessory.creator.input_error=')==1 and native_updates==native+100)
-- Leaving the Armory arms it again.
sample_mode='exit';advance();sample_mode='ready';now=now+250
for _=1,6 do advance()end
assert(presentation_builds==builds+1 and presentation_active)
assert(logged_count('runtime.error=')==0)
''', automatic=True, helmet_transmog=True, setup=TABS)


# A menu replaced under the cards (same list, new menu) takes them with it:
# every tab lets go of what it had up and builds again for the new menu.
def test_a_replaced_menu_rebuilds_the_cards_of_the_tab_on_screen():
    run(r'''
assert(presentation_builds==1 and presentation_active)
local old_flow_leaves=leave_count
menu_token='replacement-menu'
for _=1,6 do advance()end
assert(leave_count>old_flow_leaves and presentation_builds==2 and presentation_active,'builds='..presentation_builds)
assert(flow:view().selected_variant.label=='Existing')
assert(logged_count('Custom presentation already active')==0 and logged_count('runtime.error=')==0)
''', automatic=True, helmet_transmog=True, setup=TABS)


# Review of stage 5: a list that is no tab's (another view) followed by an
# unreadable frame handed the frame to body armor, and its guard came back.
def test_an_unreadable_frame_on_a_screen_that_is_no_tabs_changes_nothing():
    run(r'''
assert(presentation_builds==1 and presentation_active)
grid_mode='other_mode';for _=1,5 do advance()end
local guards,left=before_count,leave_count
grid_mode='unreadable';for _=1,10 do advance()end
assert(before_count==guards and leave_count==left,'body armor took the frame of a screen that is not its own')
grid_mode='other_mode';for _=1,5 do advance()end
assert(leave_count==left,'and was hidden again for it')
grid_mode='ready';for _=1,6 do advance()end
assert(presentation_builds==2 and presentation_active and logged_count('runtime.error=')==0)
''', automatic=True, helmet_transmog=True, setup=TABS)


# Review of stage 5: the catalog read again by the debug command left the
# helmet tab with a session made against the old one, and asked no tab but
# body armor whether a composition was still worn.
def test_reading_the_catalog_again_asks_every_tab_and_resets_every_tab():
    run(r'''
switch(1);for _=1,6 do advance()end
assert(session_created==2 and flow:view().selected_variant.label=='Hat')
worn_through_helmets=true
assert(command('read_catalog') and command_result:find('Ownership-only refresh',1,true),tostring(command_result))
worn_through_helmets=false
assert(command('read_catalog') and command_result:find('catalog observation scheduled',1,true),tostring(command_result))
presentation_active=false;for _=1,8 do advance()end
assert(session_created==3,'the helmet tab kept a session made against the old catalog: '..session_created)
assert(presentation_active and flow:view().selected_variant.label=='Hat' and logged_count('runtime.error=')==0)
''', automatic=True, helmet_transmog=True, setup=TABS + r'''
result.refresh_ownership=function()return 'ready',false end
local make=VariantSession.new
VariantSession.new=function(...)
 local s=make(...);local mine=session_created
 s.is_active=function()return mine==2 and worn_through_helmets==true end
 return s
end
''')


# The options body armor honours reach every tab: with the automatic section
# off, no tab puts cards up by itself.
def test_the_automatic_option_holds_for_every_tab():
    run(r'''
switch(1);for _=1,10 do advance()end
assert(presentation_builds==0 and not presentation_active,'the helmet tab built cards with the automatic section off')
switch(0);for _=1,10 do advance()end
assert(presentation_builds==0 and logged_count('runtime.error=')==0)
''', automatic=False, helmet_transmog=True, setup=TABS)
