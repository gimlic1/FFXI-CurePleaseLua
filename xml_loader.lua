--[[
Assumptions:
- [A1] CurePlease v2.0.4.4f stores job profiles as flat <MySettings> XML files (e.g. WHM_SCH.xml) where boolean tags are 'true'/'false', numeric tags are integers/floats, and dropdown tags are 0-based integer indices.
- [A2] All 0-based dropdown index arrays below match the exact combo-box item order extracted from Cure Please.exe v2.0.4.4f.
- [A3] When saving or updating settings in-game, XML files are written back in the same <MySettings> schema so they remain 100% compatible with CurePlease XML files.
]]

local xml_loader = {}

-- [A2] Exact 0-based dropdown tables from Cure Please.exe v2.0.4.4f
xml_loader.INDI_SPELLS = {
    [0]  = 'Indi-Voidance',   [1]  = 'Indi-Precision',  [2]  = 'Indi-Regen',
    [3]  = 'Indi-Haste',      [4]  = 'Indi-Attunement', [5]  = 'Indi-Focus',
    [6]  = 'Indi-Barrier',    [7]  = 'Indi-Refresh',    [8]  = 'Indi-CHR',
    [9]  = 'Indi-MND',        [10] = 'Indi-Fury',       [11] = 'Indi-INT',
    [12] = 'Indi-AGI',        [13] = 'Indi-Fend',       [14] = 'Indi-VIT',
    [15] = 'Indi-DEX',        [16] = 'Indi-Acumen',     [17] = 'Indi-STR',
    [18] = 'Indi-Poison',     [19] = 'Indi-Slow',       [20] = 'Indi-Torpor',
    [21] = 'Indi-Slip',       [22] = 'Indi-Languor',    [23] = 'Indi-Paralysis',
    [24] = 'Indi-Vex',        [25] = 'Indi-Frailty',    [26] = 'Indi-Wilt',
    [27] = 'Indi-Malaise',    [28] = 'Indi-Gravity',    [29] = 'Indi-Fade',
}

xml_loader.GEO_SPELLS = {
    [0]  = 'Geo-Voidance',    [1]  = 'Geo-Precision',   [2]  = 'Geo-Regen',
    [3]  = 'Geo-Haste',       [4]  = 'Geo-Attunement',  [5]  = 'Geo-Focus',
    [6]  = 'Geo-Barrier',     [7]  = 'Geo-Refresh',     [8]  = 'Geo-CHR',
    [9]  = 'Geo-MND',         [10] = 'Geo-Fury',        [11] = 'Geo-INT',
    [12] = 'Geo-AGI',         [13] = 'Geo-Fend',        [14] = 'Geo-VIT',
    [15] = 'Geo-DEX',         [16] = 'Geo-Acumen',      [17] = 'Geo-STR',
    [18] = 'Geo-Poison',      [19] = 'Geo-Slow',        [20] = 'Geo-Torpor',
    [21] = 'Geo-Slip',        [22] = 'Geo-Languor',     [23] = 'Geo-Paralysis',
    [24] = 'Geo-Vex',         [25] = 'Geo-Frailty',     [26] = 'Geo-Wilt',
    [27] = 'Geo-Malaise',     [28] = 'Geo-Gravity',     [29] = 'Geo-Fade',
}

-- Enemy-targeted Geo spells (starting at index 18 Geo-Poison through 29 Geo-Fade)
xml_loader.ENEMY_GEO_SPELLS = {
    ['Geo-Poison'] = true, ['Geo-Slow'] = true, ['Geo-Torpor'] = true,
    ['Geo-Slip'] = true, ['Geo-Languor'] = true, ['Geo-Paralysis'] = true,
    ['Geo-Vex'] = true, ['Geo-Frailty'] = true, ['Geo-Wilt'] = true,
    ['Geo-Malaise'] = true, ['Geo-Gravity'] = true, ['Geo-Fade'] = true,
}

