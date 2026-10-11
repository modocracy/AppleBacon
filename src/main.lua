-- Bundled after State, Platform, Adapter and Panel by tools/build.py.
local MODULE = 'mods/applebacon/core'
local STATS_FOLLOW_LOOK = false -- Arsenal build option; default keeps independent stats.
local HELMET_TRANSMOG = true -- Shared helmet/cape creator, gated by observed gameplay data.
local PASSIVE_PREVIEW_ICONS = true -- Armor thumbnail badges only; default on.
-- Independent Arsenal settings are ordinary Lua resources, not loader addons.
-- Missing resources preserve defaults (including a disabled option group).
do
    local function setting(name,fallback)
        local resource='mods/applebacon/options/'..name
        local application=rawget(_G,'Application')or (rawget(_G,'stingray')or {}).Application
        if not application or type(application.can_get)~='function'then return fallback end
        local checked,available=pcall(application.can_get,'lua',resource)
        if not checked or available~=true then return fallback end
        local ok,value=pcall(require,resource)
        if ok and type(value)=='boolean' then return value end
        return fallback
    end
    STATS_FOLLOW_LOOK=setting('stats_follow_look',STATS_FOLLOW_LOOK)
    HELMET_TRANSMOG=setting('helmet_transmog',HELMET_TRANSMOG)
    PASSIVE_PREVIEW_ICONS=setting('passive_preview_icons',PASSIVE_PREVIEW_ICONS)
end
local UiLayout=UiLayout or require('src.ui_layout')
local EquippedState=EquippedState or require('src.equipped_state')
if rawget(_G, 'AppleBacon') then return rawget(_G, 'AppleBacon') end
local runtime = {version='1.0.0',build='source', status='starting', armor_writes=false,native_hitbox_source='root',automatic_custom_ui=true,profile={frames=0,tick=0,guard=0,draw=0}}
rawset(_G, 'AppleBacon', runtime)
-- Phase 0 probe support. Published as globals, not referenced as locals: the debug
-- command table is already at LuaJIT's 60-upvalue ceiling for a single function.
if CatalogLabels then rawset(_G,'APPLEBACON_CATALOG_LABELS',CatalogLabels) end
if AppleBaconOptionsMenu then rawset(_G,'APPLEBACON_OPTIONS_MENU',AppleBaconOptionsMenu) end
rawset(_G,'APPLEBACON_ARMORY_SLOT',ArmorySlot or require('src.armory_slot'))
if ArmoryModelFix then rawset(_G,'APPLEBACON_MODEL_FIX_MODULE',ArmoryModelFix) end
-- The modules an Armory tab is made of, looked up when the tab uses them. One
-- table, so no function takes an upvalue per module for them.
local ArmoryLib=setmetatable({},{__index=function(_,name)
    if name=='ArmorySection' then return ArmorySection or require('src.armory_section') end
    if name=='VariantCards' then return VariantCards or require('src.variant_cards') end
    if name=='UiLayout' then return UiLayout end
    if name=='EquippedState' then return EquippedState end
    if name=='State' then return State end
    if name=='NativeGridPresentation' then return NativeGridPresentation end
    if name=='VariantSession' then return VariantSession end
    if name=='ArmorRefresh' then return ArmorRefresh end
    if name=='ArmorRefreshBridge' then return ArmorRefreshBridge end
    if name=='VariantWizard' then return VariantWizard end
    if name=='UiWorkflow' then return UiWorkflow end
end})
-- AppleBacon's own startup hook (src/boot_hook.lua) supplies its folders and API
-- marker; Bingus Shared Loader is only a fallback when the hook did not run.
local loader = rawget(_G, 'AppleBaconStandaloneLoader') or rawget(_G, 'CowboyBingusModLoader')
local log
local function report(key, value)
    if log then log:report(key,value)end
