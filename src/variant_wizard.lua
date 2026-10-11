-- Pure Custom Variant wizard. No GUI, native calls, pointer storage, or I/O.
--
-- local wizard = VariantWizard.new(State)
-- wizard:view(domain, context) -> render model
-- wizard:action(domain, context, {type=..., id=...}) -> true|nil, error, transaction
-- Actions: open, select_look, select_stats, select_passive, rename (label),
--          back, cancel, create, select_variant (label),
--          edit_variant (label): reopen a saved variant with its choices,
--          forward: on to the next stage keeping the current choice.
--
-- Saving an edited variant replaces it under the same id, so it stays the same
-- variant (equipped records and thumbnails follow it); its transaction carries
-- edited={label=<old label>, id=<id>}.
--
-- A create transaction contains {kind='save_variant', label, candidate, encoded}.
-- Before persisting: wizard:validate_transaction(tx, current_domain, context).
-- Then atomically persist tx.encoded, adopt tx.candidate and call
-- wizard:saved(tx, adopted_domain). On failure call wizard:failed(tx, reason).
-- No creation or navigation changes requested/selected/equipped armor.
-- select_variant returns an intent only; the caller owns any subsequent action.
--
-- context.labels[field][id], appearance_previews[id], passive_variants[id]
-- are optional display metadata. Preview descriptors are passed through to the
-- renderer without invoking them and are NEVER copied into persisted state.
-- policy.stats_follow_look=true skips the stats picker and inherits the owned
-- appearance donor's stats_id. Saved variants retain their original definitions.
-- Manual stats choices require stats_profiles[stats_id] = {
--   base_only=true, base_values_verified=true,
--   base_values={armor_rating=number, speed=number, stamina_regen=number}
-- }. Boosted donor totals and unverifiable profiles are excluded. The caller
-- supplies proven base values; this model never guesses/subtracts perk bonuses.

local M = {}
local Wizard = {}
Wizard.__index = Wizard
local MAX_PRESETS = 256
local function capacity(context)
 local limit=context and context.variant_capacity
 if limit==nil then return MAX_PRESETS end -- pure/offline hosts retain the storage bound
 if type(limit)~='number'or limit%1~=0 or limit<0 then return 0 end
 return math.min(MAX_PRESETS,limit)
end
local fields = {'appearance_id', 'stats_id', 'passive_variant_id'}
local stat_fields = {'armor_rating', 'speed', 'stamina_regen'}

local function triple(value)
  if type(value) ~= 'table' then return nil end
  return {appearance_id=value.appearance_id, stats_id=value.stats_id,
    passive_variant_id=value.passive_variant_id, id=value.id}
end

