"""The save file is never written in a form its own reader rejects, and a file
that cannot be read is kept as it is instead of being restored or replaced."""
import json
import subprocess
from pathlib import Path

from test_startup_restore_main import run as run_startup

ROOT = Path(__file__).resolve().parents[1]


def run_lua(code):
    result = subprocess.run(['luajit', '-'], input="local S=dofile('src/state.lua')\n" + code,
                            text=True, cwd=ROOT, capture_output=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr


def test_encoder_never_writes_a_file_its_own_reader_rejects():
    run_lua(r'''
local st=S.new()
for i=1,257 do st.presets['Look '..i]={appearance_id='a',stats_id='s',passive_variant_id='p'}end
local raw,why=S.encode(st)
assert(not raw and why:find('too many presets',1,true),'oversized save would disappear on next boot')
st=S.new()
for i=1,2200 do local id='kit'..i;st.catalog[id]={appearance_id='a',stats_id='s',passive_variant_id='p'};st.owned[id]=true end
raw,why=S.encode(st)
assert(not raw and why:find('too many records',1,true),'catalog cache exceeded decoder record budget')
st=S.new()
for i=1,4000 do st.catalog['kit'..i]={appearance_id=string.rep('a',128),stats_id=string.rep('s',128),passive_variant_id=string.rep('p',128)}end
raw,why=S.encode(st)
assert(not raw and why:find('too large',1,true),'encoded save exceeded reader byte limit')
''')


def test_explicit_duplicate_ids_are_not_silently_reassigned_on_load():
    run_lua(r'''
local raw='AB_STATE 1\nP v0000000000000001 First a s p\nP v0000000000000001 Second b s p\n'
local st,why=S.decode(raw)
assert(not st and why:find('duplicate variant id',1,true),'ambiguous identity must not be repaired by guesswork')
''')


def test_a_variant_without_an_id_or_another_format_is_not_read():
    run_lua(r'''
assert(not S.decode('AB_STATE 1\nP Saved a s p\n'),'every saved variant names its id')
assert(not S.decode('AB_STATE 2\n'),'an unknown version is not guessed at')
assert(not S.decode('AB_STATEX 1\n') and not S.decode('AB_STATE'),'the header is exact')
local st=assert(S.decode('AB_STATE 1\nP v0000000000000001 Saved a s p\n'))
assert(st.presets.Saved.id=='v0000000000000001')
''')


SAVED = 'AB_STATE 1\nS armor:00000001 stats-b perk-a\nP v0000000000000001 Saved armor:00000001 stats-b perk-a\n'


def test_current_main_preserves_future_or_corrupt_body_save_without_restoring():
    for raw in ['AB_UI\t2\nappearance\n' + SAVED,
                'AB_UI\t1\nappearance\nAB_STATE 99\n',
                'AB_UI\t1\nappearance\nAB_STATE 1\nP invalid\n']:
        run_startup(r'''
local original=files['applebacon.state']
for i=1,40 do tick_ship()end
assert(commits==0 and patches==0)
assert(files['applebacon.state']==original)
assert(logged_count('state.decode_error=')==1)
''', "files['applebacon.state']=" + json.dumps(raw) + '\n')
