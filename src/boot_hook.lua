-- AppleBacon startup hook, deployed as core/wwise/lua/wwise_bank_reference.
-- The game's own core/wwise/lua/wwise_flow_callbacks requires this module at
-- the top of its chunk while the game boots, and Bingus Shared Loader runs
-- that same original chunk, so this hook runs with or without the loader and
-- never shares a resource with it. The original module runs first, unchanged;
-- then AppleBacon starts once. Nothing here may stop the game from booting.
-- tools/build.py replaces the marker below with the game's original bytecode.
local ORIGINAL = --[[APPLEBACON_ORIGINAL_BYTECODE]]nil
local MODULE = 'mods/applebacon/core'

local function pack(...) return {n = select('#', ...), ...} end
local original = assert(loadstring(ORIGINAL, '=core/wwise/lua/wwise_bank_reference'))
local results = pack(original(...))

-- What AppleBacon needs from a loader, supplied by AppleBacon itself: the API marker,
-- its own log folder (saves live beside it, in ..\Data) and a way to open a
-- log file there. Used whether or not Bingus Shared Loader is installed.
local function standalone_loader()
    local base = os.getenv('LOCALAPPDATA')
    if type(base) ~= 'string' or #base == 0 then return nil end
    local root = base .. '\\AppleBacon'
    local directory, data = root .. '\\Logs', root .. '\\Data'
    pcall(function()
        local ffi = require('ffi')
        pcall(ffi.cdef, 'int CreateDirectoryA(const char*, void*);')
        local kernel = ffi.load('kernel32')
        for _, path in ipairs({root, directory, data}) do
            kernel.CreateDirectoryA(path, nil) -- an existing folder is fine
        end
    end)
    return {api = 1, version = 'applebacon-standalone-1', standalone = true, log_directory = directory,
        open_log = function(name)
            if type(name) ~= 'string' or name:find('[\\/]') then return nil end
            return io.open(directory .. '\\' .. name, 'wb')
        end}
end

pcall(function()
    if rawget(_G, 'AppleBacon') then return end
    local application = rawget(_G, 'Application') or (rawget(_G, 'stingray') or {}).Application
    if not (application and type(application.can_get) == 'function') then return end
    local present, available = pcall(application.can_get, 'lua', MODULE)
    if not present or available ~= true then return end
    if not rawget(_G, 'CowboyBingusModLoader') then
        -- AppleBacon is a large Lua mod: raise the shared LuaJIT machine-code
        -- budget above its 2015 defaults first, as Bingus Shared Loader does.
        if type(jit) == 'table' and type(jit.opt) == 'table' and type(jit.opt.start) == 'function' then
            pcall(jit.opt.start, 'maxmcode=65536', 'maxtrace=8000')
        end
    end
    if not rawget(_G, 'AppleBaconStandaloneLoader') then rawset(_G, 'AppleBaconStandaloneLoader', standalone_loader()) end
    require(MODULE)
end)

return unpack(results, 1, results.n)
