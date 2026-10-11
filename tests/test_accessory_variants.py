"""Live accessory schemas, isolated slot commits, and shared creation navigation."""
import pytest
from test_catalog import DATA, fixture_script
from test_helmet_catalog import run, ARMOR, HELMET
from test_variant_patch import fixture
from test_variant_wizard import run_lua, FIXTURE
from test_native_grid import run_lua as run_native, SELECTION, COMMIT

CAPE=next(k for k in DATA['kits'].values() if k['category']==2)


def test_modified_cape_is_detected_with_owned_exact_passives_and_separate_domain():
    text=run(fixture_script(selected=[ARMOR,CAPE],live_passives=True,
        mutation="patch(0x23000+28,string.char(7,0,0,0));patch(0x40000+0x1ce4+184+0x14,string.char(2,0,0,0))",
        post_ready=f"""
local c=result.capes;local id='{CAPE['id']}'
assert(c.category==2 and c.capabilities.cape_transmog_enabled and c.capabilities.accessory_transmog_enabled)
assert(c.owned[id] and c.verify_owned({{id}}) and not result.owned[id] and not result.helmets.owned[id])
assert(c.catalog[id].passive_variant_id==data.passives[7].variant_id)
assert(c.context.passive_variants[data.passives[7].variant_id].enum==7)
patch(0x40000+0x1ce4+184+0x14,string.char(1,0,0,0))
local phase;repeat phase=result.refresh_ownership()until phase~='resolving'
assert(phase=='ready' and not c.owned[id] and not c.verify_owned({{id}}))
"""))
    assert text.startswith('ready'),text


def test_cape_composition_preserves_look_resources_and_rejects_cross_slot_donors():
    ids=[f'{k["item_id"]:08x}' for k in DATA['kits'].values() if k['category']==2][:3]
    script=fixture(*ids).replace("dofile('src/variant_patch.lua')","dofile('src/armor_composition.lua')")
    run(script+'''
result.category=2;result.capabilities.cape_transmog_enabled=true
assert(P.compatible(result,request))
local plan=assert(patch:plan(result,request));assert(patch:apply(plan))
assert(read(source.address,28)==source.bytes:sub(1,28))
assert(read(source.address+32,16)==source.bytes:sub(33,48))
local at=ptr(read(source.address+48,8),0)
for i=0,1 do
 local body=read(at+i*24,24);local pieces=ptr(body,8)
 local expected={}
 for _,b in ipairs(source.bodies)do if b.type==3 or b.type==i then
  for _,p in ipairs(b.pieces)do expected[#expected+1]=p end
 end end
 assert(u32(body,16)==#expected)
 for j,p in ipairs(expected)do local raw=read(pieces+(j-1)*96,96)
  assert(raw:sub(1,16)==p.bytes:sub(1,16) and raw:sub(21)==p.bytes:sub(21))
 end
end
assert(patch:reset());assert(read(source.address,64)==source.bytes)
source.category=1;assert(not patch:plan(result,request))
''')


def test_single_numeric_stats_choice_skips_and_back_returns_to_look_without_changing_equipment():
    run_lua(FIXTURE+'''
for id in pairs(context.stats_profiles)do context.stats_profiles[id]=profile(100,500,100)end
local before=S.encode(state)
assert(act('open'));assert(act('select_look','look-b'))
local v=wizard:view(state,context);assert(v.step==3 and v.step_count==2 and v.step_number==2)
assert(v.selection.stats_id=='stats-b')
assert(act('back'));assert(wizard:view(state,context).step==1)
assert(act('select_look','look-a'));assert(act('select_passive','perk-b'))
local ok,why,tx=act('create');assert(ok,why);assert(tx)
assert(wizard:validate_transaction(tx,state,context));assert(S.encode(state)==before)
context.stats_profiles['stats-a'].base_values_verified=false
assert(not wizard:validate_transaction(tx,state,context))
''')


def test_single_accessory_weight_choice_skips_without_inventing_numeric_ratings():
    run_lua(FIXTURE+'''
context.category=2
for id in pairs(context.stats_profiles)do context.stats_profiles[id]={category=2,base_only=true,
 weight_profile_verified=true,body_weights={{body_type=3,pieces={{slot=1,kind=2,weight=0}}}}}end
assert(act('open') and act('select_look','look-b'))
local v=wizard:view(state,context);assert(v.step==3 and v.step_count==2 and v.selection.stats_id=='stats-b')
assert(act('select_passive','perk-b'));assert(act('create'))
''')


@pytest.mark.parametrize('category,offset',[(1,4),(2,8)])
def test_native_accessory_commit_changes_only_requested_profile_slot(category,offset):
    run_native(SELECTION+COMMIT+f'''
catalog.category={category}
for _,record in pairs(catalog.records)do record.category={category} end
put(owner+0x1f83ac,b({category},4))
backend.write_armor=function(at,id)
 assert(at==owner+0x64+{offset},'wrong equipment slot')
 armor_assignments=armor_assignments+1;put(at,b(id,4));return true
end
local g=G.new(bridge,nil,backend);assert(ready(g)=='ready')
local s=assert(g:commit_snapshot(catalog));assert(not s.pending_nonarmor)
local before=read(owner+0x64,44)
assert(g:commit_owned('armor:00005678',s,catalog))
local after=read(owner+0x64,44)
assert(after:sub(1,{offset})==before:sub(1,{offset}) and after:sub({offset+5})==before:sub({offset+5}))
assert(after:sub({offset+1},{offset+4})==b(0x5678,4) and read(owner+0x38,44)==after and commits==1)
''')


def test_passive_effect_change_invalidates_retained_accessory_donor_evidence():
    index=list(DATA['passives']).index('7')
    text=run(fixture_script(selected=[ARMOR,CAPE],live_passives=True,
        mutation="patch(0x23000+28,string.char(7,0,0,0));patch(0x40000+0x1ce4+184+0x14,string.char(2,0,0,0))",
        post_ready=f"""
local c=result.capes;local id='{CAPE['id']}'
assert(c.verify_owned({{id}}))
patch({0xB10000+index*0x1000+48},string.char(77,0,0,0))
assert(not c.verify_owned({{id}}))
assert(not c.verify_owned({{'{ARMOR['id']}'}}))
"""))
    assert text.startswith('ready'),text


def test_logged_sa25_steel_trooper_creation_with_own_stats_has_no_topology_mismatch():
    script=fixture('a3a7e93d','a3a7e93d','7934ed8b').replace("dofile('src/variant_patch.lua')","dofile('src/armor_composition.lua')")
    run(script+'''
result.category=1;result.capabilities.helmet_transmog_enabled=true
assert(P.compatible(result,request))
local plan,why=patch:plan(result,request);assert(plan,why)
assert(plan.source_id==plan.stats_source_id and plan.target_id==request.appearance_id)
assert(patch:apply(plan));assert(patch:reset())
assert(read(source.address,64)==source.bytes)
''')