local function keys(t)
  local out = {}
  for key in pairs(t or {}) do out[#out+1] = key end
  table.sort(out)
  return out
end

local function label(context, field, id)
  local names = context.labels and context.labels[field]
  return names and type(names[id]) == 'string' and names[id] or id
end

local function after_look(self)
  return (self._stats_follow_look or self._stats_skipped) and 3 or 2
end

local function stage_list(skip_stats)
  local out = {1}
  if not skip_stats then out[#out+1] = 2 end
  out[#out+1] = 3
  return out
end

local function fresh(domain)
  return domain.ownership_verified == true
end

local function owned_parts(domain)
  local out = {appearance_id={}, stats_id={}, passive_variant_id={}}
  if not fresh(domain) then return out end
  for _, kit_id in ipairs(keys(domain.owned)) do
    local kit = domain.owned[kit_id] and domain.catalog[kit_id]
    if kit then
      for _, field in ipairs(fields) do
        local id = kit[field]
        out[field][id] = out[field][id] or {}
        out[field][id][#out[field][id]+1] = kit_id
      end
    end
  end
  return out
end

local function owned_request(parts, request)
  if not request then return false end
  for _, field in ipairs(fields) do
    if not request[field] or not parts[field][request[field]] then return false end
  end
  return true
end

local function sort_named(a, b)
  if a.label == b.label then return a.id < b.id end
  return a.label < b.label
end

local function base_tuple(profile)
  if type(profile) ~= 'table' or profile.base_only ~= true
    or profile.base_values_verified ~= true or type(profile.base_values) ~= 'table' then
    return nil
  end
  local values, parts = {}, {}
  for _, field in ipairs(stat_fields) do
    local value = profile.base_values[field]
    if type(value) ~= 'number' or value ~= value or value == math.huge
      or value == -math.huge or value < 0 then return nil end
    if value == 0 then value = 0 end -- Normalize negative zero for grouping.
    values[field] = value
    parts[#parts+1] = string.format('%.17g', value)
  end
  return 'base:'..table.concat(parts, '/'), values
end

-- Accessories expose verified native weight profiles, not invented numeric ratings.
local function accessory_tuple(profile)
  if type(profile)~='table' or (profile.category~=1 and profile.category~=2)
    or profile.base_only~=true or profile.weight_profile_verified~=true then return end
  local parts,weights={},{}
  for _,kind in ipairs({0,1})do
    local fields={}
    for _,body in ipairs(profile.body_weights or {})do
      if body.body_type==3 or body.body_type==kind then
        for _,piece in ipairs(body.pieces or {})do
          if type(piece.weight)~='number'or piece.weight%1~=0 or piece.weight<0 or piece.weight>2 then return end
          fields[#fields+1]=piece.slot..':'..piece.kind..':'..piece.weight
          weights[piece.weight]=true
        end
      end
    end
    if #fields==0 then return end
    table.sort(fields);parts[#parts+1]=kind..'='..table.concat(fields,',')
  end
  local names={};for weight=0,2 do if weights[weight]then names[#names+1]=({'Light','Medium','Heavy'})[weight+1]end end
  return 'weight:'..profile.category..':'..table.concat(parts,'/'), table.concat(names,' / ')..' profile'
end

local function options(domain, context)
  local parts, looks, stats, passives = owned_parts(domain), {}, {}, {}
  local stat_map, stat_by_donor, look_stats, unresolved = {}, {}, {}, 0
  for _, id in ipairs(keys(parts.appearance_id)) do
    -- Stable owned donor selection when multiple kits share an appearance.
    look_stats[id] = domain.catalog[parts.appearance_id[id][1]].stats_id
    looks[#looks+1] = {id=id, label=label(context, 'appearance_id', id),
      donor_kit_ids=parts.appearance_id[id], preview=context.appearance_previews
        and context.appearance_previews[id], action={type='select_look', id=id}}
  end
  table.sort(looks, sort_named)
  for _, id in ipairs(keys(parts.stats_id)) do
    local profile = context.stats_profiles and context.stats_profiles[id]
    local tuple_id, values = base_tuple(profile)
    local weight_label
    if not tuple_id then tuple_id,weight_label=accessory_tuple(profile)end
    if tuple_id then
      local choice = stat_map[tuple_id]
      if not choice then
        choice = {id=tuple_id, base_values=values, stats_id=id, donor_stats_ids={},
          donor_kit_ids={}, label=weight_label or string.format('%s / %s / %s',
            tostring(values and values.armor_rating), tostring(values and values.speed), tostring(values and values.stamina_regen)),
          action={type='select_stats', id=tuple_id}}
        stat_map[tuple_id], stats[#stats+1] = choice, choice
      end
      choice.donor_stats_ids[#choice.donor_stats_ids+1] = id
      for _, kit_id in ipairs(parts.stats_id[id]) do
        choice.donor_kit_ids[#choice.donor_kit_ids+1] = kit_id
      end
      stat_by_donor[id] = tuple_id
    else unresolved = unresolved + 1 end
  end
  table.sort(stats, function(a, b)
    if not a.base_values or not b.base_values then return a.id<b.id end
    for _, field in ipairs(stat_fields) do
      if a.base_values[field] ~= b.base_values[field] then
        return a.base_values[field] < b.base_values[field]
      end
    end
    return a.id < b.id
  end)
  for _, id in ipairs(keys(parts.passive_variant_id)) do
    local meta = context.passive_variants and context.passive_variants[id] or {}
    passives[#passives+1] = {id=id, label=label(context, 'passive_variant_id', id),
      donor_kit_ids=parts.passive_variant_id[id], icon_hash=meta.icon_hash,
      effects=meta.effects, exact_variant=true, action={type='select_passive', id=id}}
  end
  table.sort(passives, sort_named)
  return {parts=parts, looks=looks, stats=stats, passives=passives,
    stat_map=stat_map, stat_by_donor=stat_by_donor, look_stats=look_stats, unresolved=unresolved}
end

local function clone_domain(S, domain)
  local candidate = S.new({catalog=domain.catalog, owned=domain.owned})
  candidate.ownership_verified = domain.ownership_verified
  candidate.requested, candidate.selected = triple(domain.requested), triple(domain.selected)
  for name, value in pairs(domain.presets) do candidate.presets[name] = triple(value) end
  return candidate
end

local function request_valid(self, model, request, tuple_id)
  if not owned_request(model.parts, request) then return false end
  if self._stats_follow_look then
    return model.look_stats[request.appearance_id] == request.stats_id
  end
  return tuple_id ~= nil and model.stat_by_donor[request.stats_id] == tuple_id
end

local function draft_valid(self, model)
  local draft = self._draft
  return draft and request_valid(self, model, draft, draft.stats_tuple_id) or false
end

-- "Look - Passive" from the first of two name tables that knows each part.
local function derived_name(first, second, request, fallback)
  first, second = first or {}, second or {}
  local look=(first.appearance_id and first.appearance_id[request.appearance_id])
    or (second.appearance_id and second.appearance_id[request.appearance_id])
  local perk=(first.passive_variant_id and first.passive_variant_id[request.passive_variant_id])
    or (second.passive_variant_id and second.passive_variant_id[request.passive_variant_id])
  if look and perk then return look..' - '..perk end
  return fallback or (look or 'Armor')..' - '..(perk or 'Passive')
end

-- Saved labels are stable action identities: the automatic one is made from
-- the catalog's fixed English names, whatever language the game runs in.
local function identity_name(context, request, fallback)
  return derived_name(context and (context.variant_labels or context.labels),
    context and context.labels, request, fallback)
end

-- What the player sees: the game's own (localized) names first.
function M.display_name(context, request, fallback)
  return derived_name(context and context.labels, context and context.variant_labels, request, fallback)
end

local function default_name(domain)
  for i=1, MAX_PRESETS+1 do
    local name = 'Custom Variant '..i
    if not domain.presets[name] then return name end
  end
end

-- The label of the saved variant being edited, which its draft may keep.
local function editing_label(self)
  return self._editing and self._editing.label or nil
end

local function label_valid(self, domain, value)
  if type(value) ~= 'string' or value:find('%c') or value:match('^%s*$') then
    return nil, 'Enter a nonempty variant name without control characters.'
  end
  if domain.presets[value] and value ~= editing_label(self) then return nil, 'A saved variant already has that name.' end
  local candidate = clone_domain(self._state, domain)
  -- State owns UTF-8 and length validation; use a valid triple for this check.
  candidate.presets[value] = {appearance_id='check', stats_id='check', passive_variant_id='check'}
  if not self._state.validate(candidate) then return nil, 'The variant name is invalid or too long.' end
  return true
end

function M.new(state_api, policy)
  assert(type(state_api) == 'table' and type(state_api.encode) == 'function'
    and type(state_api.validate) == 'function' and type(state_api.new) == 'function',
    'VariantWizard requires the pure State module')
  return setmetatable({_state=state_api, _step=0, _allow_create=not policy or policy.allow_create~=false,
    _stats_follow_look=policy and policy.stats_follow_look==true}, Wizard)
end

function Wizard:is_open()
  return self._step > 0
end

-- Opt-in display cache: the host replaces ownership/catalog tables and bumps
-- this revision whenever display metadata changes in place. Action validation
-- always builds fresh options below; cached display data never authorizes equip.
local function view_options(self, domain, context)
  local revision=context.options_revision
  if type(revision)~='number' then return options(domain,context) end
  local cached=self._options
  if not cached or cached.revision~=revision or cached.context~=context
    or cached.catalog~=domain.catalog or cached.owned~=domain.owned
    or cached.verified~=domain.ownership_verified then
    cached={revision=revision,context=context,catalog=domain.catalog,owned=domain.owned,
      verified=domain.ownership_verified,model=options(domain,context)}
    self._options=cached
  end
  return cached.model
end

-- The name a draft gets until the player renames it.
local function name_draft(self, domain, context)
  if self._renamed then return end
  local base=identity_name(context,self._draft,default_name(domain))
  local name=base;local i=2
  while domain.presets[name] and name~=editing_label(self) do name=base..' ('..i..')';i=i+1 end
  self._label=name
end

-- A saved name that is just the automatic "Look - Passive" name (possibly with
-- a " (2)" suffix) follows the new choices when edited; a name the player gave
-- is kept.
local function automatic_name(context, request, name)
  local base=identity_name(context,request,'')
  if base=='' then return false end
  return name==base or (name:sub(1,#base+2)==base..' (' and name:sub(#base+3):match('^%d+%)$')~=nil)
end
-- A draft's label as the player sees it: an automatic name is shown in the
-- game's own names, keeping its " (2)" suffix; a name the player gave is kept.
local function shown_label(context, request, label)
  if type(label)~='string' or type(request)~='table' or not automatic_name(context,request,label) then return label end
  return M.display_name(context,request,'')..label:sub(#identity_name(context,request,'')+1)
end

-- Hard rule: a single available passive is no choice. It is taken for the
-- draft on reaching the last step and its list is not shown.
local function fixed_passive(model)
  return #model.passives==1 and model.passives[1].id or nil
end
local function enter(self, step, model, domain, context)
  self._step=step
  local only=step==3 and fixed_passive(model)
  if only and self._draft and self._draft.passive_variant_id~=only then
    self._draft.passive_variant_id=only
    name_draft(self,domain,context)
  end
end

function Wizard:view(domain, context)
  context = context or {}
  local model = view_options(self, domain, context)
  local tiles = {}
  for _, name in ipairs(keys(domain.presets)) do
    local request = domain.presets[name]
    local meta = context.passive_variants and context.passive_variants[request.passive_variant_id] or {}
    tiles[#tiles+1] = {kind='variant', label=name, display_name=M.display_name(context,request,name), request=triple(request),
      enabled=owned_request(model.parts, request),
      preview=context.appearance_previews and context.appearance_previews[request.appearance_id],
      icon_hash=meta.icon_hash, action={type='select_variant', label=name}}
  end
  if self._allow_create then tiles[#tiles+1] = {kind='add', label='+', accessible_label='Create custom variant',
    enabled=fresh(domain) and #model.looks > 0 and #tiles < capacity(context) and self._step == 0,
    action={type='open'}} end
  local valid_label, label_error = label_valid(self, domain, self._label)
  local selected = self._draft or {}
  local skip_stats=self._stats_follow_look or self._stats_skipped or (#model.stats==1 and model.unresolved==0)
  local stages=stage_list(skip_stats)
  local step_number=self._step
  for index,step in ipairs(stages)do if step==self._step then step_number=index end end
  local only_passive = self._step == 3 and fixed_passive(model)
  local active_options = self._step == 1 and model.looks or self._step == 2 and model.stats
    or self._step == 3 and (only_passive and {} or model.passives) or {}
  local displayed_options={}
  for _, source in ipairs(active_options) do
    local choice={};for key,value in pairs(source)do choice[key]=value end
    if self._step==1 then
      choice.preview=context.appearance_previews and context.appearance_previews[choice.id]
    end
    displayed_options[#displayed_options+1]=choice
    choice.selected = choice.id == (self._step == 1 and selected.appearance_id
      or self._step == 2 and selected.stats_tuple_id or selected.passive_variant_id)
  end
  return {
    section={title='Custom Variant', before='Light Armor', tiles=tiles},
    open=self._step > 0, step=self._step,
    -- Keep semantic step IDs stable for renderers/input; number only visible stages.
    step_number=step_number,
    step_count=#stages, stats_follow_look=self._stats_follow_look==true,
    title=({'Choose a look', context.category and context.category~=0 and 'Choose stats' or 'Choose base stats',
      only_passive and 'Name and create' or 'Choose a passive'})[self._step],
    passive_fixed=only_passive and true or nil,
    -- Forward keeps the current choice and moves on.
    can_forward=not self._pending and (self._step==1 and selected.appearance_id~=nil
      or self._step==2 and not skip_stats and selected.stats_id~=nil and selected.stats_tuple_id~=nil) or false,
    options=displayed_options, selection=triple(selected), stats_tuple_id=selected.stats_tuple_id,
    label=self._label, display_label=shown_label(context,self._draft,self._label), can_back=self._step > 1 and not self._pending,
    can_cancel=self._step > 0 and not self._pending,
    -- Sections are edited in any order: Create is available wherever the
    -- draft is complete.
    editing=({'look','stats','passive'})[self._step],
    -- Set while a saved variant is being edited: Create saves over it.
    editing_variant=self._step>0 and editing_label(self) or nil,
    edit=self._step>0 and {look=true,
      stats=selected.appearance_id~=nil and not self._stats_follow_look,
      passive=selected.appearance_id~=nil and selected.stats_id~=nil} or nil,
    can_create=(self._step == 3
      or (self._step == 1 or self._step == 2) and selected.passive_variant_id ~= nil)
      and not self._pending and valid_label == true
      -- An edit replaces its own card, so it fits even when the list is full.
      and #tiles - (editing_label(self) and 1 or 0) <= capacity(context) and draft_valid(self, model) or false,
    saving=self._pending ~= nil, ownership_verified=fresh(domain),
    unresolved_stats_count=model.unresolved,
    empty_options_notice=only_passive and (model.passives[1].label..' is the only passive available here. Nothing to choose.')
      or self._step==2 and #active_options==0 and
      (context.stats_status=='unavailable'and 'Base stats could not be verified. Reopen Armor; if this persists, include STATUS.txt and AppleBacon.log in your report.'
       or context.stats_status=='player_unavailable'and 'Player body type is unavailable. Return to the ship and reopen Armor.'
       or 'Verifying owned base stats. If this persists, reopen Armor and check the diagnostics.')or nil,
    stats_notice=not self._stats_follow_look and model.unresolved > 0 and 'Some owned base stats are awaiting verification.' or nil,
    label_error=self._step > 0 and not valid_label and label_error or nil,
    notice=self._notice,
  }
end

function Wizard:action(domain, context, action)
  context = context or {}
  if type(action) ~= 'table' then return nil, 'Invalid wizard action.' end
  if not self._state.validate(domain) then return nil, 'Invalid variant state.' end
  local kind = action.type
  if not self._allow_create and kind~='select_variant' then
    return nil, 'Create variants in the ship Armory.'
  end
  if self._pending then return nil, 'Finish saving the current variant first.' end
  if kind == 'cancel' then
    self._step, self._draft, self._label, self._notice, self._editing = 0, nil, nil, nil, nil
    return true
  end
  if kind == 'back' then
    if self._step <= 1 then return nil, 'There is no previous step.' end
    if self._step == 2 then self._step = 1
    else self._step = (self._stats_follow_look or self._stats_skipped) and 1 or 2 end
    return true
  end
  local model = options(domain, context)
  if kind == 'select_variant' then
    if self._step ~= 0 then return nil, 'Finish or cancel the open wizard first.' end
    local request = domain.presets[action.label]
    if not owned_request(model.parts, request) then return nil, 'This variant needs verified ownership.' end
    return true, nil, {kind='select_variant', label=action.label, request=triple(request)}
  elseif kind == 'open' then
    if self._step ~= 0 then return nil, 'The wizard is already open.' end
    if #keys(domain.presets) >= capacity(context) then return nil, 'The saved variant limit is reached.' end
    if #model.looks == 0 then return nil, 'No owned looks have been verified.' end
    self._step, self._draft, self._label, self._notice = 1, {}, default_name(domain), nil
    self._renamed=false;self._stats_skipped=false;self._editing=nil
    return true
  elseif kind == 'edit_variant' then
    if self._step ~= 0 then return nil, 'The wizard is already open.' end
    local saved = domain.presets[action.label]
    if not saved then return nil, 'Select a saved variant to edit.' end
    if not owned_request(model.parts, saved) then return nil, 'This variant needs verified ownership.' end
    local draft = triple(saved);draft.id = nil
    self._stats_skipped = #model.stats==1 and model.unresolved==0
    if self._stats_follow_look then
      draft.stats_id = model.look_stats[draft.appearance_id]
    elseif self._stats_skipped then
      local choice = model.stats[1]
      if model.stat_by_donor[draft.stats_id] ~= choice.id then draft.stats_id = choice.stats_id end
      draft.stats_tuple_id = choice.id
    else
      -- Stats that cannot be verified now leave the tuple empty: the player
      -- picks verified stats before Save is offered.
      draft.stats_tuple_id = model.stat_by_donor[draft.stats_id]
    end
    self._draft, self._label, self._notice = draft, action.label, nil
    self._editing = {label = action.label, id = saved.id}
    self._renamed = not automatic_name(context, saved, action.label)
    enter(self,3,model,domain,context)
    return true
  elseif kind == 'rename' then
    if self._step == 0 then return nil, 'Open the wizard first.' end
    local ok, err = label_valid(self, domain, action.label)
    if not ok then return nil, err end
    self._label = action.label;self._renamed=true
    return true
  elseif kind == 'select_look' and self._step == 1 then
    if not model.parts.appearance_id[action.id] then return nil, 'This look needs verified ownership.' end
    self._stats_skipped=#model.stats==1 and model.unresolved==0
    self._draft.appearance_id = action.id
    if self._stats_follow_look then
      self._draft.stats_id = model.look_stats[action.id]
      self._draft.stats_tuple_id = nil
    elseif self._stats_skipped then
      local choice=model.stats[1]
      local look=model.look_stats[action.id]
      self._draft.stats_id=model.stat_by_donor[look]==choice.id and look or choice.stats_id
      self._draft.stats_tuple_id=choice.id
    end
    enter(self,after_look(self),model,domain,context)
    return true
  elseif kind == 'forward' then
    -- Go on to the next stage keeping what is already chosen (after Back, or
    -- when editing a saved variant).
    local draft = self._draft or {}
    if self._step == 1 then
      if not draft.appearance_id then return nil, 'Choose a look first.' end
      return self:action(domain, context, {type='select_look', id=draft.appearance_id})
    elseif self._step == 2 then
      if not(draft.stats_id and draft.stats_tuple_id) then return nil, 'Choose base stats first.' end
      enter(self,3,model,domain,context)
      return true
    end
    return nil, 'There is no next step.'
  elseif kind == 'select_stats' and self._step == 2 and not self._stats_follow_look then
    local choice = model.stat_map[action.id]
    if not choice then return nil, 'This owned base-stat tuple has not been verified.' end
    self._draft.stats_id, self._draft.stats_tuple_id = choice.stats_id, choice.id
    enter(self,3,model,domain,context)
    return true
  elseif kind == 'select_passive' and self._step == 3 then
    if not model.parts.passive_variant_id[action.id] then return nil, 'This exact passive needs verified ownership.' end
    self._draft.passive_variant_id = action.id
    name_draft(self,domain,context)
    return true
  elseif kind == 'edit' then
    -- Jump straight to one section of the draft from the details panel.
    if self._step == 0 then return nil, 'Open the wizard first.' end
    local draft = self._draft
    if action.section == 'look' then
      self._step = 1
    elseif action.section == 'stats' then
      if self._stats_follow_look then return nil, 'Base stats follow the look.' end
      if not draft.appearance_id then return nil, 'Choose a look first.' end
      enter(self,2,model,domain,context)
    elseif action.section == 'passive' then
      if not(draft.appearance_id and draft.stats_id) then return nil, 'Choose a look and base stats first.' end
      enter(self,3,model,domain,context)
    else return nil, 'Unknown section.' end
    return true
  elseif kind == 'create' then
    local complete_step = self._step == 3
      or (self._step == 1 or self._step == 2) and self._draft.passive_variant_id ~= nil
    if not complete_step or not draft_valid(self, model) then
      return nil, self._stats_follow_look and 'Choose an owned look and an exact owned passive.'
        or 'Choose an owned look, verified base stats, and an exact owned passive.'
    end
    local editing = self._editing
    if editing then
      local source = domain.presets[editing.label]
      if not source or source.id ~= editing.id then
        return nil, 'The variant being edited was removed or renamed. Cancel and edit it again.'
      end
    elseif #keys(domain.presets) >= capacity(context) then return nil, 'The saved variant limit is reached.' end
    local ok, err = label_valid(self, domain, self._label)
    if not ok then return nil, err end
    local candidate = clone_domain(self._state, domain)
    if editing then candidate.presets[editing.label] = nil end
    candidate.presets[self._label] = triple(self._draft)
    -- A created variant is a new one: its id is given when it is first written.
    -- An edited one stays the same variant and keeps its id.
    candidate.presets[self._label].id = editing and editing.id or nil
    local encoded, encoding_error = self._state.encode(candidate)
    if not encoded then return nil, encoding_error end
    -- Also enforce the decoder's persistence bounds before proposing a write.
    if self._state.decode and not self._state.decode(encoded) then return nil, 'Variant storage limit exceeded.' end
    local tx = {kind='save_variant', label=self._label, candidate=candidate, encoded=encoded,
      edited=editing and {label=editing.label, id=editing.id, request=triple(domain.presets[editing.label])} or nil}
    self._pending = {tx=tx, encoded=encoded, before=self._state.encode(domain),
      request=triple(self._draft), tuple_id=self._draft.stats_tuple_id}
    self._notice = nil
    return true, nil, tx
  end
  return nil, 'That action is unavailable in the current step.'
end

function Wizard:validate_transaction(tx, domain, context)
  local pending = self._pending
  if not pending or pending.tx ~= tx then return nil, 'Unknown or completed save transaction.' end
  if tx.encoded ~= pending.encoded or self._state.encode(tx.candidate) ~= pending.encoded then
    return nil, 'The save candidate changed after creation.'
  end
  if self._state.encode(domain) ~= pending.before then return nil, 'Variant state changed; create a new save transaction.' end
  if #keys(tx.candidate.presets)>capacity(context) then return nil, 'The saved variant limit is reached.' end
  local model = options(domain, context or {})
  if not request_valid(self, model, pending.request, pending.tuple_id) then
    return nil, 'Ownership or base-stat verification changed before saving.'
  end
  return true
end

function Wizard:saved(tx, adopted_domain)
  local pending = self._pending
  if not pending or pending.tx ~= tx then return nil, 'Unknown or completed save transaction.' end
  if self._state.encode(adopted_domain) ~= pending.encoded then return nil, 'The adopted state does not match the saved candidate.' end
  self._step, self._draft, self._label, self._pending, self._notice, self._editing = 0, nil, nil, nil, nil, nil
  return true
end

function Wizard:failed(tx, reason)
  if not self._pending or self._pending.tx ~= tx then return nil, 'Unknown or completed save transaction.' end
  self._pending = nil
  self._notice = type(reason) == 'string' and reason:sub(1, 256) or 'The variant could not be saved.'
  return true
end

return M
