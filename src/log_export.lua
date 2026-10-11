-- On-demand, streaming support reports. The game uses Win32 on Windows and
-- Linux/Proton; wide APIs also handle localized and redirected Desktop paths.
local M={}
local function join(a,b)return a:gsub('[/\\]+$','')..'/'..b end
function M.desktop(host)
 if host.wine then
  local home=host.getenv('HOME')
  if home and home:sub(1,1)=='/'then
   local config=host.getenv('XDG_CONFIG_HOME')
   if not config or config:sub(1,1)~='/'then config=join(home,'.config')end
   local text=host.read_text('Z:'..join(config,'user-dirs.dirs'))
   local desktop
   for line in (text or''):gmatch('[^\r\n]+')do
    local value=line:match('^%s*XDG_DESKTOP_DIR="(.-)"%s*$')
    if value then
     value=value:gsub('^%${HOME}',function()return home end):gsub('^%$HOME',function()return home end)
     -- This is data, never shell input. Decode only shell-quoted literals.
     value=value:gsub('\\([\\"$`])','%1')
     if value:sub(1,1)=='/'then desktop=value end
    end
   end
   return 'Z:'..(desktop or join(home,'Desktop'))
  end
 end
 return host.desktop()
end

function M.native()
 local ffi=require('ffi')
 for _,decl in ipairs({
  'typedef struct { uint32_t attributes; uint32_t times[6]; uint32_t size_high,size_low,reserved[2]; uint16_t name[260],alternate[14]; } AppleBaconLogFind;',
  'int MultiByteToWideChar(unsigned int,unsigned long,const char*,int,uint16_t*,int);',
  'int WideCharToMultiByte(unsigned int,unsigned long,const uint16_t*,int,char*,int,const char*,int*);',
  'int SHGetFolderPathW(void*,int,void*,uint32_t,uint16_t*);',
  'void *CreateFileW(const uint16_t*,uint32_t,uint32_t,void*,uint32_t,uint32_t,void*);',
  'int ReadFile(void*,void*,uint32_t,uint32_t*,void*);',
  'int WriteFile(void*,const void*,uint32_t,uint32_t*,void*);',
  'int GetFileSizeEx(void*,int64_t*);','int FlushFileBuffers(void*);','int CloseHandle(void*);',
  'int DeleteFileW(const uint16_t*);','uint32_t GetLastError(void);',
  'void *FindFirstFileW(const uint16_t*,void*);','int FindNextFileW(void*,void*);','int FindClose(void*);',
  'const char *wine_get_version(void);',
 })do pcall(ffi.cdef,decl)end
 local k=ffi.load('kernel32');local shell=ffi.load('shell32')
 local invalid=ffi.cast('void*',-1)
 local function wide(text)
  assert(type(text)=='string'and not text:find('\0',1,true),'Invalid file path')
  local cp=65001;local n=k.MultiByteToWideChar(cp,8,text,#text,nil,0)
  if n==0 then cp=0;n=k.MultiByteToWideChar(cp,0,text,#text,nil,0)end
  assert(n>0,'Path conversion failed')
  local out=ffi.new('uint16_t[?]',n+1)
  assert(k.MultiByteToWideChar(cp,cp==65001 and 8 or 0,text,#text,out,n)==n,'Path conversion failed')
  return out
 end
 local function utf8(value)
  local n=k.WideCharToMultiByte(65001,0,value,-1,nil,0,nil,nil);assert(n>0,'Path conversion failed')
  local out=ffi.new('char[?]',n)
  assert(k.WideCharToMultiByte(65001,0,value,-1,out,n,nil,nil)==n,'Path conversion failed')
  return ffi.string(out,n-1)
 end
 local function opened(path,writing)
  local h=k.CreateFileW(wide(path),writing and 0x40000000 or 0x80000000,7,nil,writing and 1 or 3,0x80,nil)
  if h==invalid then return nil,tonumber(k.GetLastError())end
  local self={};local buffer=ffi.new('uint8_t[65536]');local count=ffi.new('uint32_t[1]')
  function self:size()
   local size=ffi.new('int64_t[1]');assert(k.GetFileSizeEx(h,size)~=0,'Log size unavailable');return tonumber(size[0])
  end
  function self:read(n)
   assert(n<=65536 and n>0,'Invalid read size')
   assert(k.ReadFile(h,buffer,n,count,nil)~=0,'Log read failed')
   return ffi.string(buffer,count[0])
  end
  function self:write(text)
   local offset=0
   while offset<#text do
    local piece=text:sub(offset+1,offset+65536)
    assert(k.WriteFile(h,piece,#piece,count,nil)~=0 and count[0]>0,'Report write failed (check free disk space)')
    offset=offset+tonumber(count[0])
   end
   return true
  end
  function self:flush()assert(k.FlushFileBuffers(h)~=0,'Report flush failed');return true end
  function self:close()
   if h then local old=h;h=nil;assert(k.CloseHandle(old)~=0,'File close failed')end
   return true
  end
  return self
 end
 local host={getenv=os.getenv,open=opened,remove=function(path)k.DeleteFileW(wide(path))end}
 host.wine=pcall(function()return ffi.load('ntdll').wine_get_version()end)
 function host.desktop()
  local path=ffi.new('uint16_t[260]')
  assert(shell.SHGetFolderPathW(nil,0x10,nil,0,path)==0,'Desktop folder unavailable')
  return utf8(path)
 end
 function host.read_text(path)
  local f=opened(path);if not f then return nil end
  local ok,text=pcall(function()return f:read(math.min(65536,f:size()+1))end)
  f:close();return ok and text or nil
 end
 function host.list(directory)
  local data=ffi.new('AppleBaconLogFind[1]');local opaque=ffi.cast('void*',data)
  local h=k.FindFirstFileW(wide(join(directory,'*.log')),opaque)
  if h==invalid then
   assert(tonumber(k.GetLastError())==2,'Log directory unavailable');return{}
  end
  local ok,result=pcall(function()
   local out={}
   repeat
    if math.floor(tonumber(data[0].attributes)/16)%2==0 then out[#out+1]=utf8(data[0].name)end
   until k.FindNextFileW(h,opaque)==0
   assert(tonumber(k.GetLastError())==18,'Log enumeration failed')
   return out
  end)
  k.FindClose(h);assert(ok,result);return result
 end
 return host
end

-- Injectable file operations keep failure handling and platform selection
-- testable without touching a player's files. No tailing, line or byte limits.
function M.export(loader,metadata,host)
 local output,input,path
 local ok,result=pcall(function()
  host=host or M.native()
  local directory=loader and loader.log_directory
  if not directory or directory==''then
   directory=join(assert(host.getenv('LOCALAPPDATA'),'Log directory unavailable'),'AppleBacon/Logs')
  end
  local names=host.list(directory);table.sort(names)
  local desktop=assert(M.desktop(host),'Desktop folder unavailable')
  local base='AppleBacon-Logs-'..os.date('!%Y%m%d-%H%M%S')
  for suffix=0,999 do
   local candidate=join(desktop,base..(suffix>0 and'-'..suffix or'')..'.txt')
   local why;output,why=host.open(candidate,true)
   if output then path=candidate;break end
   assert(why==80 or why==183,'Cannot write to Desktop: '..tostring(why))
  end
  assert(output,'No free report filename')
  local function write(text)assert(output:write(text),'Report write failed')end
  write('AppleBacon support report\nUTC: '..os.date('!%Y-%m-%dT%H:%M:%SZ')..'\n'..(metadata or'')
   ..'\nAll available .log files, including retained sessions. Each file is copied to its size at export time.\n')
  local copied,missing=0,0
  for _,name in ipairs(names)do
   if name:lower():match('%.log$')and not name:find('[/\\%z]')then
    write('\n===== '..name..' =====\n')
    local why;input,why=host.open(join(directory,name),false)
    if not input then missing=missing+1;write('[UNAVAILABLE: '..tostring(why)..']\n')
    else
     local remaining=input:size()
     while remaining>0 do
      local chunk=input:read(math.min(remaining,65536))
      assert(chunk and #chunk>0,'Log changed or could not be read: '..name)
      write(chunk);remaining=remaining-#chunk
     end
     assert(input:close(),'Log close failed');input=nil;copied=copied+1
     write('\n===== END '..name..' =====\n')
    end
   end
  end
  assert(copied>0,'No readable logs found')
  write('\nExport complete. Files: '..copied..'; unavailable: '..missing..'\n')
  assert(output:flush(),'Report flush failed');assert(output:close(),'Report close failed');output=nil
  return{path=path,files=copied,unavailable=missing}
 end)
 if input then pcall(input.close,input)end
 if output then pcall(output.close,output)end
 if not ok then if path and host then pcall(host.remove,path)end;return nil,tostring(result)end
 return result
end
return M