xml_loader.GAIN_BOOST_SPELLS = {
    [0]  = 'Gain-STR',  [1]  = 'Gain-DEX',  [2]  = 'Gain-VIT',  [3]  = 'Gain-AGI',
    [4]  = 'Gain-INT',  [5]  = 'Gain-MND',  [6]  = 'Gain-CHR',
    [7]  = 'Boost-STR', [8]  = 'Boost-DEX', [9]  = 'Boost-VIT', [10] = 'Boost-AGI',
    [11] = 'Boost-INT', [12] = 'Boost-MND', [13] = 'Boost-CHR',
}

xml_loader.GAIN_BOOST_BUFF_ID = {
    ['Gain-STR']  = 119, ['Boost-STR'] = 119,
    ['Gain-DEX']  = 120, ['Boost-DEX'] = 120,
    ['Gain-VIT']  = 121, ['Boost-VIT'] = 121,
    ['Gain-AGI']  = 122, ['Boost-AGI'] = 122,
    ['Gain-INT']  = 123, ['Boost-INT'] = 123,
    ['Gain-MND']  = 124, ['Boost-MND'] = 124,
    ['Gain-CHR']  = 125, ['Boost-CHR'] = 125,
}

xml_loader.BAR_ELEMENT_SINGLE = {
    [0] = 'Barfire', [1] = 'Barstone', [2] = 'Barwater',
    [3] = 'Baraero', [4] = 'Barblizzard', [5] = 'Barthunder',
}

xml_loader.BAR_ELEMENT_AOE = {
    [0] = 'Barfira', [1] = 'Barstonra', [2] = 'Barwatera',
    [3] = 'Baraera', [4] = 'Barblizzara', [5] = 'Barthundra',
}

xml_loader.BAR_ELEMENT_BUFF_ID = {
    [0] = 100, -- Barfire
    [1] = 103, -- Barstone
    [2] = 105, -- Barwater
    [3] = 102, -- Baraero
    [4] = 101, -- Barblizzard
    [5] = 104, -- Barthunder
}

xml_loader.BAR_STATUS_SINGLE = {
    [0] = 'Baramnesia', [1] = 'Barvirus',   [2] = 'Barparalyze', [3] = 'Barsilence',
    [4] = 'Barpetrify', [5] = 'Barpoison',  [6] = 'Barblind',    [7] = 'Barsleep',
}

xml_loader.BAR_STATUS_AOE = {
    [0] = 'Baramnesra', [1] = 'Barvira',    [2] = 'Barparalyzra', [3] = 'Barsilencera',
    [4] = 'Barpetra',   [5] = 'Barpoisonra',[6] = 'Barblindra',   [7] = 'Barsleepra',
}

xml_loader.BAR_STATUS_BUFF_ID = {
    [0] = 286, -- Baramnesia
    [1] = 112, -- Barvirus
    [2] = 108, -- Barparalyze
    [3] = 110, -- Barsilence
    [4] = 111, -- Barpetrify
    [5] = 107, -- Barpoison
    [6] = 109, -- Barblind
    [7] = 106, -- Barsleep
}

xml_loader.ENSPELLS = {
    [0] = 'Enfire',    [1] = 'Enstone',    [2] = 'Enwater',
    [3] = 'Enaero',    [4] = 'Enblizzard', [5] = 'Enthunder',
    [6] = 'Enfire II', [7] = 'Enstone II', [8] = 'Enwater II',
    [9] = 'Enaero II', [10] = 'Enblizzard II', [11] = 'Enthunder II',
}

xml_loader.ENSPELL_BUFF_ID = {
    ['Enfire'] = 94, ['Enblizzard'] = 95, ['Enaero'] = 96,
    ['Enstone'] = 97, ['Enthunder'] = 98, ['Enwater'] = 99,
    ['Enfire II'] = 277, ['Enblizzard II'] = 278, ['Enaero II'] = 279,
    ['Enstone II'] = 280, ['Enthunder II'] = 281, ['Enwater II'] = 282,
}

