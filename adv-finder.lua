-- Find and track historical figures and artifacts
--@module = true

local argparse = require('argparse')
local gui = require('gui')
local widgets = require('gui.widgets')
local utils = require('utils')

local world = df.global.world
local transName = dfhack.translation.translateName
local findHF = df.historical_figure.find
local toSearch = dfhack.toSearchNormalized

LType = utils.invert{'None','Local','Site','Wild','Under','Army'} --Location type

filter_text = filter_text --Stored filter between lists; for setting only!
--  Use AdvSelWindow:get_filter_text() instead for getting current filter
cur_tab = cur_tab or 1 -- 1: HF, 2: Artifact, 3: Units
show_dead = show_dead or false --Exclude dead HFs
show_books = show_books or false --Exclude books
sel_hf = sel_hf or -1 --Selected historical_figure.id
sel_art = sel_art or -1 --Selected artifact_record.id
sel_unit = sel_unit or -1 -- Selected df.unit.id

debug_id = false --Show target ID in window title; reopening without -d option resets
show_dead_units = show_dead_units or false  -- Include dead units in Units tab
show_anonymous = show_anonymous or true
------------------
--Math & distance
------------------

local function dist2(a, b)
    if not a or not b or not a.x or not a.y or not b.x or not b.y then return math.huge end
    return (a.x - b.x)^2 + (a.y - b.y)^2
end
------------------
--Name formatters
------------------

--- Returns DFHack’s human‐readable name for any unit (alive, dead, or corpse),
--- prefixing “Anonymous” whenever the underlying personal name is blank.
local function get_unit_full_name(unit)
    -- 1) Base: DFHack readable (species or personal)
    local name = dfhack.units.getReadableName(unit)
    if name == '' then
        name = 'Anonymous'
    end

    -- 2) If no personal name, prefix “Anonymous ”
    local personal = transName(unit.name, false)
    if personal == '' or personal:match('^%s*$') then
        if name ~= 'Anonymous' then
            name = 'Anonymous ' .. name
        end
    end

    return name
end

---------------------------
--Functionsfor target names
---------------------------
local function get_race_name(hf) --E.g., 'Plump Helmet Man'
    return dfhack.capitalizeStringWords(dfhack.units.getRaceReadableNameById(hf.race))
end

function get_hf_name(hf) --'Native Name "Translated Name", Race'
    local full_name = transName(hf.name, false)
    if full_name == '' then --Improve searchability
        full_name = 'Anonymous'
    else --Add the translation
        local t_name = transName(hf.name, true)
        if full_name ~= t_name then --Don't repeat
            full_name = full_name..' "'..t_name..'"'
        end
    end
    local race_name = get_race_name(hf)
    if race_name == '' then --Elf deities don't have a race
        full_name = full_name..', Force'
    else --Add the race
        full_name = full_name..', '..race_name
    end
    return full_name
end

function get_art_name(ar) --'Native Name "Translated Name", Item'
    local full_name = transName(ar.name, false)
    if full_name == '' then --Improve searchability
        full_name = 'Anonymous'
    else --Add the translation
        local t_name = transName(ar.name, true)
        if full_name ~= t_name then --Don't repeat
            full_name = full_name..' "'..t_name..'"'
        end
    end
    return full_name..', '..dfhack.items.getDescription(ar.item, 1, true)
end
------------------
--List builders & filters
------------------

-- Rebuilds the Units list, now respecting show_anonymous

local function build_unit_list()
    local adv_unit = dfhack.world.getAdventurer()
    local adv_id = adv_unit and adv_unit.id or -1
    local adv_gpos = (get_adv_data() or {}).g_pos
    local t = {}

    for _, unit in ipairs(world.units.active) do
        -- Skip the adventurer themself
        if unit.id == adv_id then
            goto continue
        end

        -- 1) Determine if this unit is “anonymous” (no personal name)
        local personal_name = transName(unit.name, false)
        local is_anonymous  = (personal_name == '')

        -- 2) Skip dead (if toggled off) and anonymous (if toggled off)
        if (show_dead_units or not dfhack.units.isDead(unit))
           and (show_anonymous or not is_anonymous)
        then
            -- Build the display name (will be “Anonymous” if blank)
            local display_name = get_unit_full_name(unit)

            -- Prepare search key and distance
            local str = toSearch(display_name)
            local pos = xyz2pos(dfhack.units.getPosition(unit))
            local g_pos = global_from_local(pos)
            local distance = dist2(adv_gpos, g_pos)

            table.insert(t, {
                text = display_name,
                id = unit.id,
                search_key = str,
                distance = distance,
            })
        end
        ::continue::
    end

    table.sort(t, function(a, b)
        if a.distance == b.distance then
            return a.search_key < b.search_key
        else
            return a.distance < b.distance
        end
    end)

    return t
end

