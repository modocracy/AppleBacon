"""Headless equip and forced actor redraw with no Armory UI and no variant session."""
from test_runtime import run_lua

FIXTURE = '''
local Direct=dofile('src/armor_refresh_direct.lua')
local Refresh=dofile('src/armor_refresh.lua')
local A,B,C='armor:00000001','armor:00000002','armor:00000003'
local owned={[A]=true,[B]=true,[C]=true}
local passives={[A]=11,[B]=22,[C]=33}
local live={session='ship:local1',other_key='helmet|cape|body',pending_nonarmor=false,
 controller_armor_id=A,profile_armor_id=A,request_armor_id=A,cache_armor_id=A,cache_passive=11}
local calls={}
local settled=true
local bridges=0
local bridge={capabilities={commit_verified=true,cache_layout_verified=true,passive_cache_available=true}}
bridge.snapshot=function()local copy={};for k,v in pairs(live)do copy[k]=v end;return copy end
bridge.verify=function(s)for k,v in pairs(s)do if live[k]~=v then return false end end;return true end
bridge.verify_owned=function(ids)
 for _,id in ipairs(ids)do if not owned[id]then return false end end;return #ids>0
end
bridge.owned_armors=function()
 local ids={};for id,yes in pairs(owned)do if yes then ids[#ids+1]=id end end;return ids
end
bridge.commit_owned=function(id,expected)
 assert(bridge.verify(expected)and owned[id],'unguarded native commit')
 calls[#calls+1]=id
 live.controller_armor_id=id;live.profile_armor_id=id;live.request_armor_id=id
 return true
end
local catalog={catalog={},owned=owned,context={passive_variants={}},
 verify_owned=function(ids)return bridge.verify_owned(ids)end}
for _,id in ipairs({A,B,C})do
 catalog.catalog[id]={appearance_id=id,stats_id='native-stats:'..id,passive_variant_id='pv:'..id}
 catalog.context.passive_variants['pv:'..id]={enum=passives[id]}
end
local direct=Direct.new{catalog=function()return catalog end,
 player=function()
  return {settled=settled,request_armor_id=live.request_armor_id,cache_armor_id=live.cache_armor_id,
   cache_passive_enum=live.cache_passive}
 end,
 new_refresh=function()bridges=bridges+1;return Refresh.new(bridge)end}
local function settle(id,passive)live.cache_armor_id=id;live.cache_passive=passive end
'''


def test_redraw_cycles_an_alternate_owned_armor_and_returns_to_the_worn_kit():
    run_lua(FIXTURE + '''
assert(direct:redraw(0))
assert(direct:status().alternate_id==B and #calls==0)
assert(direct:step(1)=='wait_alternate');assert(#calls==1 and calls[1]==B)
assert(direct:step(2)=='wait_alternate') -- The cache still holds the original carrier.
settle(B,22)
assert(direct:step(3)=='wait_alternate');assert(direct:step(4)=='commit_target')
assert(direct:step(5)=='wait_target');assert(#calls==2 and calls[2]==A)
settle(A,11)
assert(direct:step(6)=='wait_target')
assert(direct:step(7)=='complete')
local status=direct:status()
assert(status.phase=='complete'and status.outcome=='complete'and status.intent=='redraw')
assert(status.target_id==A and status.commits==2 and not status.needs_recovery)
-- The redraw ends on exactly the equipment and passive it started from.
assert(live.request_armor_id==A and live.cache_armor_id==A and live.cache_passive==11)
assert(status.native.request_armor_id==A and status.native.cache_armor_id==A and status.native.cache_passive==11)
''')


def test_equip_of_a_different_owned_kit_commits_once_and_completes():
    run_lua(FIXTURE + '''
assert(direct:equip('00000002',0))
assert(direct:status().alternate_id==nil)
assert(direct:step(1)=='wait_target');assert(#calls==1 and calls[1]==B)
settle(B,22)
assert(direct:step(2)=='wait_target');assert(direct:step(3)=='complete')
assert(live.request_armor_id==B and live.cache_armor_id==B)
assert(direct:status().outcome=='complete'and direct:status().intent=='equip')
-- A later request reuses the same driver once the previous one finished.
assert(direct:equip('armor:00000002',4))
assert(direct:step(5)=='wait_alternate');assert(calls[2]==A) -- Already worn: alternate cycle.
''')


def test_a_second_request_is_refused_while_a_transition_is_in_flight():
    run_lua(FIXTURE + '''
assert(direct:redraw(0));assert(direct:step(1)=='wait_alternate');assert(#calls==1)
local ok,why=direct:equip('00000003',2)
assert(not ok and why=='a native refresh is already in flight')
assert(not direct:redraw(2))
assert(#calls==1) -- The refused requests never reached native code.
''')


def test_unknown_unowned_and_malformed_ids_are_refused_without_any_commit():
    run_lua(FIXTURE + '''
local ok,why=direct:equip('not-hex',0);assert(not ok and why=='expected an 8-hex armor id')
ok,why=direct:equip('000000ff',0);assert(not ok and why=='no armor record for armor:000000ff')
owned[C]=false
ok,why=direct:equip('00000003',0);assert(not ok and why=='armor:00000003 is not owned')
assert(#calls==0 and bridges==0)
''')