xml_loader.STORM_SPELLS = {
    [0]  = 'Firestorm',    [1]  = 'Sandstorm',    [2]  = 'Rainstorm',    [3]  = 'Windstorm',
    [4]  = 'Hailstorm',    [5]  = 'Thunderstorm', [6]  = 'Voidstorm',    [7]  = 'Aurorastorm',
    [8]  = 'Firestorm II', [9]  = 'Sandstorm II', [10] = 'Rainstorm II', [11] = 'Windstorm II',
    [12] = 'Hailstorm II', [13] = 'Thunderstorm II', [14] = 'Voidstorm II', [15] = 'Aurorastorm II',
}

xml_loader.STORM_BUFF_ID = {
    ['Firestorm'] = 178, ['Hailstorm'] = 179, ['Windstorm'] = 180, ['Sandstorm'] = 181,
    ['Thunderstorm'] = 182, ['Rainstorm'] = 183, ['Aurorastorm'] = 184, ['Voidstorm'] = 185,
    ['Firestorm II'] = 589, ['Hailstorm II'] = 590, ['Windstorm II'] = 591, ['Sandstorm II'] = 592,
    ['Thunderstorm II'] = 593, ['Rainstorm II'] = 594, ['Aurorastorm II'] = 595, ['Voidstorm II'] = 596,
}

xml_loader.SPIKES_SPELLS = {
    [0] = 'Blaze Spikes', [1] = 'Ice Spikes', [2] = 'Shock Spikes',
}

xml_loader.SPIKES_BUFF_ID = {
    ['Blaze Spikes'] = 34, ['Ice Spikes'] = 35, ['Shock Spikes'] = 38,
}

xml_loader.REFRESH_SPELLS = {
    [0] = 'Refresh', [1] = 'Refresh II', [2] = 'Refresh III',
}

xml_loader.REGEN_SPELLS = {
    [0] = 'Regen', [1] = 'Regen II', [2] = 'Regen III', [3] = 'Regen IV', [4] = 'Regen V',
}

xml_loader.PROTECT_SPELLS = {
    [0] = 'Protect', [1] = 'Protect II', [2] = 'Protect III', [3] = 'Protect IV', [4] = 'Protect V',
}

xml_loader.SHELL_SPELLS = {
    [0] = 'Shell', [1] = 'Shell II', [2] = 'Shell III', [3] = 'Shell IV', [4] = 'Shell V',
}

xml_loader.RERAISE_SPELLS = {
    [1] = 'Reraise', [2] = 'Reraise II', [3] = 'Reraise III', [4] = 'Reraise IV',
}

xml_loader.SILENCE_ITEMS = {
    [0] = 'Echo Drops', [1] = 'Catholicon', [2] = 'Remedy', [3] = 'Rmdy. Ointment', [4] = "Vicar's Drink",
}

xml_loader.DOOM_ITEMS = {
    [0] = 'Holy Water', [1] = 'Hallowed Water',
}

xml_loader.WAKE_SLEEP_SPELLS = {
    [0] = 'Cure', [1] = 'Curaga', [2] = 'Cura',
}

