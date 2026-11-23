--[[
Assumptions:
- [A1] Windower's `texts` library renders fixed-width Consolas text at (pos_x, pos_y). Character cell dimensions are ~7.2px wide by 15.5px high at size 10, allowing deterministic line and column hit-testing on mouse left-click release (type == 2) without blocking normal camera dragging.
- [A2] Every clickable control is registered during `hud.render(state)` as a line-indexed hit region `{col_start, col_end, action, arg1, arg2}` so clicks always match what is currently displayed on screen.
- [A3] The HUD mirrors the Cure Please v2.0.4.4f main window (Pause/Start, Profile, Selected PL, Monitored Player, Party 1-3 rows with Enable/High-Priority/MENU/AUTO buttons, expandable Options & Party Buffs drawers, and Current Action bar).
]]

local texts = require('texts')
local xml_loader = require('xml_loader')

local hud = {}

local CHAR_W = 7.2
local LINE_H = 15.6
local PAD_X  = 6
local PAD_Y  = 6

hud.box = nil
hud.pos_x = 1180
hud.pos_y = 60
hud.visible = true
hud.hit_map = {} -- line_index (1-based) -> list of {c1, c2, callback_id, arg1, arg2}
hud.mouse_down_in_hud = false

-- Colors in Windower text format \cs(R,G,B) ... \cr
local C_TITLE  = '\\cs(120,200,255)'
local C_GREEN  = '\\cs(100,255,120)'
local C_RED    = '\\cs(255,95,95)'
local C_YELLOW = '\\cs(255,220,100)'
local C_CYAN   = '\\cs(110,235,235)'
local C_GRAY   = '\\cs(155,155,155)'
local C_ORANGE = '\\cs(255,165,80)'
local C_WHITE  = '\\cs(240,240,240)'
local CR       = '\\cr'

function hud.init(pos_x, pos_y)
    hud.pos_x = pos_x or hud.pos_x
    hud.pos_y = pos_y or hud.pos_y
    hud.box = texts.new({
        pos = {x = hud.pos_x, y = hud.pos_y},
        padding = PAD_X,
        text = {
            font = 'Consolas',
            size = 10,
            alpha = 255,
            red = 235,
            green = 235,
            blue = 235,
            stroke = {width = 1, alpha = 200, red = 0, green = 0, blue = 0},
        },
        bg = {
            alpha = 185,
            red = 18,
            green = 22,
            blue = 30,
            visible = true,
        },
        flags = {
            draggable = true,
            bold = false,
        },
    })
    hud.box:show()
end

local function add_hit(line_num, c1, c2, action, arg1, arg2)
    if not hud.hit_map[line_num] then
        hud.hit_map[line_num] = {}
    end
    table.insert(hud.hit_map[line_num], {
        c1 = c1,
        c2 = c2,
        action = action,
        arg1 = arg1,
        arg2 = arg2,
    })
end

local function btn(active, label_on, label_off)
    if active then
        return C_GREEN .. '[' .. label_on .. ']' .. CR
    else
        return C_GRAY .. '[' .. (label_off or label_on) .. ']' .. CR
    end
end

local function hp_color(hpp)
    if not hpp then return C_GRAY end
    if hpp <= 40 then return C_RED
    elseif hpp <= 75 then return C_YELLOW
    else return C_GREEN end
end

-- Build short debuff badge string for a member's active buff IDs
local function format_debuff_badges(buff_set)
    if not buff_set then return '' end
    local tags = {}
    if buff_set[15] then table.insert(tags, C_RED .. 'DOOM' .. CR) end
    if buff_set[7] or buff_set[18] then table.insert(tags, C_ORANGE .. 'PETR' .. CR) end
    if buff_set[2] or buff_set[19] then table.insert(tags, C_CYAN .. 'SLP' .. CR) end
    if buff_set[6] then table.insert(tags, C_YELLOW .. 'SIL' .. CR) end
    if buff_set[4] or buff_set[566] then table.insert(tags, C_YELLOW .. 'PAR' .. CR) end
    if buff_set[9] or buff_set[20] or buff_set[30] then table.insert(tags, C_ORANGE .. 'CRS' .. CR) end
    if buff_set[8] or buff_set[31] then table.insert(tags, C_ORANGE .. 'VIR' .. CR) end
    if buff_set[3] or buff_set[540] then table.insert(tags, C_GREEN .. 'PSN' .. CR) end
    if buff_set[5] then table.insert(tags, C_GRAY .. 'BLN' .. CR) end
    if buff_set[13] or buff_set[565] or buff_set[194] then table.insert(tags, C_YELLOW .. 'SLW' .. CR) end
    if #tags == 0 then return '' end
    return ' ' .. table.concat(tags, ',')