local function build_hf_list()
    local adv_unit = dfhack.world.getAdventurer()
    local adv_gpos = (get_adv_data() or {}).g_pos
    local t = {}

    for _, hf in ipairs(world.history.figures) do
        -- Skip if this HF is the adventurer
        if adv_unit and hf.unit_id == adv_unit.id then
            goto continue
        end

        if (show_dead or hf.died_year == -1) then
            local personal = transName(hf.name, false)
            local is_anon = (personal == '' or personal:match('^%s*$'))

            if show_anonymous or not is_anon then
                -- Name handling
                local native_full     = personal
                if native_full == '' then native_full = 'Anonymous' end
                local translated_full = transName(hf.name, true)
                if translated_full == '' then translated_full = native_full end

                -- Split names
                local native_first, native_last = native_full:match('^(%S+)%s+(.+)$')
                if not native_first then native_first, native_last = native_full, '' end
                local trans_first, trans_last = translated_full:match('^(%S+)%s+(.+)$')
                if not trans_first then trans_first, trans_last = translated_full, '' end

                -- Display name
                local display_name = trans_first
                if trans_last  ~= '' then display_name = display_name .. ' '  .. trans_last  end
                if native_last ~= '' then display_name = display_name .. ' "' .. native_last .. '"' end

                -- Race & status
                local race = dfhack.units.getRaceReadableNameById(hf.race)
                race = dfhack.capitalizeStringWords(race)
                if race ~= '' then display_name = display_name .. ', ' .. race end
                local status = (hf.died_year ~= -1) and 'Dead' or 'Alive'
                display_name = display_name .. ', ' .. status

                local prof = dfhack.units.getProfessionName(hf) or 'Unknown'
                display_name = display_name .. ', ' .. prof

                -- Distance
                local str      = toSearch(display_name)
                local data     = get_hf_data(hf)
                local pos      = (data and data.g_pos) or nil
                local distance = dist2(adv_gpos, pos)

                table.insert(t, {
                    text       = display_name,
                    id         = hf.id,
                    search_key = str,
                    distance   = distance,
                })
            end
        end
        ::continue::
    end

    table.sort(t, function(a, b)
        if a.distance == b.distance then
            return a.search_key < b.search_key
        else
            return a.distance < b.distance
        end
    end)

    return t
end

local function get_id(first, second) --Try to get a numeric id or -1
    return (first >= 0 and first) or (second >= 0 and second) or -1
end

local function is_book(ar) --Return true if codex/scroll/quire
    local item = ar.item
    return item._type == df.item_bookst or --We'll ignore slabs, despite legends mode behaviour
        (item._type == df.item_toolst and item:hasToolUse(df.tool_uses.CONTAIN_WRITING))
end

local function build_art_list()
    local adv_data = get_adv_data() or {}
    local adv_pos  = adv_data.pos
    local adv_gpos = adv_data.g_pos
    local t = {}

    for _, ar in ipairs(world.artifacts.all) do
        -- only filter out books if that toggle is off
        if show_books or not is_book(ar) then
            -- 1) display & search key
            local name = get_art_name(ar)
            local key  = toSearch(name)

            -- 2) raw data
            local data = get_art_data(ar)

            -- 3) holder override (as before)
            if data.holder then
                local hdata = get_hf_data(data.holder)
                if hdata.pos then
                    data.pos   = hdata.pos
                    data.g_pos = global_from_local(hdata.pos)
                elseif hdata.g_pos then
                    data.g_pos = hdata.g_pos
                    data.pos   = nil
                end
            end

            -- 4) pick distance (local then global)
            local dist
            if adv_pos and data.pos then
                dist = dist2(adv_pos, data.pos)
            elseif adv_gpos and data.g_pos then
                dist = dist2(adv_gpos, data.g_pos)
            else
                dist = math.huge
            end

            table.insert(t, {
                text       = name,
                id         = ar.id,
                search_key = key,
                distance   = dist,
            })
        end
    end

    -- 5) sort by distance then name
    table.sort(t, function(a, b)
        if a.distance == b.distance then
            return a.search_key < b.search_key
        else
            return a.distance < b.distance
        end
    end)

    return t
end

------------------
-- AdvSelWindow --
------------------

AdvSelWindow = defclass(AdvSelWindow, widgets.Window)
AdvSelWindow.ATTRS{
    frame_title = 'Find Target',
    frame = {w=90, h=28, t=22, r=34},
    resizable = true,
    visible = false,
}