xml_loader.SONGS = {
    [0]  = "Knight's Minne",     [1]  = "Knight's Minne II",  [2]  = "Knight's Minne III",
    [3]  = "Knight's Minne IV",  [4]  = "Knight's Minne V",   [5]  = 'Valor Minuet',
    [6]  = 'Valor Minuet II',    [7]  = 'Valor Minuet III',   [8]  = 'Valor Minuet IV',
    [9]  = 'Valor Minuet V',     [10] = "Army's Paeon",       [11] = "Army's Paeon II",
    [12] = "Army's Paeon III",   [13] = "Army's Paeon IV",    [14] = "Army's Paeon V",
    [15] = "Army's Paeon VI",    [16] = 'Sword Madrigal',     [17] = 'Blade Madrigal',
    [18] = "Hunter's Prelude",   [19] = "Archer's Prelude",   [20] = 'Sinewy Etude',
    [21] = 'Dextrous Etude',     [22] = 'Vivacious Etude',    [23] = 'Quick Etude',
    [24] = 'Learned Etude',      [25] = 'Spirited Etude',     [26] = 'Enchanting Etude',
    [27] = 'Herculean Etude',    [28] = 'Uncanny Etude',      [29] = 'Vital Etude',
    [30] = 'Swift Etude',        [31] = 'Sage Etude',         [32] = 'Logical Etude',
    [33] = 'Bewitching Etude',   [34] = 'Sheepfoe Mambo',     [35] = 'Dragonfoe Mambo',
    [36] = "Mage's Ballad",      [37] = "Mage's Ballad II",   [38] = "Mage's Ballad III",
    [39] = 'Advancing March',    [40] = 'Victory March',      [41] = 'Honor March',
    [42] = 'Fire Carol',         [43] = 'Fire Carol II',      [44] = 'Ice Carol',
    [45] = 'Ice Carol II',       [46] = 'Wind Carol',         [47] = 'Wind Carol II',
    [48] = 'Earth Carol',        [49] = 'Earth Carol II',     [50] = 'Lightning Carol',
    [51] = 'Lightning Carol II', [52] = 'Water Carol',        [53] = 'Water Carol II',
    [54] = 'Light Carol',        [55] = 'Light Carol II',     [56] = 'Dark Carol',
    [57] = 'Dark Carol II',      [58] = "Goddess's Hymnus",   [59] = "Sentinel's Scherzo",
}