def test_redraw_without_an_alternate_owned_armor_is_refused_without_any_commit():
    run_lua(FIXTURE + '''
owned[B]=false;owned[C]=false
local ok,why=direct:redraw(0)
assert(not ok and why:find('a different owned armor is required'),tostring(why))
assert(#calls==0 and direct:status().phase=='idle')
-- Ownership returning makes the very same request succeed, so nothing latched.
owned[B]=true
assert(direct:redraw(0));assert(direct:step(1)=='wait_alternate'and calls[1]==B)
''')


def test_a_native_transition_already_in_flight_is_refused():
    run_lua(FIXTURE + '''
live.cache_armor_id=B
local ok,why=direct:redraw(0);assert(not ok and why=='native armor is still transitioning')
ok,why=direct:equip('00000003',0);assert(not ok and why=='native armor is still transitioning')
live.cache_armor_id=A;settled=false
ok,why=direct:redraw(0);assert(not ok and why=='native armor is still transitioning')
settled=true;live.pending_nonarmor=true
ok,why=direct:redraw(0);assert(not ok and why:find('pending native non%-armor'),tostring(why))
assert(#calls==0)
''')


def test_an_uncertain_outcome_blocks_further_requests_until_explicit_recovery():
    run_lua(FIXTURE + '''
assert(direct:redraw(0));assert(direct:step(1)=='wait_alternate'and #calls==1)
live.other_key='the player changed a helmet'
assert(direct:step(2)=='blocked')
local status=direct:status()
assert(status.outcome=='blocked'and status.needs_recovery and status.commits==1)
assert(direct:is_busy(),'a blocked native coordinator must still hold other writers back')
local ok,why=direct:redraw(3);assert(not ok and why=='a native refresh needs recovery')
assert(#calls==1)
live.other_key='helmet|cape|body'
assert(direct:recover(3));assert(direct:step(4)=='wait_restore'and #calls==2 and calls[2]==A)
settle(A,11);direct:step(5)
assert(direct:step(6)=='failed') -- Restored, but the redraw itself is never claimed.
assert(direct:status().outcome=='failed'and not direct:status().needs_recovery)
assert(not direct:is_busy())
assert(live.request_armor_id==A and live.cache_armor_id==A)
assert(direct:redraw(7)) -- A finished failure releases the driver for the next attempt.
''')


def test_status_is_readable_before_any_request_and_reports_the_native_records():
    run_lua(FIXTURE + '''
local status=direct:status()
assert(status.phase=='idle'and status.outcome=='idle'and status.target_id==nil and status.commits==0)
assert(status.native.request_armor_id==A and status.native.cache_armor_id==A
 and status.native.cache_passive==11 and status.native.settled==true)
local text=Direct.format(status)
assert(text:find('phase=idle')and text:find('native=armor:00000001/armor:00000001/11/true'),text)
assert(direct:redraw(0));direct:step(1)
text=Direct.format(direct:status())
assert(text:find('intent=redraw')and text:find('target=armor:00000001')
 and text:find('alternate=armor:00000002')and text:find('commits=1'),text)
''')


def test_busy_query_does_not_sample_native_equipment_and_tracks_completion():
    run_lua(FIXTURE + '''
local empty=Direct.new{catalog=function()error('idle busy query read catalog')end,
 player=function()error('idle busy query sampled native player')end,
 new_refresh=function()error('idle busy query created coordinator')end}
for i=1,1000 do assert(empty:is_busy()==false)end
assert(not direct:is_busy())
assert(direct:equip(B,0));assert(direct:is_busy())
for now=1,20 do direct:step(now);settle(B,22)end
assert(not direct:is_busy()and direct:status().outcome=='complete')
''')


def test_step_is_inert_without_a_request_and_ignores_an_invalid_clock():
    run_lua(FIXTURE + '''
assert(direct:step(0)=='idle'and direct:step('later')=='idle'and #calls==0)
assert(direct:redraw(0))
assert(direct:step(0/0)=='commit_alternate'and #calls==0) -- NaN never drives a commit.
assert(direct:step(1)=='wait_alternate'and #calls==1)
''')


# A caller that composed a record with a variant's passive names that passive:
# it is the one verified after the commit, not the catalog's static metadata.
def test_equip_honours_a_caller_supplied_passive_over_the_catalog_metadata():
    run_lua(FIXTURE + '''
assert(direct:equip('00000002',0,{passive_enum=44}))
assert(direct:step(1)=='wait_target');assert(#calls==1 and calls[1]==B)
settle(B,22)
assert(direct:step(2)=='wait_target','the catalog passive must not complete a refresh that asked for another')
settle(B,44)
assert(direct:step(3)=='wait_target');assert(direct:step(4)=='complete')
local ok,why=direct:equip('00000003',5,{passive_enum='x'});assert(not ok and why=='a passive enum must be a number',tostring(why))
''')