function AdvSelWindow:init()
    self:addviews{
        -- Tab bar at the top
        widgets.TabBar{
            frame = { t=0 },
            labels = { 'Historical Figures', 'Artifacts', 'Units' },
            get_cur_page = function() return cur_tab end,
            on_select = self:callback('swap_tab'),
        },

        -- HF list
        widgets.FilteredList{
            view_id = 'sel_hf_list',
            frame = { t=2, b=2 },
            not_found_label = 'No results',
            edit_key = 'CUSTOM_ALT_S',
            on_submit = self:callback('select_entry'),
            visible = function() return cur_tab == 1 end,
        },

        -- Artifact list
        widgets.FilteredList{
            view_id = 'sel_art_list',
            frame = { t=2, b=2 },
            not_found_label = 'No results',
            edit_key = 'CUSTOM_ALT_S',
            on_submit = self:callback('select_entry'),
            visible = function() return cur_tab == 2 end,
        },

        -- Unit list
        widgets.FilteredList{
            view_id = 'sel_unit_list',
            frame = { t=2, b=2 },
            not_found_label = 'No results',
            edit_key = 'CUSTOM_ALT_S',
            on_submit = self:callback('select_entry'),
            visible = function() return cur_tab == 3 end,
        },

        -- Show‐dead toggle (HF tab)
        widgets.ToggleHotkeyLabel{
            view_id = 'dead_toggle',
            frame = { b=0, l=0,  w=17, h=1 },
            label = 'Show dead:',
            key = 'CUSTOM_SHIFT_D',
            initial_option = show_dead,
            on_change = self:callback('set_show_dead'),
            visible = function() return cur_tab == 1 end,
        },

        -- Show‐anonymous toggle (HF tab)
        widgets.ToggleHotkeyLabel{
            view_id = 'hf_anon_toggle',
            frame = { b=0, l=36, w=19, h=1 },
            label = 'Show anonymous:',
            key = 'CUSTOM_SHIFT_A',
            initial_option = show_anonymous,
            on_change = self:callback('set_show_anonymous'),
            visible = function() return cur_tab == 1 end,
        },

        -- In AdvSelWindow:init(), add a Show‐dead toggle for Units (tab 3):
        widgets.ToggleHotkeyLabel{
            view_id = 'unit_dead_toggle',
            frame = { b=0, r=14, w=17, h=1 },
            label = 'Show dead:',
            key = 'CUSTOM_SHIFT_D',
            initial_option = show_dead_units,
            on_change = self:callback('set_show_dead_units'),
            visible = function() return cur_tab == 3 end,
        },

        -- Show‐books toggle (Artifacts tab)
        widgets.ToggleHotkeyLabel{
            view_id = 'book_toggle',
            frame = { b=0, r=0,  w=18, h=1 },
            label = 'Show books:',
            key = 'CUSTOM_SHIFT_B',
            initial_option = show_books,
            on_change = self:callback('set_show_books'),
            visible = function() return cur_tab == 2 end,
        },
        -- **Show‐anonymous toggle (Units tab)**
        widgets.ToggleHotkeyLabel{
            view_id = 'anon_toggle',
            frame = { b=0, l=36, w=19, h=1 },
            label = 'Show anonymous:',
            key = 'CUSTOM_SHIFT_A',
            initial_option = show_anonymous,
            on_change = self:callback('set_show_anonymous'),
            visible = function() return cur_tab == 3 end,
        },

        -- Refresh hotkey (all tabs)
        widgets.HotkeyLabel{
            view_id = 'refresh_list',
            frame = { b=0, l=18, w=18, h=1 },
            label = 'Refresh',
            key = 'CUSTOM_CTRL_Z',
            on_activate = self:callback('refresh_list'),
        },
    }
end

-- Handler for the “Show anonymous” toggle: flips the flag and rebuilds only the Units list
function AdvSelWindow:set_show_anonymous(val)
    show_anonymous = not not val       -- ensure boolean
    filter_text = self:get_filter_text()

    if cur_tab == 1 then
        self.subviews.sel_hf_list:setChoices()
    else
        self.subviews.sel_unit_list:setChoices()
    end

    self:sel_list()
end

function AdvSelWindow:get_filter_text()
    if cur_tab == 1 then -- HF
        return self.subviews.sel_hf_list:getFilter()
    elseif cur_tab == 2 then -- Artifact
        return self.subviews.sel_art_list:getFilter()
    else -- Units
        return self.subviews.sel_unit_list:getFilter()
    end
end

function AdvSelWindow:swap_tab(idx) --Persist filter and swap list
    if cur_tab ~= idx then
        filter_text = self:get_filter_text()
        cur_tab = idx
        self:sel_list()
    end
end

function AdvSelWindow:sel_list()
    local new, build_fn

    if cur_tab == 1 then -- Historical Figures
        new = self.subviews.sel_hf_list
        build_fn = build_hf_list
    elseif cur_tab == 2 then -- Artifacts
        new = self.subviews.sel_art_list
        build_fn = build_art_list
    else -- Units
        new = self.subviews.sel_unit_list
        build_fn = build_unit_list
    end

    -- Hide all lists before showing the current one
    self.subviews.sel_hf_list.visible = false
    self.subviews.sel_art_list.visible = false
    self.subviews.sel_unit_list.visible = false

    new.visible = true
    if not next(new:getChoices()) then
        new:setChoices(build_fn())
    end
    new:setFilter(filter_text)
    new.edit:setFocus(true)
end

function AdvSelWindow:select_entry(sel, obj) --Set correct target for tab
    local id = obj and obj.id or -1
    if cur_tab == 1 then
       sel_hf, sel_art, sel_unit = id, -1, -1
    elseif cur_tab == 2 then
        sel_hf, sel_art, sel_unit = -1, id, -1
    else
        sel_hf, sel_art, sel_unit = -1, -1, id
    end
end

function AdvSelWindow:refresh_list()
    -- preserve current filter
    local filter = self:get_filter_text()

    -- choose the right list + builder
    local list, build_fn
    if cur_tab == 1 then
        list, build_fn = self.subviews.sel_hf_list, build_hf_list
    elseif cur_tab == 2 then
        list, build_fn = self.subviews.sel_art_list, build_art_list
    else
        list, build_fn = self.subviews.sel_unit_list, build_unit_list
    end

    -- rebuild, re-filter, refocus
    list:setChoices(build_fn())
    list:setFilter(filter)
    list.edit:setFocus(true)
end

function AdvSelWindow:set_show_dead(show) --Set filtering of dead HFs, rebuild list
    show = not not show --To bool
    if show == show_dead then
        return --No change
    end
    show_dead = show
    filter_text = self:get_filter_text()
    self.subviews.sel_hf_list:setChoices()
    self.subviews.sel_art_list:setChoices() --Held by HF
    self:sel_list()
end