-- Complete mapping of FFXI Debuff IDs -> CurePlease XML setting keys & removal spells
xml_loader.DEBUFF_MAP = {
    -- Primary -na / Doom / Sleep debuffs
    {id = 15,  name = 'Doom',          spell = 'Cursna',   party_key = 'naCurse',         pl_key = 'plDoom',          mon_key = 'monitoredDoom',          is_doom = true},
    {id = 7,   name = 'Petrification', spell = 'Stona',    party_key = 'naPetrification', pl_key = nil,               mon_key = 'monitoredPetrification'},
    {id = 18,  name = 'Gradual Petr.', spell = 'Stona',    party_key = 'naPetrification', pl_key = nil,               mon_key = 'monitoredPetrification'},
    {id = 6,   name = 'Silence',       spell = 'Silena',   party_key = 'naSilence',       pl_key = 'plSilence',       mon_key = 'monitoredSilence'},
    {id = 4,   name = 'Paralysis',     spell = 'Paralyna', party_key = 'naParalysis',     pl_key = 'plParalysis',     mon_key = 'monitoredParalysis'},
    {id = 566, name = 'Paralysis II',  spell = 'Paralyna', party_key = 'naParalysis',     pl_key = 'plParalysis',     mon_key = 'monitoredParalysis'},
    {id = 9,   name = 'Curse',         spell = 'Cursna',   party_key = 'naCurse',         pl_key = 'plCurse',         mon_key = 'monitoredCurse'},
    {id = 20,  name = 'Curse II',      spell = 'Cursna',   party_key = 'naCurse',         pl_key = 'plCurse2',        mon_key = 'monitoredCurse2'},
    {id = 30,  name = 'Bane',          spell = 'Cursna',   party_key = 'naCurse',         pl_key = 'plBane',          mon_key = 'monitoredBane'},
    {id = 8,   name = 'Disease',       spell = 'Viruna',   party_key = 'naDisease',       pl_key = 'plDisease',       mon_key = 'monitoredDisease'},
    {id = 31,  name = 'Plague',        spell = 'Viruna',   party_key = 'naPlague',        pl_key = 'plPlague',        mon_key = 'monitoredPlague'},
    {id = 5,   name = 'Blindness',     spell = 'Blindna',  party_key = 'naBlindness',     pl_key = 'plBlindness',     mon_key = 'monitoredBlindness'},
    {id = 3,   name = 'Poison',        spell = 'Poisona',  party_key = 'naPoison',        pl_key = 'plPoison',        mon_key = 'monitoredPoison'},
    {id = 540, name = 'Poison II',     spell = 'Poisona',  party_key = 'naPoison',        pl_key = 'plPoison',        mon_key = 'monitoredPoison'},

    -- Eraseable debuffs
    {id = 13,  name = 'Slow',          spell = 'Erase',    party_key = 'na_Slow',             pl_key = 'plSlow',          mon_key = 'monitoredSlow',          is_erase = true},
    {id = 565, name = 'Slow II',       spell = 'Erase',    party_key = 'na_Slow',             pl_key = 'plSlow',          mon_key = 'monitoredSlow',          is_erase = true},
    {id = 194, name = 'Elegy',         spell = 'Erase',    party_key = 'na_Elegy',            pl_key = 'plElegy',         mon_key = 'monitoredElegy',         is_erase = true},
    {id = 21,  name = 'Addle',         spell = 'Erase',    party_key = 'na_Addle',            pl_key = 'plAddle',         mon_key = 'monitoredAddle',         is_erase = true},
    {id = 12,  name = 'Weight',        spell = 'Erase',    party_key = 'na_Weight',           pl_key = 'plWeight',        mon_key = 'monitoredWeight',        is_erase = true},
    {id = 567, name = 'Weight II',     spell = 'Erase',    party_key = 'na_Weight',           pl_key = 'plWeight',        mon_key = 'monitoredWeight',        is_erase = true},
    {id = 11,  name = 'Bind',          spell = 'Erase',    party_key = 'na_Bind',             pl_key = 'plBind',          mon_key = 'monitoredBind',          is_erase = true},
    {id = 135, name = 'Bio',           spell = 'Erase',    party_key = 'na_Bio',              pl_key = 'plBio',           mon_key = 'monitoredBio',           is_erase = true},
    {id = 134, name = 'Dia',           spell = 'Erase',    party_key = 'na_Dia',              pl_key = 'plDia',           mon_key = 'monitoredDia',           is_erase = true},
    {id = 128, name = 'Burn',          spell = 'Erase',    party_key = 'na_Burn',             pl_key = 'plBurn',          mon_key = 'monitoredBurn',          is_erase = true},
    {id = 129, name = 'Frost',         spell = 'Erase',    party_key = 'na_Frost',            pl_key = 'plFrost',         mon_key = 'monitoredFrost',         is_erase = true},
    {id = 130, name = 'Choke',         spell = 'Erase',    party_key = 'na_Choke',            pl_key = 'plChoke',         mon_key = 'monitoredChoke',         is_erase = true},
    {id = 131, name = 'Rasp',          spell = 'Erase',    party_key = 'na_Rasp',             pl_key = 'plRasp',          mon_key = 'monitoredRasp',          is_erase = true},
    {id = 132, name = 'Shock',         spell = 'Erase',    party_key = 'na_Shock',            pl_key = 'plShock',         mon_key = 'monitoredShock',         is_erase = true},
    {id = 133, name = 'Drown',         spell = 'Erase',    party_key = 'na_Drown',            pl_key = 'plDrown',         mon_key = 'monitoredDrown',         is_erase = true},
    {id = 149, name = 'Defense Down',  spell = 'Erase',    party_key = 'na_DefenseDown',      pl_key = 'plDefenseDown',   mon_key = 'monitoredDefenseDown',   is_erase = true},
    {id = 167, name = 'Magic Def. Down',spell = 'Erase',   party_key = 'na_MagicDefenseDown', pl_key = nil,               mon_key = nil,                      is_erase = true},
    {id = 147, name = 'Attack Down',   spell = 'Erase',    party_key = 'na_AttackDown',       pl_key = 'plAttackDown',    mon_key = 'monitoredAttackDown',    is_erase = true},
    {id = 146, name = 'Accuracy Down', spell = 'Erase',    party_key = 'na_AccuracyDown',     pl_key = 'plAccuracyDown',  mon_key = 'monitoredAccuracyDown',  is_erase = true},
    {id = 175, name = 'Magic Atk Down',spell = 'Erase',    party_key = 'na_MagicAttackDown',  pl_key = 'plMagicAtkDown',  mon_key = 'monitoredMagicAtkDown',  is_erase = true},
    {id = 174, name = 'Magic Acc Down',spell = 'Erase',    party_key = 'na_MagicAccDown',     pl_key = 'plMagicAccDown',  mon_key = 'monitoredMagicAccDown',  is_erase = true},
    {id = 148, name = 'Evasion Down',  spell = 'Erase',    party_key = 'na_EvasionDown',      pl_key = 'plEvasionDown',   mon_key = 'monitoredEvasionDown',   is_erase = true},
    {id = 144, name = 'Max HP Down',   spell = 'Erase',    party_key = 'na_MaxHpDown',        pl_key = 'plMaxHpDown',     mon_key = 'monitoredMaxHpDown',     is_erase = true},
    {id = 145, name = 'Max MP Down',   spell = 'Erase',    party_key = 'na_MaxMpDown',        pl_key = 'plMaxMpDown',     mon_key = 'monitoredMaxMpDown',     is_erase = true},
    {id = 189, name = 'Max TP Down',   spell = 'Erase',    party_key = 'na_MaxTpDown',        pl_key = 'plMaxTpDown',     mon_key = 'monitoredMaxTpDown',     is_erase = true},
    {id = 186, name = 'Helix',         spell = 'Erase',    party_key = 'na_Helix',            pl_key = 'plHelix',         mon_key = 'monitoredHelix',         is_erase = true},
    {id = 192, name = 'Requiem',       spell = 'Erase',    party_key = 'na_Requiem',          pl_key = 'plRequiem',       mon_key = 'monitoredRequiem',       is_erase = true},
    {id = 217, name = 'Threnody',      spell = 'Erase',    party_key = 'na_Threnody',         pl_key = 'plThrenody',      mon_key = 'monitoredThrenody',      is_erase = true},
    {id = 136, name = 'STR Down',      spell = 'Erase',    party_key = 'na_StrDown',          pl_key = 'plStrDown',       mon_key = 'monitoredStrDown',       is_erase = true},
    {id = 137, name = 'DEX Down',      spell = 'Erase',    party_key = 'na_DexDown',          pl_key = 'plDexDown',       mon_key = 'monitoredDexDown',       is_erase = true},
    {id = 138, name = 'VIT Down',      spell = 'Erase',    party_key = 'na_VitDown',          pl_key = 'plVitDown',       mon_key = 'monitoredVitDown',       is_erase = true},
    {id = 139, name = 'AGI Down',      spell = 'Erase',    party_key = 'na_AgiDown',          pl_key = 'plAgiDown',       mon_key = 'monitoredAgiDown',       is_erase = true},
    {id = 140, name = 'INT Down',      spell = 'Erase',    party_key = 'na_IntDown',          pl_key = 'plIntDown',       mon_key = 'monitoredIntDown',       is_erase = true},
    {id = 141, name = 'MND Down',      spell = 'Erase',    party_key = 'na_MndDown',          pl_key = 'plMndDown',       mon_key = 'monitoredMndDown',       is_erase = true},
    {id = 142, name = 'CHR Down',      spell = 'Erase',    party_key = 'na_ChrDown',          pl_key = 'plChrDown',       mon_key = 'monitoredChrDown',       is_erase = true},
}

