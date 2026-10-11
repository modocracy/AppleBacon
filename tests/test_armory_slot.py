"""One description of an Armory tab (src/armory_slot.lua), shared by body armor,
helmets and capes: the variant session's host, the cards and the startup
restore."""
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


def run_lua(code):
    result = subprocess.run(['luajit', '-'], input=code, text=True, cwd=ROOT, capture_output=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr


FIXTURE = r'''
local Slot=dofile('src/armory_slot.lua')
local calls,reports={},{}
local catalog={}
local grid={}
function grid:preview_variant_details(look,stats,passive,c,o)calls[#calls+1]={'preview',look,o};return{kit=look}end
function grid:detail_state()return{kit_id='armor:000000aa'}end
function grid:equipment_feedback(id,c)calls[#calls+1]={'feedback',id};return true end
function grid:focus_index(index,id,c)calls[#calls+1]={'focus',index,id};return{}end
local cards={{label='One',kit_id='armor:donor001'},{label='Two',kit_id='armor:000000aa'}}
local remembered
local session={verify_appearance=function(_,id)return id=='armor:000000aa'end,
 verify_composition=function()return false end,verify_base_stats=function(_,id,stats)return stats=='s'end}
local host=Slot.session_host{slot=Slot.SLOTS[CATEGORY],report=function(k,v)reports[#reports+1]=k..'='..tostring(v)end,
 catalog=function()return catalog end,grid=function()return grid end,cards=function()return cards end,
 session=function()return session end,
 equipped={remember=function(_,label,request)remembered={label,request};return true end},
 native_patch=function()return'native'end,compatible=function(request)return request.ok==true end}
local request={appearance_id='armor:000000aa',stats_id='s',passive_variant_id='p'}
'''


@pytest.mark.parametrize('category,name', [(0, 'armor'), (1, 'helmet'), (2, 'cape')])
def test_every_tab_gets_the_same_session_host(category, name):
    run_lua(f'local CATEGORY={category}\nlocal NAME="{name}"\n' + FIXTURE + r'''
assert(Slot.SLOTS[CATEGORY].name==NAME and Slot.SLOTS[CATEGORY].category==CATEGORY)
-- The card found by its label gives the list focus; the look gives the model.
assert(host.preview_variant(request,true,'One',9))
local shown=calls[#calls];local o=shown[3]
assert(shown[2]=='armor:000000aa' and o.focus_index==0 and o.focus_kit_id=='armor:donor001' and o.requires_apply==true and o.widgets_only==nil)
assert(o.verify_appearance('armor:000000aa')==true and o.verify_composition('x')==false and o.verify_base_stats('x','s')==true)
assert(host.refresh_widgets(request,'Two',4));o=calls[#calls][3]
assert(o.focus_index==1 and o.focus_kit_id=='armor:000000aa' and o.widgets_only==true and o.requires_apply==false)
-- The worn variant is remembered by its label and request.
assert(host.persist_equipped('One',request) and remembered[1]=='One' and remembered[2]==request)
-- The composition is always the native patch.
assert(host.new_patch()=='native')
assert(host.validate_composition({ok=true})==true and host.detail_state().kit_id=='armor:000000aa')
assert(host.equipped_feedback(request) and calls[#calls][2]=='armor:000000aa')
-- Only a card below the custom ones is an ordinary card to go back to.
local ok,why=host.restore_focus('armor:000000bb',1);assert(ok==nil and why:find('changed',1,true))
assert(host.restore_focus('armor:000000bb',2)==true and calls[#calls][2]==2 and reports[#reports]=='variant.original_focus=armor:000000bb:2')
''')


# One tab object for every category (stage 2 of research/106): the custom cards
# in the game's list are built, put back, retired and rebuilt by one rule set.
TAB = r'''
local Slot=dofile('src/armory_slot.lua')
local State=dofile('src/state.lua')
local SLOT=Slot.SLOTS[CATEGORY]
local now,said=1000,{}
local A,B,C='armor:0000000a','armor:0000000b','armor:0000000c'
local catalog={category=CATEGORY,catalog={[A]={appearance_id=A,stats_id='s-a',passive_variant_id='p-a'},
 [B]={appearance_id=B,stats_id='s-b',passive_variant_id='p-b'},[C]={appearance_id=C,stats_id='s-c',passive_variant_id='p-c'}},
 owned={[B]=true,[C]=true},context={passive_variants={['p-b']={enum=2}},appearance_previews={stale=true}}}
local domain=State.new{catalog=catalog.catalog,owned=catalog.owned}
local custom,selected_kit,headers,restores,attempts,leaves,flow_clears,actions,options,planned,tokens=0,nil,{},0,0,0,0,{},nil,nil,{}
local index,scroll,category,kind,mode=0,0,CATEGORY,4,0
local phase_after_attempt='active'
local grid={}
function grid:inspect_model()return{item_count=3,offers={{kit_id=A,owned=false},{kit_id=B,owned=true},{kit_id=C,owned=true}}}end
function grid:snapshot()return{kind=kind,native_view_mode=mode,native_category=category,identity_mapping_verified=true,
 item_count=3+custom,scroll=scroll,logical_selected_index=index,widgets={
  {logical_index=0,bound_owned_kit_id=planned and planned[1]and planned[1].kit_id,root_viewport_rect={x=1,y=1,w=1,h=1}},
  {logical_index=custom,bound_owned_kit_id=A,root_viewport_rect={x=2,y=2,w=1,h=1}},
  {logical_index=custom+1,bound_owned_kit_id=B,root_viewport_rect={x=3,y=3,w=1,h=1}}}}end
function grid:select_kit(id)selected_kit=id;return true end
function grid:custom_headers(n,selected,cards,kind)headers[#headers+1]={n,selected,kind};return true end
function grid:presentation_bridge(c,token)tokens[#tokens+1]=token;return{}end
local Presentation={new=function(bridge,o)options=o;return{phase='idle',
 attempt=function(self,cards)attempts=attempts+1;planned=cards;self.phase=phase_after_attempt
  if self.phase=='active'then custom=#cards end;return{phase=self.phase,error=self.phase~='active'and'not ready'or nil}end,
 restore=function(self)restores=restores+1;custom=0;self.phase='restored';return{phase='restored'}end,
 status=function(self)return{phase=self.phase}end}end}
local open,busy=false,false
local unselected,cancelled=0,0
local flow={clear=function()flow_clears=flow_clears+1 end,leave=function()leaves=leaves+1 end,is_open=function()return open end,
 clear_selected_variant=function()unselected=unselected+1 end,
 action=function(_,a)actions[#actions+1]=a;return true end}
local session_left=0
local session={busy=function()return busy end,leave=function()session_left=session_left+1;return true end,
 cancel_preview=function()cancelled=cancelled+1;return true end}
local screen='armory'
local files={}
local tab=Slot.new{slot=SLOT,lib={State=State,NativeGridPresentation=Presentation,UiLayout=dofile('src/ui_layout.lua')},
 fs={now=function()return now end,read=function(name)return files[name],files[name]and nil or'missing'end,
  write_atomic=function(name,value)files[name]=value;return true end},
 engine={Gui={resolution=function()return 1920,1080 end}},
 report=function(k,v)said[#said+1]=k..'='..tostring(v)end,
 catalog=function()return catalog end,grid=function()return grid end,domain=function()return domain end,
 screen=function()return screen end,token=function()return'menu'end}
local st=tab.state
st.flow=flow;st.session=session
local function heard(text)for _,line in ipairs(said)do if line:find(text,1,true)then return true end end return false end
local KEY=CATEGORY==0 and''or'accessory.'
'''


@pytest.mark.parametrize('category', [0, 1, 2])
def test_every_tab_builds_its_cards_the_same_way(category):
    run_lua(f'local CATEGORY={category}\n' + TAB + r'''
domain.presets.Mine={appearance_id=B,stats_id='s-c',passive_variant_id='p-b'}
domain.presets.Other={appearance_id=C,stats_id='s-c',passive_variant_id='p-b'}
domain.presets.Lost={appearance_id=A,stats_id='s-c',passive_variant_id='p-b'}
assert(tab:build_list()==true and attempts==1)
-- Saved variants whose look is owned, then the create card on the first OWNED offer.
assert(#planned==3 and planned[1].label=='Mine' and planned[2].label=='Other' and planned[3].kind=='create' and planned[3].kit_id==B,
 'the create card must borrow the first owned offer')
assert(options.allow_create==true and tab:cards()==planned and st.custom_expected_count==6 and st.revision==1)
assert(tokens[1]=='menu:'..CATEGORY..':1','the list lease names the tab and its revision: '..tostring(tokens[1]))
-- Room is kept for every known unlock of the slot, not just the listed ones.
assert(catalog.context.variant_capacity==256-3-1)
catalog.counts={verified_armors=40};assert(tab:restore_list() and tab:build_list());assert(catalog.context.variant_capacity==256-40-1)
-- The first saved card is previewed when nothing is to be resumed.
assert(actions[1].type=='select_variant' and actions[1].label=='Mine')
st.resume_label='Other';assert(tab:restore_list() and tab:build_list() and actions[#actions].label=='Other','the resumed card is selected again')
st.last_created_label='Mine';assert(tab:restore_list() and tab:build_list() and actions[#actions].label=='Mine' and st.last_created_label==nil)
assert(heard(KEY..'presentation.auto_preview='..(CATEGORY==0 and''or CATEGORY..':')..'Mine'))
-- A second build over a live one is refused; the deployment screen has no create card.
assert(not pcall(tab.build_list,tab))
screen='deployment';assert(tab:restore_list() and tab:build_list() and #planned==2 and options.allow_create==false)
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_a_removed_variant_leaves_an_ordinary_card_selected_on_every_tab(category):
    run_lua(f'local CATEGORY={category}\n' + TAB + r'''
domain.presets.Mine={appearance_id=B,stats_id='s-c',passive_variant_id='p-b'}
st.removed_appearance=B;st.resume_label='Mine'
assert(tab:build_list())
local last=actions[#actions]
assert(#actions==1 and last.type=='select_native_look' and last.id==B and last.index==3 and st.removed_appearance==nil,
 'the removal must leave an ordinary owned card selected, not a saved one')
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_putting_the_list_back_clears_headers_previews_and_the_creator_on_every_tab(category):
    run_lua(f'local CATEGORY={category}\n' + TAB + r'''
domain.presets.Mine={appearance_id=B,stats_id='s-c',passive_variant_id='p-b'}
assert(tab:restore_list()==true and restores==0,'nothing to put back')
assert(tab:build_list());st.snapshot={};st.next_sample=99;catalog.context.appearance_previews={stale=true};local cleared=flow_clears
assert(tab:restore_list()==true and restores==1 and tab:cards()==nil and st.presentation==nil)
assert(headers[#headers][1]==0 and headers[#headers][2]==false,'the custom headers stay up')
assert(st.snapshot==nil and st.next_sample==0 and next(catalog.context.appearance_previews)==nil and flow_clears==cleared+1)
''')


@pytest.mark.parametrize('category', [0, 1, 2])
@pytest.mark.parametrize('change,reason', [('kind=5', 'category changed'), ('category=(CATEGORY+1)%3', 'category changed'),
                                           ('mode=1', 'view mode changed'), ('custom=custom+1', 'item count changed'),
                                           ("st.presentation.phase='retired'", 'native model changed')])
def test_cards_under_a_rebuilt_native_list_are_retired_not_restored_on_every_tab(category, change, reason):
    run_lua(f'local CATEGORY={category}\n' + TAB + r'''
domain.presets.Mine={appearance_id=B,stats_id='s-c',passive_variant_id='p-b'}
assert(tab:build_list());st.selected_label='Mine';st.native_browse_index=4
assert(tab:retire(grid:snapshot(),now)==false and tab:cards(),'an unchanged list keeps its cards')
''' + change + r'''
assert(tab:retire(grid:snapshot(),now)==true)
assert(tab:cards()==nil and st.presentation==nil and restores==0,'retired cards are never restored into the new list')
assert(st.selected_label==nil and st.native_browse_index==nil and leaves==1 and session_left==1)
assert(tab.section:status().reason=='Native list rebuilt')
assert(heard('presentation.retired='..(CATEGORY==0 and''or CATEGORY..':')..''' + repr(reason) + r'''),table.concat(said,';'))
assert(tab:retire(grid:snapshot(),now)==false)
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_a_changed_list_is_rebuilt_in_the_same_steps_on_every_tab(category):
    run_lua(f'local CATEGORY={category}\n' + TAB + r'''
domain.presets.Mine={appearance_id=B,stats_id='s-c',passive_variant_id='p-b'}
tab.section:observe(now,{token='menu',armor=true,ready=true});assert(tab.section:begin(now))
st.custom_rows_dirty=true
busy=true;tab:rebuild(now);assert(selected_kit==nil and st.custom_rows_dirty,'never while an equipment change is in flight')
busy=false;open=true;tab:rebuild(now);assert(selected_kit==nil and st.custom_rows_dirty,'never under the open creator')
open=false;tab:rebuild(now)
assert(selected_kit==B and st.rebuild_pending and not st.custom_rows_dirty and attempts==0,'the first OWNED card is selected first')
index=5;tab:rebuild(now);assert(attempts==0,'the build waits for the selection to settle at the top')
index=0;scroll=3;tab:rebuild(now);assert(attempts==0)
scroll=0;tab:rebuild(now);assert(attempts==1 and tab:cards() and tab.section:status().phase=='active')
-- The creator's rows are put back before the full build.
st.custom_rows_dirty=true;tab:rebuild(now);assert(restores==1 and st.rebuild_pending)
tab:rebuild(now);assert(attempts==2 and tab:cards())
-- A selection that never settles is retried, not built on.
st.custom_rows_dirty=true;tab:rebuild(now);index=9;now=now+2001;tab:rebuild(now)
assert(st.rebuild_pending==nil and attempts==2 and tab.section:status().reason=='Native first-row selection is not ready')
-- A failed build is reported and spends the section's budget.
index=0;phase_after_attempt='blocked';st.custom_rows_dirty=true;tab:rebuild(now);tab:rebuild(now)
assert(attempts==3 and heard('presentation.rebuild_failed=') and tab.section:status().phase=='blocked')
-- An ownership change puts the list back and asks for a fresh build.
phase_after_attempt='active';assert(tab:build_list());st.ownership_changed=true;local before=restores
st.selected_label='Mine';st.native_browse_index=7
tab:rebuild(now);assert(restores==before+1 and not st.ownership_changed and st.rebuild_pending and tab.section:status().phase=='waiting')
assert(cancelled==1 and unselected==1 and st.selected_label==nil and st.native_browse_index==nil,'what was selected may no longer be owned')
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_the_drawn_prefix_is_one_rule_for_every_tab(category):
    run_lua(f'local CATEGORY={category}\n' + TAB + r'''
domain.presets.Mine={appearance_id=B,stats_id='s-c',passive_variant_id='p-b'}
local sample={};tab:prefix(sample,grid:snapshot());assert(sample.native_prefix==nil,'no cards, no prefix')
assert(tab:build_list());st.selected_label='Mine'
tab:prefix(sample,grid:snapshot());local p=sample.native_prefix
assert(p and p.verified and #p.cells==1 and p.cells[1].label=='Mine' and p.cells[1].selected==true and p.cells[1].passive.enum==2)
-- An ordinary card is badged only when its kit has a passive to show.
assert(#p.original_badges==1 and p.original_badges[1].passive.enum==2,'a card without a passive carries no badge')
assert(headers[#headers][1]==2 and headers[#headers][2]==true and headers[#headers][3]=='variant')
-- A header refusal is reported once, not every frame.
function grid:custom_headers()return nil,'header proof changed'end
tab:prefix(sample,grid:snapshot());tab:prefix(sample,grid:snapshot())
local n=0;for _,line in ipairs(said)do if line:find('presentation.header=',1,true)then n=n+1 end end;assert(n==1)
''')


# Stage 3 of research/106: one creator host, one input guard and one way of
# following the game's cursor for every tab.
CREATOR = TAB.replace("lib={State=State,NativeGridPresentation=Presentation,UiLayout=dofile('src/ui_layout.lua')},", "lib=LIB,").replace('''local screen='armory'
local files={}''', r'''local screen='armory'
local files={}
local creator,panel_made,guard,locked,write_fails,hitbox,native_patch=nil,0,true,false,false,'root','native'
local refreshes,bridges,applied={},{},{}
local actor={request_armor_id=B,cache_armor_id=B,cache_passive_enum=2}
local LIB={State=State,NativeGridPresentation=Presentation,UiLayout=dofile('src/ui_layout.lua'),VariantWizard={},
 UiWorkflow={new=function(state,wizard,panel,h)creator=h;panel_made=panel
  flow.before=function()if guard=='throw'then error('guard broke')end;if guard then return true end;return nil,'capture refused'end
  return flow end},
 VariantSession={new=function(o)session.host=o;return session end},
 ArmorRefresh={new=function(bridge)refreshes[#refreshes+1]=bridge;return{bridge=bridge}end},
 ArmorRefreshBridge={new=function(g,probe,c,opts)bridges[#bridges+1]={probe=probe,opts=opts};return{armory=true}end}}
''').replace('''screen=function()return screen end,token=function()return'menu'end}
local st=tab.state
st.flow=flow;st.session=session''', r'''screen=function()return screen end,token=function()return'menu'end,
 panel=function()return'panel'end,hitbox=function()return hitbox end,
 adopt=function(candidate)domain=candidate end,locked=function()return locked end,
 write=function(encoded)if write_fails then return nil,'disk full'end;files.saved=encoded;return true end,
 probe=function()return'probe'end,actor=function(probe)assert(probe=='probe');return actor end,
 data_bridge=function()return'data'end,startup_guard=function()return true end,
 native_patch=function()return native_patch end,compatible=function(request)return request.appearance_id~=C,'incompatible'end,
 refresh_options=function(opts)if type(opts)=='table'then opts.seen=true end end}
local st=tab.state
function grid:selection_index()return index end
function grid:input_scope(category)assert(category==CATEGORY);return true end
function grid:consume_select()return true end
function grid:consume_creator(category)assert(category==CATEGORY);return true end
function grid:player_refresh_bridge(probe,c,data,guard)assert(probe=='probe' and data=='data' and guard());return{headless=true}end
grid.phase='ready'
session.cancel_preview=function()cancelled=cancelled+1;return true end
session.view=function()return{}end
local browsed
session.browse=function(_,id,at,i)browsed={id,i};return true end
session.select=function(_,label)applied[#applied+1]='select:'..label;return true end
session.apply=function()applied[#applied+1]='apply';return true end
assert(tab:ensure_flow()==flow and tab:flow()==flow and panel_made=='panel')''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_every_tab_makes_its_session_the_same_way(category):
    run_lua(f'local CATEGORY={category}\n' + CREATOR + r'''
assert(tab:session()==nil and tab:ensure_session()==session and tab:ensure_session()==session)
local o=session.host
assert(o.player()==actor and o.new_patch()=='native' and o.catalog()==catalog)
-- A worn variant is checked against the slot's passive cache; capes have none.
local passive={enum=2}
assert(o.equipped_matches(actor,B,passive)==true and o.equipped_matches(actor,C,passive)==false)
assert(o.equipped_matches(actor,B,{enum=9})==(CATEGORY==2),'only a slot without a passive cache ignores the passive')
-- Outside the Armory the refresh drives the player; inside it the Armory; a caller's bridge is used as given.
assert(o.new_refresh(true).bridge.headless and o.new_refresh(false,nil,{reconcile=true}).bridge.armory and bridges[1].opts.seen)
assert(o.new_refresh(false,{external=true}).bridge.external and bridges[1].probe=='probe')
-- An Apply of the player's own ends the startup restore; a background one does not.
files[SLOT.record]=nil;st.startup.finished=false
assert(o.before_apply(true)==true and st.startup.finished==false)
assert(o.before_apply(false)==true and st.startup.finished==true)
st.startup.finished=false;assert(o.before_apply(true,true)==true and st.startup.finished==true)
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_the_creator_host_is_one_table_for_every_tab(category):
    run_lua(f'local CATEGORY={category}\n' + CREATOR + r'''
assert(creator.stats_follow_look==(CATEGORY~=0),'only body armor has stats of its own to choose')
assert(creator.allow_create==true and creator.input_scope()==true and creator.consume_creator()==true)
domain.presets.Mine={appearance_id=B,stats_id='s-c',passive_variant_id='p-b'}
-- Saving is refused past the capacity the list has room for.
local tx={label='New',candidate={presets={Mine=domain.presets.Mine,New={appearance_id=B,stats_id='s-b',passive_variant_id='p-b'}}},encoded='bytes'}
catalog.verify_owned=function()return true end
local ok,why=creator.verify_create(tx);assert(ok==nil and why:find('capacity',1,true))
catalog.context.variant_capacity=1;ok,why=creator.verify_create(tx);assert(ok==nil and why:find('limit',1,true),tostring(why))
catalog.context.variant_capacity=2;assert(creator.verify_create(tx)==true)
tx.candidate.presets.New.appearance_id=C;ok,why=creator.verify_create(tx);assert(not ok and why=='incompatible')
tx.candidate.presets.New.appearance_id=A;ok,why=creator.verify_create(tx);assert(not ok and why:find('no longer owned',1,true))
tx.candidate.presets.New.appearance_id=B
-- The caller keeps the file; the tab keeps the rules.
locked=true;ok,why=creator.persist(tx);assert(ok==nil and why:find('recovery',1,true) and files.saved==nil)
locked=false;write_fails=true;assert(creator.persist(tx)==nil and domain~=tx.candidate)
write_fails=false;local saved,adopted=creator.persist(tx);assert(saved==true and adopted==tx.candidate and domain==tx.candidate and files.saved=='bytes')
domain=State.new{catalog=catalog.catalog,owned=catalog.owned};domain.presets.Mine={appearance_id=B,stats_id='s-c',passive_variant_id='p-b'}
creator.created('New');assert(st.last_created_label=='New' and st.custom_rows_dirty and heard('creator.created='))
-- The list is rebuilt after the creator only when it was up before it.
st.custom_rows_dirty=false;st.last_created_label=nil
assert(creator.begin_creation()==true and st.rebuild_after_creator==false and #st.creator_look_order==2 and st.creator_look_order[1]==B)
creator.end_creation();assert(not st.custom_rows_dirty,'nothing was up, nothing to rebuild')
assert(tab:build_list());assert(creator.begin_creation()==true and st.rebuild_after_creator==true and restores==1)
creator.end_creation();assert(st.custom_rows_dirty and st.rebuild_after_creator==false)
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_removing_a_variant_follows_one_rule_on_every_tab(category):
    run_lua(f'local CATEGORY={category}\n' + CREATOR + r'''
local E=dofile('src/equipped_state.lua')
domain.presets.Mine={appearance_id='armor:0000000b',stats_id='native-stats:0000000c',passive_variant_id='p-b'}
assert(tab:build_list() and tab:ensure_session());st.selected_label='Other'
local ok,why=creator.remove_variant('Mine');assert(ok==nil and why:find('selected variant changed',1,true))
st.selected_label='Mine';busy=true;ok,why=creator.remove_variant('Mine');assert(ok==nil and why:find('armor change',1,true))
busy=false;write_fails=true;ok,why=creator.remove_variant('Mine')
assert(ok==nil and why=='disk full' and domain.presets.Mine and tab:cards(),'a failed write removes nothing')
write_fails=false;screen='deployment';assert(not creator.remove_variant('Mine'));screen='armory'
assert(tab.equipped:remember('Mine',domain.presets.Mine) and tab.equipped:record().label=='Mine')
assert(creator.remove_variant('Mine')==true)
assert(domain.presets.Mine==nil and State.decode(files.saved).presets.Mine==nil)
assert(not tab.equipped:record(),'the removed variant must not be restored at the next launch')
assert(browsed and browsed[1]==nil and st.selected_label==nil and st.resume_label==nil and st.removed_appearance=='armor:0000000b')
assert(tab:cards()==nil and st.custom_rows_dirty==true and heard('creator.removed='))
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_selection_capture_and_confirmation_follow_one_rule_on_every_tab(category):
    run_lua(f'local CATEGORY={category}\n' + CREATOR + r'''
domain.presets.Mine={appearance_id=B,stats_id='s-c',passive_variant_id='p-b'}
assert(creator.should_capture({x=0,y=0,down=false})==false,'nothing of ours in the list')
assert(tab:build_list());st.selected_label=nil;actions={}
-- The cursor on a custom card is ours; on an ordinary card only until it was browsed to.
index=0;assert(creator.should_capture({x=0,y=0,down=false})==true)
index=3;assert(creator.should_capture({x=0,y=0,down=false})==false)
assert(creator.preview_native_look(B,3)==true and st.native_browse_index==3 and st.resume_label==nil and browsed[1]==B and browsed[2]==3)
local ok,why=creator.preview_native_look(B,1);assert(ok==nil and why:find('card changed',1,true),'a custom card is never an original')
assert(creator.should_capture({x=0,y=0,down=false})==false,'the browsed original keeps the game Apply')
st.custom_rows_dirty=true;assert(creator.should_capture(nil)==true);st.custom_rows_dirty=false
-- A confirm acts only on what the cursor is on.
index=0;assert(creator.validate_confirm{label='Mine'}==true and creator.validate_confirm{label='Other'}==false)
index=3;assert(creator.validate_confirm{id=B}==true and creator.validate_confirm{id=C}==false,'the widget at the cursor must carry that kit')
st.native_browse_index=2;assert(creator.validate_confirm{id=B}==false)
index=1;local open_action=creator.controller_action();assert(open_action.type=='open' and creator.validate_confirm(open_action)==true)
st.revision=st.revision+1;assert(creator.validate_confirm(open_action)==false,'a rebuilt list invalidates the confirm')
category=(CATEGORY+1)%3;assert(creator.validate_confirm{label='Mine'}==false and creator.controller_action()==nil);category=CATEGORY
-- Selecting a saved card and applying go through the session.
assert(creator.intent{kind='select_variant',label='Mine',request=domain.presets.Mine}==true and st.selected_label=='Mine' and st.resume_label=='Mine')
assert(creator.intent{kind='other'}==false)
assert(creator.apply_variant()==true and applied[#applied]=='apply')
APPLEBACON_NATIVE_BUSY=function()return true end
ok,why=creator.apply_variant();assert(ok==nil and why:find('armor change',1,true) and #applied==2,'another refresh in flight holds every tab')
APPLEBACON_NATIVE_BUSY=nil
-- Looks in the creator are hit by the configured rectangle and previewed with the session's proof.
function grid:snapshot()return{kind=4,native_view_mode=0,native_category=CATEGORY,identity_mapping_verified=true,widgets={
 {logical_index=4,bound_owned_kit_id=C,root_viewport_rect={x=0,y=0,w=10,h=10},image_viewport_rect={x=20,y=20,w=5,h=5}}}}end
assert(creator.look_at(5,5)==C and creator.look_at(22,22)==nil)
hitbox='image';assert(creator.look_at(5,5)==nil and creator.look_at(22,22)==C);hitbox='none';assert(creator.look_at(22,22)==nil)
local seen;function grid:preview_variant_details(id,stats,passive,c,o)seen={id,stats,passive,o};return{}end
session.verify_appearance=function(_,id)return id==C end;session.verify_composition=function()return false end
assert(creator.preview_look(C)==true and seen[1]==C and seen[2]=='s-c' and seen[3]=='p-c')
assert(seen[4].verify_appearance(C)==true and seen[4].verify_composition(C)==false)
ok,why=creator.preview_look('armor:ffffffff');assert(ok==nil)
''')


@pytest.mark.parametrize('category', [0, 1, 2])
@pytest.mark.parametrize('failure', ['false', "'throw'"])
def test_a_failed_input_guard_takes_the_creator_down_once_on_every_tab(category, failure):
    run_lua(f'local CATEGORY={category}\n' + CREATOR + r'''
domain.presets.Mine={appearance_id=B,stats_id='s-c',passive_variant_id='p-b'}
assert(tab:build_list());st.custom_rows_dirty=true;st.rebuild_pending={}
local asked=0;local guarded=flow.before;flow.before=function(...)asked=asked+1;return guarded(...)end
assert(tab:before({})==true and asked==0,'a tab that is not on screen guards nothing')
st.shown=true;assert(tab:before({})==true and asked==1)
guard=''' + failure + r'''
local ok,why=tab:before({});assert(ok==nil and why)
assert(tab:flow()==nil and leaves==1 and restores==1 and tab:cards()==nil,'the creator and its cards go')
assert(st.creator_failed==true and not st.custom_rows_dirty and st.rebuild_pending==nil and tab.section:status().phase=='blocked')
assert(heard('creator.input_error='))
assert(tab:before({})==true and leaves==1,'a failed guard is never repeated')
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_the_games_cursor_is_followed_the_same_way_on_every_tab(category):
    run_lua(f'local CATEGORY={category}\n' + CREATOR + r'''
domain.presets.Mine={appearance_id=B,stats_id='s-c',passive_variant_id='p-b'}
assert(tab:build_list() and tab:ensure_session());actions={};st.selected_label='Mine'
local pad={x=5,y=5,down=false,controller_source='pad',nav_y=1}
local function look()st.snapshot=grid:snapshot();st.snapshot.logical_selected_group=st.group or 0;return st.snapshot end
-- A category key moved the cursor to an ordinary card: the preview is dropped, the card adopted.
tab:navigate(look());assert(#actions==0)
st.group=1;index=3;tab:navigate(look())
assert(cancelled==1 and unselected==1 and st.selected_label==nil and actions[1].type=='select_native_look' and actions[1].id==B and actions[1].index==3)
busy=true;st.group=0;index=0;tab:navigate(look());assert(#actions==1 and st.navigation_pending,'never during an equipment change')
busy=false;tab:navigate(look());assert(actions[2].type=='select_variant' and actions[2].label=='Mine' and not st.navigation_pending)
-- The pad owns the cursor only through its own gesture.
actions={};st.selected_label=nil;st.native_browse_index=nil
tab:browse(now,{x=5,y=5,down=false,controller_source='pad'});assert(#actions==0,'an idle pad adopts nothing')
tab:browse(now,pad);assert(actions[1].type=='select_variant' and actions[1].label=='Mine')
st.selected_label='Mine';index=3
tab:browse(now,pad);assert(actions[2].type=='select_native_look' and actions[2].index==3,'a moved cursor is read again before acting')
st.selected_label=nil;st.native_browse_index=3;index=1;st.selected_label='Mine'
tab:browse(now,pad);assert(st.selected_label==nil and #actions==2,'the create card holds no selection')
index=0;tab:browse(now,{x=9,y=5,down=false,controller_source='pad',nav_y=1});assert(#actions==2,'pointer movement takes the cursor back')
tab:browse(now,{x=9,y=5,down=true,controller_source='pad',nav_y=1});assert(#actions==2)
category=(CATEGORY+1)%3;look();tab:browse(now,{x=9,y=5,down=false,controller_source='pad',nav_y=1});assert(#actions==2,'another tab is on screen')
''')


# Stage 4 of research/106: one startup restore per slot.
RESTORE = CREATOR.replace("compatible=function(request)return request.appearance_id~=C,'incompatible'end",
                          "compatible=function(request)return not REJECT and request.appearance_id~=C,'incompatible'end"
                          ).replace("local tab=Slot.new{", r'''local E=dofile('src/equipped_state.lua')
local SAVED={appearance_id=B,stats_id='s-c',passive_variant_id='p-b'}
domain.presets.Mine=SAVED
if RECORD~=false then files[SLOT.record]=assert(E.encode(State,'Mine',SAVED,RECORD))end
catalog.context.category=CATEGORY
local ship,idle=true,true
local tab=Slot.new{''').replace("startup_guard=function()return true end,", "startup_guard=function()return ship end,") + r'''
function grid:idle_menu()return idle end
local restoring,restored,steps,abandoned=false,nil,0,nil
session.restore=function(_,label,request,at)restored={label,request,at};restoring=true;return true end
session.restoring=function()return restoring end
session.step=function()steps=steps+1 end
session.abandon_restore=function(_,why)abandoned=why;restoring=false end
local function run(ms)
 local done
 for _=1,ms/100 do now=now+100;done=tab:restore_startup(now)end
 return done
end
local function count(text)local n=0;for _,line in ipairs(said)do if line:find(text,1,true)then n=n+1 end end;return n end
'''


@pytest.mark.parametrize('category', [0, 1, 2])
def test_the_startup_restore_is_one_rule_for_every_tab(category):
    run_lua(f'local CATEGORY={category}\nlocal RECORD=nil\n' + RESTORE + r'''
-- Not before the ship has loaded, not under a menu, not alongside another refresh.
ship=false;assert(run(3000)==false and restored==nil)
ship=true;idle=false;assert(run(3000)==false and restored==nil)
idle=true;APPLEBACON_NATIVE_BUSY=function()return true end;assert(run(3000)==false and restored==nil,'a refresh in flight is a reason to wait')
APPLEBACON_NATIVE_BUSY=nil
-- The equipment must have settled on the saved item for a second.
actor.cache_armor_id=C;assert(run(3000)==false and restored==nil,'equipment still streaming')
actor.cache_armor_id=B;assert(run(400)==false and restored==nil,'not stable yet')
assert(run(500)==false and restored==nil,'half a second is not stable')
assert(run(1100)==false and restored and restored[1]=='Mine' and restored[2].appearance_id==B and st.startup.active==true)
assert(count('restore.started=')==1)
-- The session finishes it; the restored card is the one a later list selects.
steps=0;assert(run(300)==false and steps==3)
restoring=false;session.restore_status='complete'
assert(run(100)==true and st.startup.finished and not st.startup.active and st.resume_label=='Mine' and count('restore.result=')==1)
steps=0;assert(run(1000)==true and steps==0,'a finished restore does nothing more')
-- It can be armed again from the record as it is now.
assert(tab.equipped:remember('Mine',SAVED));assert(tab:restore_again()==true and st.startup.finished==false)
restored=nil;assert(run(2500)==false and restored,'the re-armed restore runs the same path')
local refused,why=tab:restore_again();assert(refused==nil and why:find('running',1,true))
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_a_restore_gives_up_on_a_chosen_item_but_waits_out_the_login_gear_on_every_tab(category):
    run_lua(f'local CATEGORY={category}\nlocal RECORD=nil\n' + RESTORE + r'''
-- The login gear is the game still dressing the actor: wait for the saved item.
actor.request_armor_id=SLOT.login;actor.cache_armor_id=SLOT.login
assert(run(10000)==false and restored==nil and count('restore.skipped=')==0,'the login gear is not a choice')
actor.request_armor_id=B;actor.cache_armor_id=B
assert(run(2500)==false and restored,'the saved item arrived')
''')
    run_lua(f'local CATEGORY={category}\nlocal RECORD=nil\n' + RESTORE + r'''
-- Anything else that stays on is the player's choice: give up, so later changes are not held behind this.
actor.request_armor_id=C;actor.cache_armor_id=C
assert(run(2500)==false,'two seconds is not yet a choice')
assert(run(2000)==true and restored==nil and count('restore.skipped=')==1 and heard('another item is worn (armor:0000000c)'))
''')
    run_lua(f'local CATEGORY={category}\nlocal RECORD=nil\n' + RESTORE + r'''
-- Thirty seconds of waiting is the limit.
actor.request_armor_id=SLOT.login;actor.cache_armor_id=SLOT.login
assert(run(31000)==true and restored==nil and heard('startup evidence timed out'))
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_a_restore_that_cannot_run_is_skipped_once_on_every_tab(category):
    head = f'local CATEGORY={category}\nlocal RECORD=nil\n' + RESTORE
    run_lua(head + "locked=true;assert(run(1000)==true and restored==nil and heard('saved state needs recovery'))")
    run_lua(head + "domain.presets.Mine=nil;assert(run(1000)==true and restored==nil and count('restore.skipped=')==1)")
    run_lua(head + "REJECT=true\n"
            "assert(run(3000)==true and restored==nil and heard('incompatible'),'the composition is checked before anything is worn')")
    run_lua(head + "session.restore=function()return nil,'session is not idle'end\n"
            "assert(run(3000)==true and heard('session is not idle') and not st.startup.active)")
    # A broken adapter is isolated from the frame, and never resets what may be worn.
    run_lua(head + "session.restore=function()restoring=true;return true end;session.step=function()error('native proof changed')end\n"
            "assert(run(3000)==true and st.startup.finished and not st.startup.active and tostring(abandoned):find('native proof changed',1,true))\n"
            "assert(count('restore.skipped=')==1 and run(1000)==true)")
    run_lua(f'local CATEGORY={category}\nlocal RECORD=false\n' + RESTORE + "assert(run(100)==true and #said==0,'nothing saved, nothing to do')")


@pytest.mark.parametrize('category', [0, 1, 2])
def test_a_restore_may_fetch_the_catalog_it_needs(category):
    run_lua(f'local CATEGORY={category}\nlocal RECORD=nil\n' + RESTORE.replace(
        "catalog=function()return catalog end,", "catalog=function()return ready and catalog or nil end,ensure_catalog=function()asked=asked+1;return ready and catalog or nil,failure end,"
    ).replace("local ship,idle=true,true", "local ship,idle=true,true\nlocal ready,asked,failure=false,0,nil") + r'''
assert(run(1000)==false and asked>=5 and restored==nil,'a pending catalog is asked for again')
failure='catalog unavailable';assert(run(200)==true and heard('restore.skipped='..(CATEGORY==0 and''or CATEGORY..':')..'catalog unavailable'))
''')


# Stage 5 of research/106: one frame for every tab. The caller observes the
# list, frames the tab whose list is up, hides the others, and tells every tab
# when the Armory cannot be read or is gone.
FRAME = CREATOR.replace("assert(tab:ensure_flow()==flow and tab:flow()==flow and panel_made=='panel')", r'''
local draws,steps,stepped,samples=0,0,0,0
flow.draw=function(_,sample,input)draws=draws+1;flow.drawn_prefix=sample.native_prefix end
session.step=function()steps=steps+1 end
local taken=grid.snapshot
function grid:snapshot(...)samples=samples+1;if unreadable then return nil,'list is being rebuilt'end;return taken(self,...)end
local input={x=0,y=0,down=false}
local sample={}
local function frame(with)
 now=now+100;tab:observe(now);tab:frame(now,sample,with==nil and input or with or nil)
end
catalog.capabilities={ownership_verified=true,accessory_transmog_enabled=true}
domain.presets.Mine={appearance_id=B,stats_id='s-c',passive_variant_id='p-b'}
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_every_tab_runs_the_same_frame(category):
    run_lua(f'local CATEGORY={category}\n' + FRAME + r'''
-- The cards go up by themselves: the creator is made, the first owned card
-- selected, and the list built once that selection has settled.
frame();assert(tab:flow()==flow and selected_kit==B and attempts==0 and draws==1 and flow.drawn_prefix==nil)
frame();assert(attempts==1 and tab:cards() and draws==1,'nothing is drawn over a list that was not read again')
frame();assert(draws==2 and flow.drawn_prefix and #flow.drawn_prefix.cells==1)
frame();frame();assert(attempts==1 and draws==4)
-- The session is stepped on the tab's own verified list, and before the draw.
assert(tab:ensure_session());steps=0;frame();assert(steps==1 and draws==5)
frame(false);assert(steps==2 and draws==5,'without input the session still steps and nothing is drawn')
-- An unreadable list is not a departure: the cards stay, the panel waits.
unreadable=true;local cleared=flow_clears
frame();assert(tab:cards() and flow_clears==cleared+1 and draws==5 and leaves==0 and steps==2)
unreadable=false;frame();assert(draws==6 and attempts==1)
assert(heard('grid.wait=') and heard('grid.recovered='))
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_the_list_is_read_once_a_frame_with_cards_and_ten_times_a_second_without(category):
    run_lua(f'local CATEGORY={category}\n' + FRAME + r'''
now=now+1000;samples=0
for _=1,10 do now=now+10;tab:observe(now)end
assert(samples==1,'no cards: one reading per 100 ms, got '..samples)
assert(tab:build_list());samples=0
for _=1,10 do now=now+10;tab:observe(now)end
assert(samples==10,'cards up: one reading per frame, got '..samples)
-- What the reading says is published for the creator.
assert(catalog.context.current_kit_id==nil and next(catalog.context.appearance_previews)==nil)
-- The game rebuilt its list under the cards: the reading retires them.
custom=custom+1;now=now+10;tab:observe(now);assert(tab:cards()==nil and restores==0)
-- Leaving the picker view ends the session's browsing.
assert(tab:ensure_session());now=now+200;tab:observe(now);assert(session_left==0)
mode=1;now=now+200;tab:observe(now);assert(session_left==1,'the picker went away')
now=now+200;tab:observe(now);assert(session_left==1,'once')
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_a_tab_whose_list_left_the_screen_is_hidden_once(category):
    run_lua(f'local CATEGORY={category}\n' + FRAME + r'''
tab:hide(now);assert(leaves==0,'a tab that was never shown has nothing to leave')
frame();frame();frame();assert(tab:cards() and draws==2)
assert(tab:ensure_session());st.selected_label='Mine';st.custom_rows_dirty=true;st.creator_failed=true
tab:hide(now)
assert(leaves==1 and session_left==1 and tab:cards()==nil and restores==0,'nothing is restored into another list')
assert(st.selected_label==nil and not st.custom_rows_dirty and not st.creator_failed and tab.section:status().reason=='left Armor')
local asked=0;flow.before=function()asked=asked+1;return true end
assert(tab:before(input)==true and asked==0,'a hidden tab guards nothing')
tab:hide(now);tab:hide(now);assert(leaves==1,'leaving is an event, not a state')
-- Back on screen: the cards go up again and the guard returns.
frame();frame();frame();assert(tab:cards() and attempts==2 and draws==4)
assert(tab:before(input)==true and asked==1)
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_an_unreadable_armory_keeps_the_cards_and_a_departed_one_drops_them(category):
    run_lua(f'local CATEGORY={category}\n' + FRAME + r'''
frame();frame();frame();assert(tab:cards() and draws==2)
local asked=0;flow.before=function()asked=asked+1;return true end
-- First frame without a sample, not known to be gone: the panel is cleared, nothing else.
local cleared=flow_clears
tab:away(now,false,true,false);assert(flow_clears==cleared+1 and tab:cards() and leaves==0 and st.snapshot==nil)
tab:away(now,false,false,false);assert(flow_clears==cleared+1,'cleared once')
assert(tab:before(input)==true and asked==1,'the guard still protects the cards in view')
-- Known to be gone: everything of the tab goes, once, and the section is armed for the next entry.
tab:away(now,true,false,true);assert(leaves==1 and tab:cards()==nil and restores==0 and tab.section:status().reason=='left Armor')
assert(tab:before(input)==true and asked==1)
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_a_failed_guard_keeps_the_creator_down_until_the_tab_is_left(category):
    run_lua(f'local CATEGORY={category}\n' + FRAME + r'''
frame();frame();frame();assert(tab:cards() and draws==2)
guard=false;assert(tab:before(input)==nil and tab:flow()==nil)
for _=1,20 do frame()end
assert(tab:flow()==nil and attempts==1 and leaves==1,'the creator came back while its guard is failing')
tab.section:request(now);for _=1,5 do frame()end
assert(tab:flow()==nil and attempts==1,'a section asked for again must not bring a failed creator back')
-- Leaving the tab is what arms it again.
guard=true;tab:hide(now);frame();frame();frame()
assert(tab:flow()==flow and attempts==2)
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_ownership_drift_is_read_the_same_way_on_every_tab(category):
    run_lua(f'local CATEGORY={category}\n' + FRAME + r'''
domain.owned={};frame()
assert(domain.owned[B] and domain.ownership_verified and not st.ownership_changed,'the first reading is the catalog arriving')
frame();frame();assert(attempts==1)
-- The same ownership in a new table is no change.
catalog.owned={[B]=true,[C]=true};frame();assert(not st.ownership_changed and restores==0)
-- A reading that is no longer verified stops Apply and keeps the list.
catalog.capabilities.ownership_verified=false;frame()
assert(domain.ownership_verified==false and restores==0 and tab:cards(),'an unverified reading must not tear the list down')
assert(creator.variant_view().can_apply==false)
catalog.capabilities.ownership_verified=true;frame();assert(domain.ownership_verified==true and restores==0)
-- What is owned changed: the list is put back and built again.
catalog.owned={[B]=true};frame()
assert(domain.owned[C]==nil and restores==1,'a change of ownership rebuilds the list')
frame();frame();assert(attempts==2 and tab:cards())
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_the_tab_lifecycle_calls_are_the_same_for_every_tab(category):
    run_lua(f'local CATEGORY={category}\n' + FRAME.replace(
        "native_patch=function()return native_patch end,", "native_patch=function()return native_patch end,automatic=function()return automatic end,"
        "stepped=function()STEPPED=(STEPPED or 0)+1 end,timed=function(name,seconds)timed[name]=(timed[name]or 0)+1 end,"
    ).replace("local input={x=0,y=0,down=false}", "local input={x=0,y=0,down=false}\nautomatic=false;timed={}") + r'''
local closed=0;session.is_active=function()return false end;session.shutdown=function()closed=closed+1 end
-- A tab told not to put its cards up by itself leaves the list alone.
frame();frame();frame();assert(tab:flow()==nil and attempts==0)
automatic=true;frame();frame();frame();assert(tab:cards() and timed.draw==2)
assert(tab:before(input)==true and timed.guard==1)
assert(tab:ensure_session());frame();assert(STEPPED==1)
-- Availability: body armor always; the others in the ship Armory when the slot can be transmogged.
assert(tab:available()==true)
screen='deployment';assert(tab:available()==(CATEGORY==0));screen='armory'
catalog.capabilities.accessory_transmog_enabled=false;assert(tab:available()==(CATEGORY==0))
-- A catalog read again keeps no session made against the old one.
assert(tab:is_active()==false and tab:busy()==false)
tab:reset_catalog();assert(tab:session()==nil and st.owned_source==nil)
-- A screen of another kind decides anew what the creator may do.
tab:drop_flow();assert(tab:flow()==nil and leaves==1)
-- Suspended: nothing of the tab on screen until it is resumed.
tab:hide(now);frame();frame();assert(tab:flow() and tab:cards(),'the next entry makes a creator for the screen that is up')
assert(tab:suspend()==true and tab:cards()==nil and tab:flow()==nil and not st.custom_rows_dirty)
tab:resume(now);assert(tab.section:status().phase=='waiting')
assert(tab:ensure_session());tab:shutdown();assert(closed==1)
''')


# Review of stage 4: the thirty seconds must not include the time the caller
# needs before it can read a catalog at all.
@pytest.mark.parametrize('category', [0, 1, 2])
def test_nothing_is_timed_before_the_caller_can_read_a_catalog(category):
    run_lua(f'local CATEGORY={category}\nlocal RECORD=nil\n' + RESTORE.replace(
        "native_patch=function()return native_patch end,", "native_patch=function()return native_patch end,restore_ready=function()return READY end,") + r'''
assert(run(60000)==false and restored==nil and count('restore.skipped=')==0,'a slow catalog reader timed the restore out')
READY=true;assert(run(2500)==false and restored and restored[1]=='Mine')
''')


# research/106, the two preview bugs. The model of a card is the record that
# shows that card's look: its thumbnail donor when it has one.
@pytest.mark.parametrize('category', [0, 1, 2])
def test_a_card_is_previewed_on_the_record_that_shows_its_look(category):
    run_lua(f'local CATEGORY={category}\nlocal NAME="x"\n' + FIXTURE + r'''
assert(host.model_kit(request,'One')=='armor:donor001','a card with a donor is modelled by the donor')
assert(host.model_kit(request,'Two')=='armor:000000aa' and host.model_kit(request,'Gone')==nil and host.model_kit(request,nil)==nil)
function grid:equipment_feedback(id,c,shown)calls[#calls+1]={'feedback',id,shown};return true end
assert(host.equipped_feedback(request,'One') and calls[#calls][2]=='armor:000000aa' and calls[#calls][3]=='armor:donor001',
 'the feedback must know which record the applied card is shown on')
assert(host.equipped_feedback(request) and calls[#calls][3]==nil)
''')


# Seen in game 2026-10-01: with more looks than records the card that found no
# record was rebuilt into the list on every click. The model is now built from
# a record that shows the look, and selecting a card never rebuilds the list.


@pytest.mark.parametrize('category', [0, 1, 2])
def test_selecting_a_card_never_rebuilds_the_list(category):
    run_lua(f'local CATEGORY={category}\n' + FRAME + r"""
frame();frame();frame();assert(tab:cards() and attempts==1)
assert(tab:ensure_session())
APPLEBACON_VARIANT_THUMBNAILS={borrow=function(cards,catalog)return catalog.registered_entries end,
 stale=function()return'armor:0000000b'end,model=function(c,label,record)return record end}
local before=restores
for _=1,3 do assert(creator.intent{kind='select_variant',label='Mine',request=domain.presets.Mine}==true);frame();frame()end
assert(attempts==1 and restores==before and not heard('presentation.redress='))
""")


# Review of stage 5: leaving the Armory ended a startup restore that was
# running for a tab that was not even on screen, and the saved item stayed off.
@pytest.mark.parametrize('category', [0, 1, 2])
def test_leaving_the_armory_does_not_end_a_restore_that_is_running(category):
    run_lua(f'local CATEGORY={category}\nlocal RECORD=nil\n' + RESTORE + r'''
assert(run(2500)==false and restored and st.startup.active)
tab:away(now,true,false,true);tab:leave();tab:hide(now)
assert(session_left==0,'the running restore was ended by leaving the Armory')
-- Nor is its session taken from under it by a catalog read again.
session.is_active=function()return false end
assert(tab:is_active()==true,'a running restore is something on its way through the catalog')
tab:reset_catalog();assert(tab:session()==session,'the restoring session was dropped')
assert(run(100)==false and count('restore.skipped=')==0)
restoring=false;session.restore_status='complete';assert(run(100)==true)
tab:leave();assert(session_left==1,'an ordinary session is left as ever')
''')


# Review of stage 5: a catalog replaced under a tab (not through a new menu).
@pytest.mark.parametrize('category', [0, 1, 2])
def test_a_catalog_replaced_under_the_tab_keeps_nothing_made_against_the_old_one(category):
    run_lua(f'local CATEGORY={category}\n' + FRAME.replace(
        "catalog=function()return catalog end,", "catalog=function()return current or catalog end,") + r'''
frame();frame();frame();assert(tab:ensure_session()==session)
local active=false;session.is_active=function()return active end
current=setmetatable({},{__index=catalog});frame()
assert(tab:session()==nil,'a session made against the old catalog was kept')
assert(tab:ensure_session()==session)
-- A composition still worn through the session is never dropped under the wearer.
active=true;current=setmetatable({},{__index=catalog});frame()
assert(tab:session()==session)
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_starting_apply_preserves_last_equipped_intent_until_successful_persist(category):
    run_lua(f'local CATEGORY={category}\n' + CREATOR + r'''
local request={appearance_id=B,stats_id='native-stats:0000000b',passive_variant_id='p-b'}
assert(tab.equipped:remember('Original',request))
local original=files[SLOT.record]
local o=tab:ensure_session().host
assert(o.before_apply(true)==true and files[SLOT.record]==original)
assert(o.before_apply(false)==true and files[SLOT.record]==original)
assert(o.before_apply(true,true)==true and files[SLOT.record]==original)
-- Only the callback reached after a verified native completion clears intent.
assert(o.persist_equipped(nil,nil))
assert(files[SLOT.record]~=original and tab.equipped:record()==nil)
''')


@pytest.mark.parametrize('category', [0, 1, 2])
def test_hidden_tab_steps_only_an_existing_profile_reconcile(category):
    run_lua(f'local CATEGORY={category}\n' + CREATOR + r'''
local pending=true;local ticks={}
session.reconciling=function()return pending end
session.step=function(_,now)ticks[#ticks+1]=now end
st.session=session;st.shown=true
local left=0;session.leave=function()left=left+1;return true end
-- The first hide leaves the presentation, then continues verified observation.
tab:hide(10);tab:hide(11)
assert(left==1 and #ticks==2 and ticks[1]==10 and ticks[2]==11)
pending=false;tab:hide(12);assert(#ticks==2,'ordinary hidden session stepped')
pending=true;tab:away(13,false,false,true);assert(ticks[3]==13)
''')


def test_own_list_rebuild_cancels_old_preview_before_temporary_native_selection():
    run_lua('local CATEGORY=0\n' + TAB + r'''
domain.presets.Mine={appearance_id=B,stats_id='s-c',passive_variant_id='p-b'}
assert(tab:build_list());st.selected_label='Mine';st.resume_label='Mine';st.custom_rows_dirty=true
local cancelled_before=false
session.cancel_preview=function()cancelled_before=true;return true end
local select=grid.select_kit
grid.select_kit=function(self,...)assert(cancelled_before,'old preview survived temporary native focus');return select(self,...)end
tab:rebuild(now)
assert(cancelled_before and st.rebuild_pending and st.resume_label=='Mine')
''')