function AdvSelWindow:set_show_books(show) --Set filtering of books, rebuild list
    show = not not show
    if show == show_books then
        return
    end
    show_books = show
    filter_text = self:get_filter_text()
    self.subviews.sel_art_list:setChoices()
    self:sel_list()
end

--Units‐tab dead toggle handler here
function AdvSelWindow:set_show_dead_units(val)
    val = not not val
    if val == show_dead_units then return end
    show_dead_units = val
    filter_text = self:get_filter_text()
    self.subviews.sel_unit_list:setChoices()
    self:sel_list()
end

function AdvSelWindow:onInput(keys) --Close only this window
    if keys.LEAVESCREEN or keys._MOUSE_R then
        self.visible = false
        filter_text = self:get_filter_text()
        self.subviews.sel_hf_list:setChoices()
        self.subviews.sel_art_list:setChoices()
        return true
    end
    return self.super.onInput(self, keys)
end
-------------------------------
--Coordinate & adventurer data
-------------------------------

function global_from_local(pos) --Calc global coords (blocks from world origin) from local map pos
    return pos and {x = world.map.region_x*3 + pos.x//16, y = world.map.region_y*3 + pos.y//16} or nil
end

function get_adv_data() --All the coords we can get
    local adv = dfhack.world.getAdventurer()
    if not adv then --Army exists when unit doesn't
        local army = df.army.find(df.global.adventure.player_army_id)
        if army then --Should always exist if unit doesn't
            return {g_pos = army.pos}
        end
        return nil --Error
    end
    return {g_pos = global_from_local(adv.pos), pos = adv.pos}
end

----------------------
--Death & whereabouts 
----------------------

---- Functions for getting target data ----

local function div(n, d) return n//d, n%d end
--We can get the MLT coords of a CZ from its ID (e.g., hf.info.whereabouts.cz_id)
--The g_pos will represent the center of the 3x3 MLT
--In testing, the HF of interest remained in limbo, but it might be of use to someone

function cz_g_pos(cz_id) --Creation zone center in global coords
    if not cz_id or cz_id < 0 then return nil end
    local w, t, rem = world.world_data.world_width, {}, nil
    t.reg_y, rem = div(cz_id, 16*16*w)
    t.mlt_y, rem = div(rem, 16*w)
    t.reg_x, t.mlt_x = div(rem, 16)
    return {x = (t.reg_x*16 + t.mlt_x)*3+1, y = (t.reg_y*16 + t.mlt_y)*3+1}
end

function site_g_pos(site) --Site center in global coords (blocks from world origin)
    local x, y = site.global_min_x, site.global_min_y
    x, y = (x + (site.global_max_x - x)//2)*3+1, (y + (site.global_max_y - y)//2)*3+1
    return {x = x, y = y}
end

local function apply_site_z(site, g_pos) --Improve Z coord using site
    local pos = g_pos or site_g_pos(site) --Fall back on site center
    pos.z = site.min_depth == site.max_depth and site.min_depth or nil --Single layer site
    return pos --Return new table
end

local function death_at_idx(idx) --Return death location data
    if idx then --Dead
        local event = world.history.events_death[idx]
        return {site = event.site, sr = event.subregion, layer = event.feature_layer}
    end
    return {site = -1, sr = -1, layer = -1} --Alive
end

local death_hfid, death_found_idx, death_last_idx --Cache history.events_death data
function get_death_data(hf) --Try to get death location data
    if hf.died_year == -1 then --Alive (or undead)
        return death_at_idx()
    elseif hf.id ~= death_hfid then --Wrong HF, clear cache
        death_hfid, death_found_idx, death_last_idx = hf.id, nil, nil
    end
    local deaths = world.history.events_death
    local deaths_end = #deaths-1

    if death_last_idx and death_last_idx == deaths_end then --No new entries
        return death_at_idx(death_found_idx) --Use cached death
    end
    death_last_idx = death_last_idx or 0 --First time search entire vector

    for i=deaths_end, death_last_idx, -1 do --Iterate new entries backwards
        local event = deaths[i]
        if event._type == df.history_event_hist_figure_diedst then
            if event.victim_hf == hf.id then
                death_found_idx = i --Cache HF's most recent death
                break
            end
        elseif event._type == df.history_event_hist_figure_revivest then
            if event.histfig == hf.id then --Just in case died_year check failed somehow
                death_found_idx = nil --Clear death state
                break
            end
        end
    end
    death_last_idx = deaths_end --Cache latest index
    return death_at_idx(death_found_idx)
end

local function get_whereabouts(hf) --Return state profile data
    local w = hf and hf.info and hf.info.whereabouts
    if w then
        local g_pos = w.abs_smm_x >= 0 and {x = w.abs_smm_x, y = w.abs_smm_y} or nil
        return {site = w.site_id, sr = w.subregion_id, layer = w.feature_layer_id, army = w.army_id, g_pos = g_pos}
    end
    return {site = -1, sr = -1, layer = -1, army = -1}
end
------------------------
--Target data extractors
------------------------

function get_unit_data(unit)
    if not unit then return nil end
    local pos = xyz2pos(dfhack.units.getPosition(unit))
    pos = pos.x >= 0 and pos or nil
    return {
        loc_type = LType.Local,
        g_pos = global_from_local(pos),
        pos = pos
    }
end

function get_hf_data(hf) --Locational data and coords
    if not hf then --No target
        return nil
    end

    local where = get_whereabouts(hf)
    for _,unit in ipairs(world.units.active) do
        if unit.id == hf.unit_id then --Unit is loaded and active (i.e., player not traveling)
            local pos = xyz2pos(dfhack.units.getPosition(unit))
            pos = pos.x >= 0 and pos or nil --Avoid bad coords
            local g_pos = global_from_local(pos) or where.g_pos
            return {loc_type = LType.Local, g_pos = g_pos, pos = pos}
        end
    end
    local death = get_death_data(hf)

    local site = df.world_site.find(get_id(where.site, death.site))
    if site then --Site
        return {loc_type = LType.Site, site = site, g_pos = apply_site_z(site, where.g_pos)}
    end

    local sr = df.world_region.find(get_id(where.sr, death.sr))
    if sr then --Surface biome
        if where.g_pos then
            where.g_pos.z = 0 --Must be surface
        end
        return {loc_type = LType.Wild, sr = sr, g_pos = where.g_pos}
    end

    local layer = df.world_underground_region.find(get_id(where.layer, death.layer))
    if layer then --Cavern layer
        if where.g_pos then
            where.g_pos.z = layer.layer_depth
        end
        return {loc_type = LType.Under, g_pos = where.g_pos}
    end

    local army = df.army.find(where.army)
    if army then --Traveling
        return {loc_type = LType.Army, g_pos = army.pos}
    end

    if #hf.site_links > 0 then --Try to grab site from links
        local site = df.world_site.find(hf.site_links[#hf.site_links-1].site) --Only try last link
        if site and utils.binsearch(site.populace.nemesis, hf.nemesis_id) then --HF is present
            return {loc_type = LType.Site, site = site, g_pos = apply_site_z(site, where.g_pos)}
        end
    end
    --We'd try cz_g_pos here if it actually helped
    return {loc_type = LType.None, g_pos = where.g_pos} --Probably in limbo
end

function get_art_data(ar) --Locational data and coords
    if not ar then --No target
        return nil
    end
    local holder = findHF(get_id(ar.holder_hf, ar.owner_hf))
    local data = get_hf_data(holder) or {loc_type = LType.None}
    data.holder = holder

    local g_pos = ar.abs_tile_x >= 0 and {x = ar.abs_tile_x//16, y = ar.abs_tile_y//16} or nil

    for _,item in ipairs(world.items.other.ANY_ARTIFACT) do
        if item == ar.item then --Item is nearby if categorized
            local pos = xyz2pos(dfhack.items.getPosition(item))
            pos = pos.x >= 0 and pos or nil --Avoid bad coords
            g_pos = global_from_local(pos) or g_pos
            return {loc_type = LType.Local, holder = holder, g_pos = g_pos, pos = pos}
        end
    end

    local site = df.world_site.find(get_id(ar.site, ar.storage_site))
    if site then --Site
        return {loc_type = LType.Site, site = site, holder = holder, g_pos = apply_site_z(site, g_pos)}
    end

    if data.loc_type ~= LType.None then --Inherit from holder (seems lower priority than site)
        return data
    end

    local sr = df.world_region.find(get_id(ar.subregion, ar.loss_region))
    if sr then --Surface biome
        if g_pos then
            g_pos.z = 0 --Must be surface
        end
        return {loc_type = LType.Wild, holder = holder, sr = sr, g_pos = g_pos}
    end

    local layer = df.world_underground_region.find(get_id(ar.feature_layer, ar.last_layer))
    if layer then --Cavern layer
        if g_pos then
            g_pos.z = layer.layer_depth
        end
        return {loc_type = LType.Under, holder = holder, g_pos = g_pos}
    end

    data.g_pos = data.g_pos or g_pos or nil --Try our own if no holder g_pos
    return data --Probably in limbo
end
--------------
--Pathing hook
--------------

-- teleporting to the target

local function teleport_to_target()
    -- 1) Grab your army record
    local my_army_id = df.global.adventure.player_army_id
    local my_army    = df.army.find(my_army_id)
    if not my_army then
        dfhack.gui.showPopupAnnouncement(
            "[FF0000]Error: Player army not found. You must first be in map mode and move at least one tile."
        )
        return
    end

    -- 2) Fetch the selected target’s data
    local target_data
    if sel_hf  and sel_hf  >= 0 then
        target_data = get_hf_data(df.historical_figure.find(sel_hf))
    elseif sel_art and sel_art >= 0 then
        target_data = get_art_data(df.artifact_record.find(sel_art))
    elseif sel_unit and sel_unit >= 0 then
        target_data = get_unit_data(df.unit.find(sel_unit))
    end
    if not target_data then
        dfhack.gui.showPopupAnnouncement("[FF0000]Error: No target selected.")
        return
    end

    -- 3) Determine block‐coords (g_pos) for the target
    local block_pos = target_data.g_pos
    if not block_pos then
        if target_data.pos then
            block_pos = global_from_local(target_data.pos)
        else
            dfhack.gui.showPopupAnnouncement("[FF0000]Error: Target has no valid position data.")
            return
        end
    end

    -- 4) Clamp into int16 range
    local function clamp_i16(v)
        if type(v) ~= 'number' then return 0 end
        if v < -32768 then return -32768 end
        if v >  32767 then return  32767 end
        return v
    end
    local bx = clamp_i16(block_pos.x)
    local by = clamp_i16(block_pos.y)

    -- 5) Apply to your army
    my_army.pos.x = bx
    my_army.pos.y = by

    -- 6) Check alignment and announce
    if my_army.pos.x == block_pos.x and my_army.pos.y == block_pos.y then
        dfhack.gui.showPopupAnnouncement("[00FF00]You have arrived at the target.")
    else
        dfhack.gui.showPopupAnnouncement("[FF0000]More teleports required.")
    end