-- Default settings matching WHM_SCH.xml [A1]
function xml_loader.get_defaults()
    return {
        settingsSet = true,
        cure1enabled = false, cure1amount = 90,
        cure2enabled = false, cure2amount = 196,
        cure3enabled = true,  cure3amount = 446,
        cure4enabled = true,  cure4amount = 833,
        cure5enabled = true,  cure5amount = 1051,
        cure6enabled = true,  cure6amount = 1321,
        curagaEnabled = false,  curagaAmount = 196,
        curaga2enabled = false, curaga2Amount = 446,
        curaga3enabled = true,  curaga3Amount = 833,
        curaga4enabled = true,  curaga4Amount = 1051,
        curaga5enabled = true,  curaga5Amount = 1321,
        curePercentage = 75,
        priorityCurePercentage = 95,
        monitoredCurePercentage = 85,
        curagaCurePercentage = 75,
        curagaTargetType = 0,
        curagaTargetName = '',
        curagaRequiredMembers = 3,
        autoHasteMinutes = 5,
        autoAdloquiumMinutes = 2,
        autoPhalanxIIMinutes = 2,
        autoStormspellMinutes = 5.0,
        autoRefresh_Minutes = 2,
        autoRefresh_Spell = 0,
        autoRegen_Minutes = 3.0,
        autoRegen_Spell = 3,
        autoProtect_Minutes = 45,
        autoProtect_Spell = 4,
        autoShellMinutes = 45,
        autoShell_Spell = 4,
        autoStorm_Spell = 0,
        plShellra = true, plShellra_Level = 5,
        plProtectra = true, plProtectra_Level = 5,
        plGainBoost = false, plGainBoost_Spell = 7,
        plBarElement = true, plBarElement_Spell = 0, AOE_Barelemental = true,
        plBarStatus = false, plBarStatus_Spell = 0, AOE_Barstatus = true,
        plAuspice = false,
        plRegen = true, plRegen_Level = 4,
        plReraise = true, plReraise_Level = 4,
        plRefresh = true, plRefresh_Level = 1,
        plProtect = false, plShell = false, plBlink = false, plPhalanx = false,
        plStoneskin = true,
        plTemper = false, plTemper_Level = 0,
        plEnspell = false, plEnspell_Spell = 0,
        plStormSpell = true, plStormSpell_Spell = 7,
        plAdloquium = false, plKlimaform = false,
        plAquaveil = true,
        plHaste = true, plHaste_Level = 1,
        plSpikes = false, plSpikes_Spell = 0,
        plUtsusemi = false,
        accessionCure = false, accessionProShell = false,
        AccessionRegen = false, PerpetuanceRegen = false,
        regenPerpetuance = false, regenAccession = true,
        refreshPerpetuance = false, refreshAccession = false,
        blinkPerpetuance = false, blinkAccession = false,
        phalanxPerpetuance = false, phalanxAccession = false,
        stoneskinPerpetuance = false, stoneskinAccession = true,
        enspellPerpetuance = false, enspellAccession = false,
        stormspellPerpetuance = false, stormspellAccession = false,
        adloquiumPerpetuance = false, adloquiumAccession = false,
        aquaveilPerpetuance = false, aquaveilAccession = false,
        barspellPerpetuance = false, barspellAccession = false,
        barstatusPerpetuance = false, barstatusAccession = false,
        EnlightenmentReraise = false,
        EnableGeoSpells = false, IndiWhenEngaged = false,
        EnableLuopanSpells = false, GeoWhenEngaged = false,
        specifiedEngageTarget = false,
        IndiSpell_Spell = 0, GeoSpell_Spell = 0, EntrustedSpell_Spell = 0,
        LuopanSpell_Target = '', EntrustedSpell_Target = '',
        enableSinging = false, recastSongs_Monitored = false, SongsOnlyWhenNear = false,
        song1 = 0, song2 = 0, song3 = 0, song4 = 0,
        dummy1 = 0, dummy2 = 0, recastSongTime = 2,
        LightArts = true, Sublimation = true, AddendumWhite = true,
        Celerity = false, Accession = true, Perpetuance = true,
        Penury = false, Rapture = false,
        DarkArts = false, AddendumBlack = false,
        AfflatusSolace = true, AfflatusMisery = false,
        DivineSeal = true, Devotion = true, DivineCaress = true,
        Composure = false, Convert = false,
        Entrust = false, FullCircle = false, Dematerialize = false,
        BlazeOfGlory = false, RadialArcana = false, EclipticAttrition = false, LifeCycle = false,
        Pianissimo = false, Nightingale = false, Troubadour = false, Marcato = false,
        Majesty = false,
        plDebuffEnabled = true, monitoredDebuffEnabled = true,
        enablePartyDebuffRemoval = true, SpecifiednaSpellsenable = false,
        PrioritiseOverLowerTier = true,
        plSilenceItemEnabled = true, plSilenceItem = 1,
        plDoomEnabled = false, plDoomitem = 0,
        wakeSleepEnabled = true, wakeSleepSpell = 2,
        naBlindness = true, naCurse = true, naDisease = true, naParalysis = true,
        naPetrification = true, naPlague = false, naPoison = true, naSilence = true,
        naErase = true, Esuna = true, EsunaOnlyAmnesia = false,
        PrioritizeDoomRemoval = true, AugmentDoomRemoval = true, AugmentDoomRemoval_Method = 0,
        mpMinCastValue = 100, lowMPcheckBox = false,
        healLowMP = true, healWhenMPBelow = 100,
        standAtMP = true, standAtMP_Percentage = 99,
        convertMP = 300,
        sublimationMP = 100, SublimationRecoverWhenCharging = true,
        Fullcircle_DisableEnemy = false, Fullcircle_GEOTarget = false,
        RadialArcanaMP = 300, RadialArcana_Spell = 0,
        DevotionMP = 200, DevotionTargetType = 1, DevotionTargetName = '', DevotionWhenEngaged = false,
        autoTarget = false, Hate_SpellType = 0, autoTargetSpell = 'Dia', autoTarget_Target = '',
        AssistSpecifiedTarget = false, DisableTargettingCancel = false, TargetRemoval_Delay = 3,
        AcceptRaise = true, AcceptRaiseOnlyWhenNotInCombat = false,
        Overcure = false, Undercure = false,
        enableMonitoredPriority = false, enableOutOfPartyHealing = true, OvercureOnHighPriority = false,
        EnableAddOn = true,
        pauseOnZoneBox = true, pauseOnStartBox = true, pauseOnKO = false, MinimiseonStart = false,
        autoFollowName = '', autoFollowDistance = 3, autoFollow_Warning = true, FFXIDefaultAutoFollow = false,
        enableHotKeys = true,
    }
