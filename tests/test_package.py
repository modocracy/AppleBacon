"""Verify the shipped archive, not just the loose source files."""
from pathlib import Path
import json
import io

from PIL import Image
import struct
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'vendor/BingusSharedLoader/scripts'))
from archive import resource_hash


def resources(package,folder):
    archive=package.read(folder+'/9ba626afa44a3aa3.patch_0')
    magic,types,count=struct.unpack_from('<III',archive)
    assert (magic,types)==(0xf0000011,1)
    found={}
    for index in range(count):
        entry=struct.unpack_from('<7Q6I',archive,104+80*index)
        assert entry[1]==0xa14e8dfa2cd117e2
        offset,length=entry[2],entry[7]
        assert struct.unpack_from('<II',archive,offset)==(length-8,2)
        found[entry[0]]=archive[offset+8:offset+length]
    return found


def resource(package,folder):
    found=resources(package,folder)
    assert len(found)==1
    return next(iter(found.items()))


def test_installable_package_and_luajit_discovery_entry():
    subprocess.run([sys.executable,'tools/build.py'],cwd=ROOT,check=True,capture_output=True,text=True)
    package=ROOT/'dist/AppleBacon-1.0.1.zip'
    first=package.read_bytes()
    settings=[('stats_follow_look','IndependentStats','LookStats'),
              ('helmet_transmog','HelmetOff','HelmetOn'),
              ('passive_preview_icons','PassiveIconsOff','PassiveIconsOn')]
    with zipfile.ZipFile(package) as z:
        folders=['Addon']+[folder for _,off,on in settings for folder in (off,on)]
        expected={'manifest.json','README.txt','README.md','README.ko.md','CREDITS.md','THIRD-PARTY-LICENSES.txt','applebacon-icon.png'}
        expected.update(folder+'/9ba626afa44a3aa3.patch_0'+suffix
                        for folder in folders for suffix in ['', '.stream', '.gpu_resources'])
        assert set(z.namelist())==expected
        readme=z.read('README.txt').decode('utf-8')
        assert readme.startswith('AppleBacon 1.0.1\n') and 'README.ko.md' in readme and 'CREDITS.md' in readme
        for guide, heading in [('README.md', '## Install'), ('README.ko.md', '## 설치')]:
            text = z.read(guide).decode('utf-8')
            assert heading in text and 'CREDITS.md' in text and '%LOCALAPPDATA%\\AppleBacon\\Data' in text
            assert '](sdk/' not in text  # Archive users have no SDK checkout.
        assert 'RatInPlat' in z.read('CREDITS.md').decode('utf-8')
        manifest=json.loads(z.read('manifest.json'))
        assert manifest['Name']=='AppleBacon 1.0.1' and manifest['IconPath']=='applebacon-icon.png'
        assert 'CREDITS.md' in manifest['Description']
        icon_bytes=z.read(manifest['IconPath'])
        assert len(icon_bytes)<=64*1024, 'Packaged thumbnail must not include full-resolution artwork'
        with Image.open(io.BytesIO(icon_bytes)) as icon:
            assert icon.format=='PNG' and icon.size==(256,256)
            icon.load()
        with Image.open(ROOT/'assets/applebacon-icon.png') as source_icon:
            assert source_icon.width>256 and source_icon.height>256, 'Keep the original artwork for future exports'
        assert manifest['Guid']=='d99cee1b-6d55-4b0e-8a5b-9f260f628746'
        groups=manifest['Options']
        assert [group['Name'] for group in groups]==['AppleBacon','Helmet and cape variants','Passive icons on armor cards']
        assert [group['Include'] for group in groups]==[['Addon'],[],[]]
        assert [[c['Include'] for c in group['SubOptions']] for group in groups]==[
            [['IndependentStats'],['LookStats']],[['HelmetOn'],['HelmetOff']],[['PassiveIconsOn'],['PassiveIconsOff']]]
        assert [c['Name'] for c in groups[0]['SubOptions']]==['Base stats: choose separately (default)','Base stats: follow the look']
        # The Addon archive carries AppleBacon and its startup hook, nothing else.
        sys.path.insert(0,str(ROOT/'tools'))
        import build
        addon=resources(z,'Addon')
        assert set(addon)=={resource_hash('mods/applebacon/core'),resource_hash(build.HOOK_NAME)}
        assert addon[resource_hash(build.HOOK_NAME)]==build.hook_source().encode()
        key=resource_hash('mods/applebacon/core');body=addon[key]
        assert body.startswith(b'-- HD2-Addon: mods/applebacon/core\n')
        assert body==(ROOT/'dist/applebacon.lua').read_bytes()
        # Development-only modules stay out of the release.
        for name in (b'PixelProbe',b'DebugBridge',b'IconProbe',b'SteamProbe'):
            assert b'local '+name+b' = (function()' not in body
        # Exercise the packaged lexical dependency: loose-file tests can hide
        # a bundle-order mistake by satisfying require() from the repository.
        prefix=body[:body.index(b'-- Bundled after State, Platform, Adapter and Panel by tools/build.py.')]
        dependency_probe=b'''local builtin=require
require=function(name)
 if name=='ffi'or name=='bit'or name=='jit'then return builtin(name)end
 error('unexpected external module: '..name)
end
'''+prefix+b'''\n
assert(State and EquippedState and ArmorySlot and UiWorkflow and AppearancePatch and ArmoryModelFix and AccessoryUi)
'''
        checked=subprocess.run(['luajit','-'],input=dependency_probe,capture_output=True)
        assert checked.returncode==0,checked.stderr.decode()
        parser=['luajit','-e','assert(loadstring(io.read("*a")))']
        assert subprocess.run(parser,input=body,capture_output=True).returncode==0
        assert subprocess.run(parser,input=b'local x = 5 // 2',capture_output=True).returncode!=0
        payloads={}
        keys={key}
        for name,off,on in settings:
            for enabled,folder in ((False,off),(True,on)):
                key,payload=resource(z,folder)
                assert key==resource_hash('mods/applebacon/options/'+name)
                assert key not in keys or folder==on
                if folder==off: keys.add(key)
                assert len(payload)>=1024
                assert payload.endswith(('return '+str(enabled).lower()+'\n').encode())
                assert not payload.startswith(b'-- HD2-Addon:')
                payloads[name,enabled]=payload.decode()
        # Execute the packaged settings through the same require path as main,
        # in all eight combinations. Missing settings retain runtime defaults.
        import itertools
        prefix=body.decode().split('-- Bundled after State, Platform, Adapter and Panel by tools/build.py.')[1].split('local UiLayout=')[0]
        for values in itertools.product((False,True),repeat=3):
            preload='\n'.join("package.preload['mods/applebacon/options/"+name+"']=function() "+payloads[name,value]+" end"
                              for (name,_,_),value in zip(settings,values))
            checks='\n'.join('assert('+variable+'=='+str(value).lower()+')' for variable,value in
                             zip(['STATS_FOLLOW_LOOK','HELMET_TRANSMOG','PASSIVE_PREVIEW_ICONS'],values))
            result=subprocess.run(['luajit','-'],input=preload+'\nApplication={can_get=function(_,name)return package.preload[name]~=nil end}\n'+prefix+'\n'+checks,text=True,capture_output=True)
            assert result.returncode==0,result.stderr
        defaults='assert(not STATS_FOLLOW_LOOK and HELMET_TRANSMOG and PASSIVE_PREVIEW_ICONS);assert((missing_calls or 0)==0)'
        for preload in ("missing_calls=0;Application={can_get=function()return false end};require=function()missing_calls=missing_calls+1;error('missing native require must not run')end", '', "package.preload['mods/applebacon/options/helmet_transmog']=function()error('unavailable')end",
                        "package.preload['mods/applebacon/options/helmet_transmog']=function()return {}end"):
            result=subprocess.run(['luajit','-'],input=preload+'\n'+prefix+'\n'+defaults,text=True,capture_output=True)
            assert result.returncode==0,result.stderr
    subprocess.run([sys.executable,'tools/build.py'],cwd=ROOT,check=True,capture_output=True,text=True)
    assert package.read_bytes()==first


def test_release_tag_must_match_runtime_and_checksum_identifies_exact_zip():
    package=ROOT/'dist/AppleBacon-1.0.1.zip'
    subprocess.run([sys.executable,'tools/build.py','--release-tag','v1.0.1'],cwd=ROOT,check=True,capture_output=True,text=True)
    before=package.read_bytes()
    import hashlib
    assert package.with_suffix('.zip.sha256').read_text()==f'{hashlib.sha256(before).hexdigest()}  {package.name}\n'
    rejected=subprocess.run([sys.executable,'tools/build.py','--release-tag','v99.0'],cwd=ROOT,capture_output=True,text=True)
    assert rejected.returncode!=0 and 'release tag must be' in rejected.stderr
    assert package.read_bytes()==before