end


function begin_auto_pathing()
    local you = df.global.world.units.adv_unit
    if not (you and you.path and you.path.dest) then return end

    local pos
    if sel_hf >= 0 then
        local hf = df.historical_figure.find(sel_hf)
        local data = get_hf_data(hf)
        pos = data and (data.pos or data.g_pos)
    elseif sel_art >= 0 then
        local art = df.artifact_record.find(sel_art)
        local data = get_art_data(art)
        pos = data and (data.pos or data.g_pos)
    elseif sel_unit >= 0 then
        local unit = df.unit.find(sel_unit)
        local data = get_unit_data(unit)
        pos = data and (data.pos or data.g_pos)
    end

    if pos and pos.x and pos.y and pos.z then
        you.path.dest.x = pos.x
        you.path.dest.y = pos.y
        you.path.dest.z = pos.z
        you.path.goal = 215
    end
end
---------------------------------
--Text-layout & compass utilities
---------------------------------

---- Functions for adventurer info panel ----

local compass_dir = {
    'E','ENE','NE','NNE',
    'N','NNW','NW','WNW',
    'W','WSW','SW','SSW',
    'S','SSE','SE','ESE',
}
local compass_pointer = { --Same chars as movement indicators
    '>',string.char(191),string.char(191),string.char(191),
    '^',string.char(218),string.char(218),string.char(218),
    '<',string.char(192),string.char(192),string.char(192),
    'v',string.char(217),string.char(217),string.char(217),
}

