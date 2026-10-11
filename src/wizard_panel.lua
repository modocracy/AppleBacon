-- Native-adjacent presentation for VariantWizard; no native memory or calls.
-- Coordinates use viewport pixels with a bottom-left origin.
--
-- panel:draw(sample, wizard:view(domain, context), context) -> true|false
-- panel:hit(x,y) -> structured action or {type='panel_background'}
-- panel:capture(x,y) -> whether an owned surface must consume input
-- panel:handle(action) -> true for panel_page actions (redraw afterwards)
-- panel:input_policy() -> controller instructions; keyboard enforcement belongs
--   to the caller. Native grid clicks choose a look only while native_look_pick.
-- panel:metrics() -> draw_count, rebuild_count, signature_ms,
--   signature_total_ms, signature_bytes (local counters only; no engine calls).
-- panel:clear() removes owned GUI primitives and input capture.
--
-- sample.custom_section is REQUIRED for the browse section. It must describe
-- a row already reserved by the native controller. There is no fallback row,
-- no automatic native resize, and no overlay on existing native armor tiles.
-- Alternatively sample.native_prefix={verified=true,clip={x,y,w,h},
--   headers={{rect={x,y,w,h},text='Custom Variant'}},
--   cells={{rect={x,y,w,h},key='stable-key',kind='variant'|'create',
--     image_rect={x,y,w,h},label='saved name',
--     passive={icon_hash='material hash'},selected=false}}}
-- supplies actual native header/cell geometry and takes browse precedence.
-- Geometry must be sampled in the same update as draw; callers must not reuse
-- a throttled grid snapshot. Fully clipped-out rectangles are skipped. Partial
-- cells capture only their visible intersection, without actions. Decorations
-- remain anchored to the full native card/image, never the clipped rectangle.
-- Variants keep native thumbnails; only visible name/badge areas are
-- covered. Only these measured surfaces capture mouse input. This
-- route never reads, converts, validates, or draws borrowed native handles.
-- sample.wizard_layout may override header/picker/review/apply/footer rects.
-- sample.font/material/atlas use the same observed resources as Panel.
-- Optional view.selected_variant={label,request={appearance_id,stats_id,
-- passive_variant_id}} shows a read-only saved review while browsing. It keeps
-- prefix cards live and covers native donor details/Apply without adding any
-- Create, Apply, or equipment action. The controller supplies this metadata.
-- A strict view.native_details=true confirms that the selected variant is
-- already shown by the native stat/perk/Apply views and removes that review.
-- Native Apply and its footer hint remain visually untouched. Their invisible
-- regions emit apply_variant only while can_apply=true; apply_pending captures
-- without dispatching. The controller, never this renderer, equips the variant.
--
-- Look uses the ORIGINAL native grid. Stats and passive options use the pure
-- model's ordering. Review remains alongside the native 3D model; it covers
-- the donor title/stats/perk/Apply while creation is open. Create saves only.
-- Raw material_pointer descriptors are rejected. Borrowed engine material
-- handles additionally require native_handle_verified, engine handle_source,
-- and a fresh valid() proof. Resource thumbnails require verified=true.
-- Known passive hashes prefer verified original DDS-derived icon geometry;
-- these retained rectangles need no texture residency or material binding.

local M = {}
M.EMPTY_PASSIVE='passive:efa5b3573272cbfb1b6b40196a0009d4' -- pinned native enum-zero identity
-- Standard Issue is the empty native passive. A provider may give enum zero
-- real effects; those still deserve a badge, regardless of localized names.
local function grid_perk(passive,passive_id)
  -- Saved neutral recipes can outlive the provider that supplied their
  -- metadata. Do not replace their absent badge with an unknown-perk marker.
  if type(passive)~='table'or passive.enum==nil then return passive_id~=M.EMPTY_PASSIVE end
  if passive.enum~=0 then return true end
  if (passive.behavior_tag or 0)~=0 or #(passive.stat_modifiers or {})>0 then return true end
  for _,effect in ipairs(passive.modifiers or {})do
    if (effect.modifier_id or 0)~=0 then return true end
  end
  return false
end
local Layout=UiLayout or require('src.ui_layout')
local STAT_FIELDS = {'armor_rating', 'speed', 'stamina_regen'}
local STAT_LABELS = {'ARMOR RATING', 'SPEED', 'STAMINA REGEN'}

