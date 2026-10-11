-- AppleBacon's row in the native MODS tab (Mod Options Menu, when installed):
-- export the logs for a bug report. The host has no buttons, so the export is
-- an applied momentary choice that resets itself and then shows the result.
local M={PANEL='AppleBacon',EXPORT_ID='applebacon.logs.export'}
local function reason(value)return(tostring(value):gsub('^.-%.lua:%d+: ',''))end
function M.new(opts)
 opts=opts or{}
 local self={phase='idle',rows=0,refused=0}
 local registered,told={},{}
 local suppressed=false
 local export_pending=false
 local function report(kind,value)
  if opts.report then pcall(opts.report,'applebacon.options.'..kind,tostring(value))end
 end
 local function once(kind,value)
  local key=kind..':'..tostring(value)
  if not told[key]then told[key]=true;report(kind,value)end
 end
 local function host()return opts.menu or rawget(_G,'ModOptionsMenu')end
 local function call(api,name,...)
  if type(api)~='table'or type(api[name])~='function'then return nil,name..' unavailable'end
  local ok,value,why=pcall(api[name],...)
  if not ok then return nil,reason(value)end
  return value,why
 end
 local function push(id,value)
  suppressed=true
  local ok,why=call(host(),'set',id,value)
  suppressed=false
  if ok~=true then once('set_failed',id..': '..tostring(why or'refused'));return nil end
  return true
 end
 local function register(api,id,spec,callback)
  if registered[id]~=nil then return end
  local accepted,why=call(api,'register_option',id,spec)
  if accepted~=true then
   registered[id]=false;self.refused=self.refused+1
   return once('refused',id..': '..tostring(why or'refused'))
  end
  registered[id]=true;self.rows=self.rows+1
  local bound,problem=call(api,'on_change',id,function(value)
   if not suppressed then callback(value)end
  end)
  if bound~=true then once('unbound',id..': '..tostring(problem or'refused'))end
  push(id,1)
 end
 function self:step()
  local api=host()
  if type(api)~='table'then self.phase='absent';return self.phase end
  local ready,why=call(api,'ready')
  if ready~=true then
   self.phase='waiting';if why then once('ready_error',why)end;return self.phase
  end
  self.phase='ready'
  register(api,M.EXPORT_ID,{mod=M.PANEL,label='Export logs to Desktop',type='choice',default=1,
   choices={'No export requested','Export now','Saved to Desktop','Export failed','Saved; some logs unavailable'},
   description='Select Export now and Apply. Saves full available loader and mod .log files, including previous sessions, in one dated AppleBacon-Logs file on your Desktop (Windows or Linux/Proton). Attach it to your bug report. The row shows the result; select Export now again to retry.'},function(value)
    local reset=push(M.EXPORT_ID,1)
    if value==2 then
     if not reset then self.export_error='Could not reset export control';return report('export_failed',self.export_error)end
     export_pending=true
    end
   end)
  if export_pending then
   export_pending=false
   local runtime=rawget(_G,'AppleBacon')
   local export=opts.export_logs or type(runtime)=='table'and runtime.export_logs
   local ok,result,failure
   if type(export)=='function'then ok,result,failure=pcall(export)else failure='Log export unavailable'end
   self.export_path=ok and type(result)=='table'and result.path or nil
   self.export_error=not self.export_path and tostring(ok and failure or result or failure)or nil
   self.export_unavailable=self.export_path and result.unavailable or nil
   push(M.EXPORT_ID,self.export_path and((result.unavailable or 0)>0 and 5 or 3)or 4)
   report(self.export_path and 'export_saved'or 'export_failed',self.export_path or self.export_error)
  end
  return self.phase
 end
 function self:status()
  return{phase=self.phase,rows=self.rows,refused=self.refused,export_path=self.export_path,
   export_error=self.export_error,export_unavailable=self.export_unavailable}
 end
 return self
end
function M.format_status(status)
 local function clean(value)return tostring(value or'none'):gsub('%c',' ')end
 return table.concat({'AB_OPTIONS 1',
  'phase='..clean(status.phase)..' rows='..clean(status.rows)..' refused='..clean(status.refused),
  'export_path='..clean(status.export_path)..' export_error='..clean(status.export_error)..' unavailable='..clean(status.export_unavailable)},'\n')..'\n'
end
return M
