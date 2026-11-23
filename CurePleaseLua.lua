--[[
Assumptions:
- [A1] Pure Windower 4 Lua replacement for Cure Please v2.0.4.4f. Uses zero external DLLs or memory hooks so monthly FFXI client updates cannot break it.
- [A2] Reads and writes native CurePlease <MySettings> JOB_SUB.xml profiles from `data/settings/<MAIN>_<SUB>.xml` (with all 7 of Kevin's saved profiles pre-installed).
- [A3] Tracks party member buffs/debuffs via incoming packet 0x076 (5 party members) AND zero-config Windower IPC (`windower.send_ipc_message`) when loaded on dual-boxed characters on the same PC.
- [A4] Enforces the FFXI Windower Fair-Play Policy: never injects illegal action packets, checks spell recasts/MP/known-spells/job levels, never casts while moving or mid-cast, and enforces legitimate FFXI spell ranges (< 20.4 yalms for single-target magic, < 8 yalms for Devotion, < 10 yalms for self-centered AoEs).
]]

_addon.name = 'CurePleaseLua'
_addon.author = 'Kevin & Antigravity'
_addon.version = '2.0.0'
_addon.commands = {'cp', 'cureplease', 'cplua'}

require('luau')
require('packets')
local res = require('resources')
local xml_loader = require('xml_loader')
local hud = require('hud')

-- Addon runtime state
local state = {
    paused = true,
    minimized = false,
    show_options = false,
    show_buffs = false,
    profile_name = 'default.xml',
    cfg = xml_loader.get_defaults(),
    key_order = {},
    pl_name = 'NONE',
    pl_mpp = 100,
    monitored_name = '',
    follow_target = '',
    current_action = 'Paused',
    ipc_connected = false,
    menu_member = nil,

    -- Per-member HUD settings: name -> {enabled = bool, high_priority = bool, buffs = {Haste=bool,...}}
    member_cfg = {},
    -- Roster list for HUD rendering: {{name=..., hpp=..., hp=..., mp=..., mpp=..., slot=..., distance=..., in_party=bool}}
    roster = {},
    -- Party & IPC buff table: character_name -> {[buff_id] = true}
    party_buffs = {},
    -- Monitored / IPC remote character state: character_name -> {hp, max_hp, hpp, mp, mpp, status, target_id, updated_at, buffs}
    ipc_peers = {},
    -- Per-member timed buff timestamps: character_name -> {[buff_key] = last_cast_os_clock}
    buff_timers = {},
    -- Singing timestamps
    last_song_cycle = 0,
    song_step = 1,

    -- Casting & movement locks [A4]
    is_casting = false,
    cast_End_Time = 0,
    last_action_time = 0,
    action_delay = 2.6,
    last_tick = 0,
    last_ipc_broadcast = 0,
    last_pos = {x = 0, y = 0},
    is_moving = false,
    moving_stopped_at = 0,
}

local function chat_msg(msg)
    windower.add_to_chat(207, '\31\200[\31\05CurePleaseLua\31\200]\31\207 ' .. tostring(msg))
end

local function ensure_member_cfg(name, is_party1)
    if not name or name == '' then return nil end
    if not state.member_cfg[name] then
        state.member_cfg[name] = {
            enabled = (is_party1 ~= false),
            high_priority = false,
            buffs = {
                Haste = false,
                HasteII = false,
                Flurry = false,
                PhalanxII = false,
                Regen = false,
                Refresh = false,
                Protect = false,
                Shell = false,
                Adloquium = false,
                Storm = false,
            },
        }
    end
    return state.member_cfg[name]
end

-- Auto-load `data/settings/<MAIN>_<SUB>.xml` (or `default.xml`) [A2]
local function load_job_profile(custom_name)
    local player = windower.ffxi.get_player()
    local filename = custom_name
    if not filename then
        if player and player.main_job and player.sub_job and player.sub_job ~= 'NONE' then
            filename = string.format('%s_%s.xml', player.main_job:upper(), player.sub_job:upper())
        elseif player and player.main_job then
            filename = string.format('%s.xml', player.main_job:upper())
        else
            filename = 'default.xml'
        end
    end
    if not filename:lower():match('%.xml$') then
        filename = filename .. '.xml'
    end

    local settings_dir = windower.addon_path .. 'data\\settings\\'
    local filepath = settings_dir .. filename
    local cfg, order = xml_loader.load_xml(filepath)
    if not cfg then
        filepath = settings_dir .. 'default.xml'
        cfg, order = xml_loader.load_xml(filepath)
        if cfg then
            filename = 'default.xml'
        else
            cfg = xml_loader.get_defaults()
            order = {}
            filename = 'built-in'
        end
    end

    state.cfg = cfg
    state.key_order = order or {}
    state.profile_name = filename
    if cfg.autoFollowName and cfg.autoFollowName ~= '' and state.follow_target == '' then
        state.follow_target = cfg.autoFollowName
    end
    if cfg.pauseOnStartBox then
        state.paused = true
        state.current_action = 'Paused (Profile)'
    end
    if cfg.MinimiseonStart then
        state.minimized = true
    end
    chat_msg('Loaded profile: ' .. filename)
    hud.render(state)
end

local function save_job_profile(custom_name)
    local filename = custom_name or state.profile_name or 'default.xml'
    if filename == 'built-in' then filename = 'default.xml' end
    if not filename:lower():match('%.xml$') then
        filename = filename .. '.xml'
    end
    local filepath = windower.addon_path .. 'data\\settings\\' .. filename
    if xml_loader.save_xml(filepath, state.cfg, state.key_order) then
        state.profile_name = filename
        chat_msg('Saved profile: ' .. filename)
    else
        chat_msg('ERROR: Could not write profile to ' .. filepath)
    end
end

-- Packet 0x076 Party Buff Parser (Tracks all 32 buff slots for up to 5 party members) [A3]
local function parse_party_buff_packet(data)
    for k = 0, 4 do
        local uid = data:unpack('I', k * 48 + 5)
        if uid and uid ~= 0 then
            local mob = windower.ffxi.get_mob_by_id(uid)
            if mob and mob.name then
                local bset = {}
                for i = 1, 32 do
                    local low_bits = data:byte(k * 48 + 5 + 16 + i - 1)
                    local high_byte = data:byte(k * 48 + 5 + 8 + math.floor((i - 1) / 4))
                    if low_bits and high_byte then
                        local high_bits = (math.floor(high_byte / (4 ^ ((i - 1) % 4))) % 4) * 256
                        local buff_id = low_bits + high_bits
                        if buff_id ~= 0 and buff_id ~= 255 then
                            bset[buff_id] = true
                        end
                    end
                end
                state.party_buffs[mob.name] = bset
            end
        end
    end
end

-- Update PL's own buffs into state.party_buffs[player.name]
local function refresh_self_buffs(player)
    if not player or not player.name then return end
    local bset = {}
    for _, bid in ipairs(player.buffs or {}) do
        if bid and bid ~= 0 and bid ~= 255 then
            bset[bid] = true
        end
    end
    state.party_buffs[player.name] = bset
end

-- Broadcast player state over Windower IPC so dual-boxed PL/Monitored instances stay synced [A3]
local function broadcast_ipc_state()
    local player = windower.ffxi.get_player()
    if not player or not player.name then return end
    local mob = windower.ffxi.get_mob_by_id(player.id)
    local tgt = windower.ffxi.get_mob_by_target('t')
    local tgt_id = (player.status == 1 and tgt and tgt.id) or 0
    local buff_list = {}
    for _, bid in ipairs(player.buffs or {}) do
        if bid and bid ~= 0 and bid ~= 255 then
            table.insert(buff_list, tostring(bid))
        end
    end
    local max_hp = (player.vitals.hpp > 0)
        and math.floor(player.vitals.hp / (player.vitals.hpp / 100) + 0.5)
        or player.vitals.hp
    local msg = string.format('CPLUA_STATE|%s|%d|%d|%d|%d|%d|%d|%d|%s',
        player.name,
        player.vitals.hp or 0,
        max_hp or 0,
        player.vitals.hpp or 100,
        player.vitals.mp or 0,
        player.vitals.mpp or 100,
        player.status or 0,
        tgt_id,
        table.concat(buff_list, ','))
    windower.send_ipc_message(msg)
end

-- Refresh the Party 1-3 + Out-of-Party Monitored Player roster
local function update_roster()
    local player = windower.ffxi.get_player()
    if not player then return end
    state.pl_name = player.name
    state.pl_mpp  = player.vitals and player.vitals.mpp or 100
    refresh_self_buffs(player)

    local party = windower.ffxi.get_party()
    if not party then return end

    local roster = {}
    local seen = {}
    local slots = {
        'p0', 'p1', 'p2', 'p3', 'p4', 'p5',
        'a10', 'a11', 'a12', 'a13', 'a14', 'a15',
        'a20', 'a21', 'a22', 'a23', 'a24', 'a25',
    }

    for idx, key in ipairs(slots) do
        local mem = party[key]
        if mem and mem.name and mem.name ~= '' then
            local is_p1 = (idx <= 6)
            ensure_member_cfg(mem.name, is_p1)
            local peer = state.ipc_peers[mem.name]
            local max_hp = (peer and peer.max_hp and peer.max_hp > 0) and peer.max_hp
                or ((mem.hpp and mem.hpp > 0 and mem.hp and mem.hp > 0) and math.floor(mem.hp / (mem.hpp / 100) + 0.5))
                or 2000
            local dist_sq = (mem.mob and mem.mob.distance) or (mem.name == player.name and 0) or 9999
            table.insert(roster, {
                name = mem.name,
                slot = key,
                in_party1 = is_p1,
                in_alliance = true,
                hp = mem.hp or 0,
                max_hp = max_hp,
                hpp = mem.hpp or 0,
                mp = mem.mp or (peer and peer.mp) or 0,
                mpp = mem.mpp or (peer and peer.mpp) or 100,
                zone = mem.zone,
                in_zone = (mem.mob ~= nil) or (mem.name == player.name),
                distance_sq = dist_sq,
                mob = mem.mob,
            })
            seen[mem.name] = true
            -- Auto-select p1 as Monitored Player if none is selected yet
            if state.monitored_name == '' and key == 'p1' then
                state.monitored_name = mem.name
            end
        end
    end

    -- Include Out-of-Party Monitored Player if enableOutOfPartyHealing is enabled [A3]
    if state.monitored_name ~= '' and not seen[state.monitored_name] then
        local mname = state.monitored_name
        ensure_member_cfg(mname, true)
        local mob = windower.ffxi.get_mob_by_name(mname)
        local peer = state.ipc_peers[mname]
        if mob or peer then
            local hpp = (peer and peer.hpp) or (mob and mob.hpp) or 100
            local hp  = (peer and peer.hp)  or (hpp * 20)
            local max_hp = (peer and peer.max_hp) or 2000
            table.insert(roster, {
                name = mname,
                slot = 'oop',
                in_party1 = false,
                in_alliance = false,
                hp = hp,
                max_hp = max_hp,
                hpp = hpp,
                mp = (peer and peer.mp) or 0,
                mpp = (peer and peer.mpp) or 100,
                in_zone = (mob ~= nil),
                distance_sq = (mob and mob.distance) or 9999,
                mob = mob,
            })
        end
    end

    state.roster = roster
end

-- Look up a spell in Windower resources and verify player MP, recast, and job/level access [A4]
local SPELL_BY_NAME = {}
for id, sp in pairs(res.spells) do
    if sp and sp.en then
        SPELL_BY_NAME[sp.en:lower()] = sp
    end
end

local JA_BY_NAME = {}
for id, ja in pairs(res.job_abilities) do
    if ja and ja.en then
        JA_BY_NAME[ja.en:lower()] = ja
    end
end

local function has_self_buff(buff_id)
    local player = windower.ffxi.get_player()
    if not player then return false end
    local bset = state.party_buffs[player.name]
    return bset and bset[buff_id] == true
end

local function can_cast_spell(spell_name)
    if not spell_name or spell_name == '' then return false, nil end
    local sp = SPELL_BY_NAME[spell_name:lower()]
    if not sp then return false, nil end

    local player = windower.ffxi.get_player()
    if not player or not player.vitals then return false, nil end

    -- Check Silence / Mute / Omerta
    if has_self_buff(6) or has_self_buff(29) or has_self_buff(262) then
        return false, nil
    end

    -- Check MP requirement
    local min_mp = state.cfg.mpMinCastValue or 0
    local mp_cost = sp.mp_cost or 0
    if player.vitals.mp < mp_cost or (mp_cost > 0 and player.vitals.mp < min_mp) then
        return false, nil
    end

    -- Check known spells list
    local known = windower.ffxi.get_spells()
    if known and known[sp.id] == false then
        return false, nil
    end

    -- Check job / subjob level requirement (including job point spells >= 100 mapped as main_job_level 99)
    local mjob_id = player.main_job_id
    local sjob_id = player.sub_job_id
    local mlvl    = player.main_job_level or 0
    local slvl    = player.sub_job_level or 0
    local req_m   = sp.levels and mjob_id and sp.levels[mjob_id]
    local req_s   = sp.levels and sjob_id and sp.levels[sjob_id]
    local level_ok = false
    if req_m and (mlvl >= req_m or (mlvl == 99 and req_m >= 99)) then
        level_ok = true
    elseif req_s and slvl >= req_s then
        level_ok = true
    end
    if not level_ok then
        return false, nil
    end

    -- Check spell recast timer (in centiseconds; 0 = ready)
    local recasts = windower.ffxi.get_spell_recasts()
    if recasts and recasts[sp.recast_id] and recasts[sp.recast_id] > 0 then
        return false, nil
    end

    return true, sp
end

local function can_use_ja(ja_name)
    if not ja_name or ja_name == '' then return false, nil end
    local ja = JA_BY_NAME[ja_name:lower()]
    if not ja then return false, nil end

    -- Check Amnesia / Impairment
    if has_self_buff(16) or has_self_buff(261) then
        return false, nil
    end

    local recasts = windower.ffxi.get_ability_recasts()
    if not recasts then return false, nil end

    -- Scholar Strategems use recast_id 231 (check charge availability)
    if ja.recast_id == 231 then
        if not has_self_buff(358) and not has_self_buff(359) and not has_self_buff(401) and not has_self_buff(402) then
            return false, nil
        end
    end

    local r = recasts[ja.recast_id]
    if r and r > 0 then
        return false, nil
    end
    return true, ja
end

-- Execute a spell, job ability, or item command and engage the casting lock [A4]
local function execute_action(prefix, action_name, target_name, cast_duration)
    if not action_name or not target_name then return false end
    local cmd = string.format('input %s "%s" %s', prefix, action_name, target_name)
    windower.send_command(cmd)
    local now = os.clock()
    state.is_casting = (prefix == '/ma' or prefix == '/item')
    state.cast_End_Time = now + (cast_duration or 3.2)
    state.last_action_time = now
    state.current_action = string.format('%s -> %s', action_name, target_name)
    hud.render(state)
    return true
end

local function cast_spell(spell_name, target_name)
    local ok, sp = can_cast_spell(spell_name)
    if not ok then return false end
    local cast_time = (sp and sp.cast_time and (sp.cast_time + 2.2)) or 3.5
    return execute_action('/ma', sp.en, target_name, cast_time)
end

local function use_ja(ja_name, target_name)
    local ok, ja = can_use_ja(ja_name)
    if not ok then return false end
    return execute_action('/ja', ja.en, target_name or '<me>', 1.5)
end

-- Check if item exists in inventory or temporary bag before using
local function has_usable_item(item_name)
    local items = windower.ffxi.get_items()
    if not items then return false end
    for _, bag_name in ipairs({'inventory', 'temporary'}) do
        local bag = items[bag_name]
        if type(bag) == 'table' then
            for _, slot in pairs(bag) do
                if type(slot) == 'table' and slot.id and slot.id > 0 and slot.count and slot.count > 0 then
                    local it = res.items[slot.id]
                    if it and it.en and it.en:lower() == item_name:lower() then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- ============================================================================
-- CURE PLEASE v2.0.4.4f PRIORITY DECISION ENGINE
-- ============================================================================

-- 1. Emergency PL Silence & Doom Items
local function check_emergency_items()
    local cfg = state.cfg
    if cfg.plSilenceItemEnabled and has_self_buff(6) then
        local item_name = xml_loader.SILENCE_ITEMS[cfg.plSilenceItem or 0] or 'Echo Drops'
        if has_usable_item(item_name) then
            return execute_action('/item', item_name, '<me>', 2.0)
        end
    end
    if cfg.plDoomEnabled and has_self_buff(15) then
        local item_name = xml_loader.DOOM_ITEMS[cfg.plDoomitem or 0] or 'Holy Water'
        if has_usable_item(item_name) then
            return execute_action('/item', item_name, '<me>', 2.0)
        end
    end
    return false
end

-- 2. Prioritize DOOM Removal (Self, Monitored, Party 1)
local function check_doom_removal()
    local cfg = state.cfg
    if not cfg.PrioritizeDoomRemoval then return false end

    for _, m in ipairs(state.roster) do
        local mcfg = state.member_cfg[m.name]
        if mcfg and mcfg.enabled and m.in_zone and m.hpp > 0 and m.distance_sq < 416 then
            local bset = state.party_buffs[m.name]
            if bset and bset[15] then
                local allowed = (m.name == state.pl_name and cfg.plDebuffEnabled and cfg.plDoom)
                    or (m.name == state.monitored_name and cfg.monitoredDebuffEnabled and cfg.monitoredDoom)
                    or (m.in_party1 and cfg.enablePartyDebuffRemoval and cfg.naCurse)
                if allowed then
                    if cfg.AugmentDoomRemoval and not has_self_buff(78) and can_use_ja('Divine Seal') then
                        return use_ja('Divine Seal', '<me>')
                    end
                    if cast_spell('Cursna', m.name) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- 3. Wake Sleep on Party Members (Cura / Curaga / Cure)
local function check_wake_sleep()
    local cfg = state.cfg
    if not cfg.wakeSleepEnabled or has_self_buff(2) or has_self_buff(19) then
        return false
    end

    for _, m in ipairs(state.roster) do
        local mcfg = state.member_cfg[m.name]
        if mcfg and mcfg.enabled and m.in_zone and m.hpp > 0 and m.distance_sq < 416 and m.name ~= state.pl_name then
            local bset = state.party_buffs[m.name]
            if bset and (bset[2] or bset[19]) then
                local wake_spell = xml_loader.WAKE_SLEEP_SPELLS[cfg.wakeSleepSpell or 1] or 'Curaga'
                if wake_spell == 'Cura' then
                    if m.distance_sq < 100 and cast_spell('Cura', '<me>') then return true end
                else
                    if cast_spell(wake_spell, m.name) then return true end
                end
                if cast_spell('Cure', m.name) then return true end
            end
        end
    end
    return false
end

-- Select the best enabled Cure I..VI tier for `missing_hp` (with Overcure & Undercure)
local function select_cure_spell(missing_hp, is_high_prio)
    local cfg = state.cfg
    local tiers = {
        {en = 'Cure',    enabled = cfg.cure1enabled, amt = cfg.cure1amount or 90},
        {en = 'Cure II', enabled = cfg.cure2enabled, amt = cfg.cure2amount or 196},
        {en = 'Cure III',enabled = cfg.cure3enabled, amt = cfg.cure3amount or 446},
        {en = 'Cure IV', enabled = cfg.cure4enabled, amt = cfg.cure4amount or 833},
        {en = 'Cure V',  enabled = cfg.cure5enabled, amt = cfg.cure5amount or 1051},
        {en = 'Cure VI', enabled = cfg.cure6enabled, amt = cfg.cure6amount or 1321},
    }

    local chosen_idx = nil
    for i = 6, 1, -1 do
        if tiers[i].enabled and missing_hp >= tiers[i].amt then
            chosen_idx = i
            break
        end
    end

    -- If missing_hp is below the lowest enabled tier's amount, pick the lowest enabled tier
    if not chosen_idx then
        for i = 1, 6 do
            if tiers[i].enabled then
                chosen_idx = i
                break
            end
        end
    end
    if not chosen_idx then return nil, 0 end

    if can_cast_spell(tiers[chosen_idx].en) then
        return tiers[chosen_idx].en, chosen_idx
    end

    -- Overcure: step UP a tier if the chosen tier is on cooldown
    local allow_overcure = cfg.Overcure or (cfg.OvercureOnHighPriority and is_high_prio)
    if allow_overcure then
        for i = chosen_idx + 1, 6 do
            if tiers[i].enabled and can_cast_spell(tiers[i].en) then
                return tiers[i].en, i
            end
        end
    end

    -- Undercure: step DOWN a tier if the chosen tier is on cooldown or insufficient MP
    if cfg.Undercure then
        for i = chosen_idx - 1, 1, -1 do
            if tiers[i].enabled and can_cast_spell(tiers[i].en) then
                return tiers[i].en, i
            end
        end
    end

    return nil, 0
end

-- 4. Curaga (Area of Effect Healing) & Single-Target Cures
local function evaluate_best_cure()
    local cfg = state.cfg

    -- Check Curaga across Party 1 members within range
    local curaga_thresh = cfg.curagaCurePercentage or 75
    local req_members   = cfg.curagaRequiredMembers or 3
    local hurt_p1 = {}
    local max_missing = 0
    local lowest_member = nil
    local lowest_hpp = 101

    for _, m in ipairs(state.roster) do
        local mcfg = state.member_cfg[m.name]
        if m.in_party1 and mcfg and mcfg.enabled and m.in_zone and m.hpp > 0 and m.distance_sq < 416 then
            if m.hpp <= curaga_thresh then
                local miss = math.max(0, (m.max_hp or 2000) - (m.hp or 0))
                table.insert(hurt_p1, m)
                if miss > max_missing then max_missing = miss end
                if m.hpp < lowest_hpp then
                    lowest_hpp = m.hpp
                    lowest_member = m
                end
            end
        end
    end

    if #hurt_p1 >= req_members and lowest_member then
        local curaga_tiers = {
            {en = 'Curaga',    enabled = cfg.curagaEnabled,  amt = cfg.curagaAmount or 196},
            {en = 'Curaga II', enabled = cfg.curaga2enabled, amt = cfg.curaga2Amount or 446},
            {en = 'Curaga III',enabled = cfg.curaga3enabled, amt = cfg.curaga3Amount or 833},
            {en = 'Curaga IV', enabled = cfg.curaga4enabled, amt = cfg.curaga4Amount or 1051},
            {en = 'Curaga V',  enabled = cfg.curaga5enabled, amt = cfg.curaga5Amount or 1321},
        }
        local c_spell = nil
        for i = 5, 1, -1 do
            if curaga_tiers[i].enabled and max_missing >= curaga_tiers[i].amt and can_cast_spell(curaga_tiers[i].en) then
                c_spell = curaga_tiers[i].en
                break
            end
        end
        if not c_spell then
            for i = 1, 5 do
                if curaga_tiers[i].enabled and can_cast_spell(curaga_tiers[i].en) then
                    c_spell = curaga_tiers[i].en
                    break
                end
            end
        end
        local tgt_name = (cfg.curagaTargetType == 1 and cfg.curagaTargetName ~= '' and cfg.curagaTargetName)
            or lowest_member.name
        if c_spell then
            return {spell = c_spell, target = tgt_name, tier = 5}
        elseif cfg.accessionCure then
            local s_cure, s_tier = select_cure_spell(max_missing, true)
            if s_cure then
                if not has_self_buff(366) and can_use_ja('Accession') then
                    return {ja = 'Accession', target = '<me>', tier = 5}
                end
                return {spell = s_cure, target = tgt_name, tier = s_tier}
            end
        end
    end

    -- Evaluate Single-Target Cures across Party 1-3 + Out-of-Party Monitored Player
    local best_target = nil
    local best_score  = -1
    local best_missing = 0
    local best_prio = false

    for _, m in ipairs(state.roster) do
        local mcfg = state.member_cfg[m.name]
        local allow_oop = m.in_alliance or cfg.enableOutOfPartyHealing
        if mcfg and mcfg.enabled and allow_oop and m.in_zone and m.hpp > 0 and m.distance_sq < 416 then
            local is_mon  = (m.name == state.monitored_name)
            local is_prio = mcfg.high_priority or (is_mon and cfg.enableMonitoredPriority)
            local thresh  = cfg.curePercentage or 75
            if mcfg.high_priority then
                thresh = cfg.priorityCurePercentage or 95
            elseif is_mon then
                thresh = cfg.monitoredCurePercentage or 85
            end

            if m.hpp <= thresh then
                local miss = math.max(100, math.floor((m.max_hp or 2000) * (100 - m.hpp) / 100))
                local score = (100 - m.hpp) + (is_prio and 25 or 0) + (m.name == state.pl_name and 15 or 0)
                if score > best_score then
                    best_score = score
                    best_target = m
                    best_missing = miss
                    best_prio = is_prio
                end
            end
        end
    end

    if best_target then
        local c_spell, c_tier = select_cure_spell(best_missing, best_prio)
        if c_spell then
            return {spell = c_spell, target = best_target.name, tier = c_tier}
        end
    end
    return nil
end

-- 5. Debuff Removal (PL, Monitored Player, and Party 1 via Packet 0x076 + IPC)
local function check_debuff_removal()
    local cfg = state.cfg

    -- Check Esuna when WHM has Afflatus Misery active and PL has a removable debuff
    if cfg.Esuna and has_self_buff(418) and can_cast_spell('Esuna') then
        local self_b = state.party_buffs[state.pl_name]
        if self_b then
            for _, d in ipairs(xml_loader.DEBUFF_MAP) do
                if self_b[d.id] then
                    return cast_spell('Esuna', '<me>')
                end
            end
        end
    end

    for _, m in ipairs(state.roster) do
        local mcfg = state.member_cfg[m.name]
        if mcfg and mcfg.enabled and m.in_zone and m.hpp > 0 and m.distance_sq < 416 then
            local bset = state.party_buffs[m.name]
            if bset then
                local is_pl  = (m.name == state.pl_name)
                local is_mon = (m.name == state.monitored_name)

                for _, d in ipairs(xml_loader.DEBUFF_MAP) do
                    if bset[d.id] then
                        local should_remove = false
                        if is_pl and cfg.plDebuffEnabled and d.pl_key and cfg[d.pl_key] then
                            should_remove = true
                        elseif is_mon and cfg.monitoredDebuffEnabled and d.mon_key and cfg[d.mon_key] then
                            should_remove = true
                        elseif m.in_party1 and cfg.enablePartyDebuffRemoval then
                            if d.is_erase then
                                should_remove = (cfg.naErase and d.party_key and cfg[d.party_key])
                            elseif d.party_key and cfg[d.party_key] then
                                should_remove = true
                            end
                        end

                        if should_remove and can_cast_spell(d.spell) then
                            -- Use Divine Caress before non-Erase, non-Curse -na spells if enabled
                            if cfg.DivineCaress and not d.is_erase and d.spell ~= 'Cursna'
                                and not has_self_buff(453) and can_use_ja('Divine Caress') then
                                return use_ja('Divine Caress', '<me>')
                            end
                            return cast_spell(d.spell, m.name)
                        end
                    end
                end
            end
        end
    end
    return false
end

-- 6. Job Abilities & Stances (Afflatus, Arts/Addendum, Sublimation, Composure, Convert, Devotion, Majesty)
local function check_job_abilities()
    local cfg = state.cfg
    local player = windower.ffxi.get_player()
    if not player then return false end

    -- WHM Afflatus Solace / Misery
    if player.main_job == 'WHM' then
        if cfg.AfflatusSolace and not has_self_buff(417) and can_use_ja('Afflatus Solace') then
            return use_ja('Afflatus Solace', '<me>')
        elseif cfg.AfflatusMisery and not cfg.AfflatusSolace and not has_self_buff(418) and can_use_ja('Afflatus Misery') then
            return use_ja('Afflatus Misery', '<me>')
        end
    end

    -- SCH / sub-SCH Light Arts, Dark Arts, Addendum, Sublimation
    if player.main_job == 'SCH' or player.sub_job == 'SCH' then
        if cfg.LightArts then
            if not has_self_buff(358) and not has_self_buff(401) and can_use_ja('Light Arts') then
                return use_ja('Light Arts', '<me>')
            elseif cfg.AddendumWhite and has_self_buff(358) and not has_self_buff(401) and can_use_ja('Addendum: White') then
                return use_ja('Addendum: White', '<me>')
            end
        elseif cfg.DarkArts then
            if not has_self_buff(359) and not has_self_buff(402) and can_use_ja('Dark Arts') then
                return use_ja('Dark Arts', '<me>')
            elseif cfg.AddendumBlack and has_self_buff(359) and not has_self_buff(402) and can_use_ja('Addendum: Black') then
                return use_ja('Addendum: Black', '<me>')
            end
        end

        if cfg.Sublimation and can_use_ja('Sublimation') then
            local max_mp = (player.vitals.mpp > 0) and math.floor(player.vitals.mp / (player.vitals.mpp / 100)) or player.vitals.mp
            local missing_mp = math.max(0, max_mp - player.vitals.mp)
            if has_self_buff(188) and missing_mp >= (cfg.sublimationMP or 100) then
                -- Sublimation: Complete -> Pop for MP
                return use_ja('Sublimation', '<me>')
            elseif has_self_buff(187) and cfg.SublimationRecoverWhenCharging and player.vitals.mp < (cfg.mpMinCastValue or 100) and missing_mp >= 200 then
                -- Sublimation: Activated -> Emergency pop while charging
                return use_ja('Sublimation', '<me>')
            elseif not has_self_buff(187) and not has_self_buff(188) and not has_self_buff(43) and player.vitals.hpp > 50 then
                -- Start charging Sublimation
                return use_ja('Sublimation', '<me>')
            end
        end
    end

    -- RDM Composure & Convert
    if player.main_job == 'RDM' or player.sub_job == 'RDM' then
        if player.main_job == 'RDM' and cfg.Composure and not has_self_buff(419) and can_use_ja('Composure') then
            return use_ja('Composure', '<me>')
        end
        if cfg.Convert and player.vitals.mp < (cfg.convertMP or 300) and player.vitals.hpp > 55 and can_use_ja('Convert') then
            return use_ja('Convert', '<me>')
        end
    end

    -- PLD Majesty
    if player.main_job == 'PLD' and cfg.Majesty and not has_self_buff(621) and can_use_ja('Majesty') then
        return use_ja('Majesty', '<me>')
    end

    -- WHM Devotion
    if player.main_job == 'WHM' and cfg.Devotion and player.vitals.hpp > 60 and can_use_ja('Devotion') then
        local dev_thresh = cfg.DevotionMP or 200
        for _, m in ipairs(state.roster) do
            if m.in_party1 and m.name ~= state.pl_name and m.in_zone and m.hpp > 0 and m.distance_sq < 64 then
                local name_match = (cfg.DevotionTargetType ~= 2)
                    or (cfg.DevotionTargetName ~= '' and m.name:lower() == cfg.DevotionTargetName:lower())
                if name_match and m.mp and m.mp > 0 and m.mp < dev_thresh then
                    return use_ja('Devotion', m.name)
                end
            end
        end
    end

    return false
end

-- 7. Geomancy (Indi Aura, Geo Luopan, Entrust, Full Circle, Radial Arcana, Blaze of Glory, Ecliptic, Life Cycle, Dematerialize)
local function check_geomancy()
    local cfg = state.cfg
    local player = windower.ffxi.get_player()
    if not player or (player.main_job ~= 'GEO' and player.sub_job ~= 'GEO') then
        return false
    end

    -- Determine engaged state (self or specified target / monitored player)
    local is_engaged = (player.status == 1)
    if cfg.specifiedEngageTarget then
        local ref_name = (cfg.LuopanSpell_Target ~= '' and cfg.LuopanSpell_Target) or state.monitored_name
        if ref_name and ref_name ~= '' then
            local ref_mob = windower.ffxi.get_mob_by_name(ref_name)
            local peer = state.ipc_peers[ref_name]
            if (peer and peer.status == 1) or (ref_mob and ref_mob.status == 1) then
                is_engaged = true
            end
        end
    end

    -- 7a. Indi Spell (Buff ID 612 = Colure Active)
    if cfg.EnableGeoSpells and (not cfg.IndiWhenEngaged or is_engaged) then
        if not has_self_buff(612) then
            local indi_spell = xml_loader.INDI_SPELLS[cfg.IndiSpell_Spell or 0]
            if indi_spell and cast_spell(indi_spell, '<me>') then
                return true
            end
        end
    end

    -- 7b. Entrust (Buff ID 584 = Entrust)
    if player.main_job == 'GEO' and cfg.Entrust and cfg.EntrustedSpell_Target and cfg.EntrustedSpell_Target ~= '' then
        local ent_target = windower.ffxi.get_mob_by_name(cfg.EntrustedSpell_Target)
        if ent_target and ent_target.hpp > 0 and ent_target.distance < 416 then
            local ent_spell = xml_loader.INDI_SPELLS[cfg.EntrustedSpell_Spell or 0]
            if ent_spell and can_cast_spell(ent_spell) then
                if has_self_buff(584) then
                    return cast_spell(ent_spell, ent_target.name)
                elseif can_use_ja('Entrust') then
                    return use_ja('Entrust', '<me>')
                end
            end
        end
    end

    -- 7c. Luopan Management & Geo Spells
    if player.main_job == 'GEO' and cfg.EnableLuopanSpells then
        local pet = windower.ffxi.get_mob_by_target('pet')
        local geo_spell = xml_loader.GEO_SPELLS[cfg.GeoSpell_Spell or 0]
        local is_enemy_geo = geo_spell and xml_loader.ENEMY_GEO_SPELLS[geo_spell]

        if pet and pet.hpp > 0 then
            -- Radial Arcana MP Recovery when MP is low
            if cfg.RadialArcana and player.vitals.mp < (cfg.RadialArcanaMP or 300) and pet.distance < 36 and can_use_ja('Radial Arcana') then
                return use_ja('Radial Arcana', '<me>')
            end
            -- Full Circle when disengaged (if GeoWhenEngaged is enabled)
            if cfg.FullCircle and cfg.GeoWhenEngaged and not is_engaged and can_use_ja('Full Circle') then
                return use_ja('Full Circle', '<me>')
            end
            -- Ecliptic Attrition / Life Cycle / Dematerialize maintenance on active Luopan
            if cfg.Dematerialize and can_use_ja('Dematerialize') then
                return use_ja('Dematerialize', '<me>')
            end
            if cfg.EclipticAttrition and pet.hpp > 70 and can_use_ja('Ecliptic Attrition') then
                return use_ja('Ecliptic Attrition', '<me>')
            end
            if cfg.LifeCycle and pet.hpp < 45 and player.vitals.hpp > 60 and can_use_ja('Life Cycle') then
                return use_ja('Life Cycle', '<me>')
            end
        elseif not cfg.GeoWhenEngaged or is_engaged then
            if geo_spell and can_cast_spell(geo_spell) then
                if cfg.BlazeOfGlory and not has_self_buff(569) and can_use_ja('Blaze of Glory') then
                    return use_ja('Blaze of Glory', '<me>')
                end
                if is_enemy_geo then
                    -- Target current enemy <bt> or <t>
                    local bt = windower.ffxi.get_mob_by_target('bt') or windower.ffxi.get_mob_by_target('t')
                    if bt and bt.valid_target and bt.is_npc and bt.hpp > 0 and bt.distance < 416 then
                        return cast_spell(geo_spell, tostring(bt.id))
                    end
                else
                    local luo_tgt = (cfg.LuopanSpell_Target ~= '' and cfg.LuopanSpell_Target) or '<me>'
                    return cast_spell(geo_spell, luo_tgt)
                end
            end
        end
    end

    return false
end

-- 8. Bard Singing (Up to 4 Songs + Dummy Songs + Nightingale/Troubadour/Marcato)
local function check_singing()
    local cfg = state.cfg
    local player = windower.ffxi.get_player()
    if not player or player.main_job ~= 'BRD' or not cfg.enableSinging then
        return false
    end

    if cfg.SongsOnlyWhenNear and state.monitored_name ~= '' then
        local mon = windower.ffxi.get_mob_by_name(state.monitored_name)
        if not mon or mon.distance >= 100 then
            return false
        end
    end

    local now = os.clock()
    local interval = (cfg.recastSongTime or 2) * 60
    if (now - state.last_song_cycle) < interval then
        return false
    end

    local queue = {}
    if cfg.song1 then table.insert(queue, {song = xml_loader.SONGS[cfg.song1], marcato = cfg.Marcato}) end
    if cfg.song2 then table.insert(queue, {song = xml_loader.SONGS[cfg.song2]}) end
    if cfg.song3 and cfg.song3 > 0 then
        if cfg.dummy1 then table.insert(queue, {song = xml_loader.SONGS[cfg.dummy1]}) end
        table.insert(queue, {song = xml_loader.SONGS[cfg.song3]})
    end
    if cfg.song4 and cfg.song4 > 0 then
        if cfg.dummy2 then table.insert(queue, {song = xml_loader.SONGS[cfg.dummy2]}) end
        table.insert(queue, {song = xml_loader.SONGS[cfg.song4]})
    end

    if #queue == 0 then return false end
    if state.song_step > #queue then
        state.song_step = 1
        state.last_song_cycle = now
        return false
    end

    if state.song_step == 1 then
        if cfg.Nightingale and not has_self_buff(347) and can_use_ja('Nightingale') then
            return use_ja('Nightingale', '<me>')
        end
        if cfg.Troubadour and not has_self_buff(348) and can_use_ja('Troubadour') then
            return use_ja('Troubadour', '<me>')
        end
    end

    local entry = queue[state.song_step]
    if entry and entry.song then
        if entry.marcato and not has_self_buff(231) and can_use_ja('Marcato') then
            return use_ja('Marcato', '<me>')
        end
        if cast_spell(entry.song, '<me>') then
            state.song_step = state.song_step + 1
            if state.song_step > #queue then
                state.song_step = 1
                state.last_song_cycle = now
            end
            return true
        end
    end
    return false
end

-- Helper to trigger Scholar Accession / Perpetuance before a PL buff if configured in XML
local function check_sch_enhancing_ja(want_accession, want_perpetuance)
    local cfg = state.cfg
    if want_accession and cfg.Accession and not has_self_buff(366) and can_use_ja('Accession') then
        return use_ja('Accession', '<me>')
    end
    if want_perpetuance and cfg.Perpetuance and not has_self_buff(469) and can_use_ja('Perpetuance') then
        return use_ja('Perpetuance', '<me>')
    end
    return false
end

-- 9. Enhancing Spells (PL Self Buffs, Group PL Buffs, and Per-Member MENU/AUTO Party Buffs)
local function check_enhancing()
    local cfg = state.cfg
    local player = windower.ffxi.get_player()
    if not player then return false end

    -- 9a. PL Reraise (Buff ID 113)
    if cfg.plReraise and not has_self_buff(113) then
        local rr_spell = xml_loader.RERAISE_SPELLS[cfg.plReraise_Level or 4] or 'Reraise'
        if cfg.EnlightenmentReraise and not has_self_buff(416) and can_use_ja('Enlightenment') then
            return use_ja('Enlightenment', '<me>')
        end
        if cast_spell(rr_spell, '<me>') then return true end
    end

    -- 9b. Group PL Buffs: Protectra / Shellra / Auspice / BarElement / BarStatus / Gain-Boost
    if cfg.plProtectra and not has_self_buff(40) then
        local sp = (cfg.plProtectra_Level and cfg.plProtectra_Level > 1) and ('Protectra ' .. ({'','II','III','IV','V'})[cfg.plProtectra_Level]) or 'Protectra'
        if cast_spell(sp, '<me>') then return true end
    elseif cfg.plProtect and not has_self_buff(40) then
        if check_sch_enhancing_ja(cfg.accessionProShell, false) then return true end
        local sp = xml_loader.PROTECT_SPELLS[cfg.autoProtect_Spell or 4] or 'Protect V'
        if cast_spell(sp, '<me>') then return true end
    end

    if cfg.plShellra and not has_self_buff(41) then
        local sp = (cfg.plShellra_Level and cfg.plShellra_Level > 1) and ('Shellra ' .. ({'','II','III','IV','V'})[cfg.plShellra_Level]) or 'Shellra'
        if cast_spell(sp, '<me>') then return true end
    elseif cfg.plShell and not has_self_buff(41) then
        if check_sch_enhancing_ja(cfg.accessionProShell, false) then return true end
        local sp = xml_loader.SHELL_SPELLS[cfg.autoShell_Spell or 4] or 'Shell V'
        if cast_spell(sp, '<me>') then return true end
    end

    if cfg.plHaste and not has_self_buff(33) and not has_self_buff(580) then
        local h_spell = (cfg.plHaste_Level == 2 and can_cast_spell('Haste II')) and 'Haste II' or 'Haste'
        if cast_spell(h_spell, '<me>') then return true end
    end

    if cfg.plRefresh and not has_self_buff(43) and not has_self_buff(187) and not has_self_buff(188) then
        if check_sch_enhancing_ja(cfg.refreshAccession, cfg.refreshPerpetuance) then return true end
        local rf_spell = (cfg.plRefresh_Level == 3 and 'Refresh III') or (cfg.plRefresh_Level == 2 and 'Refresh II') or 'Refresh'
        if cast_spell(rf_spell, '<me>') then return true end
    end

    if cfg.plRegen and not has_self_buff(42) then
        if check_sch_enhancing_ja(cfg.regenAccession or cfg.AccessionRegen, cfg.regenPerpetuance or cfg.PerpetuanceRegen) then return true end
        local rg_spell = xml_loader.REGEN_SPELLS[(cfg.plRegen_Level or 4) - 1] or 'Regen IV'
        if cast_spell(rg_spell, '<me>') then return true end
    end

    if cfg.plStoneskin and not has_self_buff(37) then
        if check_sch_enhancing_ja(cfg.stoneskinAccession, cfg.stoneskinPerpetuance) then return true end
        if cast_spell('Stoneskin', '<me>') then return true end
    end

    if cfg.plAquaveil and not has_self_buff(39) then
        if check_sch_enhancing_ja(cfg.aquaveilAccession, cfg.aquaveilPerpetuance) then return true end
        if cast_spell('Aquaveil', '<me>') then return true end
    end

    if cfg.plBlink and not has_self_buff(36) then
        if check_sch_enhancing_ja(cfg.blinkAccession, cfg.blinkPerpetuance) then return true end
        if cast_spell('Blink', '<me>') then return true end
    end

    if cfg.plPhalanx and not has_self_buff(116) then
        if check_sch_enhancing_ja(cfg.phalanxAccession, cfg.phalanxPerpetuance) then return true end
        if cast_spell('Phalanx', '<me>') then return true end
    end

    if cfg.plAuspice and not has_self_buff(275) then
        if cast_spell('Auspice', '<me>') then return true end
    end

    if cfg.plBarElement then
        local idx = cfg.plBarElement_Spell or 0
        local bid = xml_loader.BAR_ELEMENT_BUFF_ID[idx]
        if bid and not has_self_buff(bid) then
            if check_sch_enhancing_ja(cfg.barspellAccession, cfg.barspellPerpetuance) then return true end
            local sp = cfg.AOE_Barelemental and xml_loader.BAR_ELEMENT_AOE[idx] or xml_loader.BAR_ELEMENT_SINGLE[idx]
            if sp and cast_spell(sp, '<me>') then return true end
        end
    end

    if cfg.plBarStatus then
        local idx = cfg.plBarStatus_Spell or 0
        local bid = xml_loader.BAR_STATUS_BUFF_ID[idx]
        if bid and not has_self_buff(bid) then
            if check_sch_enhancing_ja(cfg.barstatusAccession, cfg.barstatusPerpetuance) then return true end
            local sp = cfg.AOE_Barstatus and xml_loader.BAR_STATUS_AOE[idx] or xml_loader.BAR_STATUS_SINGLE[idx]
            if sp and cast_spell(sp, '<me>') then return true end
        end
    end

    if cfg.plGainBoost then
        local sp = xml_loader.GAIN_BOOST_SPELLS[cfg.plGainBoost_Spell or 0]
        local bid = sp and xml_loader.GAIN_BOOST_BUFF_ID[sp]
        if sp and bid and not has_self_buff(bid) then
            if cast_spell(sp, '<me>') then return true end
        end
    end

    if cfg.plStormSpell then
        local sp = xml_loader.STORM_SPELLS[cfg.plStormSpell_Spell or 0]
        local bid = sp and xml_loader.STORM_BUFF_ID[sp]
        if sp and bid and not has_self_buff(bid) then
            if check_sch_enhancing_ja(cfg.stormspellAccession, cfg.stormspellPerpetuance) then return true end
            if cast_spell(sp, '<me>') then return true end
        end
    end

    if cfg.plEnspell then
        local sp = xml_loader.ENSPELLS[cfg.plEnspell_Spell or 0]
        local bid = sp and xml_loader.ENSPELL_BUFF_ID[sp]
        if sp and bid and not has_self_buff(bid) then
            if check_sch_enhancing_ja(cfg.enspellAccession, cfg.enspellPerpetuance) then return true end
            if cast_spell(sp, '<me>') then return true end
        end
    end

    if cfg.plTemper and not has_self_buff(432) then
        local sp = (cfg.plTemper_Level == 2 and can_cast_spell('Temper II')) and 'Temper II' or 'Temper'
        if cast_spell(sp, '<me>') then return true end
    end

    if cfg.plSpikes then
        local sp = xml_loader.SPIKES_SPELLS[cfg.plSpikes_Spell or 0]
        local bid = sp and xml_loader.SPIKES_BUFF_ID[sp]
        if sp and bid and not has_self_buff(bid) then
            if cast_spell(sp, '<me>') then return true end
        end
    end

    if cfg.plKlimaform and not has_self_buff(407) then
        if cast_spell('Klimaform', '<me>') then return true end
    end

    if cfg.plAdloquium and not has_self_buff(170) then
        if check_sch_enhancing_ja(cfg.adloquiumAccession, cfg.adloquiumPerpetuance) then return true end
        if cast_spell('Adloquium', '<me>') then return true end
    end

    if cfg.plUtsusemi and not has_self_buff(66) and not has_self_buff(444) and not has_self_buff(445) and not has_self_buff(446) then
        if cast_spell('Utsusemi: Ni', '<me>') or cast_spell('Utsusemi: Ichi', '<me>') then return true end
    end

    -- 9c. Per-Member MENU / AUTO Party Buffs (Packet 0x076 buff-wear recast + timer fallback)
    local now = os.clock()
    local party_buff_defs = {
        {key = 'HasteII',   spell = 'Haste II',   buff_id = 33,  mins = cfg.autoHasteMinutes or 2},
        {key = 'Haste',     spell = 'Haste',      buff_id = 33,  mins = cfg.autoHasteMinutes or 2},
        {key = 'Flurry',    spell = 'Flurry',     buff_id = 265, mins = cfg.autoHasteMinutes or 2},
        {key = 'PhalanxII', spell = 'Phalanx II', buff_id = 116, mins = cfg.autoPhalanxIIMinutes or 2},
        {key = 'Refresh',   spell = xml_loader.REFRESH_SPELLS[cfg.autoRefresh_Spell or 0] or 'Refresh', buff_id = 43, mins = cfg.autoRefresh_Minutes or 2},
        {key = 'Regen',     spell = xml_loader.REGEN_SPELLS[cfg.autoRegen_Spell or 3] or 'Regen IV',    buff_id = 42, mins = cfg.autoRegen_Minutes or 3},
        {key = 'Protect',   spell = xml_loader.PROTECT_SPELLS[cfg.autoProtect_Spell or 4] or 'Protect V', buff_id = 40, mins = cfg.autoProtect_Minutes or 29},
        {key = 'Shell',     spell = xml_loader.SHELL_SPELLS[cfg.autoShell_Spell or 4] or 'Shell V',       buff_id = 41, mins = cfg.autoShellMinutes or 29},
        {key = 'Adloquium', spell = 'Adloquium',  buff_id = 170, mins = cfg.autoAdloquiumMinutes or 2},
        {key = 'Storm',     spell = xml_loader.STORM_SPELLS[cfg.autoStorm_Spell or 0] or 'Aurorastorm', buff_id = nil, mins = cfg.autoStormspellMinutes or 3},
    }

    for _, m in ipairs(state.roster) do
        local mcfg = state.member_cfg[m.name]
        if mcfg and mcfg.enabled and m.in_zone and m.hpp > 0 and m.distance_sq < 416 then
            local bset = state.party_buffs[m.name]
            if not state.buff_timers[m.name] then state.buff_timers[m.name] = {} end
            local mtimers = state.buff_timers[m.name]

            for _, bd in ipairs(party_buff_defs) do
                if mcfg.buffs[bd.key] then
                    local last_t = mtimers[bd.key] or 0
                    local timer_expired = (now - last_t) >= (bd.mins * 60)
                    -- If we have packet 0x076 buff data for this party member, check if the buff wore off!
                    local buff_missing = false
                    if bset and bd.buff_id then
                        buff_missing = (not bset[bd.buff_id]) and ((now - last_t) > 8.0)
                    else
                        buff_missing = timer_expired
                    end

                    if (buff_missing or timer_expired) and cast_spell(bd.spell, m.name) then
                        mtimers[bd.key] = now
                        return true
                    end
                end
            end
        end
    end

    return false
end

-- 10. Auto-Target Hate Spell (e.g. Dia on Monitored Player's engaged target) & /heal MP management
local last_hate_mob_id = 0
local last_low_mp_tell = 0
local function check_other_options()
    local cfg = state.cfg
    local player = windower.ffxi.get_player()
    if not player then return false end

    -- Optional /tell to Monitored Player when PL MP falls below mpMinCastValue (throttled to once per 60s)
    if cfg.lowMPcheckBox and state.monitored_name ~= '' and state.monitored_name ~= state.pl_name then
        local now = os.clock()
        if player.vitals.mp < (cfg.mpMinCastValue or 100) and (now - last_low_mp_tell) > 60 then
            last_low_mp_tell = now
            windower.send_command(string.format('input /tell %s [CurePleaseLua] Low MP: %d (%d%%)',
                state.monitored_name, player.vitals.mp, player.vitals.mpp))
        end
    end

    -- Stand when MP% >= standAtMP_Percentage (Status 33 = Healing / Resting)
    if player.status == 33 then
        if cfg.standAtMP and player.vitals.mpp >= (cfg.standAtMP_Percentage or 99) then
            windower.send_command('input /heal off')
            state.last_action_time = os.clock()
            state.current_action = 'Stand (MP Full)'
            return true
        end
        return true -- Stay resting until MP threshold or healing emergency
    end

    -- Auto-cast spell to place PL on the hate list (e.g. Dia on engaged mob)
    if cfg.autoTarget and cfg.autoTargetSpell and cfg.autoTargetSpell ~= '' then
        local bt = windower.ffxi.get_mob_by_target('bt')
        if bt and bt.valid_target and bt.is_npc and bt.hpp > 0 and bt.hpp < 99 and bt.distance < 416 and bt.id ~= last_hate_mob_id then
            if cast_spell(cfg.autoTargetSpell, tostring(bt.id)) then
                last_hate_mob_id = bt.id
                return true
            end
        end
    end

    -- /heal when MP is below healWhenMPBelow and not engaged
    if cfg.healLowMP and player.status == 0 and player.vitals.mp < (cfg.healWhenMPBelow or 50) then
        windower.send_command('input /heal on')
        state.last_action_time = os.clock()
        state.current_action = 'Resting (/heal)'
        return true
    end

    return false
end

-- Auto-Follow logic (Maintains configured distance to state.follow_target)
local is_auto_running = false
local function update_auto_follow()
    if state.paused or state.follow_target == '' or state.is_casting then
        if is_auto_running then
            windower.ffxi.run(false)
            is_auto_running = false
        end
        return
    end
    local player = windower.ffxi.get_player()
    local me = player and windower.ffxi.get_mob_by_id(player.id)
    local tgt = windower.ffxi.get_mob_by_name(state.follow_target)
    if not me or not tgt or not tgt.valid_target then
        if is_auto_running then
            windower.ffxi.run(false)
            is_auto_running = false
        end
        return
    end

    local max_dist = state.cfg.autoFollowDistance or 3
    local dist = math.sqrt(tgt.distance or 0)
    if dist > (max_dist + 0.5) and dist < 45 then
        local angle = (math.atan2((tgt.y - me.y), (tgt.x - me.x)) * 180 / math.pi) * -1
        windower.ffxi.run((angle):radian())
        is_auto_running = true
    elseif is_auto_running then
        windower.ffxi.run(false)
        is_auto_running = false
    end
end

-- Main decision tick (runs every 0.35s when unpaused) [A4]
local function run_decision_tick()
    local now = os.clock()
    local player = windower.ffxi.get_player()
    if not player then return end

    -- Movement detection
    local me = windower.ffxi.get_mob_by_id(player.id)
    if me then
        local dx = (me.x or 0) - state.last_pos.x
        local dy = (me.y or 0) - state.last_pos.y
        if (dx * dx + dy * dy) > 0.04 then
            state.is_moving = true
        else
            if state.is_moving then
                state.is_moving = false
                state.moving_stopped_at = now
            end
        end
        state.last_pos.x = me.x or 0
        state.last_pos.y = me.y or 0
    end

    -- Release expired casting lock safety timeout
    if state.is_casting and now >= state.cast_End_Time then
        state.is_casting = false
    end

    -- Broadcast IPC state every 0.6s
    if (now - state.last_ipc_broadcast) >= 0.6 then
        state.last_ipc_broadcast = now
        broadcast_ipc_state()
    end

    update_roster()
    update_auto_follow()

    if state.paused then
        hud.render(state)
        return
    end

    -- Check Pause on KO
    if player.status == 2 or (player.vitals and player.vitals.hp == 0) then
        if state.cfg.pauseOnKO then
            state.paused = true
            state.current_action = 'Paused (KO)'
        end
        hud.render(state)
        return
    end

    -- Do not cast while moving, within 0.4s of stopping, while mid-cast, or during global action delay
    if state.is_moving or (now - state.moving_stopped_at) < 0.35 or state.is_casting or (now - state.last_action_time) < state.action_delay then
        hud.render(state)
        return
    end

    -- Cannot act in event/cutscene/mounted (status 4 = Event, 5/85 = Chocobo/Mount)
    if player.status ~= 0 and player.status ~= 1 and player.status ~= 33 then
        hud.render(state)
        return
    end

    -- Priority 1: Emergency Silence / Doom Items
    if check_emergency_items() then return end

    -- Priority 2: Prioritized Doom Removal
    if check_doom_removal() then return end

    -- Priority 3: Wake Sleep
    if check_wake_sleep() then return end

    -- Priority 4 & 5: Evaluate Best Cure / Curaga vs Debuff Removal (honoring PrioritiseOverLowerTier)
    local cure_plan = evaluate_best_cure()
    if cure_plan then
        -- Wake from /heal if a cure is needed
        if player.status == 33 then
            windower.send_command('input /heal off')
            state.last_action_time = now
            return
        end
        -- If PrioritiseOverLowerTier is enabled and cure is lower tier (Cure I-III), try debuff removal first
        if state.cfg.PrioritiseOverLowerTier and (cure_plan.tier or 4) <= 3 then
            if check_debuff_removal() then return end
        end
        if cure_plan.ja then
            if use_ja(cure_plan.ja, cure_plan.target) then return end
        elseif cure_plan.spell then
            if cast_spell(cure_plan.spell, cure_plan.target) then return end
        end
    end

    -- Priority 5: Debuff Removal (-na & Erase)
    if check_debuff_removal() then return end

    -- Priority 6: Core Job Abilities & Stances
    if check_job_abilities() then return end

    -- Priority 7: Geomancy (Indi, Entrust, Geo Luopan)
    if check_geomancy() then return end

    -- Priority 8: Bard Singing
    if check_singing() then return end

    -- Priority 9: Enhancing Spells (PL Self Buffs, Group Buffs, Per-Member MENU/AUTO Buffs)
    if check_enhancing() then return end

    -- Priority 10: Other Options (Stand at MP, Hate Spell, /heal on Low MP)
    if check_other_options() then return end

    state.current_action = 'Idle (Ready)'
    hud.render(state)
end

-- ============================================================================
-- HUD CLICK ACTIONS & CLI COMMAND HANDLER
-- ============================================================================

local function handle_hud_action(action, arg1, arg2)
    local cfg = state.cfg
    if action == 'toggle_pause' then
        state.paused = not state.paused
        state.current_action = state.paused and 'Paused' or 'Active'
        chat_msg(state.paused and 'Paused.' or 'Started!')
    elseif action == 'toggle_options' then
        state.show_options = not state.show_options
    elseif action == 'toggle_buffs' then
        state.show_buffs = not state.show_buffs
    elseif action == 'toggle_minimize' then
        state.minimized = not state.minimized
    elseif action == 'reload_profile' then
        load_job_profile()
    elseif action == 'save_profile' then
        save_job_profile()
    elseif action == 'set_monitored_target' then
        local t = windower.ffxi.get_mob_by_target('t')
        if t and t.name and not t.is_npc then
            state.monitored_name = t.name
            ensure_member_cfg(t.name, true)
            chat_msg('Monitored Player set to: ' .. t.name)
        else
            chat_msg('Target a player character first, then click [SET<t>] (or use //cp mon <name>).')
        end
    elseif action == 'select_monitored' and arg1 then
        state.monitored_name = arg1
        chat_msg('Monitored Player set to: ' .. arg1)
    elseif action == 'toggle_member_enable' and arg1 then
        local mc = ensure_member_cfg(arg1, true)
        mc.enabled = not mc.enabled
    elseif action == 'toggle_member_prio' and arg1 then
        local mc = ensure_member_cfg(arg1, true)
        mc.high_priority = not mc.high_priority
    elseif action == 'toggle_member_menu' and arg1 then
        state.menu_member = (state.menu_member == arg1) and nil or arg1
    elseif action == 'auto_member_buffs' and arg1 then
        local mc = ensure_member_cfg(arg1, true)
        local use_h2 = can_cast_spell('Haste II')
        mc.buffs.Haste     = not use_h2
        mc.buffs.HasteII   = use_h2
        mc.buffs.Protect   = true
        mc.buffs.Shell     = true
        mc.buffs.Regen     = true
        chat_msg('Assigned AUTO buffs (Haste, Protect, Shell, Regen) to ' .. arg1)
    elseif action == 'toggle_mbuff' and arg1 and arg2 then
        local mc = ensure_member_cfg(arg1, true)
        mc.buffs[arg2] = not mc.buffs[arg2]
    elseif action == 'toggle_cfg' and arg1 then
        cfg[arg1] = not cfg[arg1]
    elseif action == 'cycle_cure_pct' then
        local cur = cfg.curePercentage or 75
        cfg.curePercentage = (cur >= 90) and 50 or (cur + 5)
    elseif action == 'cycle_prio_pct' then
        local cur = cfg.priorityCurePercentage or 95
        cfg.priorityCurePercentage = (cur >= 95) and 70 or (cur + 5)
    elseif action == 'toggle_curaga' then
        local on = not (cfg.curaga3enabled or cfg.curaga4enabled or cfg.curaga5enabled)
        cfg.curaga3enabled = on
        cfg.curaga4enabled = on
        cfg.curaga5enabled = on
    elseif action == 'toggle_proshell' then
        local on = not (cfg.plProtectra or cfg.plShellra)
        cfg.plProtectra = on
        cfg.plShellra   = on
    elseif action == 'toggle_hasterefresh' then
        local on = not (cfg.plHaste or cfg.plRefresh)
        cfg.plHaste   = on
        cfg.plRefresh = on
    elseif action == 'toggle_follow' then
        if state.follow_target ~= '' then
            state.follow_target = ''
            windower.ffxi.run(false)
            chat_msg('Auto-Follow disabled.')
        else
            local t = windower.ffxi.get_mob_by_target('t')
            local fname = (t and not t.is_npc and t.name)
                or (state.monitored_name ~= '' and state.monitored_name)
                or (cfg.autoFollowName ~= '' and cfg.autoFollowName)
                or ''
            if fname ~= '' then
                state.follow_target = fname
                chat_msg('Auto-Follow enabled -> ' .. fname)
            else
                chat_msg('Select a Monitored Player or target a player first (or use //cp follow <name>).')
            end
        end
    end
    update_roster()
    hud.render(state)
end

-- ============================================================================
-- WINDOWER EVENT REGISTRATIONS
-- ============================================================================

windower.register_event('load', function()
    hud.init()
    -- Bind standard CurePlease hotkeys: Ctrl+Alt+F1 (Toggle), Ctrl+Alt+F2 (Start), Ctrl+Alt+F3 (Pause)
    windower.send_command('bind ^!f1 cp toggle')
    windower.send_command('bind ^!f2 cp start')
    windower.send_command('bind ^!f3 cp pause')
    if windower.ffxi.get_info().logged_in then
        load_job_profile()
        update_roster()
        hud.render(state)
    end
end)

windower.register_event('unload', function()
    windower.send_command('unbind ^!f1')
    windower.send_command('unbind ^!f2')
    windower.send_command('unbind ^!f3')
    windower.ffxi.run(false)
end)

windower.register_event('login', function()
    load_job_profile()
    update_roster()
    hud.render(state)
end)

windower.register_event('job change', function()
    load_job_profile()
    update_roster()
    hud.render(state)
end)

windower.register_event('zone change', function()
    state.is_casting = false
    windower.ffxi.run(false)
    if state.cfg.pauseOnZoneBox then
        state.paused = true
        state.current_action = 'Paused (Zoned)'
        chat_msg('Zoned -> Paused (pauseOnZoneBox enabled).')
    end
    hud.render(state)
end)

windower.register_event('incoming chunk', function(id, data)
    if id == 0x076 then
        parse_party_buff_packet(data)
    end
end)

windower.register_event('action', function(act)
    local player = windower.ffxi.get_player()
    if not player or not act then return end
    if act.actor_id == player.id then
        -- Category 4: Magic finish; Category 8 (param 28787/24931): Magic interrupted/blocked; Category 6: JA; Category 5: Item finish
        if act.category == 4 or act.category == 6 or act.category == 5 then
            state.is_casting = false
            state.last_action_time = os.clock()
        elseif act.category == 8 and (act.param == 28787 or act.param == 24931) then
            state.is_casting = false
            state.last_action_time = os.clock() - 1.5
        end
    end
end)

windower.register_event('ipc message', function(msg)
    if type(msg) ~= 'string' or not msg:match('^CPLUA_STATE|') then return end
    local parts = msg:split('|')
    local name = parts[2]
    if not name or name == '' then return end

    state.ipc_connected = true
    local bset = {}
    local buff_csv = parts[10] or ''
    for bid_str in buff_csv:gmatch('(%d+)') do
        local bid = tonumber(bid_str)
        if bid and bid > 0 and bid ~= 255 then
            bset[bid] = true
        end
    end
    state.party_buffs[name] = bset
    state.ipc_peers[name] = {
        hp = tonumber(parts[3]) or 0,
        max_hp = tonumber(parts[4]) or 2000,
        hpp = tonumber(parts[5]) or 100,
        mp = tonumber(parts[6]) or 0,
        mpp = tonumber(parts[7]) or 100,
        status = tonumber(parts[8]) or 0,
        target_id = tonumber(parts[9]) or 0,
        updated_at = os.clock(),
    }
end)

windower.register_event('prerender', function()
    local now = os.clock()
    if (now - state.last_tick) >= 0.35 then
        state.last_tick = now
        run_decision_tick()
    end
end)

windower.register_event('mouse', function(type, x, y, delta, blocked)
    if blocked then return end
    if type == 1 or type == 2 then
        return hud.handle_mouse(type, x, y, delta, blocked, handle_hud_action)
    end
end)

windower.register_event('addon command', function(command, ...)
    local cmd = command and command:lower() or 'help'
    local args = {...}

    if cmd == 'start' or cmd == 'on' then
        state.paused = false
        state.current_action = 'Active'
        chat_msg('Started!')
    elseif cmd == 'pause' or cmd == 'stop' or cmd == 'off' then
        state.paused = true
        state.current_action = 'Paused'
        windower.ffxi.run(false)
        chat_msg('Paused.')
    elseif cmd == 'toggle' then
        handle_hud_action('toggle_pause')
    elseif cmd == 'mon' or cmd == 'monitored' then
        if args[1] then
            state.monitored_name = args[1]:ucfirst()
            ensure_member_cfg(state.monitored_name, true)
            chat_msg('Monitored Player set to: ' .. state.monitored_name)
        else
            handle_hud_action('set_monitored_target')
        end
    elseif cmd == 'follow' then
        if args[1] then
            if args[1]:lower() == 'off' or args[1]:lower() == 'stop' then
                state.follow_target = ''
                windower.ffxi.run(false)
                chat_msg('Auto-Follow disabled.')
            else
                state.follow_target = args[1]:ucfirst()
                if args[2] and tonumber(args[2]) then
                    state.cfg.autoFollowDistance = tonumber(args[2])
                end
                chat_msg(string.format('Auto-Follow -> %s (dist %d)', state.follow_target, state.cfg.autoFollowDistance or 3))
            end
        else
            handle_hud_action('toggle_follow')
        end
    elseif cmd == 'load' or cmd == 'profile' then
        load_job_profile(args[1])
    elseif cmd == 'save' then
        save_job_profile(args[1])
    elseif cmd == 'indi' and args[1] then
        local q = table.concat(args, ' '):lower()
        for idx, sp in pairs(xml_loader.INDI_SPELLS) do
            if sp:lower() == q or sp:lower():find(q, 1, true) then
                state.cfg.IndiSpell_Spell = idx
                state.cfg.EnableGeoSpells = true
                chat_msg('Indi spell set to: ' .. sp)
                break
            end
        end
    elseif cmd == 'geo' and args[1] then
        local q = table.concat(args, ' '):lower()
        for idx, sp in pairs(xml_loader.GEO_SPELLS) do
            if sp:lower() == q or sp:lower():find(q, 1, true) then
                state.cfg.GeoSpell_Spell = idx
                state.cfg.EnableLuopanSpells = true
                chat_msg('Geo Luopan spell set to: ' .. sp)
                break
            end
        end
    elseif cmd == 'entrust' and args[1] then
        if args[2] then
            state.cfg.EntrustedSpell_Target = args[1]:ucfirst()
            local q = table.concat(args, ' ', 2):lower()
            for idx, sp in pairs(xml_loader.INDI_SPELLS) do
                if sp:lower() == q or sp:lower():find(q, 1, true) then
                    state.cfg.EntrustedSpell_Spell = idx
                    state.cfg.Entrust = true
                    chat_msg(string.format('Entrust set to: %s -> %s', sp, state.cfg.EntrustedSpell_Target))
                    break
                end
            end
        else
            state.cfg.Entrust = not state.cfg.Entrust
            chat_msg('Entrust: ' .. tostring(state.cfg.Entrust))
        end
    elseif cmd == 'buff' and args[1] and args[2] then
        local mname = args[1]:ucfirst()
        local bkey  = args[2]
        local mc = ensure_member_cfg(mname, true)
        if bkey:lower() == 'auto' then
            handle_hud_action('auto_member_buffs', mname)
        elseif bkey:lower() == 'clear' then
            for k, _ in pairs(mc.buffs) do mc.buffs[k] = false end
            chat_msg('Cleared auto-buffs for ' .. mname)
        else
            for k, _ in pairs(mc.buffs) do
                if k:lower() == bkey:lower() then
                    mc.buffs[k] = not mc.buffs[k]
                    chat_msg(string.format('%s %s = %s', mname, k, tostring(mc.buffs[k])))
                end
            end
        end
    elseif cmd == 'set' and args[1] and args[2] then
        local key = args[1]
        local val = args[2]
        for k, _ in pairs(state.cfg) do
            if k:lower() == key:lower() then
                if val == 'true' or val == 'on' then state.cfg[k] = true
                elseif val == 'false' or val == 'off' then state.cfg[k] = false
                elseif tonumber(val) then state.cfg[k] = tonumber(val)
                else state.cfg[k] = val end
                chat_msg(string.format('Set %s = %s', k, tostring(state.cfg[k])))
                break
            end
        end
    elseif cmd == 'hud' or cmd == 'show' or cmd == 'hide' then
        hud.visible = (cmd == 'show') and true or (cmd == 'hide' and false or not hud.visible)
    else
        chat_msg('Commands: //cp start | pause | toggle | mon <Name> | follow <Name|off> [dist]')
        chat_msg('Profiles: //cp load [JOB_SUB.xml] | //cp save [JOB_SUB.xml] | //cp set <XmlKey> <Value>')
        chat_msg('Buffs/GEO: //cp buff <Name> <auto|clear|Haste|HasteII|PhalanxII|Regen|Refresh|Protect|Shell>')
        chat_msg('GEO Shortcuts: //cp indi <Spell> | //cp geo <Spell> | //cp entrust <Target> <Spell>')
    end

    update_roster()
    hud.render(state)
end)