local function chars(value)
  local out={}
  for char in tostring(value or ''):gmatch('[%z\1-\127\194-\244][\128-\191]*') do out[#out+1]=char end
  return out
end
local function wrap(value, limit)
  local lines,line,count={}, {},0
  for _,char in ipairs(chars(value)) do
    local size=char:byte()>=0xE3 and 2 or 1
    if char=='\n' or count+size>limit then
      lines[#lines+1]=table.concat(line);line,count={},0
    end
    if char~='\n' then line[#line+1],count=char,count+size end
  end
  if #line>0 then lines[#lines+1]=table.concat(line) end
  return lines
end
local function clip(value, limit)
  local lines=wrap(tostring(value or ''):gsub('%c',' '),limit)
  return (lines[1] or '')..(#lines>1 and '...' or '')
end
-- Word-aware wrap for short captions. Lines may also break after a hyphen;
-- a part longer than a whole line still breaks inside it.
local function word_wrap(value, limit)
  local lines,line={},''
  for word in tostring(value or ''):gsub('%c',' '):gmatch('%S+')do
    local first=true
    for part in word:gmatch('[^%-]*%-?')do
      if part~=''then
        local candidate=line==''and part or line..(first and ' ' or '')..part
        if #wrap(candidate,limit)<=1 then line=candidate
        else
          if line~=''then lines[#lines+1]=line end
          local pieces=wrap(part,limit)
          for index=1,#pieces-1 do lines[#lines+1]=pieces[index]end
          line=pieces[#pieces]or ''
        end
        first=false
      end
    end
  end
  if line~=''then lines[#lines+1]=line end
  return lines
end

-- Picker geometry per step. Passives are an icon grid whose full text lives in
-- the review panel; stats are a compact table under one shared column header.
-- Other steps keep their original 122-unit rows.
M.PASSIVE_COLUMNS=5
M.PASSIVE_TILE_H=126
M.STATS_ROW_H=46
local PICKER_FOOTER=44
M.SCROLL_GUTTER=14 -- room for the picker's scrollbar at its right edge
local function option_layout(step,picker,scale)
  local usable=picker.h-PICKER_FOOTER*scale
  if step==3 then
    local columns,gap=M.PASSIVE_COLUMNS,6*scale
    local row_h=M.PASSIVE_TILE_H*scale
    local rows=math.max(1,math.floor((usable-gap)/row_h))
    return {grid=true,columns=columns,rows=rows,count=columns*rows,row_h=row_h,top=gap,gap=gap,
      tile_w=(picker.w-(10+M.SCROLL_GUTTER)*scale-(columns-1)*gap)/columns}
  elseif step==2 then
    local header,row_h=30*scale,M.STATS_ROW_H*scale
    local rows=math.max(1,math.floor((usable-header)/row_h))
    return {columns=1,rows=rows,count=rows,row_h=row_h,top=header,inset=3*scale}
  end
  local row_h=122*scale
  local rows=math.max(1,math.floor(usable/row_h))
  return {columns=1,rows=rows,count=rows,row_h=row_h,top=0,inset=6*scale}
end
local function option_rect(grid,picker,slot,scale)
  if grid.grid then
    local column,row=(slot-1)%grid.columns,math.floor((slot-1)/grid.columns)+1
    return {x=picker.x+5*scale+column*(grid.tile_w+grid.gap),y=picker.y+picker.h-grid.top-row*grid.row_h+grid.gap,
      w=grid.tile_w,h=grid.row_h-grid.gap}
  end
  return {x=picker.x+5*scale,y=picker.y+picker.h-grid.top-slot*grid.row_h+grid.inset,
    w=picker.w-(10+M.SCROLL_GUTTER)*scale,h=grid.row_h-2*grid.inset}
end
local function number(value)
  return type(value)=='number' and value==value and value~=math.huge and value~=-math.huge
end

-- Korean captions for this panel's own fixed English strings. They are used
-- only when the game's own localized names are Korean; names, labels and
-- passive text supplied by the game are never translated here.
M.KO={
  ['CUSTOM VARIANT']='커스텀 변형',['Custom Variant']='커스텀 변형',['Saved variant']='저장된 변형',
  ['New variant']='새 변형',['LOOK']='외형',['STATS']='통계',['BASE STATS']='통계',['PASSIVE']='방어구 패시브',
  ['Not selected']='선택 안 됨',['ARMOR RATING']='장갑 등급',['SPEED']='속도',['STAMINA REGEN']='스태미나 재생',
  ['Create']='생성',['Saving...']='저장 중...',['Back']='뒤로',['Forward']='앞으로',['Cancel']='취소',
  ['Choose a look']='외형 선택',['Choose base stats']='기본 능력치 선택',['Choose stats']='능력치 선택',
  ['Choose a passive']='패시브 선택',['Name and create']='확인 후 생성',
  ['Create saves this variant. Your equipped armor stays unchanged.']='생성하면 변형이 저장됩니다. 장착 중인 방어구는 바뀌지 않습니다.',
  ['Passive bonuses are excluded.']='패시브 보너스를 뺀 기본 수치입니다.',
  ["Preview only. Saved as this variant's default when you Create."]='미리보기입니다. 생성하면 이 변형의 기본 외형으로 저장됩니다.',
  ['Choose an owned thumbnail to use its look.']='보유한 방어구를 골라 외형으로 사용하세요.',
  ['Choose owned armor to use its look and base stats.']='보유한 방어구를 골라 외형과 기본 능력치로 사용하세요.',
  ['D-pad / left stick: choose a look. A: select.']='방향키/왼쪽 스틱: 외형 고르기   A: 선택',
  ['A Select   B Back   Y Cancel']='A 선택   B 뒤로   Y 취소',
  ['D-pad / stick Move    LB / RB Page']='방향키/스틱 이동    LB/RB 페이지',
  ['Create variant']='변형 만들기',['Remove variant']='변형 삭제',['Saved look']='저장된 외형',
  ['Edit variant']='변형 수정',['Save']='저장',
  ['Save replaces this variant with your changes.']='저장하면 이 변형이 바뀐 내용으로 덮어써집니다.',
  ['Saved. Equip this variant again to wear the changes.']='저장했습니다. 바뀐 내용을 입으려면 이 변형을 다시 장착하세요.',
  ['Choose a saved variant.']='저장된 변형을 고르세요.',
  ['Choose another card or + to create a variant.']='다른 카드를 고르거나 +로 새 변형을 만드세요.',
  ['Equipped']='장착됨',['Loading preview…']='미리보기 불러오는 중…',
  ['Waiting for verified owned choices.']='보유 항목을 확인하는 중입니다.',
  ['Some owned base stats are awaiting verification.']='일부 능력치를 확인하는 중입니다.',
  ['Click to change']='클릭하여 변경',['Choosing']='선택 중',
}
local function hangul(value)
  return type(value)=='string'and value:find('[\234-\237][\128-\191][\128-\191]')~=nil
end
-- The game language is inferred from the localized names it supplies.
local function korean(context)
  local labels=type(context)=='table'and type(context.labels)=='table'and context.labels or {}
  for _,field in ipairs({'appearance_id','passive_variant_id'})do
    if type(labels[field])=='table'then
      for _,name in pairs(labels[field])do if hangul(name)then return true end end
    end
  end
  return false
end

-- Review panel geometry shared by the retained-GUI signature and drawing.
M.REVIEW_LINES=7
local function passive_frame_width(r,scale,context)
  local stats=not context.category or context.category==0
  return stats and (r.w-60*scale)/2 or r.w-40*scale
end
local function effect_lines(effects,frame_w,scale)
  local limit=math.max(18,math.floor((frame_w/scale-36)/(15*0.56)))
  local lines={}
  for _,effect in ipairs(effects or {})do
    for _,line in ipairs(word_wrap(effect,limit))do lines[#lines+1]=line end
  end
  return lines
end
-- Native-style segment gauges: share of a fixed per-stat maximum.
local STAT_MAX={armor_rating=200,speed=550,stamina_regen=125}
local function stat_text(value)
  return number(value)and value>=0 and string.format('%g',value)or '--'
end
local function resource(value)
  return type(value)=='string' and #value==16 and not value:find('[^%x]')
end
local function inside(r,x,y)
  return x>=r.x and x<r.x+r.w and y>=r.y and y<r.y+r.h
end
local function valid_rect(r,width,height)
  if type(r)~='table' then return false end
  for _,key in ipairs({'x','y','w','h'}) do if not number(r[key]) then return false end end
  return r.x>=0 and r.y>=0 and r.w>0 and r.h>0 and r.x+r.w<=width and r.y+r.h<=height
end
local function contained(r,clip,width,height)
  return valid_rect(r,width,height) and r.x>=clip.x and r.y>=clip.y
    and r.x+r.w<=clip.x+clip.w and r.y+r.h<=clip.y+clip.h
end
local function intersection(r,bounds)
  local x,y=math.max(r.x,bounds.x),math.max(r.y,bounds.y)
  local right,top=math.min(r.x+r.w,bounds.x+bounds.w),math.min(r.y+r.h,bounds.y+bounds.h)
  if right<=x or top<=y then return nil end
  return {x=x,y=y,w=right-x,h=top-y}
end
local function prefix_cell_rect(cell,clip,width,height,scale)
  local r=cell.rect
  if type(r)~='table'then return nil end
  for _,key in ipairs({'x','y','w','h'})do if not number(r[key])then return nil end end
  if r.w<64*scale or r.h<64*scale then return nil end
  if contained(r,clip,width,height)then return r,false,r end
  local visible=intersection(r,clip)
  if visible then return r,true,visible end
end
local function badge_rect(cell,r,scale)
  local image=cell.image_rect
  if type(image)=='table' then
    for _,key in ipairs({'x','y','w','h'})do if not number(image[key])then image=nil;break end end
  end
  if type(image)~='table' or image.w<64*scale or image.h<64*scale or image.x<r.x or image.y<r.y
    or image.x+image.w>r.x+r.w or image.y+image.h>r.y+r.h then image=r end
  local size=math.min(28*scale,image.w/4,image.h/4)
  -- Keep the native selected/equipped marker at the top-right unobscured.
  return {x=image.x+5*scale,y=image.y+image.h-size-5*scale,w=size,h=size}
end
local function saved_review(value)
  if type(value)~='table' or type(value.label)~='string' or #value.label==0
    or #value.label>256 or type(value.request)~='table' then return nil end
  for _,field in ipairs({'appearance_id','stats_id','passive_variant_id'})do
    local id=value.request[field]
    if type(id)~='string' or #id==0 or #id>128 or id:find('[%c%s]') then return nil end
  end
  return value
end
local function valid_uv(uv)
  if type(uv)~='table' or #uv~=4 then return false end
  for i=1,4 do if not number(uv[i]) or uv[i]<0 or uv[i]>1 then return false end end
  return uv[3]>uv[1] and uv[4]>uv[2]
end
local function stamp(value,depth)
  depth=depth or 0
  if type(value)~='table' then
    if type(value)=='string' then return #value..':'..value end
    if type(value)=='number' or type(value)=='boolean' then return tostring(value) end
    return type(value)
  end
  if depth>8 then return '{}' end
  local keys,out={},{}
  for key in pairs(value) do if type(key)=='string' or type(key)=='number' then keys[#keys+1]=key end end
  table.sort(keys,function(a,b)return tostring(a)<tostring(b)end)
  for _,key in ipairs(keys) do out[#out+1]=stamp(key,depth+1)..stamp(value[key],depth+1) end
  return '{'..table.concat(out)..'}'
end

-- Compare the projected display state without sorting keys or rebuilding its
-- serialized signature on idle frames. The retained copy below is essential:
-- native geometry and caller-owned tables can be edited in place between draws.
local function same_display(a,b,depth)
  local kind=type(a)
  if kind~=type(b)then return false end
  if kind~='table'then
    if kind=='string'or kind=='number'or kind=='boolean'then return a==b end
    return true -- stamp represents other scalar kinds by their type only
  end
  depth=depth or 0
  if depth>8 then return true end
  for key,value in pairs(a)do
    if type(key)=='string'or type(key)=='number'then
      if not same_display(value,b[key],depth+1)then return false end
    end
  end
  for key in pairs(b)do
    if(type(key)=='string'or type(key)=='number')and a[key]==nil then return false end
  end
  return true
end
local function retain_display(value,depth)
  if type(value)~='table'then return value end
  local out={};depth=depth or 0
  if depth<=8 then
    for key,item in pairs(value)do
      if type(key)=='string'or type(key)=='number'then out[key]=retain_display(item,depth+1)end
    end
  end
  return out
end

function M.new(engine)
  local A,W,G=engine.Application,engine.World,engine.Gui
  local icon_art
  if type(PassiveIconDraw)=='table'and type(PassiveIconDraw.new)=='function'and type(PassiveIconGeometry)=='table'then
    local ok,value=pcall(PassiveIconDraw.new,engine,PassiveIconGeometry,PassiveIconGeometryHD)
    if ok then icon_art=value end
  end
  -- Options scroll by whole rows (scroll.options = first visible row).
  local self={regions={},captures={},pages={options=1,section=1,review=1},page_limits={},scroll={options=0},
    handles=setmetatable({},{__mode='k'}),handle_serial=0,policy={},resource_materials={}}
  local metrics={draw_count=0,rebuild_count=0,signature_ms=0,signature_total_ms=0,signature_bytes=0,signature_build_count=0,
    original_icon_available=icon_art~=nil,original_icon_draws=0,original_icon_rectangles=0}
  local function alive(world)
    for _,candidate in ipairs(A.worlds() or {}) do if candidate==world then return true end end
    return false
  end
  function self:clear()
    if self.hover_gui and alive(self.world) then W.destroy_gui(self.world,self.hover_gui) end
    self.hover_gui,self.hover_key=nil,nil
    if self.gui and alive(self.world) then W.destroy_gui(self.world,self.gui) end
    self.gui,self.world,self.signature=nil,nil,nil
    self.render_state=nil
    self.resource_materials={}
    self.regions,self.captures,self.policy,self.page_limits={},{},{},{}
    self.scroll_track,self.scroll_area=nil,nil
  end
  function self:capture(x,y)
    for _,r in ipairs(self.captures) do if inside(r,x,y) then return true end end
    return false
  end
  function self:hit(x,y)
    for _,r in ipairs(self.regions) do if inside(r,x,y) then return r.action end end
    if self:capture(x,y) then return {type='panel_background'} end
  end
  function self:input_policy() return self.policy end
  -- Mouse-over highlight. It lives in its own small GUI so moving the cursor
  -- never rebuilds the panel (a passive page alone is thousands of rects).
  local HOVER={select_passive=true,select_stats=true,select_look=true,edit=true,back=true,cancel=true,
    forward=true,create=true,remove_variant=true,edit_variant=true,open=true,panel_page=true}
  function self:hover(x,y)
    local target
    if self.gui and not self.controller_mode and type(x)=='number'and type(y)=='number'then
      for _,r in ipairs(self.regions)do if inside(r,x,y)then target=r;break end end
      if target and not HOVER[target.action.type]then target=nil end
    end
    local key=target and table.concat({target.x,target.y,target.w,target.h},',')or nil
    if key==self.hover_key and(key==nil or self.hover_gui)then return end
    if self.hover_gui and alive(self.world)then W.destroy_gui(self.world,self.hover_gui)end
    self.hover_gui,self.hover_key=nil,key
    if not target or not alive(self.world)then return end
    local gui=W.create_screen_gui(self.world,'scale',1,1);self.hover_gui=gui
    local t=math.max(1,math.floor(2*(self.scale or 1)+0.5))
    local function linear(c)return math.floor(255*(c/255)^2.2+0.5)end
    local edge=engine.Color(200,linear(255),linear(231),linear(16))
    local wash=engine.Color(22,255,255,255)
    local function box(x0,y0,w,h,c)G.rect(gui,engine.Vector3(x0,y0,989),engine.Vector2(w,h),c)end
    box(target.x,target.y,target.w,target.h,wash)
    box(target.x,target.y,target.w,t,edge);box(target.x,target.y+target.h-t,target.w,t,edge)
    box(target.x,target.y,t,target.h,edge);box(target.x+target.w-t,target.y,t,target.h,edge)
  end
  function self:metrics()
    local copy={};for key,value in pairs(metrics)do copy[key]=value end;return copy
  end
  -- Whether a wheel turn at (x,y) should scroll the option picker.
  function self:scrollable(x,y)
    return self.scroll_area~=nil and (self.scroll_limit or 0)>0 and type(x)=='number'and type(y)=='number'
      and inside(self.scroll_area,x,y)
  end
  local function scroll_options(action)
    local limit,value=self.scroll_limit or 0,self.scroll.options
    if action.type=='panel_scroll'then
      if not number(action.delta)then return false end
      value=value+action.delta
    elseif action.type=='panel_page'then
      if action.delta~=1 and action.delta~=-1 then return false end
      value=value+action.delta*(self.scroll_rows or 1)
    elseif action.type=='panel_scrollbar'then
      local track=self.scroll_track
      if not(track and number(action.y))then return true end -- a release on the bar: nothing more to do
      local travel=math.max(1,track.h-track.thumb)
      local fraction=(track.y+track.h-track.thumb/2-action.y)/travel
      value=math.floor(math.max(0,math.min(1,fraction))*limit+0.5)
    end
    self.scroll.options=math.max(0,math.min(limit,math.floor(value+0.5)))
    return true
  end
  function self:handle(action)
    if type(action)=='table'and action.target=='options'and(action.type=='panel_scroll'
      or action.type=='panel_scrollbar'or action.type=='panel_page')then return scroll_options(action)end
    if type(action)~='table' or action.type~='panel_page' then return false end
    local target=action.target
    if not self.page_limits[target] or (action.delta~=1 and action.delta~=-1) then return false end
    self.pages[target]=math.min(self.page_limits[target],math.max(1,self.pages[target]+action.delta))
    return true
  end
  function self:controller_capacity(view,sample)
    if view.step==1 and view.controller_native_looks then return 9 end
    local width,height=G.resolution();local layout=Layout.resolve(width,height,true)
    local picker=sample and sample.wizard_layout and sample.wizard_layout.picker or layout.picker
    return option_layout(view.step,picker,layout.scale).count
  end
  -- Columns of the picker grid for controller navigation; 1 means a list.
  function self:option_columns(view)
    return view and view.open and view.step==3 and M.PASSIVE_COLUMNS or 1
  end
  function self:draw(sample,view,context)
    metrics.draw_count=metrics.draw_count+1
    context=context or {}
    local preview_icons=context.passive_preview_icons~=false
    local width,height=G.resolution()
    if (sample.kind~='armory'and sample.kind~='deployment') or width<640 or height<480 then self:clear();return false end
    local world
    for _,candidate in ipairs(A.worlds() or {}) do if candidate~=A.main_world() then world=candidate;break end end
    if not world then self:clear();return false end
    local base_layout=Layout.resolve(width,height,view.open)
    local scale=base_layout.scale
    self.scale,self.controller_mode=scale,view.controller_mode==true
    local native_details=not view.open and view.native_details==true
    local native_override=not view.open and view.native_override==true
    local native_override_id=native_override and type(view.native_override_id)=='string'
      and #view.native_override_id>0 and #view.native_override_id<=128
      and not view.native_override_id:find('[%c%s]')and view.native_override_id or nil
    local apply_notice=type(view.apply_notice)=='string'and #view.apply_notice>0 and view.apply_notice
      or not view.open and view.apply_pending==true and 'Loading preview…'or nil
    local equipped=not view.open and view.variant_phase=='equipped'
    local native_apply=not view.open and (native_details or native_override or view.apply_pending==true or apply_notice~=nil)
    local apply_enabled=native_details and view.can_apply==true and view.apply_pending~=true
      and (not native_override or native_override_id~=nil)
    local saved_variant=not view.open and saved_review(view.selected_variant) or nil
    local selected_variant=(view.native_picker~=true and not native_details) and view.apply_pending~=true and saved_variant or nil
    if view.native_picker==true and saved_variant then native_apply=true end
    local prefix
    if not view.open then prefix=sample.native_prefix end
    if prefix~=nil and (type(prefix)~='table' or prefix.verified~=true
      or not valid_rect(prefix.clip,width,height) or type(prefix.headers)~='table'
      or type(prefix.cells)~='table' or #prefix.headers>32 or #prefix.cells>256
      or prefix.original_badges~=nil and(type(prefix.original_badges)~='table'or #prefix.original_badges>256)) then
      self:clear();return false
    end
    local section=not prefix and sample.custom_section or nil
    if section and (not valid_rect(section,width,height) or section.w<350*scale or section.h<100*scale) then
      self:clear();return false
    end
    if not view.open and not section and not prefix and not selected_variant and not native_apply then self:clear();return true end
    local supplied=sample.wizard_layout or {}
    local layout={
      header=supplied.header or base_layout.header,
      picker=supplied.picker or base_layout.picker,
      review=supplied.review or base_layout.review,
      apply=supplied.apply or base_layout.apply,
      footer=supplied.footer or base_layout.footer,
    }
    if view.open then
      for _,r in pairs(layout) do if not valid_rect(r,width,height) then self:clear();return false end end
      if layout.header.w<500*scale or layout.header.h<56*scale
        or layout.picker.w<400*scale or layout.picker.h<280*scale
        or layout.review.w<920*scale or layout.review.h<420*scale
        or layout.apply.w<160*scale or layout.apply.h<44*scale then self:clear();return false end
    elseif selected_variant then
      for _,key in ipairs({'review','apply','footer'})do
        if not valid_rect(layout[key],width,height) then self:clear();return false end
      end
      if layout.review.w<920*scale or layout.review.h<420*scale
        or layout.apply.w<160*scale or layout.apply.h<44*scale then self:clear();return false end
    end
    if native_apply then
      for _,key in ipairs({'apply','footer'})do
        if not valid_rect(layout[key],width,height)then self:clear();return false end
      end
    end
    local native_summary
    if native_apply and not selected_variant and (saved_variant or apply_notice or equipped)then
      local r={x=layout.review.x+16*scale,y=layout.apply.y+2*scale,
        w=layout.apply.x-layout.review.x-32*scale,h=layout.apply.h-4*scale}
      if valid_rect(r,width,height)and r.w>=180*scale and r.h>=44*scale then native_summary=r end
    end
    if self.last_step~=view.step then
      self.pages.options,self.pages.review=1,1
      self.scroll.options=0
      self.last_step=view.step
    end
    local review_request=selected_variant and selected_variant.request or view.selection or {}
    local review_key=stamp({label=selected_variant and (selected_variant.display_name or selected_variant.label) or view.label,
      appearance_id=review_request.appearance_id,stats_id=review_request.stats_id,
      passive_variant_id=review_request.passive_variant_id})
    if self.last_review_key~=review_key then self.pages.review=1;self.last_review_key=review_key end
    local signature_started=os.clock()
    local proof,proof_stamp={},{}
    local function check(spec,thumbnail)
      if type(spec)~='table' or spec.material_pointer~=nil then return false end
      if spec.material_handle~=nil then
        local handle=spec.material_handle
        if spec.native_handle_verified~=true or spec.handle_source~='engine_material'
          or (type(handle)~='userdata' and type(handle)~='cdata') or type(spec.valid)~='function' then return false end
        local ok,value=pcall(spec.valid)
        if not ok or value~=true then return false end
        if not self.handles[handle] then self.handle_serial=self.handle_serial+1;self.handles[handle]=self.handle_serial end
        return true,self.handles[handle]
      end
      return (not thumbnail or spec.verified==true) and resource(spec.material),0
    end
    -- Check borrowed handles before deciding that retained primitives are safe
    -- to reuse. A failed proof destroys their previous GUI in this same draw.
    local function remember(spec,thumbnail)
      if type(spec)~='table' then return end
      local ok,token=check(spec,thumbnail)
      proof[spec]=ok;proof_stamp[#proof_stamp+1]={ok,token}
    end
    local function image_signature(spec,thumbnail)
      if type(spec)~='table'then return false end
      remember(spec,thumbnail)
      local uv=type(spec.uv)=='table'and {spec.uv[1],spec.uv[2],spec.uv[3],spec.uv[4]}or nil
      return {material=resource(spec.material)and spec.material or false,uv=uv,has_uv=spec.uv~=nil,
        has_texture=spec.texture~=nil,verified=spec.verified==true,
        native_handle_verified=spec.native_handle_verified==true,engine_handle_source=spec.handle_source=='engine_material',
        has_pointer=spec.material_pointer~=nil,has_handle=spec.material_handle~=nil}
    end
    local function icon_signature(passive_id,hash,resource_only)
      if icon_art and icon_art:has(hash)then return {original_icon=hash:lower()}end
      if resource_only then return {material=hash}end
      local spec=context.passive_icons and context.passive_icons[passive_id]or {material=hash}
      return image_signature(spec,false)
    end
    local function caption_signature(field,key)
      local names=context.labels and context.labels[field]
      return key and (names and names[key]or key)or 'Not selected'
    end
    local function tuple_signature(values)
      local out={}
      for _,field in ipairs(STAT_FIELDS)do out[field]=values and values[field]end
      return out
    end
    local function page_signature(target,pages)
      self.pages[target]=math.min(pages,math.max(1,self.pages[target]))
      return {page=self.pages[target],pages=pages}
    end
    -- Project only fields that this draw uses. In particular, the complete
    -- catalog's body weights, modifier definitions and offscreen previews do
    -- not belong in a per-frame retained-GUI signature.
    local rendered={width=width,height=height,font=sample.font,material=sample.material,atlas=sample.atlas}
    if prefix then
      local saved,add={},nil
      for _,tile in ipairs((view.section or {}).tiles or {})do
        if tile.kind=='variant'then saved[tile.label]=tile elseif tile.kind=='add'then add=tile end
      end
      local visible={clip=prefix.clip,headers={},cells={},original_badges={}}
      if type(prefix.category)=='table'and prefix.category.text=='CUSTOM VARIANTS'
        and valid_rect(prefix.category.rect,width,height)then visible.category=prefix.category end
      for _,cell in ipairs(preview_icons and prefix.original_badges or {})do
        local r=type(cell)=='table'and prefix_cell_rect(cell,prefix.clip,width,height,scale)
        local passive=type(cell)=='table'and type(cell.passive)=='table'and cell.passive or {}
        if r and grid_perk(passive)then visible.original_badges[#visible.original_badges+1]={badge=badge_rect(cell,r,scale),
          icon=grid_perk(passive)and(resource(passive.icon_hash)and passive.icon_hash or passive.material)or nil}end
      end
      for _,header in ipairs(prefix.headers)do
        local r=type(header)=='table'and header.rect
        if type(header)=='table'and header.text=='Custom Variant'and contained(r,prefix.clip,width,height)
          and r.w>=180*scale and r.h>=24*scale then visible.headers[#visible.headers+1]={rect=r,text=header.text}end
      end
      for _,cell in ipairs(prefix.cells)do
        local tile=type(cell)=='table'and (cell.kind=='create'and add or cell.kind=='variant'and saved[cell.label])
        local r,partial,visible_rect
        if tile and type(cell.key)=='string'and #cell.key>0 and #cell.key<=256 then
          r,partial,visible_rect=prefix_cell_rect(cell,prefix.clip,width,height,scale)
        end
        if r then
          local passive=type(cell.passive)=='table'and cell.passive or {}
          visible.cells[#visible.cells+1]={rect=r,visible_rect=visible_rect,
            badge=preview_icons and grid_perk(passive,tile.request and tile.request.passive_variant_id)and cell.kind=='variant'and badge_rect(cell,r,scale)or nil,
            partial=partial,kind=cell.kind,label=cell.label,display_name=tile.display_name,selected=cell.selected,
            enabled=tile.enabled,icon=grid_perk(passive,tile.request and tile.request.passive_variant_id)and(resource(passive.icon_hash)and passive.icon_hash or passive.material)or nil}
        end
      end
      rendered.prefix=visible
    elseif not view.open and section then
      local tiles=(view.section or {}).tiles or {}
      local columns=math.max(1,math.floor(section.w/(146*scale)))
      local pages=math.max(1,math.ceil(#tiles/columns))
      local visible={rect=section,paging=page_signature('section',pages),tiles={}}
      for index=(self.pages.section-1)*columns+1,math.min(#tiles,self.pages.section*columns)do
        local tile=tiles[index]
        visible.tiles[#visible.tiles+1]={kind=tile.kind,label=tile.label,display_name=tile.display_name,enabled=tile.enabled,action=tile.action,
          preview=tile.kind~='add'and image_signature(tile.preview,true)or nil,
          icon=preview_icons and grid_perk((context.passive_variants or {})[tile.request and tile.request.passive_variant_id],tile.request and tile.request.passive_variant_id)and tile.kind~='add'and icon_signature(tile.request and tile.request.passive_variant_id,tile.icon_hash)or nil}
      end
      rendered.section=visible
    elseif view.open then
      local visible={step=view.step,step_number=view.step_number,step_count=view.step_count,
        controller_mode=view.controller_mode,controller_native_looks=view.controller_native_looks,controller_notice=view.controller_notice,controller_focus=view.controller_focus,controller_page=view.controller_page,
        stats_follow_look=view.stats_follow_look,title=view.title,header=layout.header,can_back=view.can_back,can_cancel=view.can_cancel,
        subtitle=view.subtitle,can_forward=view.can_forward,
        empty_options_notice=view.empty_options_notice}
      if view.step~=1 or view.controller_mode and not view.controller_native_looks then
        local options=view.options or {}
        local grid=option_layout(view.step,layout.picker,scale)
        local limit=math.max(0,math.ceil(#options/grid.columns)-grid.rows)
        -- A controller's focused option is always scrolled into view.
        if view.controller_mode and number(view.controller_index)then
          local row=math.floor((view.controller_index-1)/grid.columns)
          if row<self.scroll.options then self.scroll.options=row
          elseif row>=self.scroll.options+grid.rows then self.scroll.options=row-grid.rows+1 end
        end
        self.scroll.options=math.max(0,math.min(limit,self.scroll.options))
        self.scroll_limit,self.scroll_rows=limit,grid.rows
        local first=self.scroll.options*grid.columns
        visible.picker=layout.picker;visible.paging={scroll=self.scroll.options,limit=limit};visible.options={}
        for index=first+1,math.min(#options,first+grid.count)do
          local item=options[index]
          if view.step==1 then
            visible.options[#visible.options+1]={action=item.action,label=item.label,preview=image_signature(item.preview,true)}
          elseif view.step==2 then
            visible.options[#visible.options+1]={action=item.action,selected=item.selected,label=item.label,base=tuple_signature(item.base_values)}
          else
            -- Tiles draw no effect text; the review panel tracks the selected passive.
            visible.options[#visible.options+1]={action=item.action,selected=item.selected,label=item.label,
              icon=icon_signature(item.id,item.icon_hash)}
          end
        end
      end
      rendered.wizard=visible
    end
    if view.open or selected_variant then
      local selected=selected_variant and selected_variant.request or view.selection or {}
      local profile=context.stats_profiles and context.stats_profiles[selected.stats_id]
      local base=type(profile)=='table'and profile.base_only==true and profile.base_values_verified==true
        and type(profile.base_values)=='table'and profile.base_values or {}
      local passive=context.passive_variants and context.passive_variants[selected.passive_variant_id]or {}
      local name=caption_signature('passive_variant_id',selected.passive_variant_id)
      if name==selected.passive_variant_id and type(passive.name)=='string'then name=passive.name end
      local lines=effect_lines(passive.effects,passive_frame_width(layout.review,scale,context),scale)
      local per=M.REVIEW_LINES
      local visible={rect=layout.review,apply=layout.apply,footer=layout.footer,creating=view.open,
        label=selected_variant and (selected_variant.display_name or selected_variant.label) or view.label,
        look=caption_signature('appearance_id',selected.appearance_id),base=tuple_signature(base),passive_name=name,
        icon=icon_signature(selected.passive_variant_id,passive.icon_hash,not view.open),
        paging=page_signature('review',math.max(1,math.ceil(#lines/per))),lines={}}
      for index=(self.pages.review-1)*per+1,math.min(#lines,self.pages.review*per)do visible.lines[#visible.lines+1]=lines[index]end
      if view.open then visible.notice=view.notice;visible.saving=view.saving;visible.can_create=view.can_create
        visible.editing=view.editing;visible.edit=view.edit;visible.editing_variant=view.editing_variant
      else visible.notice=view.apply_notice end
      rendered.review=visible
    end
    if native_apply then
      rendered.native_apply={apply=layout.apply,footer=layout.footer,native_details=native_details,
        enabled=apply_enabled,native_override=native_override,native_override_id=native_override_id,equipped=equipped,
        label=saved_variant and saved_variant.label,can_remove=view.can_remove,can_edit=view.can_edit,
        summary=native_summary,notice=apply_notice,
        look=native_summary and saved_variant and caption_signature('appearance_id',saved_variant.request.appearance_id)or nil}
    end
    local ko=korean(context)
    local render_state={rendered,proof_stamp,preview_icons,ko}
    local unchanged=self.signature~=nil and self.world==world and same_display(self.render_state,render_state)
    local signature=self.signature
    if not unchanged then
      signature=stamp(render_state)
      metrics.signature_build_count=metrics.signature_build_count+1
    end
    metrics.signature_ms=(os.clock()-signature_started)*1000
    metrics.signature_total_ms=metrics.signature_total_ms+metrics.signature_ms
    metrics.signature_bytes=#signature
    if self.signature==signature and self.world==world then
      if not unchanged then self.render_state=retain_display(render_state)end
      return true
    end
    self:clear();self.world=world
    self.gui=assert(W.create_screen_gui(world,'scale',1,1))
    metrics.rebuild_count=metrics.rebuild_count+1
    local gui,id=self.gui,engine.IdString64.from_hex
    local font,material=id(sample.font),id(sample.material)
    local ink=assert(G.material(gui,material))
    local function parameter(hash)return id(hash..'00000000')end
    for _,hash in ipairs({'8035c266','5e8455fe','309e7783','82b803a8'}) do engine.Material.set_scalar(ink,parameter(hash),0) end
    engine.Material.set_vector2(ink,parameter('e13777ce'),engine.Vector2(1,-1))
    engine.Material.set_vector4(ink,parameter('7701209e'),engine.Color(0,0,0,0))
    engine.Material.set_texture(ink,parameter('88bac99b'),id(sample.atlas))
    -- Screen GUI colours are linear: author them in sRGB like the native UI,
    -- otherwise dark fills wash out to slate and the yellow turns pale.
    local function linear(c)return math.floor(255*(c/255)^2.2+0.5)end
    local function srgb(r,g,b,a)return engine.Color(a or 255,linear(r),linear(g),linear(b))end
    local gold,white,muted=srgb(255,231,16),srgb(236,236,236),srgb(150,156,162)
    local palette={
      panel=srgb(13,15,18),tile=srgb(27,31,35),selected=srgb(58,52,8),hover=srgb(36,40,45),
      line=srgb(205,205,205,150),line_strong=srgb(225,225,225),track=srgb(64,68,72),
      button=srgb(31,34,38),disabled=srgb(22,24,27),primary=srgb(52,47,6),done=srgb(140,126,14),
    }
    local function rect(r,c,layer)G.rect(gui,engine.Vector3(r.x,r.y,layer or 980),engine.Vector2(r.w,r.h),c)end
    local function L(value)
      value=tostring(value or '')
      if not ko then return value end
      if M.KO[value]then return M.KO[value]end
      local number_suffix=value:match('^Custom Variant (%d+)$')
      return number_suffix and ('커스텀 변형 '..number_suffix)or value
    end
    local function text(value,x,y,size,c,layer)
      G.text(gui,L(value),font,size*scale,material,engine.Vector3(x,y,layer or 984),c or white)
    end
    -- Text width measured on this GUI when the engine allows, otherwise
    -- estimated (Hangul glyphs are about twice as wide as Latin ones).
    local function extent(value,size)
      value=L(value)
      if type(G.text_extents)=='function'then
        -- Native min/max results are engine vectors (userdata), not tables.
        local ok,width=pcall(function()
          local minimum,maximum=G.text_extents(gui,value,font,size*scale)
          local measured=maximum.x-minimum.x
          return number(measured)and measured>=0 and measured or nil
        end)
        if ok and width then return width end
      end
      local units=0
      for _,char in ipairs(chars(value))do units=units+(char:byte()>=0xE3 and 1.7 or 1)end
      return units*size*scale*0.58
    end
    local function centered(value,cx,y,size,c)text(value,cx-extent(value,size)/2,y,size,c)end
    local function frame(r,c,t,layer)
      t=t or scale
      rect({x=r.x,y=r.y,w=r.w,h=t},c,layer or 982);rect({x=r.x,y=r.y+r.h-t,w=r.w,h=t},c,layer or 982)
      rect({x=r.x,y=r.y,w=t,h=r.h},c,layer or 982);rect({x=r.x+r.w-t,y=r.y,w=t,h=r.h},c,layer or 982)
    end
    -- Corner brackets like the native item cards.
    local function corners(r,c,length,t,layer)
      length,t=length*scale,(t or 2)*scale
      for _,corner in ipairs({{r.x,r.y,1,1},{r.x+r.w,r.y,-1,1},{r.x,r.y+r.h,1,-1},{r.x+r.w,r.y+r.h,-1,-1}})do
        local x,y,sx,sy=corner[1],corner[2],corner[3],corner[4]
        rect({x=sx>0 and x or x-length,y=sy>0 and y or y-t,w=length,h=t},c,layer or 983)
        rect({x=sx>0 and x or x-t,y=sy>0 and y or y-length,w=t,h=length},c,layer or 983)
      end
    end
    local function dashes(x,y,length,vertical,c)
      local dash,gap,t=9*scale,6*scale,2*scale
      local at=0
      while at<length do
        local piece=math.min(dash,length-at)
        if vertical then rect({x=x,y=y+at,w=t,h=piece},c,982)else rect({x=x+at,y=y,w=piece,h=t},c,982)end
        at=at+dash+gap
      end
    end
    -- A native "통계 ———" box: dashed outline whose top edge is broken by its title.
    -- note: optional caption at the top-right ('Click to change' / 'Choosing').
    local function titled_frame(r,title,c,note)
      local size=19
      c=c or palette.line
      local title_w=extent(title,size)
      local top=r.y+r.h
      text(title,r.x+14*scale,top-size*scale*0.45,size,c==gold and gold or white)
      local note_w=note and extent(note,13)+24*scale or 0
      dashes(r.x,top,10*scale,false,c)
      dashes(r.x+title_w+26*scale,top,math.max(0,r.w-title_w-26*scale-note_w),false,c)
      if note then text(note,r.x+r.w-note_w+12*scale,top-13*scale*0.4,13,c==gold and gold or muted)end
      dashes(r.x,r.y,r.w,false,c)
      dashes(r.x,r.y,r.h,true,c)
      dashes(r.x+r.w-2*scale,r.y,r.h,true,c)
    end
    -- Ten-segment gauge, filled in proportion to value/maximum.
    local function gauge(x,y,value,maximum,segment,height,gap)
      local filled=number(value)and value>0 and math.max(1,math.min(10,math.floor(value/maximum*10+0.5)))or 0
      for index=1,10 do
        rect({x=x+(index-1)*(segment+gap)*scale,y=y,w=segment*scale,h=height*scale},index<=filled and white or palette.track,983)
      end
    end
    local function capture(r)self.captures[#self.captures+1]=r end
    local function action(r,value,enabled)
      if enabled~=false then self.regions[#self.regions+1]={x=r.x,y=r.y,w=r.w,h=r.h,action=value}end
      local focus=view.controller_mode and view.controller_focus
      if enabled~=false and focus and focus.type==value.type and focus.id==value.id and focus.target==value.target
        and focus.name==value.name and focus.delta==value.delta and focus.button==value.button then
        local t=3*scale
        rect({x=r.x,y=r.y,w=r.w,h=t},gold,988);rect({x=r.x,y=r.y+r.h-t,w=r.w,h=t},gold,988)
        rect({x=r.x,y=r.y,w=t,h=r.h},gold,988);rect({x=r.x+r.w-t,y=r.y,w=t,h=r.h},gold,988)
      end
    end
    -- Outlined native-style button; the primary action is yellow-framed.
    local function button(r,title,value,enabled,primary)
      local on=enabled~=false
      local size=math.min(primary and 22 or 16,r.h/scale*0.55)
      rect(r,on and(primary and palette.primary or palette.button)or palette.disabled,982)
      frame(r,on and(primary and gold or palette.line_strong)or palette.line,(primary and 2 or 1)*scale,983)
      centered(title,r.x+r.w/2,r.y+(r.h-size*scale)/2,size,on and(primary and gold or white)or muted)
      action(r,value,enabled)
    end
    local function image(spec,r,thumbnail,bounds)
      if type(spec)~='table' or not check(spec,thumbnail) then return false end
      local layer=thumbnail and 982 or 985
      local uv=spec.uv
      if bounds then
        local visible=intersection(r,bounds)
        if not visible then return true end
        if visible.x~=r.x or visible.y~=r.y or visible.w~=r.w or visible.h~=r.h then
          if uv~=nil and not valid_uv(uv)then return false end
          local source=uv or {0,0,1,1}
          local u,v=source[3]-source[1],source[4]-source[2]
          -- Bitmap UVs use top-left texture coordinates while GUI rectangles
          -- use bottom-left viewport coordinates.
          uv={source[1]+(visible.x-r.x)/r.w*u,source[2]+(r.y+r.h-visible.y-visible.h)/r.h*v,
            source[1]+(visible.x+visible.w-r.x)/r.w*u,source[2]+(r.y+r.h-visible.y)/r.h*v}
          r=visible
        end
      end
      local ok,drawn=pcall(function()
        if spec.material_handle then
          if proof[spec]~=true or not valid_uv(uv) or type(G.bitmap_uv)~='function' then return false end
          G.bitmap_uv(gui,spec.material_handle,engine.Vector2(uv[1],uv[2]),engine.Vector2(uv[3],uv[4]),
            engine.Vector3(r.x,r.y,layer),engine.Vector2(r.w,r.h),white)
        else
          if type(A.can_get)~='function' or not A.can_get('material',id(spec.material)) or type(G.bitmap)~='function' then return false end
          -- Resource thumbnails must be an independently verified ready-to-use
          -- material. Texture rebinding and foreign native atlas pointers are
          -- intentionally outside this renderer's contract.
          if spec.texture~=nil then return false end
          local handle=self.resource_materials[spec.material]
          if not handle then
            handle=G.material(gui,id(spec.material))
            -- HD2's live Gui.material returns engine Material userdata. Pass
            -- that ORIGINAL value to bitmap, never the resource IdString64,
            -- an integer address, cdata pointer, or a fabricated wrapper.
            if type(handle)~='userdata' then return false end
            self.resource_materials[spec.material]=handle
          end
          if uv then
            if not valid_uv(uv) or type(G.bitmap_uv)~='function' then return false end
            G.bitmap_uv(gui,handle,engine.Vector2(uv[1],uv[2]),engine.Vector2(uv[3],uv[4]),
              engine.Vector3(r.x,r.y,layer),engine.Vector2(r.w,r.h),white)
          else G.bitmap(gui,handle,engine.Vector3(r.x,r.y,layer),engine.Vector2(r.w,r.h),white) end
        end
        return true
      end)
      return ok and drawn==true
    end
    local function icon(passive_id,hash,r,resource_only,bounds)
      if icon_art and icon_art:has(hash)then
        -- The art is 32px pixel art: draw it at a whole multiple on whole
        -- pixels so every source pixel stays square and edges stay sharp.
        local k=math.floor(math.min(r.w,r.h)/32)
        if k>=1 then
          local size=32*k
          r={x=math.floor(r.x+(r.w-size)/2+0.5),y=math.floor(r.y+(r.h-size)/2+0.5),w=size,h=size}
        end
        local result=icon_art:draw(gui,hash,r,985,{255,205,1,255},bounds,true)
        if result then
          metrics.original_icon_draws=metrics.original_icon_draws+1
          metrics.original_icon_rectangles=metrics.original_icon_rectangles+result.rectangles
          return true
        end
      end
      local spec=not resource_only and context.passive_icons and context.passive_icons[passive_id]or {material=hash}
      if image(spec,r,false,bounds)then return true end
      if not bounds or contained(r,bounds,width,height)then
        text('?',r.x+r.w/3,r.y+r.h/4,math.min(16,r.h/scale*.7),muted)
      end
      return false
    end
    local function pager(target,r,count)
      self.page_limits[target]=math.max(1,count)
      self.pages[target]=math.min(self.page_limits[target],math.max(1,self.pages[target]))
      if count<=1 then return end
      local page=self.pages[target]
      button({x=r.x,y=r.y,w=34*scale,h=28*scale},'<',{type='panel_page',target=target,delta=-1},page>1)
      text(page..' / '..count,r.x+43*scale,r.y+7*scale,13,muted)
      button({x=r.x+101*scale,y=r.y,w=34*scale,h=28*scale},'>',{type='panel_page',target=target,delta=1},page<count)
    end
    local function caption(field,key)
      local names=context.labels and context.labels[field]
      return key and (names and names[key] or key) or 'Not selected'
    end
    -- Laid out like the game's own armor details: a yellow-barred title block,
    -- then dashed "stats" and "passive" boxes, then the primary action.
    local function review(label,selected,creating)
      capture(layout.review);rect(layout.review,palette.panel)
      capture(layout.apply);rect(layout.apply,palette.panel)
      capture(layout.footer);rect(layout.footer,srgb(0,0,0))
      local r=layout.review
      -- Top-down offsets: y of a size-s line whose top is `o` below the panel top.
      local function at(o,s)return r.y+r.h-(o+s)*scale end
      local left=r.x+20*scale
      rect({x=left,y=at(22,74),w=4*scale,h=74*scale},gold,983)
      text(creating and 'CUSTOM VARIANT' or 'Saved variant',left+16*scale,at(22,15),15,muted)
      text(clip(L(label or 'New variant'),52),left+16*scale,at(42,28),28,white)
      -- While creating, the look line and both boxes open their section.
      local edit=creating and type(view.edit)=='table'and view.edit or {}
      local section=creating and view.editing
      local function note(name)
        if section==name then return 'Choosing'end
        if edit[name]then return 'Click to change'end
      end
      local look_label=L('LOOK')
      local look_name=clip(caption('appearance_id',selected.appearance_id),70)
      local look_x=left+16*scale+extent(look_label,16)+12*scale
      text(look_label,left+16*scale,at(80,16),16,section=='look'and gold or muted)
      text(look_name,look_x,at(80,16),16,section=='look'and gold or white)
      if edit.look and section~='look'then
        local hint_x=look_x+extent(look_name,16)+16*scale
        text('Click to change',hint_x,at(82,13),13,muted)
        action({x=left,y=at(84,24),w=hint_x+extent('Click to change',13)-left+8*scale,h=24*scale},{type='edit',section='look'})
      end
      if creating and view.step==1 then
        text(view.controller_mode and 'D-pad / left stick: choose a look. A: select.' or view.stats_follow_look and (context.category and context.category~=0 and 'Choose an owned thumbnail to use its look.' or 'Choose owned armor to use its look and base stats.') or 'Choose an owned thumbnail to use its look.',left+16*scale,at(108,16),16,gold)
      end
      local profile=context.stats_profiles and context.stats_profiles[selected.stats_id]
      local base=type(profile)=='table' and profile.base_only==true and profile.base_values_verified==true
        and type(profile.base_values)=='table' and profile.base_values or {}
      local frame_top,frame_bottom=150,360
      local frame_w=passive_frame_width(r,scale,context)
      local passive_x=left
      if not context.category or context.category==0 then
        local box={x=left,y=at(frame_bottom,0),w=frame_w,h=(frame_bottom-frame_top)*scale}
        titled_frame(box,'BASE STATS',section=='stats'and gold or nil,note('stats'))
        if edit.stats and section~='stats'then action(box,{type='edit',section='stats'})end
        for index,field in ipairs(STAT_FIELDS)do
          local o=182+(index-1)*44
          text(STAT_LABELS[index],box.x+18*scale,at(o,19),19,white)
          gauge(box.x+box.w-170*scale,at(o+2,16),base[field],STAT_MAX[field],5,16,3)
          text(stat_text(base[field]),box.x+box.w-74*scale,at(o-1,21),21,white)
        end
        passive_x=left+frame_w+20*scale
      end
      local passive=context.passive_variants and context.passive_variants[selected.passive_variant_id] or {}
      local pbox={x=passive_x,y=at(frame_bottom,0),w=frame_w,h=(frame_bottom-frame_top)*scale}
      titled_frame(pbox,'PASSIVE',section=='passive'and gold or nil,note('passive'))
      if edit.passive and section~='passive'then action(pbox,{type='edit',section='passive'})end
      local badge={x=pbox.x+16*scale,y=at(176,32),w=32*scale,h=32*scale}
      local chosen=selected.passive_variant_id~=nil
      if chosen then icon(selected.passive_variant_id,passive.icon_hash,badge,not creating)end
      local passive_name=caption('passive_variant_id',selected.passive_variant_id)
      if passive_name==selected.passive_variant_id and type(passive.name)=='string' then passive_name=passive.name end
      local per=M.REVIEW_LINES
      local lines=effect_lines(passive.effects,pbox.w,scale)
      local pages=math.max(1,math.ceil(#lines/per));self.pages.review=math.min(pages,math.max(1,self.pages.review))
      -- Long descriptions page in place; the pager sits beside the name.
      local name_room=pbox.w/scale-80-(pages>1 and 150 or 0)
      text(clip(L(passive_name),math.max(8,math.floor(name_room/(20*0.56)))),
        pbox.x+(chosen and 60 or 18)*scale,at(182,20),20,chosen and white or muted)
      for index=1,per do
        local line=lines[(self.pages.review-1)*per+index]
        if line then text(line,pbox.x+18*scale,at(218+(index-1)*19,15),15,white)end
      end
      pager('review',{x=pbox.x+pbox.w-147*scale,y=at(172,28)},pages)
      local note=creating and (view.notice or (view.editing_variant and 'Save replaces this variant with your changes.'
          or 'Create saves this variant. Your equipped armor stays unchanged.'))
        or (type(view.apply_notice)=='string'and view.apply_notice or (sample.kind=='deployment'and 'Choose a saved variant.'or 'Choose another card or + to create a variant.'))
      local room=(layout.apply.x-left-24*scale)/scale
      text(clip(L(note),math.max(20,math.floor(room/(14*0.56)))),left,at(404,14),14,muted)
      if creating then button(layout.apply,view.saving and 'Saving...' or (view.editing_variant and 'Save' or 'Create'),{type='create'},view.can_create,true)end
    end
    self.page_limits={}
    if prefix then
      local saved,add={},nil
      for _,tile in ipairs((view.section or {}).tiles or {})do
        if tile.kind=='variant' then saved[tile.label]=tile elseif tile.kind=='add' then add=tile end
      end
      local function fitted(value,r,size,padding)
        local clean=tostring(value or ''):gsub('%c',' ')
        local available=r.w-padding*scale
        local function fallback()
          local count=math.floor((r.w/scale-padding)/(size*.8))
          return clip(clean,math.max(1,count-3))
        end
        if type(G.text_extents)~='function'then return fallback()end
        local function measure(text)
          local ok,width=pcall(function()
            -- Observed native Lua contract: first two results are min/max
            -- vectors. Measure on this owned GUI with its actual font/size.
            local minimum,maximum=G.text_extents(gui,text,font,size*scale)
            local left,right=minimum.x,maximum.x
            if not number(left)or not number(right)or right<left then return nil end
            local extent=right-left
            return number(extent)and extent or nil
          end)
          return ok and width or nil
        end
        local width=measure(clean)
        if not width then return fallback()end
        if width<=available then return clean end
        local dots=measure('...')
        if not dots then return fallback()end
        if dots>available then return ''end
        local characters=chars(clean)
        local low,high,best=0,#characters-1,'...'
        while low<=high do
          local count=math.floor((low+high)/2)
          local candidate=table.concat(characters,'',1,count)..'...'
          local measured=measure(candidate)
          if not measured then return fallback()end
          if measured<=available then best=candidate;low=count+1 else high=count-1 end
        end
        return best
      end
      if rendered.prefix.category then
        local category=rendered.prefix.category;local r=category.rect
        rect(r,palette.panel);text(category.text,r.x+16*scale,r.y+(r.h-20*scale)/2,20,gold)
      end
      for _,cell in ipairs(rendered.prefix.original_badges)do
        local visible=intersection(cell.badge,prefix.clip)
        if visible then rect(visible,palette.panel,983);icon(nil,cell.icon,cell.badge,true,prefix.clip)end
      end
      for _,header in ipairs(prefix.headers)do
        local r=type(header)=='table' and header.rect
        if type(header)=='table' and header.text=='Custom Variant'
          and contained(r,prefix.clip,width,height) and r.w>=180*scale and r.h>=24*scale then
          capture(r);rect(r,palette.panel)
          local size=math.min(20,r.h/scale-8,(r.w/scale-16)/(14*.8))
          text('Custom Variant',r.x+8*scale,r.y+(r.h-size*scale)/2,size,gold)
        end
      end
      for _,cell in ipairs(prefix.cells)do
        local tile=type(cell)=='table' and (cell.kind=='create' and add or cell.kind=='variant' and saved[cell.label])
        local r,partial,visible
        if tile and type(cell.key)=='string'and #cell.key>0 and #cell.key<=256 then
          r,partial,visible=prefix_cell_rect(cell,prefix.clip,width,height,scale)
        end
        if r then
          capture(visible)
          if partial and cell.kind=='create' then
            -- The native placeholder must never show through while scrolling.
            -- Keep its plus at the original card center while clipping.
            rect(visible,palette.panel)
            local plus={x=r.x+r.w/2-12*scale,y=r.y+r.h/2-8*scale,w=36*scale,h=36*scale}
            if visible.w>=52*scale and visible.h>=52*scale and contained(plus,prefix.clip,width,height)then
              text('+',plus.x,plus.y,36,tile.enabled and gold or muted)
            end
          elseif cell.kind=='create' then
            rect(r,palette.tile);corners(r,palette.line_strong,16)
            centered('+',r.x+r.w/2,r.y+r.h/2-6*scale,44,tile.enabled and gold or muted)
            centered(fitted(L('Create variant'),r,15,16),r.x+r.w/2,r.y+18*scale,15,tile.enabled and white or muted)
            action(r,{type='open'},tile.enabled==true)
          else
            local name={x=r.x,y=r.y,w=r.w,h=math.min(34*scale,r.h*.3)}
            local visible_name=intersection(name,prefix.clip)
            if visible_name then
              rect(visible_name,palette.panel)
              if contained(name,prefix.clip,width,height)then
                local caption=tile.display_name or cell.label
                local fit=fitted(caption,name,13,12)
                local look,perk=caption:match('^(.-) %- (.+)$')
                if fit~=caption and look and perk then
                  text(fitted(look,name,13,12),name.x+6*scale,name.y+18*scale,13,tile.enabled and white or muted)
                  text(fitted('- '..perk,name,13,12),name.x+6*scale,name.y+3*scale,13,tile.enabled and white or muted)
                else text(fit,name.x+6*scale,name.y+(name.h-13*scale)/2,13,tile.enabled and white or muted)end
              end
              if cell.selected==true then
                local line=intersection({x=name.x,y=name.y,w=name.w,h=2*scale},prefix.clip)
                if line then rect(line,gold,983)end
              end
            end
            local badge=badge_rect(cell,r,scale)
            local visible_badge=intersection(badge,prefix.clip)
            local passive=type(cell.passive)=='table' and cell.passive or {}
            local hash=resource(passive.icon_hash) and passive.icon_hash or passive.material
            -- Construct a resource-only descriptor. Never pass foreign handle,
            -- pointer, texture, valid(), or preview metadata to the image path.
            if preview_icons and grid_perk(passive,tile.request and tile.request.passive_variant_id)and visible_badge then
              rect(visible_badge,palette.panel,983)
              icon(nil,hash,badge,true,prefix.clip)
            end
            action(visible,{type='select_variant',label=cell.label},not partial and tile.enabled==true)
          end
        end
      end
      self.policy={native_look_pick=false,block_native_apply=false,block_native_compare=false,
        native_prefix=true,custom_cells_require_interception=true}
    elseif not view.open and section then
      capture(section);rect(section,palette.panel)
      text('Custom Variant',section.x+8*scale,section.y+section.h-27*scale,20,gold)
      local tiles=(view.section or {}).tiles or {}
      local columns=math.max(1,math.floor(section.w/(146*scale)))
      local pages=math.max(1,math.ceil(#tiles/columns))
      self.pages.section=math.min(pages,math.max(1,self.pages.section))
      local gap=7*scale
      local card_width=(section.w-gap*(columns-1))/columns
      local card_height=math.max(20*scale,section.h-42*scale)
      for slot=1,columns do
        local tile=tiles[(self.pages.section-1)*columns+slot]
        if tile then
          local r={x=section.x+(slot-1)*(card_width+gap),y=section.y+5*scale,w=card_width,h=card_height}
          rect(r,palette.tile);frame(r,palette.line);action(r,tile.action,tile.enabled)
          if tile.kind=='add' then
            text('+',r.x+r.w/2-12*scale,r.y+r.h/2,36,tile.enabled and gold or muted)
            text('Create variant',r.x+8*scale,r.y+10*scale,13,tile.enabled and white or muted)
          else
            local ready=image(tile.preview,{x=r.x+4*scale,y=r.y+34*scale,w=r.w-8*scale,h=math.max(1,r.h-38*scale)},true)
            if not ready then text('Saved look',r.x+8*scale,r.y+r.h/2,13,muted)end
            text(clip(tile.display_name or tile.label,math.max(8,math.floor(card_width/(7*scale))-2)),r.x+6*scale,r.y+12*scale,14,tile.enabled and white or muted)
            local badge={x=r.x+r.w-31*scale,y=r.y+r.h-31*scale,w=25*scale,h=25*scale}
            if preview_icons and grid_perk((context.passive_variants or {})[tile.request and tile.request.passive_variant_id],tile.request and tile.request.passive_variant_id)then
              rect(badge,palette.panel,983)
              icon(tile.request and tile.request.passive_variant_id,tile.icon_hash,badge)
            end
          end
        end
      end
      pager('section',{x=section.x+section.w-140*scale,y=section.y+section.h-31*scale},pages)
      self.policy={native_look_pick=false,block_native_apply=false,block_native_compare=false}
    elseif view.open then
      capture(layout.header);rect(layout.header,palette.panel)
      local header=layout.header
      rect({x=header.x,y=header.y,w=header.w,h=scale},palette.line,981)
      -- Step progress: one segment per visible stage, current one in yellow.
      local steps=math.max(1,math.min(6,tonumber(view.step_count)or 3))
      local current=tonumber(view.step_number or view.step)or 1
      for index=1,steps do
        rect({x=header.x+12*scale+(index-1)*34*scale,y=header.y+header.h-13*scale,w=30*scale,h=4*scale},
          index==current and gold or index<current and palette.done or palette.track,983)
      end
      text(current..' / '..steps,header.x+(18+steps*34)*scale,header.y+header.h-17*scale,12,muted)
      text(view.controller_notice or view.title or 'Create variant',header.x+12*scale,header.y+9*scale,21,white)
      -- Back · Forward · Cancel.
      button({x=header.x+header.w-256*scale,y=header.y+12*scale,w=76*scale,h=32*scale},'Back',{type='back'},view.can_back)
      local forward={x=header.x+header.w-172*scale,y=header.y+12*scale,w=76*scale,h=32*scale}
      button(forward,'Forward',{type='forward'},view.can_forward==true)
      button({x=header.x+header.w-88*scale,y=header.y+12*scale,w=80*scale,h=32*scale},'Cancel',{type='cancel'},view.can_cancel)
      -- The subtitle shares the header line with the buttons; a note that would
      -- run under them moves to the picker footer instead.
      local footer_note
      if view.subtitle then
        local x=layout.header.x+190*scale
        local buttons=layout.header.x+layout.header.w-256*scale
        if #chars(view.subtitle)*12*0.62*scale<=buttons-x-8*scale or view.controller_mode then
          text(clip(view.subtitle,math.max(4,math.floor((buttons-x-8*scale)/(12*0.62*scale)))),x,layout.header.y+34*scale,12,muted)
        else footer_note=view.subtitle end
      end
      if view.step~=1 or view.controller_mode and not view.controller_native_looks then
        capture(layout.picker);rect(layout.picker,palette.panel)
        local options=view.options or {}
        local grid=option_layout(view.step,layout.picker,scale)
        local count=grid.count
        local limit=self.scroll_limit or 0
        local first=self.scroll.options*grid.columns
        self.scroll_area=layout.picker
        if view.step==2 then
          -- One shared column header instead of a label block in every row.
          local labelled=false
          for _,item in ipairs(options)do if item.base_values then labelled=true;break end end
          if labelled then
            for index in ipairs(STAT_FIELDS)do
              text(STAT_LABELS[index],layout.picker.x+17*scale+(index-1)*(layout.picker.w-34*scale)/3,
                layout.picker.y+layout.picker.h-22*scale,13,muted)
            end
          end
        end
        for slot=1,count do
          local item=options[first+slot]
          if item then
            local r=option_rect(grid,layout.picker,slot,scale)
            rect(r,item.selected and palette.selected or palette.tile)
            action(r,item.action)
            if item.selected then frame(r,gold,2*scale,983)
            elseif grid.grid then frame(r,palette.line);corners(r,palette.line_strong,10)
            else frame(r,palette.line)end
            if view.step==1 then
              image(item.preview,{x=r.x+10*scale,y=r.y+8*scale,w=80*scale,h=r.h-16*scale},true)
              local names=wrap(item.label,math.max(12,math.floor((r.w/scale-116)/9)))
              for i=1,math.min(3,#names)do text(names[i],r.x+104*scale,r.y+r.h-(24+(i-1)*24)*scale,18,gold)end
            elseif view.step==2 then
              if item.base_values then
                for index,field in ipairs(STAT_FIELDS) do
                  local value=item.base_values[field]
                  local x=r.x+12*scale+(index-1)*(r.w-24*scale)/3
                  text(number(value) and string.format('%g',value) or '--',x,r.y+(r.h-20*scale)/2,20,item.selected and gold or white)
                  gauge(x+58*scale,r.y+(r.h-12*scale)/2,value,STAT_MAX[field],4,12,2)
                end
              else
                text(clip(item.label or 'Native weight profile',48),r.x+12*scale,r.y+(r.h-17*scale)/2,17,white)
              end
            else
              -- Icon tile; the selected passive's full text is in the review panel.
              local size=math.min(64*scale,r.w-20*scale)
              local badge={x=r.x+(r.w-size)/2,y=r.y+r.h-size-10*scale,w=size,h=size}
              icon(item.id,item.icon_hash,badge)
              local names=word_wrap(item.label,math.max(6,math.floor((r.w/scale-10)/(14*0.56))))
              for index=1,math.min(2,#names)do
                local name=names[index]
                if index==2 and #names>2 then name=name..'...'end
                centered(name,r.x+r.w/2,badge.y-(21+(index-1)*17)*scale,14,item.selected and gold or white)
              end
            end
          end
        end
        if #options==0 then
          local lines=wrap(view.empty_options_notice or 'Waiting for verified owned choices.',52)
          for i=1,math.min(5,#lines)do
            text(lines[i],layout.picker.x+12*scale,layout.picker.y+layout.picker.h-(35+(i-1)*23)*scale,17,muted)
          end
        end
        if limit>0 then
          -- Scrollbar: drag the thumb or click the track; the wheel scrolls rows.
          local top=layout.picker.y+layout.picker.h-grid.top
          local track={x=layout.picker.x+layout.picker.w-12*scale,w=5*scale,y=top-grid.rows*grid.row_h,h=grid.rows*grid.row_h}
          local thumb=math.max(32*scale,track.h*grid.rows/(grid.rows+limit))
          local thumb_y=track.y+track.h-thumb-(track.h-thumb)*self.scroll.options/limit
          rect(track,palette.track,982)
          rect({x=track.x,y=thumb_y,w=track.w,h=thumb},palette.line_strong,983)
          self.scroll_track={y=track.y,h=track.h,thumb=thumb}
          action({x=track.x-5*scale,y=track.y,w=track.w+10*scale,h=track.h},{type='panel_scrollbar',target='options'})
        end
        if view.controller_mode then
          text('A Select   B Back   Y Cancel',layout.picker.x+12*scale,layout.picker.y+24*scale,12,gold)
          text('D-pad / stick Move    LB / RB Page',layout.picker.x+12*scale,layout.picker.y+8*scale,11,muted)
        end
        if view.step==2 and not view.controller_mode then text('Passive bonuses are excluded.',layout.picker.x+12*scale,layout.picker.y+13*scale,13,muted)end
        if footer_note and not view.controller_mode then
          local room=layout.picker.w-24*scale
          text(clip(footer_note,math.max(4,math.floor(room/(12*0.6*scale)))),layout.picker.x+12*scale,layout.picker.y+13*scale,12,muted)
        end
      end
      review(view.label,view.selection or {},true)
      self.policy={native_look_pick=view.step==1 and (not view.controller_mode or view.controller_native_looks==true),block_native_grid=view.step~=1 or (view.controller_mode==true and not view.controller_native_looks),
        block_native_apply=true,block_native_compare=true,wizard_open=true,native_picker_rect=layout.picker}
    end
    if selected_variant then
      review(selected_variant.display_name or selected_variant.label,selected_variant.request,false)
      self.policy.saved_variant_review=true
      self.policy.native_look_pick=false
      self.policy.block_native_apply=true
      self.policy.block_native_compare=true
    end
    if native_apply then
      capture(layout.apply);capture(layout.footer)
      local apply_action={type='apply_variant',label=not native_override and saved_variant and saved_variant.label or nil,
        id=native_override_id}
      action(layout.apply,apply_action,apply_enabled)
      action(layout.footer,apply_action,apply_enabled)
      if native_summary then
        local r=native_summary
        if apply_notice then
          local lines=wrap(apply_notice,math.max(1,math.floor(r.w/(12*scale*.8))-3))
          local offset=20
          for index=1,math.min(2,#lines)do
            text(lines[index]..(index==2 and #lines>2 and '...'or ''),r.x,r.y+r.h-(offset+(index-1)*14)*scale,12,gold)
          end
        elseif equipped then
          text('Equipped',r.x,r.y+r.h-20*scale,13,gold)

        end
      end
      if saved_variant and view.can_remove and sample.kind~='deployment' then
        local remove={x=layout.apply.x-196*scale,y=layout.apply.y,w=180*scale,h=layout.apply.h}
        if valid_rect(remove,width,height)then
          button(remove,'Remove variant',{type='remove_variant',label=saved_variant.label},view.apply_pending~=true)
        end
      end
      if saved_variant and view.can_edit and sample.kind~='deployment' then
        local edit={x=layout.apply.x-392*scale,y=layout.apply.y,w=180*scale,h=layout.apply.h}
        if valid_rect(edit,width,height)then
          button(edit,'Edit variant',{type='edit_variant',label=saved_variant.label},view.apply_pending~=true)
        end
      end
      self.policy.native_details=native_details
      self.policy.native_override=native_override
      self.policy.block_native_apply=true
      self.policy.block_native_compare=not native_details or view.apply_pending==true
      self.policy.apply_pending=view.apply_pending==true
    end
    self.signature=signature
    self.render_state=retain_display(render_state)
    return true
  end
  return self
end
return M
