#!/usr/bin/env python3
"""Bundle the LuaJIT addon and produce a deterministic Arsenal import ZIP."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import io
import json
import re
import subprocess
import sys
import zipfile

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.search(r"local runtime = \{version='([0-9]+(?:\.[0-9]+)+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?)'", (ROOT/'src/main.lua').read_text()).group(1)
NAME = 'mods/applebacon/core'
# The one version number: set in src/main.lua, shown to players, written to logs.
APPLEBACON_VERSION = VERSION
GUID = 'd99cee1b-6d55-4b0e-8a5b-9f260f628746'
TITLE = f'AppleBacon {APPLEBACON_VERSION}'
DESCRIPTION = ('Build your own armor from what you own: one armor\'s look, another\'s base stats and a third one\'s passive. '
               'Select an armor, press +, then click Stats or Armor Passive in the details panel. '
               'Standalone - no loader needed. Credits: CREDITS.md.')

def package_icon():
    # Arsenal uses this artwork as a thumbnail. Keep the full-resolution source
    # out of the install archive and use a compact, standard palette PNG.
    with Image.open(ROOT/'assets/applebacon-icon.png') as source:
        icon = source.convert('RGB')
    icon.thumbnail((256, 256), Image.Resampling.LANCZOS)
    icon = icon.quantize(colors=256, method=Image.Quantize.MEDIANCUT)
    icon.info.clear()
    output = io.BytesIO()
    icon.save(output, format='PNG', optimize=True)
    return output.getvalue()


# AppleBacon starts itself: src/boot_hook.lua replaces this game module, runs the
# game's original bytecode for it and then requires AppleBacon (no loader needed).
HOOK_NAME='core/wwise/lua/wwise_bank_reference'
HOOK_ORIGINAL=ROOT/'vendor/game/wwise_bank_reference.luac'  # tools/extract_hook_original.py
HOOK_ORIGINAL_SHA256='399265e380867d702b15f68b9411af011cddeff601af2b6fa60622178f9941bb'  # Steam build 25480438
HOOK_MARKER='--[[APPLEBACON_ORIGINAL_BYTECODE]]nil'

def hook_source():
    """src/boot_hook.lua with the pinned original module bytecode embedded."""
    original=HOOK_ORIGINAL.read_bytes()
    if hashlib.sha256(original).hexdigest()!=HOOK_ORIGINAL_SHA256 or not original.startswith(b'\x1bLJ'):
        raise SystemExit(f'{HOOK_ORIGINAL} is not the pinned original {HOOK_NAME} bytecode')
    literal='"'+''.join('\\%d'%byte for byte in original)+'"'
    template=(ROOT/'src/boot_hook.lua').read_text(encoding='utf-8')
    if template.count(HOOK_MARKER)!=1:raise SystemExit('boot hook bytecode marker missing')
    return template.replace(HOOK_MARKER,literal)

# Development-only modules stay in the source for tests and the opt-in debug
# channel (debug.enabled marker), but are not shipped: without DebugBridge the
# debug command table in main.lua is never built, and the probes are inert.
DEV_ONLY = ('debug_bridge.lua', 'debug_controller.lua', 'debug_open_armory.lua', 'native_armor_probe.lua',
            'render_probe.lua', 'customization_raw_probe.lua', 'icon_probe.lua')

def bundle(stats_follow_look=False, passive_preview_icons=True, helmet_transmog=True):
    chunks = ['-- HD2-Addon: ' + NAME + '\n']
    for variable, filename in [('LogExport','log_export.lua'), ('Diagnostics','diagnostics.lua'), ('State','state.lua'), ('EquippedState','equipped_state.lua'), ('ControllerInput','controller_input.lua'), ('CreatorController','creator_controller.lua'), ('Platform','platform.lua'),
                               ('ArmorLayout','armor_layout.lua'),
                               ('HelmetLayout','helmet_layout.lua'),
                               ('AppleBaconOptionsMenu','applebacon_options_menu.lua'),
                               ('CompatSpec','compat_spec.lua'),
                               ('CatalogCompat','catalog_compat.lua'),
                               ('CatalogData','catalog_data.lua'),
                               ('CatalogLabels','catalog_labels.lua'),
                               ('Localization','localization.lua'),
                               ('HelmetCatalog','helmet_catalog.lua'),
                               ('CatalogProbe','catalog_probe.lua'),
                               ('NativeDisassembler','../vendor/LuaJIT-disassembler/dis_x86.lua'),
                               ('DebugArmory','debug_armory.lua'),  # x86 decoder used by native grid and stat resolution
                               ('ArmorStatSemantics','armor_stat_semantics.lua'),
                               ('ArmorStatResolver','armor_stat_resolver.lua'),
                               ('NativeGridModel','native_grid_model.lua'),
                               ('NativeGridFocus','native_grid_focus.lua'),
                               ('NativeGridProducers','native_grid_producers.lua'),
                               ('NativeGrid','native_grid.lua'),
                               ('NativeGridPresentation','native_grid_presentation.lua'),
                               ('ArmorySection','armory_section.lua'),
                               ('PlayerCustomizationProbe','player_customization_probe.lua'),
                               ('ArmorRefresh','armor_refresh.lua'),
                               ('ArmorRefreshDirect','armor_refresh_direct.lua'),
                               ('ArmorRefreshBridge','armor_refresh_bridge.lua'),
                               ('VariantSession','variant_session.lua'),
                               ('DiverKitCompat','diverkit_compat.lua'),
                               ('DiverKitBridge','diverkit_bridge.lua'),
                               ('VariantLayout','variant_layout.lua'),
                               ('VariantWizard','variant_wizard.lua'),
                               ('VariantCards','variant_cards.lua'),
                               ('ArmoryModelFix','armory_model_fix.lua'),
                               ('ArmorySlot','armory_slot.lua'),
                               ('ArmorBaseStats','armor_base_stats.lua'),
                               ('PassiveIconGeometry','passive_icon_geometry.lua'),
                               ('PassiveIconGeometryHD','passive_icon_geometry_hd.lua'),
                               ('PassiveIconDraw','passive_icon_draw.lua'),
                               ('UiLayout','ui_layout.lua'),
                               ('WizardPanel','wizard_panel.lua'),
                               ('UiWorkflow','ui_workflow.lua'),
                               ('AppearancePatch','armor_composition.lua'),
                               ('RuntimeWriter','runtime_writer.lua'),
                               ('Adapter','runtime_adapter.lua'), ('Panel','panel.lua'), ('AccessoryUi','accessory_ui.lua')]:
        code = (ROOT/'src'/filename).read_text()
        chunks.append('local '+variable+' = (function()\n'+code+'\nend)()\n')
    chunks.append((ROOT/'src/main.lua').read_text())
    source=''.join(chunks)
    if stats_follow_look:
        source=source.replace('local STATS_FOLLOW_LOOK = false', 'local STATS_FOLLOW_LOOK = true', 1)
    if not passive_preview_icons:
        source=source.replace('local PASSIVE_PREVIEW_ICONS = true', 'local PASSIVE_PREVIEW_ICONS = false', 1)
    if not helmet_transmog:
        source=source.replace('local HELMET_TRANSMOG = true', 'local HELMET_TRANSMOG = false', 1)
    build_id=hashlib.sha256(source.encode()).hexdigest()[:16]
    return source.replace("build='source'", "build='"+build_id+"'", 1)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release-tag', help='Require a release tag matching APPLEBACON_VERSION (for example v1.0.0).')
    args = parser.parse_args()
    if args.release_tag is not None and args.release_tag not in (APPLEBACON_VERSION, 'v'+APPLEBACON_VERSION):
        parser.error(f'release tag must be {APPLEBACON_VERSION} or v{APPLEBACON_VERSION}; got {args.release_tag!r}')
    out = ROOT/'dist'
    out.mkdir(exist_ok=True)
    source = bundle()
    lua = out/'applebacon.lua'
    lua.write_text(source, encoding='utf-8', newline='')
    subprocess.run(['luajit','-e','assert(loadstring(io.read("*a")))'],
                   input=source,text=True,check=True)
    sys.path.insert(0,str(ROOT/'vendor/BingusSharedLoader/scripts'))
    from build_addon import build_addon
    package = out/f'AppleBacon-{APPLEBACON_VERSION}.zip'
    build_addon(NAME,source.encode(),GUID,package,TITLE)
    with zipfile.ZipFile(package) as z:
        files={n:z.read(n) for n in z.namelist()}
    # The main addon is always included by its group. Each independent setting
    # has its own boolean resource; none replaces another setting or the addon.
    from archive import ARCHIVE, make_archive, resource_hash
    from build_addon import entry_source
    import struct
    # The Addon archive also carries the startup hook, so AppleBacon needs no loader.
    hook=hook_source()
    subprocess.run(['luajit','-e','assert(loadstring(io.read("*a")))'],input=hook,text=True,check=True)
    addon=entry_source(NAME,source.encode())
    files['Addon/'+ARCHIVE]=make_archive({
        resource_hash(NAME):struct.pack('<II',len(addon),2)+addon,
        resource_hash(HOOK_NAME):struct.pack('<II',len(hook.encode()),2)+hook.encode()})
    for folder,setting,value in [('IndependentStats','stats_follow_look',False),('LookStats','stats_follow_look',True),
                                 ('HelmetOff','helmet_transmog',False),('HelmetOn','helmet_transmog',True),
                                 ('PassiveIconsOn','passive_preview_icons',True),('PassiveIconsOff','passive_preview_icons',False)]:
        # Very short Lua payloads crash the native resource loader before any
        # addon executes (reproduced with 12/13-byte option scripts). Keep each
        # independent setting above the live-tested 1 KiB source size.
        payload=(b'-- AppleBacon configuration resource.\n'+b'-- '+b' '*1024+b'\n'
                 +('return '+str(value).lower()+'\n').encode())
        resource=struct.pack('<II',len(payload),2)+payload
        files[folder+'/'+ARCHIVE]=make_archive({resource_hash('mods/applebacon/options/'+setting):resource})
        for suffix in ('.stream','.gpu_resources'):
            files[folder+'/'+ARCHIVE+suffix]=b''
    manifest=json.loads(files['manifest.json'])
    manifest['Name']=TITLE
    manifest['IconPath']='applebacon-icon.png'
    files['applebacon-icon.png']=package_icon()
    manifest['Description']=DESCRIPTION
    def choice(name,folder,description):
        return {'Name':name,'Description':description,'Include':[folder],'Image':'applebacon-icon.png'}
    # Arsenal selects each enabled group's first choice on import. Defaults are
    # also correct when its global enable-all preference enables every group.
    manifest['Options']=[
        {'Name':'AppleBacon','Description':'The mod itself. Pick how base stats are chosen.',
         'Include':['Addon'],'Image':'applebacon-icon.png','SubOptions':[
             choice('Base stats: choose separately (default)','IndependentStats','Look, base stats and passive are each chosen.'),
             choice('Base stats: follow the look','LookStats','Only look and passive are chosen; the look brings its own base stats.')]},
        {'Name':'Helmet and cape variants','Description':'Helmets and capes use the same creator when another mod gives them passives.',
         'Include':[],'Image':'applebacon-icon.png','SubOptions':[
             choice('On (default)','HelmetOn','Helmets and capes with passives can be combined too.'),
             choice('Off','HelmetOff','Body armor only.')]},
        {'Name':'Passive icons on armor cards','Description':'A small passive badge on each armor card in the Armory.',
         'Include':[],'Image':'applebacon-icon.png','SubOptions':[
             choice('On (default)','PassiveIconsOn','Show the badges.'),
             choice('Off','PassiveIconsOff','Hide the badges. The picker and details panel still show icons.')]},
    ]
    files['manifest.json']=(json.dumps(manifest,indent=2)+'\n').encode()
    files['THIRD-PARTY-LICENSES.txt']=(ROOT/'vendor/LuaJIT-disassembler/COPYRIGHT').read_bytes()
    for name in ('README.md','README.ko.md','CREDITS.md'):
        files[name]=(ROOT/name).read_bytes()
    files['README.txt'] = (
        f'{TITLE}\n'
        'Build your own Helldivers 2 armor from a look, base stats and a passive you own.\n'
        'Credits: CREDITS.md.\n\n'
        'Install: close the game, import this ZIP in Arsenal, enable it, Purge / Deploy.\n'
        'No loader needed. Bingus Shared Loader may stay installed for other mods.\n\n'
        'Use: Armory > Armor, select an armor, press +, then click Stats or Armor Passive.\n'
        'Details: README.md (English), README.ko.md (Korean).\n\n'
        '설치: 게임을 끄고 Arsenal에서 이 ZIP을 가져와 켠 뒤 Purge / Deploy 하세요. 로더는 필요 없습니다.\n'
        '사용: 무기고 > 방어구에서 갑옷을 고르고 + 를 누른 뒤 통계·방어구 패시브 상자를 눌러 바꾸세요.\n'
        '자세한 내용은 README.ko.md를 보세요.\n'
    ).encode('utf-8')
    with zipfile.ZipFile(package,'w',compression=zipfile.ZIP_DEFLATED) as z:
        for name,data in sorted(files.items()):
            info=zipfile.ZipInfo(name,(1980,1,1,0,0,0))
            info.compress_type=zipfile.ZIP_DEFLATED
            info.external_attr=0o100644 << 16
            z.writestr(info,data)
    print(package)
    digest = hashlib.sha256(package.read_bytes()).hexdigest()
    package.with_suffix('.zip.sha256').write_text(f'{digest}  {package.name}\n')
    print('SHA256', digest)

if __name__=='__main__':
    main()
