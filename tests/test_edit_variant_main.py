"""Edit a worn saved variant through the real main workflow."""
from test_creator_failure_main import HARNESS, ROOT
from test_startup_restore_main import SEED
from test_diverkit_compat import run
from test_remove_equipped_main import SETUP


def exercise(body):
    return HARNESS+SEED+SETUP+'\nlocal function boot()\n'+(ROOT/'src/main.lua').read_text()+r'''
end
local runtime=boot();assert(runtime.status~='startup_failed',runtime.status)
now=16000
for i=1,30 do menu_tick()end
assert(active_patch and commits==2 and reset_count==0)
sample_mode='ready'
for i=1,15 do menu_tick()end
assert(presentation_active and flow:view().selected_variant.label=='Saved')
local function stored()
 local payload=files['applebacon.state']:match('^AB_UI\t1\nappearance\n(.*)$')
 return assert(State.decode(payload))
end
local id=stored().presets.Saved.id;assert(id)
'''+body


def test_editing_the_worn_variant_saves_over_it_and_asks_to_equip_again():
    run(exercise(r'''
local view=flow:view()
assert(view.can_edit and view.can_remove and not view.apply_pending)
local saves=save_count
assert(flow:action{type='edit_variant',label='Saved'})
view=flow:view()
assert(view.open and view.editing_variant=='Saved' and view.step==3)
assert(view.selection.appearance_id==A and view.selection.stats_id=='stats-b' and view.selection.passive_variant_id=='perk-a')
assert(save_count==saves,'opening an edit writes nothing')
assert(flow:action{type='select_passive',id='perk-b'})
assert(flow:action{type='create'})
assert(not flow:view().open and save_count==saves+1)
local presets=stored().presets;local n=0;for _ in pairs(presets)do n=n+1 end
assert(n==1 and presets.Saved and presets.Saved.id==id and presets.Saved.passive_variant_id=='perk-b')
assert(files['equipped.state']:find('none',1,true),'the worn record of the old definition is cleared')
assert(logged_count('creator.edited=Saved -> Saved (worn)')==1)
assert(active_patch and reset_count==0 and live.request_armor_id==A and commits==2,'what is worn right now is untouched')
for i=1,15 do menu_tick()end
assert(presentation_active and logged_count('runtime.error=')==0)
'''))


def test_cancelling_an_edit_changes_nothing():
    run(exercise(r'''
local before,worn=files['applebacon.state'],files['equipped.state']
assert(flow:action{type='edit_variant',label='Saved'})
assert(flow:action{type='select_passive',id='perk-b'})
assert(flow:action{type='cancel'})
for i=1,15 do menu_tick()end
assert(files['applebacon.state']==before and files['equipped.state']==worn)
assert(not flow:view().open and presentation_active and logged_count('runtime.error=')==0)
'''))
