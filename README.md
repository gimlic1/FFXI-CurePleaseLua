# CurePleaseLua — Native Windower 4 Lua Replacement for Cure Please v2.0.4.4f

> **Why `CurePleaseLua`?**
> The standalone C# `Cure Please.exe` application relies on external `EliteAPI.dll` / `EliteMMO.API.dll` memory pointers into `pol.exe`, which break every monthly FFXI version update. **`CurePleaseLua`** is written 100% in native Windower 4 Lua (`windower.ffxi.*`, packet `0x076` party buff tracking, `action` packet cast tracking, and zero-config `send_ipc_message` dual-box synchronization) so it continues working across FFXI patches without external DLL updates.

---

## Key Features
1. **Clickable On-Screen Windower HUD (`hud.lua`)**:
   - **Header Controls**: Click `[PAUSED]` / `[ACTIVE]` to start or pause, `[OPTIONS]` to open the in-game quick-toggle drawer across all 8 Cure Please tabs, `[BUFFS]` to inspect live party buff IDs, `[RELOAD]` / `[SAVE]` to reload or persist your `<MAIN>_<SUB>.xml` profile, and `[-]` / `[+]` to minimize.
   - **Party 1–3 & Out-of-Party Roster**:
     - Click `[ON]` / `[--]` to enable/disable healing & debuff removal for any member.
     - Click `[PRI]` / `[---]` to toggle High-Priority (`95%` threshold) curing for that member.
     - Click a member's **Name** (or target a character and click `[SET<t>]`) to set the **Monitored Player**.
     - Click `[MENU]` on any member to expand their per-member auto-buff toggles (`[Haste]`, `[Haste2]`, `[Phlx2]`, `[Regen]`, `[Refrsh]`, `[Prot]`, `[Shell]`, `[Flrry]`, `[Adloq]`, `[Storm]`).
     - Click `[AUTO]` on any member to auto-assign standard buffs (`Haste`/`Haste II`, `Protect`, `Shell`, `Regen`).
2. **Native CurePlease `<MySettings>` `JOB_SUB.xml` Compatibility (`xml_loader.lua`)**:
   - Directly loads and saves Cure Please v2.0.4.4f `.xml` files from `data/settings/<MAIN>_<SUB>.xml`.
   - Pre-loaded with your 7 saved profiles: `WHM_SCH.xml`, `WHM_RDM.xml`, `GEO_WHM.xml`, `GEO_RDM.xml`, `SCH_WHM.xml`, `RDM_COR.xml`, and `DRG_WHM.xml` (plus `default.xml`).
   - Automatically switches profiles on `login` and `job change`.
3. **Zero-Config Dual-Box IPC + Packet `0x076` Buff Tracking**:
   - Parses incoming packet `0x076` to track all 32 buff/debuff slots on Party 1 members (`p1..p5`) for instant `-na` removal, `Erase`, `Wake Sleep`, and buff-wear recasting.
   - When `CurePleaseLua` is loaded on both your main character (`Gimlic`) and your healer/support character (`Voicelessbicep`, `Balullu`, or `Friendlessvirus`), they automatically sync HP, Max HP, MP, engaged target, and active buff IDs over Windower IPC (`CPLUA_STATE`) — enabling accurate Out-of-Party curing and Monitored Player debuff removal without UDP ports or external processes.
4. **Fair-Play & Movement/Cast Lock Safety**:
   - Never casts while moving, zoning, KO'd, mounted, or mid-cast.
   - Verifies spell knowledge, job/subjob level, MP (`mpMinCastValue`), recast timer (`0`), and legitimate FFXI distance (`< 20.4` yalms for single-target magic, `< 8` yalms for `Devotion`, `< 10` yalms for self-centered AoEs).

---

## Commands & Hotkeys

### Hotkeys
- `Ctrl + Alt + F1`: Toggle Start / Pause (`//cp toggle`)
- `Ctrl + Alt + F2`: Start CurePleaseLua (`//cp start`)
- `Ctrl + Alt + F3`: Pause CurePleaseLua (`//cp pause`)

### Slash Commands (`//cp`, `//cureplease`, `//cplua`)
| Command | Description |
| :--- | :--- |
| `//cp start` / `//cp pause` / `//cp toggle` | Start, pause, or toggle automation |
| `//cp mon <Name>` | Set the Monitored Player (or `//cp mon` to use current target `<t>`) |
| `//cp follow <Name\|off> [dist]` | Enable/disable Auto-Follow on `<Name>` at `<dist>` yalms |
| `//cp load [JOB_SUB.xml]` | Reload current job's XML profile or load a specific `.xml` file |
| `//cp save [JOB_SUB.xml]` | Save current settings back to `data/settings/<JOB_SUB>.xml` |
| `//cp set <XmlKey> <Value>` | Modify any `<MySettings>` XML key in-game (e.g. `//cp set curePercentage 80`) |
| `//cp buff <Name> <auto\|clear\|BuffKey>` | Toggle per-member buffs (`Haste`, `HasteII`, `PhalanxII`, `Regen`, `Refresh`, `Protect`, `Shell`, `Flurry`, `Adloquium`, `Storm`) |
| `//cp indi <SpellName>` | Set & enable GEO Indi aura (e.g. `//cp indi Indi-Refresh`) |
| `//cp geo <SpellName>` | Set & enable GEO Luopan spell (e.g. `//cp geo Geo-Frailty`) |
| `//cp entrust <Target> <SpellName>` | Set & enable GEO Entrust (e.g. `//cp entrust Gimlic Indi-Fury`) |
| `//cp hud` / `//cp show` / `//cp hide` | Toggle on-screen HUD visibility |
