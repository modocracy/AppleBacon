"""AppleBacon's own startup hook: the original game module still runs, AppleBacon starts once."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

FIXTURE = r'''
local template=assert(io.open('src/boot_hook.lua','rb')):read('*a')
local MARKER='--[[APPLEBACON_ORIGINAL_BYTECODE]]nil'
local function build(original)
 local dumped=string.dump(original)
 local literal='"'..dumped:gsub('.',function(c)return '\\'..c:byte()end)..'"'
 local at=assert(template:find(MARKER,1,true))
 return template:sub(1,at-1)..literal..template:sub(at+#MARKER)
end
local MODULE='mods/applebacon/core'
local started,loaded=0,{}
local function reset()
 started=0;AppleBacon=nil;CowboyBingusModLoader=nil;AppleBaconStandaloneLoader=nil;package.loaded[MODULE]=nil
 loaded={}
end
Application={can_get=function(kind,name)return kind=='lua'and name==MODULE and not loaded.missing end}
package.preload[MODULE]=function()
 started=started+1
 if loaded.fail then error('AppleBacon failed to start')end
 AppleBacon={loader=CowboyBingusModLoader or AppleBaconStandaloneLoader}
 return AppleBacon
end
local TMP=assert(os.getenv('APPLEBACON_TEST_TMP'))
local real_getenv=os.getenv
os.getenv=function(name)if name=='LOCALAPPDATA'then return TMP end;return real_getenv(name)end
-- The game's original module: its return values must reach require unchanged.
local hook=build(function(...)ORIGINAL_RAN=(ORIGINAL_RAN or 0)+1;return 'bank_reference',select('#',...)end)
local function run(...)return assert(loadstring(hook,'=hook'))(...)end
'''


def run_lua(code, tmp_path):
    result = subprocess.run(['luajit', '-'], input=FIXTURE + code, text=True, cwd=ROOT,
                            capture_output=True, timeout=30, env={**__import__('os').environ, 'APPLEBACON_TEST_TMP': str(tmp_path)})
    assert result.returncode == 0, result.stdout + result.stderr


def test_without_a_loader_the_hook_runs_the_original_then_starts_applebacon_once(tmp_path):
    run_lua(r'''
reset()
local value,count=run('core/wwise/lua/wwise_bank_reference')
assert(value=='bank_reference'and count==1 and ORIGINAL_RAN==1,'original module result is preserved')
assert(started==1 and AppleBacon.loader==AppleBaconStandaloneLoader)
local loader=AppleBaconStandaloneLoader
assert(loader.api==1 and loader.standalone and loader.log_directory==TMP..'\\AppleBacon\\Logs')
local file=assert(loader.open_log('AppleBacon.log'));file:write('ok');file:close()
assert(not loader.open_log('..\\escape.log'),'log names stay inside the log folder')
-- A second require of the hook never starts AppleBacon again.
run();assert(started==1 and ORIGINAL_RAN==2)
''', tmp_path)
    assert (tmp_path / 'AppleBacon' / 'Logs' / 'AppleBacon.log').read_text() == 'ok'
    assert (tmp_path / 'AppleBacon' / 'Data').is_dir()


def test_with_bingus_loader_present_applebacon_still_uses_its_own_folders(tmp_path):
    run_lua(r'''
reset();CowboyBingusModLoader={api=1,version=17,log_directory='x'}
assert(run()=='bank_reference')
assert(started==1 and AppleBaconStandaloneLoader and AppleBaconStandaloneLoader.log_directory==TMP..'\\AppleBacon\\Logs')
''', tmp_path)


def test_missing_or_failing_applebacon_never_breaks_the_game_module(tmp_path):
    run_lua(r'''
reset();loaded.missing=true
assert(run()=='bank_reference' and started==0)
reset();loaded.fail=true
assert(run()=='bank_reference' and started==1,'a AppleBacon error stays inside the hook')
reset();AppleBacon={}
assert(run()=='bank_reference' and started==0,'already running: nothing to start')
''', tmp_path)


def test_the_build_embeds_the_pinned_original_bytecode():
    import hashlib, sys
    sys.path.insert(0, str(ROOT / 'tools'))
    import build
    source = build.hook_source()
    assert build.HOOK_MARKER not in source and source.count('\\27\\76\\74') == 1
    original = build.HOOK_ORIGINAL.read_bytes()
    assert hashlib.sha256(original).hexdigest() == build.HOOK_ORIGINAL_SHA256