end

-- Render the HUD and rebuild the line/column click hit map [A2, A3]
function hud.render(state)
    if not hud.box then return end
    if not hud.visible then
        hud.box:hide()
        return
    end
    hud.hit_map = {}
    local lines = {}
    local cfg = state.cfg

    -- Line 1: Header bar with [START/PAUSE], [OPTIONS], [BUFFS], [FOLLOW], [MIN]
    local status_str = state.paused
        and (C_RED .. '[PAUSED ]' .. CR)
        or  (C_GREEN .. '[ACTIVE ]' .. CR)
    local opt_str = state.show_options
        and (C_CYAN .. '[OPTIONS*]' .. CR)
        or  (C_WHITE .. '[OPTIONS ]' .. CR)
    local buf_str = state.show_buffs
        and (C_CYAN .. '[BUFFS*]' .. CR)
        or  (C_WHITE .. '[BUFFS ]' .. CR)
    local min_str = state.minimized
        and (C_YELLOW .. '[+]' .. CR)
        or  (C_GRAY .. '[-]' .. CR)

    -- Plain-text layout of line 1:
    -- "CurePleaseLua [PAUSED ] [OPTIONS ] [BUFFS ] [-]"
    --  1..13          15..23    25..34     36..43   45..47
    table.insert(lines, string.format('%sCurePleaseLua%s %s %s %s %s',
        C_TITLE, CR, status_str, opt_str, buf_str, min_str))
    add_hit(#lines, 15, 23, 'toggle_pause')
    add_hit(#lines, 25, 34, 'toggle_options')
    add_hit(#lines, 36, 43, 'toggle_buffs')
    add_hit(#lines, 45, 48, 'toggle_minimize')

    if state.minimized then
        table.insert(lines, string.format('PL:%s%-10s%s Mon:%s%-10s%s Act:%s%s%s',
            C_CYAN, state.pl_name or 'NONE', CR,
            C_YELLOW, state.monitored_name ~= '' and state.monitored_name or 'NONE', CR,
            C_GREEN, state.current_action or 'Idle', CR))
        hud.box:text(table.concat(lines, '\n'))
        hud.box:show()
        return
    end

    -- Line 2: Profile & Role/IPC bar
    -- "Profile: WHM_SCH.xml   [RELOAD] [SAVE] IPC:ON"
    local prof_str = string.format('%-13s', state.profile_name or 'default.xml')
    local ipc_str = state.ipc_connected and (C_GREEN .. 'IPC:OK' .. CR) or (C_GRAY .. 'IPC:--' .. CR)
    table.insert(lines, string.format('Profile: %s%s%s %s[RELOAD]%s %s[SAVE]%s %s',
        C_CYAN, prof_str, CR, C_WHITE, CR, C_WHITE, CR, ipc_str))
    add_hit(#lines, 24, 31, 'reload_profile')
    add_hit(#lines, 33, 38, 'save_profile')

    -- Line 3: PL & Monitored Player selector bar
    -- "PL: Voicelessb (99%) | Mon: Gimlic       [SET<t>]"
    local pl_disp = string.format('%-10s(%3d%%)', (state.pl_name or 'NONE'):sub(1, 10), state.pl_mpp or 0)
    local mon_disp = string.format('%-12s', (state.monitored_name ~= '' and state.monitored_name or 'NONE'):sub(1, 12))
    table.insert(lines, string.format('PL: %s%s%s | Mon: %s%s%s %s[SET<t>]%s',
        C_GREEN, pl_disp, CR, C_YELLOW, mon_disp, CR, C_CYAN, CR))
    add_hit(#lines, 42, 49, 'set_monitored_target')

    table.insert(lines, C_GRAY .. string.rep('-', 49) .. CR)

    -- Party / Alliance Roster (Mirrors Party 1, Party 2, Party 3 in Screenshot 1)
    -- Columns:
    -- "[ON] [PRI] Name         100% [MENU] [AUTO] badges"
    --  1..4 6..10 12..23       25..28 30..35 37..42
    table.insert(lines, C_TITLE .. 'Enab Prio  Member       HP%  Buffs  Preset Status' .. CR)

    for _, m in ipairs(state.roster or {}) do
        local mcfg = state.member_cfg[m.name] or {enabled = true, high_priority = false, buffs = {}}
        local en_btn  = mcfg.enabled and (C_GREEN .. '[ON]' .. CR) or (C_GRAY .. '[--]' .. CR)
        local pri_btn = mcfg.high_priority and (C_YELLOW .. '[PRI]' .. CR) or (C_GRAY .. '[---]' .. CR)
        local name_col = string.format('%-12s', m.name:sub(1, 12))
        local hpp_col  = string.format('%s%3d%%%s', hp_color(m.hpp), m.hpp or 0, CR)
        local is_menu_open = (state.menu_member == m.name)
        local menu_btn = is_menu_open and (C_CYAN .. '[MENU]' .. CR) or (C_WHITE .. '[MENU]' .. CR)
        local auto_btn = C_GREEN .. '[AUTO]' .. CR
        local badges   = format_debuff_badges(state.party_buffs[m.name])

        table.insert(lines, string.format('%s %s %s %s %s %s%s',
            en_btn, pri_btn, name_col, hpp_col, menu_btn, auto_btn, badges))
        local ln = #lines
        add_hit(ln, 1,  4,  'toggle_member_enable', m.name)
        add_hit(ln, 6,  10, 'toggle_member_prio',   m.name)
        add_hit(ln, 12, 23, 'select_monitored',     m.name)
        add_hit(ln, 30, 35, 'toggle_member_menu',   m.name)
        add_hit(ln, 37, 42, 'auto_member_buffs',    m.name)

        -- If this member's [MENU] is open, show two rows of clickable per-member buff toggles!
        if is_menu_open then
            local mb = mcfg.buffs
            -- Row A: "  -> [Haste] [Haste2] [Phlx2] [Regen] [Refrsh]"
            --       6..12   14..21   23..29  31..37  39..46
            table.insert(lines, string.format('  -> %s %s %s %s %s',
                btn(mb.Haste,     'Haste'),
                btn(mb.HasteII,   'Haste2'),
                btn(mb.PhalanxII, 'Phlx2'),
                btn(mb.Regen,     'Regen'),
                btn(mb.Refresh,   'Refrsh')))
            add_hit(#lines, 6,  12, 'toggle_mbuff', m.name, 'Haste')
            add_hit(#lines, 14, 21, 'toggle_mbuff', m.name, 'HasteII')
            add_hit(#lines, 23, 29, 'toggle_mbuff', m.name, 'PhalanxII')
            add_hit(#lines, 31, 37, 'toggle_mbuff', m.name, 'Regen')
            add_hit(#lines, 39, 46, 'toggle_mbuff', m.name, 'Refresh')

            -- Row B: "  -> [Prot ] [Shell ] [Flrry] [Adloq] [Storm ]"
            --       6..12   14..21   23..29  31..37  39..46
            table.insert(lines, string.format('  -> %s %s %s %s %s',
                btn(mb.Protect,   'Prot '),
                btn(mb.Shell,     'Shell '),
                btn(mb.Flurry,    'Flrry'),
                btn(mb.Adloquium, 'Adloq'),
                btn(mb.Storm,     'Storm ')))
            add_hit(#lines, 6,  12, 'toggle_mbuff', m.name, 'Protect')
            add_hit(#lines, 14, 21, 'toggle_mbuff', m.name, 'Shell')
            add_hit(#lines, 23, 29, 'toggle_mbuff', m.name, 'Flurry')
            add_hit(#lines, 31, 37, 'toggle_mbuff', m.name, 'Adloquium')
            add_hit(#lines, 39, 46, 'toggle_mbuff', m.name, 'Storm')
        end
    end

    -- Expandable [OPTIONS] Quick-Toggle Drawer covering all 8 CurePlease Tabs
    if state.show_options and cfg then
        table.insert(lines, C_GRAY .. string.rep('-', 49) .. CR)
        table.insert(lines, C_TITLE .. 'Quick Options (Click to toggle, //cp save to XML)' .. CR)

        -- Row 1 (Healing): "Heal: [Cure% 75] [Prio% 95] [Overcure] [Undrcure]"
        --                   7..16      18..27     29..38     40..49
        table.insert(lines, string.format('Heal: %s[Cure%3d]%s %s[Prio%3d]%s %s %s',
            C_CYAN, cfg.curePercentage or 75, CR,
            C_YELLOW, cfg.priorityCurePercentage or 95, CR,
            btn(cfg.Overcure, 'Overcure'),
            btn(cfg.Undercure, 'Undrcure')))
        add_hit(#lines, 7,  16, 'cycle_cure_pct')
        add_hit(#lines, 18, 27, 'cycle_prio_pct')
        add_hit(#lines, 29, 38, 'toggle_cfg', 'Overcure')
        add_hit(#lines, 40, 49, 'toggle_cfg', 'Undercure')

        -- Row 2 (AoE/OOP): "AoE : [Curaga3+] [OutOfPty] [WakeSlp ] [HateDia ]"
        table.insert(lines, string.format('AoE : %s %s %s %s',
            btn(cfg.curaga3enabled or cfg.curaga4enabled or cfg.curaga5enabled, 'Curaga3+'),
            btn(cfg.enableOutOfPartyHealing, 'OutOfPty'),
            btn(cfg.wakeSleepEnabled, 'WakeSlp '),
            btn(cfg.autoTarget, 'HateDia ')))
        add_hit(#lines, 7,  16, 'toggle_curaga')
        add_hit(#lines, 18, 27, 'toggle_cfg', 'enableOutOfPartyHealing')
        add_hit(#lines, 29, 38, 'toggle_cfg', 'wakeSleepEnabled')
        add_hit(#lines, 40, 49, 'toggle_cfg', 'autoTarget')

        -- Row 3 (Debuffs): "Debf: [Party-na] [Erase   ] [PLDebuff] [DoomPrio]"
        table.insert(lines, string.format('Debf: %s %s %s %s',
            btn(cfg.enablePartyDebuffRemoval, 'Party-na'),
            btn(cfg.naErase,                  'Erase   '),
            btn(cfg.plDebuffEnabled,          'PLDebuff'),
            btn(cfg.PrioritizeDoomRemoval,    'DoomPrio')))
        add_hit(#lines, 7,  16, 'toggle_cfg', 'enablePartyDebuffRemoval')
        add_hit(#lines, 18, 27, 'toggle_cfg', 'naErase')
        add_hit(#lines, 29, 38, 'toggle_cfg', 'plDebuffEnabled')
        add_hit(#lines, 40, 49, 'toggle_cfg', 'PrioritizeDoomRemoval')

        -- Row 4 (PL Buffs): "Enhc: [Pro/Shel] [Reraise ] [Haste/Rf] [Stonskin]"
        table.insert(lines, string.format('Enhc: %s %s %s %s',
            btn(cfg.plProtectra or cfg.plShellra, 'Pro/Shel'),
            btn(cfg.plReraise,                    'Reraise '),
            btn(cfg.plHaste or cfg.plRefresh,     'Haste/Rf'),
            btn(cfg.plStoneskin,                  'Stonskin')))
        add_hit(#lines, 7,  16, 'toggle_proshell')
        add_hit(#lines, 18, 27, 'toggle_cfg', 'plReraise')
        add_hit(#lines, 29, 38, 'toggle_hasterefresh')
        add_hit(#lines, 40, 49, 'toggle_cfg', 'plStoneskin')

        -- Row 5 (JAs):      "JAs : [Solace  ] [LghtArts] [Sublimat] [Devotion]"
        table.insert(lines, string.format('JAs : %s %s %s %s',
            btn(cfg.AfflatusSolace, 'Solace  '),
            btn(cfg.LightArts,      'LghtArts'),
            btn(cfg.Sublimation,    'Sublimat'),
            btn(cfg.Devotion,       'Devotion')))
        add_hit(#lines, 7,  16, 'toggle_cfg', 'AfflatusSolace')
        add_hit(#lines, 18, 27, 'toggle_cfg', 'LightArts')
        add_hit(#lines, 29, 38, 'toggle_cfg', 'Sublimation')
        add_hit(#lines, 40, 49, 'toggle_cfg', 'Devotion')

        -- Row 6 (GEO/BRD):  "Job : [IndiAura] [GeoLuopn] [Entrust ] [BRDSongs]"
        table.insert(lines, string.format('Job : %s %s %s %s',
            btn(cfg.EnableGeoSpells,    'IndiAura'),
            btn(cfg.EnableLuopanSpells, 'GeoLuopn'),
            btn(cfg.Entrust,            'Entrust '),
            btn(cfg.enableSinging,      'BRDSongs')))
        add_hit(#lines, 7,  16, 'toggle_cfg', 'EnableGeoSpells')
        add_hit(#lines, 18, 27, 'toggle_cfg', 'EnableLuopanSpells')
        add_hit(#lines, 29, 38, 'toggle_cfg', 'Entrust')
        add_hit(#lines, 40, 49, 'toggle_cfg', 'enableSinging')

        local indi_name = xml_loader.INDI_SPELLS[cfg.IndiSpell_Spell or 0] or 'None'
        local geo_name  = xml_loader.GEO_SPELLS[cfg.GeoSpell_Spell or 0] or 'None'
        local ent_name  = xml_loader.INDI_SPELLS[cfg.EntrustedSpell_Spell or 0] or 'None'
        table.insert(lines, string.format('GEO : %s%-12s%s | %s%-12s%s | E:%s%-11s%s',
            C_CYAN, indi_name:sub(1, 12), CR,
            C_GREEN, geo_name:sub(1, 12), CR,
            C_YELLOW, ent_name:sub(1, 11), CR))
    end

    -- Expandable [BUFFS] Inspector Drawer (Mirrors "Party Buffs" button in Screenshot 1)
    if state.show_buffs then
        table.insert(lines, C_GRAY .. string.rep('-', 49) .. CR)
        table.insert(lines, C_TITLE .. 'Tracked Party Buff IDs (Packet 0x076 & IPC)' .. CR)
        for _, m in ipairs(state.roster or {}) do
            local bset = state.party_buffs[m.name]
            local ids = {}
            if bset then
                for bid, _ in pairs(bset) do
                    table.insert(ids, tostring(bid))
                end
                table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)
            end
            local id_str = #ids > 0 and table.concat(ids, ',') or 'none'
            table.insert(lines, string.format('%-11s: %s%s%s', m.name:sub(1, 11), C_CYAN, id_str:sub(1, 35), CR))
        end
    end

    -- Bottom Status Bar: Follow & Current Action
    table.insert(lines, C_GRAY .. string.rep('-', 49) .. CR)
    local follow_active = (state.follow_target and state.follow_target ~= '')
    local follow_btn = follow_active
        and (C_GREEN .. '[FOLLOW:' .. state.follow_target:sub(1, 8) .. ']' .. CR)
        or  (C_GRAY  .. '[FOLLOW:OFF     ]' .. CR)
    table.insert(lines, string.format('%s Dist:%d | Act: %s%s%s',
        follow_btn,
        cfg and cfg.autoFollowDistance or 3,
        C_YELLOW,
        (state.current_action or 'Idle'):sub(1, 20),
        CR))
    add_hit(#lines, 1, 17, 'toggle_follow')

    hud.box:text(table.concat(lines, '\n'))
    hud.box:show()
end

-- Convert mouse (x, y) into a (line_num, col_num) hit check and invoke callback if matched [A1, A2]
function hud.handle_mouse(type, x, y, delta, blocked, on_action)
    if not hud.visible or not hud.box then return false end
    local bx, by = hud.box:pos()
    if not bx or not by then return false end

    local rel_x = x - (bx + PAD_X)
    local rel_y = y - (by + PAD_Y)
    if rel_x < 0 or rel_y < 0 then
        return false
    end

    local line_num = math.floor(rel_y / LINE_H) + 1
    local col_num  = math.floor(rel_x / CHAR_W) + 1
    local hits = hud.hit_map[line_num]
    if not hits then
        return false
    end

    for _, h in ipairs(hits) do
        if col_num >= h.c1 and col_num <= h.c2 then
            if type == 1 then
                -- Left button down on a clickable button
                hud.mouse_down_in_hud = true
                return true
            elseif type == 2 and hud.mouse_down_in_hud then
                -- Left button up on a clickable button
                hud.mouse_down_in_hud = false
                if on_action then
                    on_action(h.action, h.arg1, h.arg2)
                end
                return true
            end
        end
    end

    if type == 2 then
        hud.mouse_down_in_hud = false
    end
    return false
end

return hud