local idx_div_two_pi = 16/(2*math.pi) --16 indices / 2*Pi radians
function compass(dx, dy) --Handy compass strings
    if dx*dx + dy*dy == 0 then --On target
      return '***', string.char(249) --Char 249 is centered dot
    end
    local angle = math.atan(-dy, dx) --North is -Y
    local index = math.floor(angle*idx_div_two_pi + 16.5)%16 --0.5 helps rounding
    return compass_dir[index + 1], compass_pointer[index + 1]
end

local function insert_text(t, text) --Insert newline before text
    if text and text ~= '' then
        table.insert(t, NEWLINE)
        table.insert(t, text)
    end
end

local function relative_text(t, adv_data, target_data) --Add relative coords and compass
    if not target_data then --No target
        return
    end
    if target_data.pos and adv_data.pos then --Use local
        local dx = target_data.pos.x - adv_data.pos.x
        local dy = target_data.pos.y - adv_data.pos.y
        local dir, point = compass(dx, dy)
        table.insert(t, NEWLINE) --Improve visibility
        insert_text(t, 'Target (local):')
        insert_text(t, point..' '..dir)
        insert_text(t, ('X%+d Y%+d Z%+d'):format(dx, dy, target_data.pos.z - adv_data.pos.z))
    elseif target_data.g_pos and adv_data.g_pos then --Use global
        local dx = target_data.g_pos.x - adv_data.g_pos.x
        local dy = target_data.g_pos.y - adv_data.g_pos.y
        local dir, point = compass(dx, dy)
        table.insert(t, NEWLINE)
        insert_text(t, {text='Target (global):', pen=COLOR_GREY})
        insert_text(t, {text=point..' '..dir, pen=COLOR_GREY})

        local str = ('X%+d Y%+d'):format(dx, dy)
        if target_data.g_pos.z and adv_data.g_pos.z then --Use Z if we have it
            str = str..(' Z%+d'):format(adv_data.g_pos.z - target_data.g_pos.z) --Negate because it's depth
        end
        insert_text(t, {text=str, pen=COLOR_GREY})
    end --else insufficient data
end

local function pos_text(t, g_pos, pos) --Add available coords
    if g_pos then
        local str = g_pos.z and (' Z'..-g_pos.z) or '' --Use Z if we have it, negate because it's depth
        insert_text(t, {text='Global: X'..g_pos.x..' Y'..g_pos.y..str, pen=COLOR_GREY})
    else --Keep compass in consistent spot
        table.insert(t, NEWLINE)
    end
    if pos then
        insert_text(t, ('Local: X%d Y%d Z%d'):format(pos.x, pos.y, pos.z))
    else
        table.insert(t, NEWLINE)
    end
end
-----------------------
--Panel text generators
-----------------------

local function adv_text(adv_data, target_data) --Text for adv info panel
    if not adv_data then
        return 'Error'
    end
    local t = {'You'} --You, global, local, relative
    pos_text(t, adv_data.g_pos, adv_data.pos)

    relative_text(t, adv_data, target_data)
    return t
end

-- Simplified unit_text: name, status, race, coords – no professions
local function unit_text(unit, target_data)
    if not unit or not target_data then return '' end
    local t = {}

    -- 1) First line: just the name
    local name = dfhack.units.getReadableName(unit)
    table.insert(t, name)

    -- 2) Alive/Dead status
    if not dfhack.units.isDead(unit) then
        insert_text(t, { text='ALIVE', pen=COLOR_LIGHTGREEN })
    else
        insert_text(t, { text='DEAD',  pen=COLOR_RED })
    end

    -- 3) Race
    insert_text(t, get_race_name(unit))

    -- 4) Position info (global/local compass, etc.)
    pos_text(t, target_data.g_pos, target_data.pos)

    return t