end

-- Parse a CurePlease <MySettings> XML file into a Lua table [A1]
function xml_loader.load_xml(filepath)
    local cfg = xml_loader.get_defaults()
    local key_order = {}
    local f = io.open(filepath, 'r')
    if not f then
        return nil, nil
    end
    local content = f:read('*a')
    f:close()

    for line in content:gmatch('[^\r\n]+') do
        -- Self-closing empty tag: <tagName />
        local empty_tag = line:match('<([%w_]+)%s*/>')
        if empty_tag then
            cfg[empty_tag] = ''
            table.insert(key_order, empty_tag)
        else
            local tag, val = line:match('<([%w_]+)>(.-)</[%w_]+>')
            if tag then
                table.insert(key_order, tag)
                if val == 'true' then
                    cfg[tag] = true
                elseif val == 'false' then
                    cfg[tag] = false
                elseif tonumber(val) ~= nil and tag ~= 'ipAddress' then
                    cfg[tag] = tonumber(val)
                else
                    cfg[tag] = val
                end
            end
        end
    end
    return cfg, key_order
end

-- Save a Lua settings table back to a CurePlease <MySettings> XML file [A3]
function xml_loader.save_xml(filepath, cfg, key_order)
    local f = io.open(filepath, 'w')
    if not f then
        return false
    end
    f:write('<?xml version="1.0" encoding="utf-8"?>\n')
    f:write('<MySettings xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">\n')

    local seen = {}
    local ordered = {}
    if key_order and #key_order > 0 then
        for _, k in ipairs(key_order) do
            if not seen[k] and cfg[k] ~= nil then
                seen[k] = true
                table.insert(ordered, k)
            end
        end
    end
    local extra = {}
    for k, _ in pairs(cfg) do
        if not seen[k] then
            table.insert(extra, k)
        end
    end
    table.sort(extra)
    for _, k in ipairs(extra) do
        table.insert(ordered, k)
    end

    for _, k in ipairs(ordered) do
        local v = cfg[k]
        if v == '' then
            f:write(string.format('  <%s />\n', k))
        elseif type(v) == 'boolean' then
            f:write(string.format('  <%s>%s</%s>\n', k, v and 'true' or 'false', k))
        else
            f:write(string.format('  <%s>%s</%s>\n', k, tostring(v), k))
        end
    end
    f:write('</MySettings>')
    f:close()
    return true
end

return xml_loader