end
local ok, failure = pcall(function()
    log=(Diagnostics or require('src.diagnostics')).open(loader)
    runtime.export_logs=function()
        return log:export('Version: '..runtime.version..'\nBuild: '..runtime.build..'\nStatus: '..runtime.status..'\n')
    end
    report('creator.stats_follow_look',STATS_FOLLOW_LOOK)
    report('ui.passive_preview_icons',PASSIVE_PREVIEW_ICONS)
    report('helmet.transmog_enabled',HELMET_TRANSMOG)
    report('startup.begin',true);report('version',runtime.version);report('build',runtime.build)
    report('loader.present',type(loader)=='table')
    report('loader.version',type(loader)=='table'and loader.version or 'unknown')
    report('loader.api',type(loader)=='table'and loader.api or 'unavailable')
    assert(type(loader)=='table' and tonumber(loader.api) and tonumber(loader.api)>=1,
        'Bingus Shared Loader API 1 or the AppleBacon startup hook is required')
    report('loader.compatible',true);report('armor_writes',false)
    if type(loader.modules)=='table'then
        local modules={};for name,value in pairs(loader.modules)do
            if #modules>=64 then break end
            modules[#modules+1]=tostring(name)..':'..tostring(value)
        end
        table.sort(modules);report('loader.modules_at_init',table.concat(modules,','))
    end
    report('runtime.luajit',jit and jit.version or 'unavailable')
    local engine=assert(rawget(_G,'stingray'),'Stingray UI unavailable')
    report('startup.engine',type(engine.Gui)=='table'and 'GUI available'or 'GUI unavailable')
    local fs=Platform.new(loader, engine)
    local debug_bridge=DebugBridge and DebugBridge.new(fs,engine,report)
    local surface=Panel.new(engine)
    local domain=State.new()
    -- Body armor's tab, with the record of the worn variant and the startup
    -- restore it keeps; made once everything its host reads exists.
    local armor_tab,equipped_state,startup
    local startup_guard
    local editor=State.editor_new()
    local catalog_result, catalog_adapter, catalog_probe, catalog_failed
    local catalog_resolved,catalog_resolver_frame=false,nil
    local catalog_requested=false
    local ownership_next,ownership_running=0,false
    local armory_probe,armory_probe_written
    local armor_probe,armor_probe_written
    local grid_ui={next_sample=0,thumbnail_verified=false,thumbnail_tested=false,helmet_transmog=HELMET_TRANSMOG}
    -- The Armory's tabs by category: body armor, then helmets and capes once
    -- their catalogs say they can be transmogged. One set of calls drives all.
    local tabs={}
    -- The Armory's large model, shown again when the game leaves it hidden.
    -- Published as a global and stepped from the update hook; globals only.
    do
        local fix,failures
        rawset(_G,'APPLEBACON_MODEL_FIX',function()
            local Fix=rawget(_G,'APPLEBACON_MODEL_FIX_MODULE')
            if fix==false or not Fix then return end
            if not fix then
                local made,value=pcall(Fix.new)
                if not made then fix=false;report('armory.model_fix_off',tostring(value));return end
                fix=value;failures=0
            end
            local ok,shown=pcall(fix.step,fix)
            if not ok then
                failures=failures+1
                if failures>=3 then fix=false;report('armory.model_fix_off',tostring(shown))end
            elseif shown then report('grid.model_shown','the picker left it hidden')end
        end)
    end
    local armory_open,armory_open_pending,armory_open_waiting,armory_open_deadline,armory_open_visible_since
    local patch,patch_plan,patch_key,patch_active,patch_note
    local view={suspended=true,open=false,tab='appearance',notice='Open the Armory to read your owned armor',saved=false}
    local panel_tabs={appearance=true,stats=true,passive=true,presets=true}
    local locked=false
    local token
    function grid_ui.init_helmets()
        if not(grid_ui.helmet_transmog and catalog_result)then return end
        for category,key in pairs({[1]='helmets',[2]='capes'})do
            local result=catalog_result[key]
            if result and result.capabilities.accessory_transmog_enabled and not tabs[category]then
                tabs[category]=(AccessoryUi or require('src.accessory_ui')).new{
                    data_bridge=catalog_adapter:data_bridge(),startup_guard=function()return startup_guard and startup_guard()end,
                    armory_open=function()return grid_ui.screen_active==true end,
                    restore_pending=function()return grid_ui.restoring==true end,
                    catalog=function()return catalog_result and catalog_result[key]end,
                    grid=function()return grid_ui.bridge end,
                    screen=function()return grid_ui.screen_kind end,
                    token=function()return token end,
                    category=category,state=State,fs=fs,panel=WizardPanel.new(engine),engine=engine,report=report,
                    passive_preview_icons=PASSIVE_PREVIEW_ICONS,
                    hitbox=function()return runtime.native_hitbox_source end,
                    automatic=function()return runtime.automatic_custom_ui end,
                    player=PlayerCustomizationProbe.new(catalog_adapter:data_bridge(),CatalogData,{helmet_transmog=true,report=report}),
                    compatible=AppearancePatch.compatible,
                    patch=function(result)return AppearancePatch.new(RuntimeWriter.new(catalog_adapter:data_bridge(),result))end}
            end
        end
    end
    local function status(message)
        runtime.status=message
        report('status',message)
        local wrote, why=fs.write_atomic('STATUS.txt',message..'\nVersion: '..runtime.version..
            '\nDiverKit: '..(runtime.diverkit_notice or 'No compatibility warning')..'\nVariant transaction: '..(patch_active and 'active; native rendering requires observation' or 'inactive')..
            '\nStats: donor base weights; selected passive applied by the game\nOwnership source: '..(catalog_result and 'native progression observed' or 'waiting for native catalog')..'\n')
        if not wrote then report('status.write_error',why) end
    end
    local function decode(bytes)
        local tab, payload=bytes:match('^AB_UI\t1\n([a-z]+)\n(.*)$')
        if not tab or not panel_tabs[tab] then return nil,'Unsupported or corrupt saved state' end
        local restored,why=State.decode(payload)
        if not restored then return nil,why end
        return {tab=tab,domain=restored}
    end
    -- The saved variants' file.
    local state_file=State.writer(fs,'applebacon.state')
    local function restore()
        local bytes,why=fs.read('applebacon.state')
        if not bytes then
            report('state.load',why or 'unavailable')
            if why~='missing' then locked=true; view.notice='State unreadable - saving is disabled'; report('state.read_error',why) end
            return
        end
        local restored,reason=decode(bytes)
        if not restored then
            locked=true;view.notice='State needs recovery - saving is disabled';report('state.decode_error',reason)
            return
        end
        domain=restored.domain;view.tab=restored.tab;view.saved=true;locked=false
        state_file.loaded(bytes,domain.decoded_version)
        local count=0;for _ in pairs(domain.presets)do count=count+1 end
        report('state.loaded','schema='..domain.decoded_version..':current='..State.SCHEMA_VERSION..':variants='..count)
        editor=State.editor_new()
        if catalog_result then State.reconcile_owned(domain,catalog_result.catalog,catalog_result.owned) end
        view.notice='Saved state restored';report('state.restored',true)
    end
    restore()
    local function save(candidate)
        if locked then view.notice='Preserved unreadable state - saving disabled';return end
        local encoded,payload,why=pcall(State.encode,candidate or domain)
        if not encoded or not payload then view.notice='State validation failed'; report('state.encode_error',why or payload);return end
        local bytes='AB_UI\t1\n'..view.tab..'\n'..payload
        local wrote,reason=state_file.write(bytes)
        view.saved=wrote==true
        if wrote and candidate then domain=candidate;State.editor_saved(editor) end
        view.notice=wrote and (candidate and 'Variant saved in My variants' or 'State saved') or 'Save failed - previous state retained'
        report('state.saved',wrote or reason)
        return wrote==true
    end
    local adapter, stopped, frame, retries = nil,false,0,0
    local started, next_attempt = fs.now(),0
    local previous_down, armed
    local function reset()
        previous_down,armed=nil,nil
    end
    local function update_catalog(resolver_only)
        if not CatalogProbe or catalog_result or catalog_failed then return end
        if not catalog_adapter then
            catalog_adapter=Adapter.new(engine,function(k,v)report('catalog_resolver.'..k,v)end,nil,CatalogCompat,'catalog')
        end
        if not catalog_resolved then
            if catalog_resolver_frame==frame then return end
            catalog_resolver_frame=frame
            catalog_resolved=catalog_adapter:step()=='ready'
            if not catalog_resolved then return end
        end
        -- Signature discovery reads only the game image. Warm it while the
        -- player is elsewhere; live catalog/ownership still requires entry
        -- or the explicit read-only debug request.
        if resolver_only and not((startup.record or startup.accessories)and startup_guard and startup_guard())then return end
        if not catalog_probe then
            local bridge=catalog_adapter:data_bridge()
            if Localization then
                local reason;bridge.localize,reason=Localization.bind(bridge)
                if reason then report('localization.unavailable',reason) end
            end
            if CatalogLabels then
                local native_localize=bridge.localize
                bridge.localize=function(key)
                    return (native_localize and native_localize(key))or CatalogLabels.strings[key]
                end
            end
            catalog_probe=CatalogProbe.new(bridge,CatalogData,report)
        end
        local phase,result=catalog_probe:step()
        if phase=='failed' then
            catalog_failed=result;catalog_requested=false;view.notice='Armor catalog unavailable - saved variants retained';report('catalog.failure',result)
        elseif phase=='ready' then
            catalog_result=result
            if CatalogLabels and CatalogData then
                local names={appearance_id={},passive_variant_id={}}
                for _,kit in pairs(CatalogData.kits or {})do
                    if kit.category==0 then
                        names.appearance_id[kit.id]=CatalogLabels.strings[kit.name_cased]
                        local passive=CatalogData.passives[kit.passive_enum]
                        if passive then names.passive_variant_id[passive.variant_id]=CatalogLabels.strings[passive.name_loc]end
                    end
                end
                result.context.variant_labels=names
            end

            result.context.options_revision=0
            result.context.passive_preview_icons=PASSIVE_PREVIEW_ICONS
            ownership_next=fs.now()+2000;ownership_running=false;grid_ui.ownership_changed=false
            catalog_requested=false
            State.reconcile_owned(domain,result.catalog,result.owned)
            local reserve=0;for _ in pairs(result.catalog)do reserve=reserve+1 end
            result.context.variant_capacity=(VariantCards or require('src.variant_cards')).capacity(reserve,true)
            local rows={'AB_CATALOG 1','source_commit '..result.source_commit,
                'pe_timestamp '..tostring(catalog_adapter.pe_timestamp),
                'kits '..result.counts.kits,'owned_armors '..result.counts.owned_armors}
            local ids={};for id in pairs(result.catalog)do ids[#ids+1]=id end;table.sort(ids)
            for _,id in ipairs(ids)do
                local v=result.catalog[id]
                local function label(field,value)return (((result.context.labels[field]or{})[value]or value):gsub('[\t\r\n]',' '))end
                rows[#rows+1]=table.concat({'armor',id,result.owned[id] and 'owned' or 'unowned',v.stats_id,v.passive_variant_id,label('appearance_id',id),label('passive_variant_id',v.passive_variant_id)},'\t')
            end
            report('catalog.health','kits='..tostring(result.counts.kits)..',owned_armors='..tostring(result.counts.owned_armors)..',capacity='..tostring(result.context.variant_capacity))
            fs.write_atomic('catalog-observed.txt',table.concat(rows,'\n')..'\n')
            view.notice=tostring(result.counts.owned_armors)..' owned armors ready - create a variant'
            status('CATALOG READY - native armor and ownership verified')
        end
    end
    local stat_ui={}
    local function update_ownership(now)
        if not(catalog_result and type(catalog_result.refresh_ownership)=='function')
            or grid_ui.session and type(grid_ui.session.busy)=='function'and grid_ui.session:busy() then return end
        if not ownership_running and now<ownership_next then return end
        local called,phase,value=pcall(catalog_result.refresh_ownership)
        ownership_running=called and phase=='resolving'
        if ownership_running then return end
        ownership_next=now+2000
        if called and phase=='ready' then
            if value then
                State.reconcile_owned(domain,catalog_result.catalog,catalog_result.owned)
                stat_ui.catalog=nil;stat_ui.next_sample=0;patch_key=nil;patch_plan=nil
                grid_ui.ownership_changed=true
                report('catalog.ownership_refreshed',catalog_result.counts.owned_armors)
            end
        else
            State.reconcile_owned(domain,domain.catalog,nil)
            stat_ui.catalog=nil;patch_key=nil;patch_plan=nil
            view.notice='Ownership could not be refreshed; waiting for fresh evidence.'
            report('catalog.ownership_wait',called and value or phase)
        end
    end
    local function update_base_stats(now)
        if not(catalog_result and ArmorStatResolver and ArmorBaseStats and PlayerCustomizationProbe)
            or domain.ownership_verified~=true
            or catalog_result.capabilities and catalog_result.capabilities.ownership_verified==false then return end
        if not stat_ui.resolver then stat_ui.resolver=ArmorStatResolver.new(catalog_adapter:data_bridge(),report)end
        local phase,evidence=stat_ui.resolver:step()
        if phase~='ready' then
            catalog_result.context.stats_status=phase=='failed'and 'unavailable'or 'loading'
            if phase=='failed'and not stat_ui.reported then stat_ui.reported=true;report('stats.unavailable',evidence)end
            return
        end
        if now<(stat_ui.next_sample or 0)then return end
        stat_ui.next_sample=now+1000
        stat_ui.player=stat_ui.player or PlayerCustomizationProbe.new(catalog_adapter:data_bridge(),CatalogData,{helmet_transmog=HELMET_TRANSMOG,report=report})
        local player,why=stat_ui.player:sample_body_type()
        local body=player and player.body_type
        if body~=0 and body~=1 then
            catalog_result.context.stats_status='player_unavailable'
            if stat_ui.body_wait~=why then stat_ui.body_wait=why;report('stats.body_wait',why)end
            return
        end
        stat_ui.body_wait=nil
        catalog_result.context.stats_status='ready'
        if stat_ui.body==body and stat_ui.catalog==catalog_result then return end
        assert(evidence.verify(),'Native stat formula changed')
        local groups,reason=ArmorBaseStats.choices(catalog_result,body,evidence.contract);assert(groups,reason)
        for _,group in ipairs(groups)do
            for _,id in ipairs(group.stats_ids)do
                local profile=catalog_result.context.stats_profiles[id]or {}
                profile.base_only=true;profile.base_values_verified=group.verified==true;profile.base_values=group.base_values
                catalog_result.context.stats_profiles[id]=profile
            end
        end
        catalog_result.context.options_revision=(catalog_result.context.options_revision or 0)+1
        stat_ui.body=body;stat_ui.catalog=catalog_result
        report('stats.base_choices',#groups)
    end
    local function refresh_plan()
        if not AppearancePatch or not RuntimeWriter or not catalog_result or patch_active
            or grid_ui.session and grid_ui.session:is_active()then return end
        local request=editor.draft
        local key=request and table.concat({request.appearance_id,request.stats_id,request.passive_variant_id},'|')
        if key==patch_key then return end
        patch_key,patch_plan=key,nil
        if not request then return end
        if not patch then patch=AppearancePatch.new(RuntimeWriter.new(catalog_adapter:data_bridge(),catalog_result))end
        patch_plan,patch_note=patch:plan(catalog_result,request)
        if patch_plan then patch_note='Apply variant, then equip the armor selected under Stats.'
        else report('variant.plan_rejected',patch_note);patch_note='This variant could not be prepared; see diagnostics.' end
    end
    local function queue_native_preview(target)
        if not (target and grid_ui.bridge and grid_ui.bridge.select_kit and catalog_result)then return false end
        local snapshot=grid_ui.bridge:snapshot(catalog_result)
        if not snapshot or not snapshot.identity_mapping_verified then return false end
        local first=target
        if snapshot.selected_kit_id==target then
            local choices={}
            for id,owned in pairs(catalog_result.owned)do if owned and id~=target then choices[#choices+1]=id end end
            table.sort(choices);first=choices[1]or target
        end
        grid_ui.preview={target=target,first=first,phase='queued',deadline=fs.now()+15000}
        return true
    end
    -- Body armor's tab. Its state is grid_ui itself: the debug commands,
    -- DiverKit and the profile reconcile read it.
    -- What a tab does is described once, in ArmorySlot; body armor adds only
    -- what no other tab has: the development preview's veto on a session and
    -- the view the profile reconcile reads the Armory through.
    armor_tab=rawget(_G,'APPLEBACON_ARMORY_SLOT').new{slot=rawget(_G,'APPLEBACON_ARMORY_SLOT').SLOTS[0],lib=ArmoryLib,state=grid_ui,
        fs=fs,engine=engine,report=report,stats_follow_look=STATS_FOLLOW_LOOK,
        catalog=function()return catalog_result end,
        grid=function()return grid_ui.bridge end,
        screen=function()return grid_ui.screen_kind end,
        token=function()return token end,
        panel=function()return WizardPanel.new(engine)end,
        hitbox=function()return runtime.native_hitbox_source end,
        domain=function()return domain end,
        adopt=function(candidate)domain=candidate end,
        locked=function()return locked end,
        write=function(encoded)return state_file.write('AB_UI\t1\n'..view.tab..'\n'..encoded)end,
        probe=function()
            return PlayerCustomizationProbe.new(catalog_adapter:data_bridge(),CatalogData,{helmet_transmog=HELMET_TRANSMOG,report=report})
        end,
        actor=function(probe)return probe:sample()end,
        data_bridge=function()return catalog_adapter:data_bridge()end,
        startup_guard=function()return startup_guard()end,
        native_patch=function()return AppearancePatch.new(RuntimeWriter.new(catalog_adapter:data_bridge(),catalog_result))end,
        compatible=function(request)
            if not(AppearancePatch and AppearancePatch.compatible)then return true end
            return AppearancePatch.compatible(catalog_result,request)
        end,
        before_preview=function(probe,request,label,widgets_only)
            report('preview.request',table.concat({tostring(grid_ui.screen_kind),tostring(label),tostring(request.appearance_id),tostring(request.stats_id),tostring(request.passive_variant_id),'widgets_only='..tostring(widgets_only)},'|'))
            local observed,why=probe:sample()
            report('preview.player',observed and PlayerCustomizationProbe.format(observed)or why)
        end,
        session_guard=function()
            assert(not patch_active,'Reset the development preview before selecting a saved variant')
        end,
        refresh_options=function(opts)
            if type(opts)=='table' and opts.reconcile then opts.view=rawget(_G,'APPLEBACON_SHOWN_CATALOG')end
        end,
        stepped=function(session)runtime.armor_writes=session:is_active()or patch_active==true end,
        timed=function(name,seconds)runtime.profile[name]=runtime.profile[name]+seconds end,
        automatic=function()return runtime.automatic_custom_ui end,
        passive_preview_icons=PASSIVE_PREVIEW_ICONS,
        armory_open=function()return grid_ui.screen_active==true end,
        restore_pending=function()return grid_ui.restoring==true end,
        -- The body restore may run before the Armory was ever opened: it
        -- fetches the catalog it needs.
        restore_ready=function()return catalog_resolved end,
        ensure_catalog=function()
            if catalog_result then return catalog_result end
            if catalog_failed then return nil,catalog_failed end
            update_catalog()
            return catalog_result
        end}
    tabs[0]=armor_tab
    equipped_state=armor_tab.equipped;startup=grid_ui.startup
    startup.accessories=fs.read('equipped-helmet.state')~=nil or fs.read('equipped-cape.state')~=nil
    report('restore.intent_present',startup.record~=nil)
    -- Profile reconcile trigger. Published as a global for the upvalue-ceiling
    -- reason: the frame loop calls it without capturing anything new. Once per
    -- Armory visit, in the armor category: when the Armory's committed profile
    -- disagrees with what the actor already wears (what every startup restore of
    -- a carrier leaves behind), re-commit the worn kit before any single-slot
    -- Apply -- ours or the game's -- can re-dress the actor with the stale
    -- fields. This is the operator's own Armory apply of the worn kit, done for
    -- them, because the divergence is exactly what refused their apply.
    rawset(_G,'APPLEBACON_PROFILE_RECONCILE',function(now,visit)
        if visit==nil or grid_ui.reconcile_visit==visit then return end
        if now<(grid_ui.reconcile_next or 0)then return end
        grid_ui.reconcile_next=now+500
        if not(startup.finished and not startup.active and not grid_ui.accessory_restoring and not patch_active)then return end
        -- Any tab: the committed profile is one buffer whatever category is
        -- showing, and the Armory may open straight on helmets or capes.
        local observed=grid_ui.snapshot
        if not(observed and observed.kind==4 and observed.native_view_mode==0)then return end
        local read=rawget(_G,'APPLEBACON_NATIVE_SELECTION');local readable,native=pcall(read)
        if not readable or type(native)~='table'or not(native.profile_armor_id and native.profile_helmet_id and native.profile_cape_id)then return end
        local profile={armor_id=native.profile_armor_id,helmet_id=native.profile_helmet_id,cape_id=native.profile_cape_id}
        -- One actor reading, kept for the next check.
        local probe=rawget(_G,'APPLEBACON_BODY_PROBE')
        if not probe then
            if not(catalog_adapter and catalog_adapter.phase=='ready')then return end
            probe=PlayerCustomizationProbe.new(catalog_adapter:data_bridge(),CatalogData,{helmet_transmog=HELMET_TRANSMOG,report=report})
            rawset(_G,'APPLEBACON_BODY_PROBE',probe)
        end
        local actor=probe:sample();local worn=actor and actor.request
        if not worn or actor.settled==false then return end -- unreadable or streaming: read again later
        if not(worn.armor_id~=profile.armor_id or worn.helmet_id~=profile.helmet_id or worn.cape_id~=profile.cape_id)then
            grid_ui.reconcile_visit=visit;return
        end
        local session=grid_ui.session
        if not session then
            local made;made,session=pcall(armor_tab.ensure_session,armor_tab)
            if not made then grid_ui.reconcile_visit=visit;report('variant.reconcile_refused',session);return end
        end
        if session:busy()then return end
        local started,why=session:reconcile(profile,now)
        grid_ui.reconcile_visit=visit
        if started==nil then report('variant.reconcile_refused',why)end
    end)
    grid_ui.diverkit=(DiverKitCompat or require('src.diverkit_compat')).new{
        report=report,peer=runtime,
        notice=function(message)
            runtime.diverkit_notice=message
            if message then view.notice=message;status(message)
            else status('DiverKit compatibility rechecked')end
        end,
        active=function()return startup.active==true or grid_ui.session and grid_ui.session:is_active()or false end,
        capture=function(armor)
            if startup.active then return nil,'Startup restoration is pending'end
            if not grid_ui.session then return false end
            local id='armor:'..armor:sub(3):lower()
            local record,why=grid_ui.session:export_equipped(id)
            if not record then return record,why end
            if not EquippedState.matches(record,domain,id)then return nil,'Equipped variant was removed or changed'end
            return {version=1,label=record.label,appearance_id=record.request.appearance_id,
                stats_id=record.request.stats_id,passive_variant_id=record.request.passive_variant_id}
        end,
        prepare=function(record,armor,driver)
            if locked or patch_active or startup.active or grid_ui.session and grid_ui.session:busy()
                or grid_ui.flow and grid_ui.flow:is_open()then return nil,'Finish the current AppleBacon operation first'end
            if not catalog_result then update_catalog()end
            if not catalog_result then return nil,'Open Armor once to finish catalog verification, then retry'end
            local id='armor:'..armor:sub(3):lower()
            local request=record and {appearance_id=record.appearance_id,stats_id=record.stats_id,
                passive_variant_id=record.passive_variant_id}or catalog_result.catalog[id]
            if not request then return nil,'Original armor is unavailable'end
            if record and not EquippedState.matches({label=record.label,request=request,target_id=id},domain,id)then
                return nil,'Saved AppleBacon variant was removed or changed; save the DiverKit preset again'
            end
            local allowed,reason=AppearancePatch.compatible(catalog_result,request)
            if not allowed then return nil,reason end
            local donors={}
            for _,field in ipairs({'appearance_id','stats_id','passive_variant_id'})do
                local donor
                for kit_id,kit in pairs(catalog_result.catalog)do
                    if catalog_result.owned[kit_id]and kit[field]==request[field]then donor=kit_id;break end
                end
                if not donor then return nil,'A saved armor component is no longer owned'end
                donors[#donors+1]=donor
            end
            if catalog_result.verify_owned(donors)~=true then return nil,'Armor ownership changed'end
            local player=PlayerCustomizationProbe.new(catalog_adapter:data_bridge(),CatalogData,{helmet_transmog=HELMET_TRANSMOG,report=report})
            local bridge=(DiverKitBridge or require('src.diverkit_bridge')).new(driver,player,catalog_result)
            local initial,why=bridge.snapshot();if not initial then return nil,why end
            if initial.pending_nonarmor or initial.request_armor_id~=initial.cache_armor_id then
                return nil,'Wait for equipment to finish changing'
            end
            local session=armor_tab:ensure_session();local begun=false
            return {
                begin=function(now)
                    if begun then return nil,'Compatibility operation already started'end
                    local accepted,error=session:external_begin(record and record.label or nil,request,now,bridge,not record)
                    begun=accepted==true;return accepted,error
                end,
                poll=function(now)
                    if not begun then return 'failed','Compatibility operation did not start'end
                    session:step(now);runtime.armor_writes=session:is_active()
                    if session.external_status=='complete'and record then
                        local equipped,error=session:export_equipped(id)
                        if not equipped then return 'failed',error or 'Variant composition did not verify'end
                    end
                    return session.external_status,session.external_error
                end,
                cancel=function(reason)if begun then session:external_cancel(reason)end end,
            }
        end,
    }
    runtime.diverkit_compat=grid_ui.diverkit
    local function apply_variant()
        assert(patch and patch_plan and not patch_active,'No verified variant transaction is ready')
        local done,evidence=patch:apply(patch_plan);patch_plan=nil;patch_key=nil
        patch_active=patch:is_active()~=false
        runtime.armor_writes=patch_active
        assert(done,evidence)
        runtime.armor_writes=true
        report('preview.readback',evidence.status);report('preview.source',evidence.source_id);report('preview.target',evidence.target_id)
        report('variant.passive',editor.draft and editor.draft.passive_variant_id)
        patch_note='Equip another armor, exit, then equip the Stats armor.'
        if queue_native_preview(evidence.target_id)then patch_note='Selecting the variant in the native preview...'end
        view.notice=patch_note
        status('VARIANT PREPARED - equip another owned armor, exit Armory, reopen and equip the Stats armor')
        return 'Variant data readback verified; native preview still requires observation'
    end
    local function reset_variant()
        assert(patch,'No appearance preview exists')
        grid_ui.preview=nil
        local done,evidence=patch:reset();patch_active=patch:is_active()~=false;patch_key=nil
        assert(done,evidence)
        if evidence.target_id then queue_native_preview(evidence.target_id)end
        runtime.armor_writes=false;patch_note='Original armor restored - refresh the native preview'
        view.notice=patch_note;report('preview.reset',evidence.status)
        status('VARIANT RESET - original armor data restored')
        return patch_note
    end
    -- Test controls share the editor's domain/save/transaction paths. Requests
    -- contain identities and names only; no caller-supplied addresses or code.
    local function require_editor(mutable)
        assert(adapter and adapter.phase=='ready' and adapter:sample(),'Open the native Armory Equipment screen first')
        assert(catalog_result and domain.ownership_verified,'Current owned armor catalog is not ready')
        if mutable then assert(not patch_active,'Reset the current variant before editing') end
        return catalog_result.context or {}
    end
    local function variant_status()
        local lines={'AB_VARIANT_STATUS 1','version '..runtime.version,
            'catalog_ready '..tostring(catalog_result~=nil),
            'active '..tostring(patch_active==true),'label '..tostring(editor.label or ''),
            'dirty '..tostring(editor.dirty==true),'can_apply '..tostring(patch_plan~=nil and not patch_active)}
        lines[#lines+1]='native_thumbnail_binding '..tostring(grid_ui.thumbnail_verified)
        lines[#lines+1]='native_selected_kit '..tostring(grid_ui.snapshot and grid_ui.snapshot.selected_kit_id or '')
        for _,field in ipairs({'appearance_id','stats_id','passive_variant_id'})do
            lines[#lines+1]=field..' '..tostring(editor.draft and editor.draft[field] or '')
        end
        local labels={};for label in pairs(domain.presets)do labels[#labels+1]=label end;table.sort(labels)
        for _,label in ipairs(labels)do lines[#lines+1]='saved '..label end
        lines[#lines+1]='note '..tostring(patch_note or view.notice or ''):gsub('[\r\n]',' ')
        assert(fs.write_atomic('debug-variant-status.txt',table.concat(lines,'\n')..'\n'))
        return 'Current variant and saved-section state recorded'
    end
    local function draft_variant(args)
        require_editor(true)
        assert(not editor.dirty,'Save or discard the current draft first')
        local appearance,stats,passive,label=args:match('^(%S+) (%S+) (%S+)\n([^\r\n]+)$')
        assert(appearance and label,'Expected three stable identities followed by a variant name')
        local candidate=State.new{catalog=domain.catalog,owned=domain.owned}
        local selected,why=State.select(candidate,appearance,stats,passive);assert(selected,why)
        local draft=State.editor_new();draft.draft=candidate.requested
        local named,reason=State.editor_rename(domain,draft,label);assert(named,reason)
        editor=draft;view.open=true;patch_key=nil;refresh_plan()
        variant_status()
        return 'Owned independent choices loaded into the editable draft'
    end
    local function select_variant(args)
        require_editor(true)
        assert(not editor.dirty,'Save or discard the current draft first')
        local chosen=assert(domain.presets[args],'Saved variant was not found')
        editor=State.editor_new()
        editor.draft={appearance_id=chosen.appearance_id,stats_id=chosen.stats_id,passive_variant_id=chosen.passive_variant_id}
        editor.label,editor.source_label,editor.dirty=args,args,false
        view.open=true;patch_key=nil;refresh_plan();variant_status()
        return 'Saved variant selected'
    end
    local function ship_scene()
        local world=engine.Application.main_world()
        if not world then return false end
        local present=false
        for _,candidate in ipairs(engine.Application.worlds()or{})do if candidate==world then present=true end end
        if not present then return false end
        for _,hash in ipairs({'be0be6b1875a4a66','ce2566805c9e893a','3b9bcf29e38da0a6'})do
            local units=engine.World.units_by_resource(world,engine.IdString64.from_hex(hash))
            if type(units)~='table' or #units<1 or #units>16 then return false end
            for _,unit in ipairs(units)do if not engine.Unit.alive(unit)then return false end end
        end
        return true
    end
    startup_guard=function()
        local ok,ready=pcall(ship_scene);return ok and ready==true
    end
    -- QA lever: run the same no-Armory refresh the startup restore uses, so an actor
    -- rebuild can be forced without driving the Armory UI. Published as a global because
    -- the debug command table is already at LuaJIT's 60-upvalue ceiling.
    -- Two steps because the session previews before it commits: select queues the
    -- preview, apply commits once the preview has resolved. `restore` is not usable
    -- here -- it demands a fully idle session, which never holds once a variant is worn.
    rawset(_G,'APPLEBACON_FORCE_EQUIP',function(action,label)
        assert(catalog_result,'armor catalog is not ready')
        local session=armor_tab:ensure_session()
        if action=='select' then
            local request=assert(domain.presets and domain.presets[label],
                'no saved variant named '..tostring(label))
            local allowed,why=AppearancePatch.compatible(catalog_result,request)
            assert(allowed,why or 'variant is not compatible with the current catalog')
            local ok,reason=session:select(label,request,fs.now())
            assert(ok,reason or 'selection refused')
            return 'selected '..label..'; phase='..tostring(session.phase)
        end
        if action=='apply' then
            local ok,reason=session:apply(fs.now())
            assert(ok,reason or 'apply refused')
            return 'native refresh committed; phase='..tostring(session.phase)
        end
        if action=='phase' then
            return 'phase='..tostring(session.phase)..' busy='..tostring(session:busy())
        end
        error('expected: select <label> | apply | phase')
    end)
    -- QA lever: drive ArmorRefresh directly, with no Armory UI and no variant session.
    -- The session cannot commit headlessly at all, so equipment changes and forced actor
    -- rebuilds go through this instead. Published as a global for the same upvalue-ceiling
    -- reason as APPLEBACON_FORCE_EQUIP; the update hook steps it so a started refresh reaches
    -- `complete` rather than stalling after the first commit.
    local refresh_module,refresh_direct,refresh_player
    -- Headless refresh guards (options menu, temporary looks, forced redraws).
    -- Scene: the local actor is live -- a main world exists and the customization
    -- probe samples it -- which holds on the ship and in a mission alike. The
    -- login restore keeps ship_scene because it must not touch the actor before
    -- the ship has finished loading. Menu: only the Armory equipment screen holds
    -- the headless refresh; Options and the MODS tab do not. The Armory blocks
    -- for now because it has its own commit path and the profile reconcile on
    -- entry: a headless equip underneath an open grid would put the actor and
    -- the Armory's committed profile out of step again mid-visit, exactly the
    -- state the reconcile exists to repair. Lifting that needs the Armory path
    -- to observe headless changes, which it does not yet.
    local function live_actor_scene()
        local ok,world=pcall(engine.Application.main_world)
        if not(ok and world)then return false end
        return refresh_player~=nil and refresh_player:sample()~=nil
    end
    local function armory_inactive()return grid_ui.screen_active~=true end
    rawset(_G,'APPLEBACON_REFRESH_DIRECT',function(action,args,opts)
        if action=='busy'then return refresh_direct~=nil and refresh_direct:is_busy()end
        if action=='step' then
            if refresh_direct then refresh_direct:step(fs.now())end
            return
        end
        assert(catalog_result and catalog_adapter and catalog_adapter.phase=='ready','armor catalog is not ready')
        refresh_player=refresh_player or PlayerCustomizationProbe.new(catalog_adapter:data_bridge(),CatalogData,
            {helmet_transmog=HELMET_TRANSMOG,report=report})
        if not refresh_direct then
            refresh_module=ArmorRefreshDirect or require('src.armor_refresh_direct')
            refresh_direct=refresh_module.new{
                report=report,
                catalog=function()return catalog_result end,
                player=function()return refresh_player:sample()end,
                new_refresh=function()
                    if not(grid_ui.bridge and grid_ui.bridge.phase=='ready')then
                        return nil,'native equipment evidence is not ready'
                    end
                    -- The same no-Armory bridge the startup restoration uses, with
                    -- the headless guards above instead of the login ones.
                    local bridge,why=grid_ui.bridge:player_refresh_bridge(refresh_player,catalog_result,
                        catalog_adapter:data_bridge(),live_actor_scene,armory_inactive)
                    if not bridge then return nil,why end
                    return ArmorRefresh.new(bridge,report)
                end}
        end
        if action=='redraw' then
            local ok,why=refresh_direct:redraw(fs.now());assert(ok,why)
            return 'forced redraw started; '..refresh_module.format(refresh_direct:status())
        end
        if action=='equip' then
            local ok,why=refresh_direct:equip(args,fs.now(),opts);assert(ok,why)
            return 'headless equip started; '..refresh_module.format(refresh_direct:status())
        end
        if action=='status' then
            if args=='recover' then
                local ok,why=refresh_direct:recover(fs.now());assert(ok,why)
            end
            return refresh_module.format(refresh_direct:status())
        end
        error('expected: redraw | equip <8hex> | status [recover]')
    end)
    -- True while any native refresh is in flight. Never raises.
    rawset(_G,'APPLEBACON_NATIVE_BUSY',function()
        if grid_ui.session and grid_ui.session:busy()then return true end
        local direct=rawget(_G,'APPLEBACON_REFRESH_DIRECT')
        if direct then
            local ok,active=pcall(direct,'busy')
            if ok and type(active)=='boolean'then
                if active then return true end
            else
                local read,status=pcall(direct,'status')
                if read and tostring(status):match('outcome=pending')then return true end
            end
        end
        for category=1,2 do
            local tab=tabs[category]
            if tab then
                local ok,busy=pcall(tab.busy,tab)
                if ok and busy==true then return true end
            end
        end
        return false
    end)
    -- The catalog of the tab the Armory is showing: the grid view is verified
    -- only against it, while the committed profile is the same buffer on every
    -- tab. Nil on the armor tab, where the armor catalog is the view.
    rawset(_G,'APPLEBACON_SHOWN_CATALOG',function()
        local shown=grid_ui.snapshot and grid_ui.snapshot.native_category
        if shown==1 then return catalog_result and catalog_result.helmets end
        if shown==2 then return catalog_result and catalog_result.capes end
        return nil
    end)
    rawset(_G,'APPLEBACON_NATIVE_SELECTION',function()
        if not(grid_ui.bridge and grid_ui.bridge.phase=='ready' and catalog_result
            and type(grid_ui.bridge.commit_capabilities)=='function' and type(grid_ui.bridge.commit_snapshot)=='function')then return nil end
        local caps=grid_ui.bridge:commit_capabilities()
        if not(type(caps)=='table' and caps.commit_verified)then return nil end
        local native=grid_ui.bridge:commit_snapshot(catalog_result,{view=rawget(_G,'APPLEBACON_SHOWN_CATALOG')()})
        if type(native)~='table' then return nil end
        return {profile_armor_id=native.profile_armor_id,controller_armor_id=native.controller_armor_id,
            profile_helmet_id=native.profile_helmet_id,profile_cape_id=native.profile_cape_id}
    end)
    -- AppleBacon's MODS-tab row (Mod Options Menu). Published as a global and
    -- stepped from the update hook for the same upvalue-ceiling reason as the
    -- driver. The host mod may be absent and the row then idles silently.
    do
        local menu,module,next_sync
        rawset(_G,'APPLEBACON_OPTIONS_MENU_STEP',function(action)
            if not menu then
                module=rawget(_G,'APPLEBACON_OPTIONS_MENU') or require('src.applebacon_options_menu')
                menu=module.new{report=report}
            end
            if action=='status' then
                local text=module.format_status(menu:status())
                fs.write_atomic('debug-options-menu.txt',text)
                return (text:gsub('\n','; '))
            end
            -- The row mirrors state into a settings panel: a quarter second keeps it current.
            local now=fs.now()
            if not(next_sync and now<next_sync and now>=next_sync-250)then next_sync=now+250;menu:step()end
        end)
    end
    local function armory_open_status(kind,message)
        report('debug.open_armory.'..kind,message)
        fs.write_atomic('debug-armory-open.txt','AB_ARMORY_OPEN 1\n'..
            debug_bridge.session..'\n'..kind..'\n'..tostring(message):gsub('[\r\n]',' ')..'\n')
    end
    local function poll_debug()
    if debug_bridge and(not debug_bridge.due or debug_bridge:due())then debug_bridge:poll({
            sound_reference=function(args)
                assert(args=='on'or args=='off','Expected on or off')
                assert(not(grid_ui.session and grid_ui.session:busy()),'Wait for the armor change to finish')
                if args=='on'then
                    for category=0,2 do local tab=tabs[category];if tab then assert(tab:suspend())end end
                    surface:clear();reset();grid_ui.preview=nil
                    runtime.sound_reference=true
                else
                    runtime.sound_reference=false
                    for category=0,2 do local tab=tabs[category];if tab then tab:resume(fs.now())end end
                end
                return args=='on'and 'Native equipment reference: custom UI and capture disabled'
                    or 'Custom UI resumed'
            end,
            variant_status=variant_status,
            icon_probe=function(args)
                if grid_ui.icon_probe then grid_ui.icon_probe:clear();grid_ui.icon_probe=nil end
                if args=='off'then return 'Icon probe cleared'end
                assert(type(args)=='string'and args:match('^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$'),'Expected icon resource hash or off')
                local sample,why=adapter and adapter:sample();assert(sample,why or 'Open the Armory first')
                grid_ui.icon_probe=IconProbe.new(engine)
                local shown,reason=grid_ui.icon_probe:draw(sample,args)
                fs.write_atomic('debug-icon-probe.txt',grid_ui.icon_probe:report())
                assert(shown,reason)
                return 'Four owned-material icon tests drawn once; awaiting visual comparison'
            end,
            ui_status=function(args)
                local rows={'AB_UI_STATUS 1'}
                local category=grid_ui.shown_category
                local tab=category~=false and tabs[category or 0]
                local flow=tab and type(tab.flow)=='function'and tab:flow()
                    or (category==nil or category==0)and grid_ui.flow
                local catalog=tab and type(tab.catalog)=='function'and tab:catalog()or catalog_result
                rows[#rows+1]='slot='..tostring(category~=false and ({[0]='armor',[1]='helmet',[2]='cape'})[category or 0]or '')
                for key,value in pairs(runtime.profile)do rows[#rows+1]=key..'='..tostring(value)end
                if flow and flow.metrics then for key,value in pairs(flow:metrics())do rows[#rows+1]='panel.'..key..'='..tostring(value)end end
                if flow and flow.automation_snapshot then
                    local state=flow:automation_snapshot();local current=state.view
                    local w,h=engine.Gui.resolution();rows[#rows+1]='viewport='..w..','..h
                    rows[#rows+1]='step='..tostring(current.step);rows[#rows+1]='open='..tostring(current.open)
                    rows[#rows+1]='can_create='..tostring(current.can_create);rows[#rows+1]='label='..tostring(current.label or '')
                    rows[#rows+1]='stats_tuple_id='..tostring(current.stats_tuple_id or '')
                    rows[#rows+1]='controller_mode='..tostring(current.controller_mode==true)
                    rows[#rows+1]='controller_focus_type='..tostring(current.controller_focus and current.controller_focus.type or '')
                    rows[#rows+1]='controller_focus_id='..tostring(current.controller_focus and current.controller_focus.id or '')
                    local input=fs.sample_input()
                    rows[#rows+1]='controller_source='..tostring(input and input.controller_source or '')
                    for _,key in ipairs({'native_details','can_apply','apply_pending','variant_phase','apply_notice'})do
                        rows[#rows+1]=key..'='..tostring(current[key]or ''):gsub('[\r\n]',' ')
                    end
                    rows[#rows+1]='selected_variant='..tostring(current.selected_variant and current.selected_variant.label or '')
                    for key,value in pairs(current.selection or {})do rows[#rows+1]='selection.'..key..'='..tostring(value)end
                    local function region(action,r)
                        if not(action and r and type(r.x)=='number'and type(r.y)=='number')then return end
                        local value=tostring(action.id or action.label or ''):gsub('[\t\r\n]',' ')
                        rows[#rows+1]=table.concat({'region',action.type,value,r.x,r.y,r.w,r.h,action.target or '',action.delta or ''},'\t')
                    end
                    for _,r in ipairs(state.regions)do region(r.action,r)end
                    if current.open and current.step==1 and not current.controller_mode and grid_ui.bridge then
                        local native=grid_ui.bridge:snapshot(catalog);local picker=UiLayout.resolve(w,h).picker
                        for _,widget in ipairs(native and native.widgets or {})do
                            local r=widget.root_viewport_rect
                            if widget.bound_owned_kit_id and r and UiLayout.contains_rect(picker,r)then
                                region({type='select_look',id=widget.bound_owned_kit_id},r)
                            end
                        end
                    end
                end
                assert(fs.write_atomic('debug-ui-status.txt',table.concat(rows,'\n')..'\n'))
                if args=='reset'then runtime.profile={frames=0,tick=0,guard=0,draw=0}end
                return 'UI timing and retained drawing counters recorded'
            end,
            presentation_trial=function(args)
                require_editor(true)
                if args=='off'then assert(armor_tab:restore_list());return 'Native armor list restored'end
                assert(args=='on','Expected on or off')
                assert(armor_tab:build_list());armor_tab:ensure_flow()
                return 'Custom section constructed once; awaiting visual verification'
            end,
            open_creator=function()
                require_editor(true)
                local snapshot,why=grid_ui.bridge and grid_ui.bridge:snapshot(catalog_result)
                assert(snapshot and snapshot.kind==4 and snapshot.identity_mapping_verified,why or 'Open the native Armor list first')
                local done,reason=armor_tab:ensure_flow():action{type='open'};assert(done,reason)
                return 'Creation UI opened; equipped armor is unchanged'
            end,
        draft_variant=draft_variant,
        select_variant=select_variant,
        save_variant=function()
            local context=require_editor(true)
            local handled,notice,candidate=State.editor_action(domain,editor,'save_variant',view.tab,context)
            assert(handled and candidate,notice or 'No editable variant to save')
            assert(save(candidate),'Variant save failed; previous file retained')
            variant_status();return 'Variant saved through the editor persistence path'
        end,
        apply_variant=function()require_editor(false);refresh_plan();local result=apply_variant();variant_status();return result end,
        reset_variant=function()require_editor(false);local result=reset_variant();variant_status();return result end,
        probe_armor=function()
            assert(NativeArmorProbe and catalog_adapter and catalog_adapter.phase=='ready','Native armor evidence not ready')
            armor_probe=NativeArmorProbe.new(catalog_adapter:data_bridge(),report);armor_probe_written=false
            return 'Read-only native armor-consumer inspection scheduled'
        end,
        inspect_player_armor=function()
            assert(PlayerCustomizationProbe and catalog_adapter and catalog_adapter.phase=='ready','Native armor catalog is not ready')
            -- The committed profile and pending controller armor ids ride along
            -- so the native-selection check is observable from outside. Nothing
            -- exposed them before, and that blindness is why the lockout took so
            -- long to find. Unavailable outside the Armory, never a failure.
            local probe=PlayerCustomizationProbe.new(catalog_adapter:data_bridge(),CatalogData,
                {helmet_transmog=HELMET_TRANSMOG,report=report,
                 native_selection=rawget(_G,'APPLEBACON_NATIVE_SELECTION')})
            local result,reason=probe:sample();assert(result,reason)
            assert(fs.write_atomic('debug-player-armor.txt',PlayerCustomizationProbe.format(result)))
            return 'Current local-player armor request and cache recorded without addresses'
        end,
        inspect_customization_raw=function(args)
            assert(CustomizationRawProbe and catalog_adapter and catalog_adapter.phase=='ready','Native armor catalog is not ready')
            local probe=CustomizationRawProbe.new(catalog_adapter:data_bridge())
            local result,reason=probe:sample(args);assert(result,reason)
            assert(fs.write_atomic('debug-customization-raw.txt',CustomizationRawProbe.format(result)))
            return 'Customization manager region recorded relative to its base'
        end,
        force_equip=function(args)
            local run=assert(rawget(_G,'APPLEBACON_FORCE_EQUIP'),'force equip unavailable')
            assert(type(args)=='string' and args~='','Expected: select <label> | apply | phase')
            local action,label=args:match('^(%a+)%s+(.+)$')
            if not action then action=args:match('^(%a+)$') end
            assert(action,'Expected: select <label> | apply | phase')
            return run(action,label)
        end,
        force_redraw=function()
            local run=assert(rawget(_G,'APPLEBACON_REFRESH_DIRECT'),'direct armor refresh unavailable')
            return run('redraw')
        end,
        force_equip_kit=function(args)
            local run=assert(rawget(_G,'APPLEBACON_REFRESH_DIRECT'),'direct armor refresh unavailable')
            assert(type(args)=='string' and args:match('^%x%x%x%x%x%x%x%x$'),'Expected an 8-hex armor id')
            return run('equip',args)
        end,
        refresh_status=function(args)
            local run=assert(rawget(_G,'APPLEBACON_REFRESH_DIRECT'),'direct armor refresh unavailable')
            assert(args==nil or args=='' or args=='recover','Expected no argument or recover')
            return run('status',args~='' and args or nil)
        end,
        options_menu=function()
            local run=assert(rawget(_G,'APPLEBACON_OPTIONS_MENU_STEP'),'options menu unavailable')
            return run('status')
        end,
        layout_trial=function(args)
            require_editor(true)
            assert(args=='on' or args=='off','Expected on or off')
            catalog_result.render_trial=args=='on';patch=nil;patch_key=nil;refresh_plan()
            report('variant.unverified_render_trial',catalog_result.render_trial)
            return args=='on' and 'Explicit development trial enabled; rendering is not yet verified' or 'Development trial disabled'
        end,
            -- Read-only evidence for per-variant thumbnails: one dump of the
            -- thumbnail manager and the grid's image records, or `trace <ms>`
            -- to record the manager's state changes for that long.
            inspect_thumbnails=function(args)
                assert(NativeGrid and adapter and adapter.phase=='ready','Armory UI evidence not ready')
                grid_ui.bridge=grid_ui.bridge or NativeGrid.new(adapter:debug_bridge(),report)
                local span=tonumber(tostring(args):match('^trace%s+(%d+)$'))
                if span then
                    grid_ui.thumbnail_trace={deadline=fs.now()+math.min(span,120000),lines={'AB_THUMBNAIL_TRACE 1'},started=fs.now()}
                    return 'Thumbnail manager trace started'
                end
                local text,why=grid_ui.bridge:thumbnail_dump(catalog_result);assert(text,why)
                local labels={}
                for index,card in ipairs(grid_ui.custom_cards or{})do
                    labels[#labels+1]=string.format('custom %d kind=%s label=%s',index-1,tostring(card.kind),tostring(card.label))
                end
                assert(fs.write_atomic('debug-thumbnails.txt',text..table.concat(labels,'\n')..'\n'))
                return 'Read-only thumbnail manager observations recorded'
            end,
            inspect_armory_grid=function()
            assert(NativeGrid and adapter and adapter.phase=='ready','Armory UI evidence not ready')
            grid_ui.bridge=grid_ui.bridge or NativeGrid.new(adapter:debug_bridge(),report)
            local result,why=grid_ui.bridge:snapshot(catalog_result);assert(result,why)
            assert(fs.write_atomic('debug-armory-grid.txt',NativeGrid.format(result)))
                return 'Read-only native armor-grid observations recorded'
            end,
            inspect_armory_model=function()
                assert(NativeGridModel and NativeGrid and adapter and adapter.phase=='ready','Armory UI evidence not ready')
                grid_ui.bridge=grid_ui.bridge or NativeGrid.new(adapter:debug_bridge(),report)
                local result,reason=grid_ui.bridge:inspect_model(catalog_result);assert(result,reason)
                assert(fs.write_atomic('debug-armory-model.txt',NativeGridModel.format(result)))
                return 'Read-only native logical rows and group boundaries recorded'
            end,
            inspect_armory_producers=function()
                assert(grid_ui.bridge and grid_ui.bridge.phase=='ready','Native grid evidence is not ready')
                local started,reason=grid_ui.bridge:start_producer_scan();assert(started,reason)
                grid_ui.producer_written=false
                return 'Bounded read-only native list-builder inspection scheduled'
            end,
        inspect_render_types=function()
            assert(surface.material_diagnostic,'Render diagnostics unavailable')
            local values=surface:material_diagnostic()
            local lines={'AB_RENDER_TYPES 1'}
            for _,key in ipairs({'gui_present','material_type','ffi_available','void_pointer_cast'})do
                lines[#lines+1]=key..'='..tostring(values[key])
            end
            assert(fs.write_atomic('debug-render-types.txt',table.concat(lines,'\n')..'\n'))
            if RenderProbe and adapter and adapter.phase=='ready' and surface.material_handle then
                local result,reason=RenderProbe.inspect(engine,surface.material_handle,adapter:debug_bridge())
                fs.write_atomic('debug-material-box.txt',result and RenderProbe.format(result)or tostring(reason)..'\n')
            end
            return 'Existing GUI material types recorded without addresses'
        end,
        inspect_api=function()return debug_bridge:inspect()end,
        inspect_world=function()return debug_bridge:inspect_world()end,
        open_armory=function()
            assert(DebugOpenArmory and adapter and adapter.phase=='ready','Armory UI evidence not ready')
            assert(not armory_open_pending and not armory_open_waiting,'An Armory request is already in progress')
            if not armory_open then armory_open=DebugOpenArmory.new(adapter:debug_bridge(),ship_scene,report)end
            armory_open_pending=true
            armory_open_visible_since=nil
            armory_open_status('pending','Resolving and checking the native Armory transition')
            return 'Native Armory request queued; verify the resulting Equipment screen'
        end,
        read_catalog=function()
            local active=patch_active
            for category=0,2 do local tab=tabs[category];if tab and tab:is_active()then active=true end end
            if catalog_result and type(catalog_result.refresh_ownership)=='function' and active then
                ownership_next=0
                return 'Ownership-only refresh scheduled for the visible armor picker'
            end
            assert(not active,'Reset the preview before refreshing ownership')
            catalog_result,catalog_probe,catalog_failed=nil,nil,nil
            patch,patch_key,patch_plan=nil,nil,nil
            for category=0,2 do local tab=tabs[category];if tab then tab:reset_catalog()end end
            State.reconcile_owned(domain,domain.catalog,nil)
            catalog_requested=true
            return 'Read-only catalog observation scheduled'
        end,
        probe_armory=function()
            assert(DebugArmory and adapter and adapter.phase=='ready','Armory UI evidence not ready')
            armory_probe=DebugArmory.new(adapter:debug_bridge(),report);armory_probe_written=false
            return 'Read-only native menu inspection scheduled; no menu call made'
        end,
        inspect_controller=function()
            assert(DebugController and adapter and adapter.phase=='ready','Armory UI evidence not ready')
            local bridge=adapter:debug_bridge();bridge.decode=DebugArmory.decode
            local result,why=DebugController.inspect(bridge);assert(result,why)
            fs.write_atomic('debug-controller.txt',DebugController.format(result))
            return 'Read-only Armory controller metadata recorded'
        end,
        inspect_native_code=function(args)
            assert(DebugArmory and adapter and adapter.phase=='ready','Armory UI evidence not ready')
            local rva,count=args:match('^%s*(%x+)%s+(%d+)%s*$')
            assert(rva,'Expected hexadecimal relative location and decimal byte count')
            local text,why=DebugArmory.inspect_code(adapter:debug_bridge(),tonumber(rva,16),tonumber(count))
            assert(text,why);fs.write_atomic('debug-native-code.txt',text)
            return 'Bounded native instruction semantics recorded; no call made'
        end,
            inspect_native_switch=function(args)
            assert(DebugArmory and adapter and adapter.phase=='ready','Armory UI evidence not ready')
            local rva,count=args:match('^%s*(%x+)%s+(%d+)%s*$')
            assert(rva,'Expected hexadecimal switch table location and decimal count')
            local text,why=DebugArmory.inspect_switch(adapter:debug_bridge(),tonumber(rva,16),tonumber(count))
            assert(text,why);fs.write_atomic('debug-native-switch.txt',text)
                return 'Validated native switch selectors recorded; no call made'
            end,
            inspect_native_callee=function(args)
                assert(DebugArmory and adapter and adapter.phase=='ready','Native UI evidence not ready')
                local site,count=args:match('^%s*(%x+)%s+(%d+)%s*$');assert(site,'Expected callsite RVA and byte count')
                local result,reason=DebugArmory.inspect_callee(adapter:debug_bridge(),tonumber(site,16),tonumber(count))
                assert(result,reason);assert(fs.write_atomic('debug-native-callee.txt',result))
                return 'Verified direct-call target inspected read-only; no native call made'
            end,
    }) end
    end
    function grid_ui.can_idle()
        return adapter.phase=='ready' and catalog_resolved
            and grid_ui.bridge and grid_ui.bridge.phase=='ready'
            and not(catalog_probe and not catalog_result and not catalog_failed)
            and not(armory_probe and not armory_probe_written)
            and not(armor_probe and not armor_probe_written)
            and not(grid_ui.bridge.producer_status and grid_ui.bridge:producer_status()=='scanning')
    end
    local function tick()
        frame=frame+1
        local now=fs.now()
        local trace=grid_ui.thumbnail_trace
        if trace then
            local state=grid_ui.bridge and grid_ui.bridge:thumbnail_state()or'unavailable'
            if state~=trace.last then trace.last=state;trace.lines[#trace.lines+1]=(now-trace.started)..' '..state end
            if now>=trace.deadline or #trace.lines>4000 then
                grid_ui.thumbnail_trace=nil;fs.write_atomic('debug-thumbnail-trace.txt',table.concat(trace.lines,'\n')..'\n')
            end
        end
        if now<next_attempt then return end
        if now-started<15000 and not(startup.record or startup.accessories)then return end
        if grid_ui.capture_latched and grid_ui.bridge and grid_ui.bridge.phase=='ready' then
            -- Keep ownership through release, including leaving the menu or
            -- moving outside the overlay. This path never dereferences its grid.
            local held=fs.sample_input()
            local consumed,reason=grid_ui.bridge:consume_select()
            if held and not held.down then grid_ui.capture_latched=false end
            if not consumed then report('grid.consume_error',reason);surface:clear();reset();return end
        end
        local catalog_stepped=false
        poll_debug()
        -- No Armory-entry callback is exposed by loader API 1. Once discovery
        -- has finished, wake the inactive UI at most four times per second.
        -- Explicit debug work and in-flight native operations bypass this wait.
        if grid_ui.idle_until and now>=grid_ui.idle_until-250 and now<grid_ui.idle_until
            and not catalog_requested and not armory_open_pending and not armory_open_waiting
            and not startup.active and not grid_ui.accessory_restoring and not grid_ui.diverkit:busy() then return end
        grid_ui.idle_until=nil
        if runtime.sound_reference then return end
        if armory_open_pending then
            local passed,phase,reason=pcall(function()return armory_open:step()end)
            if not passed or phase=='failed' then
                armory_open_pending=false;armory_open_status('error',reason or phase)
            elseif phase=='ready' then
                armory_open_pending=false
                local called,done,why=pcall(function()return armory_open:open()end)
                if called and done then
                    armory_open_waiting=true;armory_open_deadline=now+45000
                    armory_open_status('pending','Native transition sent; awaiting the visible Armory Equipment view')
                else armory_open_status('error',why or done)end
            end
        end
        if armory_probe and not armory_probe_written then
            local phase=armory_probe:step()
            if phase~='resolving' then
                fs.write_atomic('debug-armory.txt',armory_probe:summary());armory_probe_written=true
            end
        end
        if armor_probe and not armor_probe_written then
            local phase=armor_probe:step()
            if phase~='resolving' then
                fs.write_atomic('debug-native-armor.txt',armor_probe:summary());armor_probe_written=true
            end
        end
        if catalog_requested then
            catalog_stepped=true
            local passed,why=pcall(update_catalog)
            if not passed then catalog_failed=tostring(why);catalog_requested=false;report('catalog.failure',why)end
        end
        if not adapter then
            adapter=Adapter.new(engine,report)
            status('RESOLVING - checking current game UI layout')
        end
        if not catalog_stepped then
            local passed,reason=pcall(update_catalog,true)
            if not passed then catalog_failed=tostring(reason);report('catalog.failure',reason)end
        end
        local sample,why=adapter:sample()
        if armory_open_waiting then
            if sample and sample.kind=='armory' then
                armory_open_visible_since=armory_open_visible_since or now
                if now-armory_open_visible_since>=500 then
                    armory_open_waiting=false;armory_open_status('ok','Native Armory Equipment view stably observed')
                end
            else armory_open_visible_since=nil end
            if armory_open_waiting and now>armory_open_deadline then
                armory_open_waiting=false;armory_open_status('error','Native request was sent, but Equipment visibility was not confirmed')
            end
        end
        if adapter.phase=='ready' and not runtime.compat_ready then
            runtime.compat_ready=true;status('READY - open ship Armory Equipment')
        end
        if NativeGrid and adapter.phase=='ready' then
            grid_ui.bridge=grid_ui.bridge or NativeGrid.new(adapter:debug_bridge(),report)
            if grid_ui.bridge.phase=='resolving'or(grid_ui.bridge.producer_status and grid_ui.bridge:producer_status()=='scanning')then
                grid_ui.bridge:step()
            end
            if grid_ui.producer_written==false and grid_ui.bridge.producer_status then
                local phase=grid_ui.bridge:producer_status()
                if phase=='complete'or phase=='failed'then
                    fs.write_atomic('debug-armory-producers.txt',grid_ui.bridge:producer_report());grid_ui.producer_written=true
                end
            end
        end
        if grid_ui.diverkit:busy()then
            surface:clear()
            if grid_ui.flow then grid_ui.flow:clear()end
            runtime.armor_writes=grid_ui.session and grid_ui.session:is_active()or false
            return
        end
        -- Startup restores, one tab after the other: body armor first, the
        -- others once it is done and their catalogs exist.
        local restoring=not armor_tab:restore_startup(now)
        grid_ui.accessory_restoring=false
        if not restoring and catalog_result and grid_ui.bridge and grid_ui.bridge.phase=='ready'then
            grid_ui.init_helmets()
            for category=1,2 do
                local tab=tabs[category]
                if tab and not tab:restore_startup(now)then grid_ui.accessory_restoring=true;break end
            end
        end
        grid_ui.restoring=restoring or grid_ui.accessory_restoring
        if not sample then
            if why and runtime.wait_reason~=why then runtime.wait_reason=why;report('screen.wait',why) end
            local inactive=why=='not ship Armory' or why=='Equipment Armor picker inactive'
            local exited=grid_ui.observation_active~=false
            grid_ui.observation_active=false
            -- An unreadable observation is not a departure: the independent
            -- input guard must still protect any native custom rows in view.
            if inactive then grid_ui.screen_active=false end
            if exited then surface:clear();reset();grid_ui.preview=nil end
            local left=inactive and token~=nil
            for category=0,2 do local tab=tabs[category];if tab then tab:away(now,left,exited,inactive)end end
            if left then
                if grid_ui.icon_probe then grid_ui.icon_probe:clear();grid_ui.icon_probe=nil end
                token=nil;grid_ui.shown_category=nil
                grid_ui.preview=nil
                if grid_ui.bridge and grid_ui.bridge.release_view then grid_ui.bridge:release_view()end
            end
            -- Once the Armory is known to be gone, any unreadable screen after
            -- it (a mission has no Armory menu at all) is looked at four times
            -- a second, not on every frame.
            if grid_ui.screen_active==false and grid_ui.can_idle()then
                grid_ui.idle_until=now+250
            end
            return
        end
        grid_ui.screen_active=true;grid_ui.observation_active=true
        if token~=sample.token then
            ownership_next=0
            -- A replaced menu took every list with it; a screen of another
            -- kind also decides anew what the creator may do.
            for category=0,2 do
                local tab=tabs[category]
                if tab then
                    if token~=nil then tab:leave()end
                    if grid_ui.screen_kind~=sample.kind then tab:drop_flow()end
                end
            end
            grid_ui.screen_kind=sample.kind;grid_ui.shown_category=nil
            surface:clear();reset();token=sample.token;report('screen.detected',sample.kind)
            if sample.anchor then
                report('screen.anchor',table.concat({sample.anchor.x,sample.anchor.y,sample.anchor.w,sample.anchor.h},','))
            end
            local active=patch_active
            for category=0,2 do local tab=tabs[category];if tab and tab:is_active()then active=true end end
            if not active then
                catalog_result,catalog_probe,catalog_failed=nil,nil,nil
                patch,patch_key,patch_plan=nil,nil,nil
                for category=0,2 do local tab=tabs[category];if tab then tab:reset_catalog()end end
                State.reconcile_owned(domain,domain.catalog,nil)
            end
        end
        local catalog_ok,catalog_why=true,nil
        if not catalog_stepped then catalog_ok,catalog_why=pcall(update_catalog)end
        if not catalog_ok and not catalog_failed then catalog_failed=tostring(catalog_why);report('catalog.failure',catalog_failed) end
        update_ownership(now)
        grid_ui.init_helmets()
        -- Body armor's reading of the list is also how the screen is read:
        -- which list is up says which tab has the frame.
        local screen=armor_tab:observe(now)
        local input=fs.sample_input()
        if catalog_result and grid_ui.bridge and grid_ui.bridge.phase=='ready' then
            -- The profile reconcile runs on every tab, through the body
            -- session: it alone is stepped off its own tab, and only while
            -- that commit is in flight. A tab's own Apply never outlives its
            -- list, since a hidden tab leaves its session.
            if screen and screen.kind==4 then
                rawget(_G,'APPLEBACON_PROFILE_RECONCILE')(now,token)
                if grid_ui.session and grid_ui.session:busy() and not screen.identity_mapping_verified then
                    grid_ui.session:step(now)
                end
            end
            -- An unreadable list changes nothing: the tab that had the frame keeps it.
            -- False while a list that is no tab's is up; nil until one was read.
            local category=grid_ui.shown_category
            if category==nil then category=0 end
            if screen then category=screen.kind==4 and screen.native_view_mode==0 and(screen.native_category or 0)end
            grid_ui.shown_category=category
            local shown
            for index=0,2 do
                local tab=tabs[index]
                if tab then
                    if index==category and tab:available()then shown=tab else tab:hide(now)end
                end
            end
            if shown and shown~=armor_tab then
                surface:clear()
                shown:observe(now)
                shown:frame(now,sample,input)
                return
            end
            grid_ui.armor_shown=shown==armor_tab
            -- The previous native-resize experiment is intentionally removed.
            -- New custom rows must use the verified list model, never a repeated
            -- move/restore cycle when a transformed child becomes clipped.
            local pending=grid_ui.preview
            if pending then
                if now>pending.deadline then
                    grid_ui.preview=nil;report('variant.native_preview_error','native selection was not observed before deadline')
                    view.notice='Select the Stats armor to inspect this variant.'
                elseif pending.phase=='queued' then
                    local selected,reason=grid_ui.bridge:select_kit(pending.first,catalog_result)
                    if selected then pending.phase='waiting';grid_ui.next_sample=0
                    else grid_ui.preview=nil;report('variant.native_preview_error',reason);view.notice='Select the Stats armor to inspect this variant.'end
                elseif grid_ui.snapshot and grid_ui.snapshot.selected_kit_id==pending.first then
                    if pending.first~=pending.target then pending.first=pending.target;pending.phase='queued'
                    else
                        grid_ui.preview=nil;patch_note=patch_active and 'Use the native Apply button to equip this variant.'or 'Original armor selected in the native preview.'
                        view.notice=patch_note;report('variant.native_preview',pending.target)
                    end
                end
            end
        else grid_ui.armor_shown=true end
        refresh_plan()
        if not stat_ui.disabled then
            local verified,reason=pcall(update_base_stats,now)
            if not verified then
                if catalog_result then catalog_result.context.stats_status='unavailable'end
                if stat_ui.last_error~=reason then report('stats.unavailable',reason);stat_ui.last_error=reason end
            end
        end
        -- Body armor has the frame, or no tab has: the tab first, and the
        -- development panel below only while the tab has no creator of its own.
        if grid_ui.armor_shown then armor_tab:frame(now,sample,input)end
        if not input then surface:clear();reset();return end
        if grid_ui.flow then return end
        -- The development panel's model, built only when that panel is drawn:
        -- it walks the whole catalog, and a tab with a creator never shows it.
        view.editor=State.editor_view(domain,editor,view.tab,catalog_result and catalog_result.context or {})
        view.active_variant=nil
        if patch_active and editor.draft and grid_ui.snapshot and grid_ui.snapshot.identity_mapping_verified
            and grid_ui.snapshot.selected_kit_id=='armor:'..editor.draft.stats_id:gsub('^native%-stats:','') then
            view.active_variant={label=editor.label,appearance_label=view.editor.appearance_label,
                stats_label=view.editor.stats_label,passive_label=view.editor.passive_label}
        end
        view.editor.can_apply=patch_plan~=nil and not patch_active
        view.editor.patch_active=patch_active==true
        view.editor.apply_note=patch_note
        if patch_active then
            for _,key in ipairs({'can_new','can_duplicate','can_discard','can_previous','can_next','can_save'})do
                view.editor[key]=false
            end
        end
        if not runtime.draw_started then runtime.draw_started=true;report('panel.stage','drawing first surface')end
        local shown=surface:draw(sample,view)
        if not shown then reset();return end
        if not runtime.draw_finished then runtime.draw_finished=true;report('panel.stage','first surface completed')end
        if input.down and surface.capture and surface:capture(input.x,input.y)
            and grid_ui.bridge and grid_ui.bridge.phase=='ready' then
            local consumed,reason=grid_ui.bridge:consume_select()
            if not consumed then report('grid.consume_error',reason);reset();return end
            grid_ui.capture_latched=true
        end
        if not runtime.panel_seen then runtime.panel_seen=true;status('UI DRAWN - verify placement and interaction in game') end
        local target=surface:hit(input.x,input.y)
        if previous_down==nil then previous_down=input.down;armed=nil;return end
        if input.down and not previous_down then armed=target end
        if not input.down and previous_down then
            if armed and target==armed then
                if target=='toggle' then view.open=not view.open
                elseif panel_tabs[target] then view.tab=target;view.saved=false;editor.detail_page=1
                elseif target=='save' then save()
                elseif target=='reload' then restore()
                elseif target=='apply_variant' then
                    local done,why=pcall(apply_variant);if not done then view.notice='Preview rejected - see diagnostics';report('preview.error',why)end
                elseif target=='reset_variant' then
                    local done,why=pcall(reset_variant);if not done then view.notice='Reset needs attention - see diagnostics';report('preview.reset_error',why)end
                else
                    local handled,notice,candidate,event=State.editor_action(domain,editor,target,view.tab,catalog_result and catalog_result.context or {})
                    if handled then
                        view.notice=notice or view.notice;view.saved=false
                        if candidate then save(candidate) end
                        if (target=='new_variant' or target=='duplicate_variant') and editor.dirty then view.open=true end
                        if event then
                            local acted,reason=pcall(function()
                                if patch_active then reset_variant() end
                                patch_key=nil;refresh_plan()
                                if event.open_editor then view.open=true
                                else apply_variant();view.open=false end
                            end)
                            if not acted then view.notice='Variant could not be selected - see diagnostics';report('variant.select_error',reason)end
                        end
                    end
                end
                report('ui.action',target)
            end
            armed=nil
        end
        previous_down=input.down
    end
    local previous_update, previous_shutdown=rawget(_G,'update'),rawget(_G,'shutdown')
    local function after(...)
        if not stopped then
            if grid_ui.diverkit.after_update then grid_ui.diverkit:after_update()end
            local started_tick=os.clock()
            local passed,reason=pcall(tick)
            runtime.profile.tick=runtime.profile.tick+os.clock()-started_tick;runtime.profile.frames=runtime.profile.frames+1
            if not passed then
                retries=retries+1
                pcall(function() surface:clear() end);reset()
                report('runtime.error',reason);report('frame',frame)
                next_attempt=fs.now()+5000*retries
                if retries>=3 then stopped=true; status('STOPPED - see AppleBacon.log for compatibility error') end
            end
        end
        do -- the Armory's large model, after the native update; globals only
            local fix=rawget(_G,'APPLEBACON_MODEL_FIX')
            if fix then pcall(fix) end
        end
        return ...
    end
    rawset(_G,'update',function(...)
        -- One input sample and one pass over the code proofs per game update:
        -- the stamp tells the readers that a new update began.
        rawset(_G,'APPLEBACON_FRAME',(rawget(_G,'APPLEBACON_FRAME')or 0)+1)
        if fs.begin_frame then fs.begin_frame()end
        local dkstate=rawget(_G,'CodexLoadouts')
        if dkstate or grid_ui.diverkit.status~='absent' then
            local diverkit=grid_ui.diverkit
            local checked,why=pcall(diverkit.step,diverkit,fs.now(),rawget(_G,'update'),dkstate)
            if not checked then report('diverkit.error',why)end
        end
        do -- headless refresh driver; globals only, no new upvalues
            local direct=rawget(_G,'APPLEBACON_REFRESH_DIRECT')
            if direct then pcall(direct,'step') end
        end
        do -- the MODS-tab row; globals only, no new upvalues
            local menu=rawget(_G,'APPLEBACON_OPTIONS_MENU_STEP')
            if menu then pcall(menu,'step') end
        end
        -- Every tab guards its own cards before the game reads this frame's
        -- input. A guard that fails has taken its creator down: cancel this
        -- press once; never repeat a failing guard every frame.
        if not stopped and grid_ui.screen_active~=false then
            for category=0,2 do
                local tab=tabs[category]
                if tab and not tab:before(fs.sample_input)then
                    status('CREATOR PAUSED - reopen the Armory after input capture recovers')
                    return
                end
            end
        end
        if previous_update then return after(previous_update(...)) end
        return after()
    end)
    report('startup.hooks_installed',true)
    rawset(_G,'shutdown',function(...)
        stopped=true;pcall(function()grid_ui.diverkit:shutdown()end);pcall(function() surface:clear() end)
        for category=0,2 do local tab=tabs[category];if tab then pcall(tab.shutdown,tab)end end
        if grid_ui.icon_probe then pcall(function()grid_ui.icon_probe:clear()end)end
        if grid_ui.bridge and grid_ui.bridge.release_view then pcall(function()grid_ui.bridge:release_view()end)end
        if patch_active then
            local restored,reason=pcall(reset_variant);report('shutdown.preview_reset',restored and reason or 'session no longer available')
        end
        report('shutdown',true)
        if log then pcall(function() log:close() end); log=nil end
        if previous_shutdown then return previous_shutdown(...) end
    end)
    status('LOADED - UI initialization scheduled')
end)
if not ok then
    runtime.status='startup_failed';report('startup.error',failure)
    print('[AppleBacon] '..tostring(failure))
end
return runtime