end

---- Functions for target info panel ----

local function insert_name_text(t, name)
    -- Insert a single line containing native and translated names together
    local native = transName(name, false)
    if native == '' then
        native = 'Anonymous'
    end
    local translated = transName(name, true)
    -- Build full display name: native plus translation in quotes if different
    local full = native
    if translated ~= '' and translated ~= native then
        full = full .. ' "' .. translated .. '"'
    end
    table.insert(t, full)
    -- no return: default nil indicates single-line insertion
end

-- Simplified HF info‐panel text: prefer getReadableName when loaded
local function hf_text(hf, target_data)
    if not hf or not target_data then
        return ''
    end

    local t = {}

    -- 1) Name: prefer readable if unit is loaded
    local display_name
    if hf.unit_id and hf.unit_id >= 0 then
        local u = df.unit.find(hf.unit_id)
        if u and not dfhack.units.isDead(u) then
            display_name = dfhack.units.getReadableName(u)
        end
    end
    if not display_name then
        display_name = transName(hf.name, false)
        if display_name == '' then display_name = 'Anonymous' end
    end
    table.insert(t, display_name)

    -- 2) Race
    local race = get_race_name(hf)
    insert_text(t, race ~= '' and race or 'Force')

    -- 3) Alive/Dead or Eternal/Missing
    if hf.died_year ~= -1 then
        insert_text(t, {text='DEAD', pen=COLOR_RED})
    elseif hf.old_year == -1 and target_data.loc_type == LType.None then
        insert_text(t, {text='ETERNAL', pen=COLOR_LIGHTBLUE})
    else
        insert_text(t, {text='ALIVE', pen=COLOR_LIGHTGREEN})
    end

    -- 4) Location descriptor
    if target_data.loc_type == LType.None then
        local label = (hf.died_year ~= -1) and 'Missing' or 'Transcendent'
        insert_text(t, {text=label, pen=COLOR_MAGENTA})
    elseif target_data.loc_type == LType.Local then
        insert_text(t, 'Nearby')
    elseif target_data.loc_type == LType.Site then
        insert_text(t, {text='At '..transName(target_data.site.name, true), pen=COLOR_LIGHTBLUE})
    elseif target_data.loc_type == LType.Army then
        insert_text(t, {text='Traveling', pen=COLOR_LIGHTBLUE})
    elseif target_data.loc_type == LType.Wild then
        insert_text(t, {text='Wilderness ('..transName(target_data.sr.name, true)..')', pen=COLOR_LIGHTRED})
    elseif target_data.loc_type == LType.Under then
        insert_text(t, {text='Underground', pen=COLOR_LIGHTRED})
    else
        insert_text(t, {text='Error', pen=COLOR_MAGENTA})
    end

    -- 5) Coordinates
    pos_text(t, target_data.g_pos, target_data.pos)

    return t
end

local function art_text(art, target_data) --Artifact text for target info panel
    if not art or not target_data then --No target
        return ''
    end
    local t = {} --Native, [translated], item_type, [held,] location, global, local

    local both_lines = insert_name_text(t, art.name)
    insert_text(t, dfhack.items.getDescription(art.item, 1, true))
    if not both_lines then --Consistent spacing
        table.insert(t, NEWLINE)
    end

    if target_data.holder then
        local str = 'Held by '..transName(target_data.holder.name, false)
        insert_text(t, {text=str, pen=(target_data.holder.died_year == -1 and COLOR_LIGHTGREEN or COLOR_RED)})
    else --Consistent spacing
        table.insert(t, NEWLINE)
    end

    if target_data.loc_type == LType.None then
        insert_text(t, {text='Missing', pen=COLOR_MAGENTA})
    elseif target_data.loc_type == LType.Local then
        insert_text(t, 'Nearby')
    elseif target_data.loc_type == LType.Site then
        insert_text(t, {text='At '..transName(target_data.site.name, true), pen=COLOR_LIGHTBLUE})
    elseif target_data.loc_type == LType.Army then
        insert_text(t, {text='Traveling', pen=COLOR_LIGHTBLUE})
    elseif target_data.loc_type == LType.Wild then
        insert_text(t, {text='Wilderness ('..transName(target_data.sr.name, true)..')', pen=COLOR_LIGHTRED})
    elseif target_data.loc_type == LType.Under then
        insert_text(t, {text='Underground', pen=COLOR_LIGHTRED})
    else --Undefined loc_type
        insert_text(t, {text='Error', pen=COLOR_MAGENTA})
    end
    pos_text(t, target_data.g_pos, target_data.pos)
    return t
end
-------------------
-- AdvFindWindow --
-------------------

AdvFindWindow = defclass(AdvFindWindow, widgets.Window)
AdvFindWindow.ATTRS{
    frame_title = 'Finder',
    frame = {w=31, h=30, t=22, r=2},
    resizable = true,
}

