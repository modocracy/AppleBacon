"""The Armory lockout of 2026-09-30, through the real main.lua frame loop.

The game re-equips the login armor at launch, the startup restore puts the
carrier back on the actor through the live player setter only, and the
Armory's committed profile keeps the login gear. Every single-slot commit
then re-dresses the actor from that stale profile. On entering the Armory
main.lua must commit the worn kit once, before anything else commits.
"""
from test_creator_failure_main import HARNESS, ROOT, run

SETUP = r'''
local worn={armor_id='armor:000000a1',helmet_id='armor:000000c2',cape_id='armor:000000d1'}
local live={controller='armor:000000b1',profile='armor:000000b1',helmet='armor:000000c1',cape='armor:000000d1'}
result.owned[worn.armor_id]=true;result.owned[live.profile]=true
worn_calls={}
function grid:commit_capabilities()return {commit_verified=true}end
function grid:commit_snapshot(_,opts)
 local reconcile=opts and opts.reconcile==true or false
 return {session='armory',local_player_id=7,pending_nonarmor=false,
  other_key=reconcile and 'rest' or 'rest|'..live.helmet..'|'..live.cape,
  controller_armor_id=live.controller,profile_armor_id=live.profile,
  profile_helmet_id=live.helmet,profile_cape_id=live.cape,reconcile=reconcile}
end
function grid:verify_commit()return true end
function grid:commit_owned(id)error('a single-slot commit reached the game before the profile was reconciled: '..tostring(id))end
function grid:commit_worn(snapshot,_,fields)
 assert(snapshot.reconcile,'the reconcile commit needs the reconcile snapshot')
 worn_calls[#worn_calls+1]=fields
 live.controller,live.profile,live.helmet,live.cape=fields.armor_id,fields.armor_id,fields.helmet_id,fields.cape_id
 return true
end
local probe={sample=function()
 local request={body_type=0,armor_id=worn.armor_id,helmet_id=worn.helmet_id,cape_id=worn.cape_id}
 return {local_player_id=7,session_key='actor',request=request,current=request,
  request_armor_id=worn.armor_id,cache_armor_id=worn.armor_id,cache_passive_enum=1,settled=true,
  verify=function()return true end}
end,sample_body_type=function()return {body_type=0}end}
PlayerCustomizationProbe={new=function()return probe end}
AppearancePatch={compatible=function()return true end}
VariantSession=dofile('src/variant_session.lua')
ArmorRefresh=dofile('src/armor_refresh.lua')
ArmorRefreshBridge=dofile('src/armor_refresh_bridge.lua')
'''


def test_entering_the_armory_commits_the_worn_kit_once_before_any_single_slot_commit():
    run('''
for _=1,8 do advance()end
assert(logged_count('variant.reconcile=armor:000000a1')==1,'the profile reconcile did not start')
assert(#worn_calls==1,'the worn kit was not committed exactly once: '..#worn_calls)
assert(worn_calls[1].armor_id=='armor:000000a1' and worn_calls[1].helmet_id=='armor:000000c2' and worn_calls[1].cape_id=='armor:000000d1')
assert(logged_count('variant.reconciled=')==1,'the reconcile did not complete')
assert(logged_count('variant.reconcile_refused=')==0 and logged_count('variant.reconcile_failed=')==0)
assert(logged_count('runtime.error=')==0,'frame loop raised')
-- The same visit never reconciles twice; a new visit with an agreeing profile does nothing.
for _=1,8 do advance()end
assert(#worn_calls==1)
sample_mode='exit';advance();advance()
menu_token='menu-two';sample_mode='ready'
for _=1,8 do advance()end
assert(#worn_calls==1 and logged_count('variant.reconcile=')==1,'an agreeing profile was reconciled again')
assert(logged_count('runtime.error=')==0)
''', setup=SETUP)


# 2026-09-30, second launch: the Armory opened straight on the helmet tab, the
# reconcile only ran on the armor tab, and the helmet commit re-dressed the
# body from the stale profile again. The committed profile is one buffer
# whatever tab is showing; the reconcile must run on any of them.
def test_the_reconcile_runs_when_the_armory_opens_on_an_accessory_tab():
    run('''
for _=1,8 do advance()end
assert(logged_count('variant.reconcile=armor:000000a1')==1,'the profile reconcile did not run on the helmet tab')
assert(#worn_calls==1 and logged_count('variant.reconciled=')==1)
assert(views_seen>=1,'the reconcile must read the Armory through the catalog of the tab being shown')
assert(editor_draws>0,'the helmet editor must have owned the frames, as it does in the game')
assert(logged_count('runtime.error=')==0)
''', helmet_transmog=True, setup=SETUP+'''
-- The real grid verifies identity mapping only against the catalog of the tab
-- that is showing: an armor-catalog snapshot on the helmet tab is unverified.
result.helmets={category=1,catalog={},owned={},records={},verify_owned=function()return true end,
 capabilities={accessory_transmog_enabled=true}}
-- The real frame loop hands an accessory tab to its editor and returns early;
-- the reconcile must run before that hand-over, not after it.
editor_draws=0
local function stub_tab(category,hooks)
 hooks=hooks or {}
 return {slot={category=category},available=function()return true end,observe=function()end,
  frame=hooks.frame or function()end,hide=function()end,away=function()end,leave=function()end,
  drop_flow=function()end,reset_catalog=function()end,before=hooks.before or function()return true end,
  restore_startup=function()return true end,respawn=function(_,action)if action=='status'then return {restores=0,abandoned=0}end end,
  busy=function()return false end,is_active=function()return false end,shutdown=function()end,
  suspend=function()return true end,resume=function()end}
end
AccessoryUi={new=function(host)return stub_tab(host.category,{frame=function()editor_draws=editor_draws+1 end})end}
local base_snapshot=grid.snapshot
function grid:snapshot(catalog)
 local s=base_snapshot(self,catalog);if not s then return s end
 s.native_category=1;s.identity_mapping_verified=(catalog and catalog.category or 0)==1;return s
end
views_seen=0
local base_commit_snapshot=grid.commit_snapshot
function grid:commit_snapshot(catalog,opts)
 local view=opts and opts.view or catalog
 if not self:snapshot(view).identity_mapping_verified then return nil,'verified native Armor context required'end
 views_seen=views_seen+1
 return base_commit_snapshot(self,catalog,opts)
end
''')