function AdvFindWindow:init()
    self:addviews{
        widgets.Panel{
            view_id = 'adv_panel',
            frame = {t=1, h=9},
            frame_style = gui.FRAME_INTERIOR,
            subviews = {
                widgets.Label{
                    view_id = 'adv_label',
                    text = '',
                    frame = {t=0},
                },
            },
        },
        widgets.Panel{
            view_id = 'target_panel',
            frame = {t=11, h=9},
            frame_style = gui.FRAME_INTERIOR,
            subviews = {
                widgets.Label{
                    view_id = 'target_label',
                    text = '',
                    frame = {t=0},
                },
            },
        },
-- Auto Path Panel (renamed from extra_panel)
widgets.Panel{
    view_id = 'path_panel',
    frame = {t=20, h=3},
    frame_style = gui.FRAME_INTERIOR,
    subviews = {
        widgets.HotkeyLabel{
            view_id     = 'path_button',
            label       = 'Auto Path',
            key         = 'CUSTOM_CTRL_P',
            auto_width  = true,
            frame       = {l=1},
            on_activate = begin_auto_pathing,
        },
    },
},

-- New Teleport Panel
widgets.Panel{
    view_id = 'teleport_panel',
    frame = {t=23, h=3},
    frame_style = gui.FRAME_INTERIOR,
    subviews = {
        widgets.HotkeyLabel{
            view_id     = 'teleport_button',
            label       = 'Port to Target',
            key         = 'CUSTOM_CTRL_T',
            auto_width  = true,
            frame       = {l=1},
on_activate = function()
    local ok, err = pcall(teleport_to_target)
    if not ok then
        dfhack.printerr("Teleport failed: " .. tostring(err))
    end
end,
        },
    },
},


        widgets.ConfigureButton{
            frame = {t=0, r=0},
            on_click = function()
                local sel_window = view.subviews[2]
                sel_window.visible = true
                sel_window:sel_list()
            end,
        },
    }
end

local function set_title(self)
    if debug_id then
        local id = get_id(sel_hf, get_id(sel_art, sel_unit))
        self.frame_title = 'Finder'..(id ~= -1 and ' (#'..id..')' or '')
    else
        self.frame_title = 'Finder'
    end
end


function AdvFindWindow:onRenderFrame(dc, rect)
    if not dfhack.world.isAdventureMode() then
        view:dismiss()
        print('gui/adv-finder: lost adv mode, dismissing view')
    end
    self.super.onRenderFrame(self, dc, rect)

    local adv_panel    = self.subviews.adv_panel
    local target_panel = self.subviews.target_panel
    local target_data

    if sel_hf >= 0 then
        -- Historical Figure
        local target_hf = findHF(sel_hf)
        target_data = get_hf_data(target_hf)
        target_panel.subviews.target_label:setText(
            hf_text(target_hf, target_data)
        )

    elseif sel_art >= 0 then
        -- Artifact (with fixed holder‐position override)
        local target_art = df.artifact_record.find(sel_art)
        local data       = get_art_data(target_art)

        if data.holder then
            local hdata = get_hf_data(data.holder)
            if hdata.pos then
                -- holder is actually loaded → use exact tile coords for local
                data.pos   = hdata.pos
                data.g_pos = global_from_local(hdata.pos)
            elseif hdata.g_pos then
                -- fallback to block coords
                data.g_pos = hdata.g_pos
                data.pos   = nil
            end
        end

        target_data = data
        target_panel.subviews.target_label:setText(
            art_text(target_art, target_data)
        )

    elseif sel_unit >= 0 then
        -- Unit
        local unit = df.unit.find(sel_unit)
        target_data = get_unit_data(unit)
        target_panel.subviews.target_label:setText(
            unit_text(unit, target_data)
        )

    else
        -- Nothing selected
        target_panel.subviews.target_label:setText()
    end

    -- Adventurer panel: will now pick up data.pos if set, else use data.g_pos
    adv_panel.subviews.adv_label:setText(
        adv_text(get_adv_data(), target_data)
    )

    adv_panel:updateLayout()
    target_panel:updateLayout()
    set_title(self)
end

AdvFindScreen = defclass(AdvFindScreen, gui.ZScreen)
AdvFindScreen.ATTRS{
    focus_path = 'advfinder',
}
---------------
--AdvFindScreen
---------------
function AdvFindScreen:init()
    self:addviews{AdvFindWindow{}, AdvSelWindow{}}
end

function AdvFindScreen:onDismiss()
    view = nil
end

if dfhack_flags.module then
    return
end

if not dfhack.world.isAdventureMode() then
    qerror('Adventure mode only!')
end
------------------------------------
--Event-handler & argparse callbacks
------------------------------------

dfhack.onStateChange['adv-finder'] = function(sc)
    if sc == SC_WORLD_UNLOADED then --Data is world-specific
        sel_hf = -1 --Invalidate IDs
        sel_art = -1
        filter_text = nil --Probably unwanted
        cur_tab = 1 --Reset to first tab, but keep other settings
        print('gui/adv-finder: cleared target')
        dfhack.onStateChange['adv-finder'] = nil --Do once
    end
end

argparse.processArgsGetopt({...}, {
    {'h', 'histfig', handler = function(arg)
        sel_hf = math.tointeger(arg) or -1
        sel_art = -1
    end, hasArg = true},
    {'a', 'artifact', handler = function(arg)
        sel_art = math.tointeger(arg) or -1
        sel_hf = -1
    end, hasArg = true},
    {'d', 'debug', handler = function() debug_id = true end},
})

view = view and view:raise() or AdvFindScreen{}:show()
