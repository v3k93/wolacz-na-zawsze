--[[
==========================================================================
  WoW Forever – "Zawołaj Ekipę"
==========================================================================
  Jedno kliknięcie przycisku "Zawołaj Ekipę":
    1. zbiera dane o postaci, kolejce (Dungeon Finder / Battleground /
       Premade Group Finder) i aktualnej grupie,
    2. zapisuje je do WoWForeverDB (SavedVariables),
    3. wywołuje ReloadUI(), dzięki czemu gra natychmiast zrzuca plik
       WTF/Account/<KONTO>/SavedVariables/WoWForever.lua na dysk.

  Program "wow_forever_watcher.py" (lub .exe) działający w tle wykrywa
  nowe notification_id w tym pliku i wysyła powiadomienie na Discorda.

  Kompatybilność:
    * stare API (WotLK 3.3.5a i podobne): GetLFGMode(), GetLFGRoles(),
      GetBattlefieldStatus(), GetNumPartyMembers(), GetNumRaidMembers()
    * nowe API (Retail / nowe Classic): GetLFGMode(kategoria),
      C_LFGList, GetNumGroupMembers(), IsInRaid()
  Każde wywołanie API jest opakowane w pcall – brak funkcji w danej
  wersji klienta nigdy nie powoduje błędu Lua, a jedynie pominięcie
  danej informacji.

  Kod jest zgodny z Lua 5.1 (wszystkie klienty WoW).
==========================================================================
]]

local ADDON_NAME    = ... or "WoWForever"
local ADDON_VERSION = "1.0.0"

local WF = {}
_G.WoWForever = WF

-- Lokalne skróty (Lua 5.1: "unpack" jest globalne, w 5.2+ "table.unpack")
local unpack  = unpack or table.unpack
local tinsert = table.insert
local tconcat = table.concat
local tsort   = table.sort
local format  = string.format

-- Ikona "okrzyku bojowego" – istnieje we wszystkich wersjach gry.
-- (Emoji 📢 nie da się wyświetlić czcionkami WoW-a, dlatego używamy ikony.)
local ICON = "Interface\\Icons\\Ability_Warrior_BattleShout"

local MAX_NOTE_BYTES = 200   -- maksymalna długość notatki w bajtach (UTF-8)

------------------------------------------------------------------------
-- 1. WERSJA KLIENTA I WYKRYWANIE DOSTĘPNEGO API
------------------------------------------------------------------------

-- GetBuildInfo(): "3.3.5", "12340", "Jun 24 2010", 30300
-- (czwarta wartość – numer TOC – nie istnieje w bardzo starych klientach,
--  wtedy wyliczamy go z numeru wersji).
local clientVersion, clientBuild, _, clientToc = GetBuildInfo()
clientToc = tonumber(clientToc)
if not clientToc then
    local major, minor, patch = string.match(clientVersion or "", "^(%d+)%.(%d+)%.?(%d*)")
    clientToc = (tonumber(major) or 0) * 10000 + (tonumber(minor) or 0) * 100 + (tonumber(patch) or 0)
end

WF.clientVersion = clientVersion or "?"
WF.clientBuild   = clientBuild or "?"
WF.clientToc     = clientToc

-- Wykrywanie funkcji zamiast zgadywania po numerze wersji – działa także
-- na serwerach prywatnych z niestandardowymi buildami.
WF.API = {
    groupMembers  = type(GetNumGroupMembers) == "function",  -- nowe API grup (MoP+, nowe Classic)
    lfgCategories = type(LE_LFG_CATEGORY_LFD) == "number",   -- GetLFGMode(kategoria)
    lfgList       = type(C_LFGList) == "table",              -- Premade Group Finder
    pvpRoles      = type(GetPVPRoles) == "function",
    specs         = type(GetSpecialization) == "function" and type(GetSpecializationRole) == "function",
}

-- "Klient legacy" = stare API grup i kolejek (np. 3.3.5a).
WF.isLegacyClient = (not WF.API.groupMembers) and clientToc < 50000

-- World of Warcraft: Forever (interfejs 16xxx, typ gry "camelot").
-- To klient z rodziny Mainline (API jak w Midnight 12.1.5), ale:
--   * brak Dungeon Findera (Blizzard_GroupFinder / PVEFrame / PVPUIFrame nie ładują się),
--   * Group Finder w stylu Vanilla (LFGParentFrame, ładowany na żądanie),
--   * aktywne "secret values" z Midnight.
-- WOW_PROJECT_ID na Forever bywał różny w betach, więc sprawdzamy też numer TOC.
WF.isForever = (WOW_PROJECT_ID ~= nil and WOW_PROJECT_ID == (WOW_PROJECT_CAMELOT or 18))
    or (clientToc >= 16000 and clientToc < 20000)

------------------------------------------------------------------------
-- 2. FUNKCJE POMOCNICZE
------------------------------------------------------------------------

-- Pakuje wszystkie wartości (także nil) do tabeli z polem n.
local function pack(...)
    return { n = select("#", ...), ... }
end

-- Midnight / WoW Forever: część wartości zwracanych przez API może być
-- "sekretna" (secret value) – nie wolno ich porównywać ani zapisywać.
-- Takie wartości traktujemy jak brak danych.
local issecretvalue = _G.issecretvalue
local function IsSecret(value)
    if not issecretvalue then
        return false
    end
    local ok, secret = pcall(issecretvalue, value)
    return (not ok) or secret and true or false
end

-- Bezpieczne wywołanie funkcji API. Zwraca wszystkie wyniki funkcji
-- albo nil, jeśli funkcja nie istnieje lub zgłosiła błąd.
-- Wartości sekretne są zamieniane na nil.
local function SafeCall(func, ...)
    if type(func) ~= "function" then
        return nil
    end
    local r = pack(pcall(func, ...))
    if not r[1] then
        return nil
    end
    if issecretvalue then
        for i = 2, r.n do
            if IsSecret(r[i]) then
                r[i] = nil
            end
        end
    end
    return unpack(r, 2, r.n)
end

-- Bezpiecznie zwraca n-tą wartość zwróconą przez funkcję, ale tylko
-- jeśli jest niepustym tekstem.
local function SafeString(index, func, ...)
    if type(func) ~= "function" then
        return nil
    end
    local r = pack(pcall(func, ...))
    if not r[1] then
        return nil
    end
    local value = r[index + 1]
    if type(value) == "string" and not IsSecret(value) and value ~= "" then
        return value
    end
    return nil
end

local function IsNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

------------------------------------------------------------------------
-- 3. TEKSTY INTERFEJSU
------------------------------------------------------------------------
-- Część klientów (zwłaszcza stare wersje enUS) nie posiada polskich
-- znaków w czcionkach. Komenda "/wf ascii" przełącza interfejs na
-- wersję bez ogonków. Dane wysyłane na Discorda ZAWSZE są w pełnym UTF-8.

local TEXTS = {
    utf8 = {
        TITLE         = "WoW Forever",
        BUTTON        = "Zawołaj Ekipę",
        NOTE_HINT     = "Notatka (opcjonalnie)...",
        TOOLTIP_TITLE = "Zawołaj Ekipę",
        TOOLTIP_TEXT  = "Wysyła na Discorda informację o Twojej kolejce/grupie. Interfejs zostanie przeładowany (ReloadUI).",
        TOOLTIP_DRAG  = "Shift + przeciągnij, aby przesunąć przycisk.",
        SENDING       = "Wysyłam powiadomienie na Discorda...",
        SAVED         = "Powiadomienie zapisane – WoW Forever Watcher wyśle je na Discorda.",
        IN_COMBAT     = "Nie można zawołać ekipy w trakcie walki – spróbuj po walce.",
        PANEL_SHOWN   = "Panel pokazany.",
        PANEL_HIDDEN  = "Panel ukryty. Wpisz /wf, aby go przywrócić.",
        ASCII_ON      = "Tryb bez polskich znaków: WŁĄCZONY.",
        ASCII_OFF     = "Tryb bez polskich znaków: WYŁĄCZONY.",
        RESET         = "Pozycje panelu i przycisków zostały zresetowane.",
        PREVIEW       = "Podgląd danych (nic nie zostało wysłane):",
        HELP          = {
            "Komendy:",
            "  /wf – pokaż/ukryj panel",
            "  /wf send [notatka] – zawołaj ekipę od razu",
            "  /wf test – podgląd danych bez wysyłania",
            "  /wf ascii – interfejs bez polskich znaków (gdy widzisz krzaki)",
            "  /wf reset – zresetuj pozycję panelu i przycisków",
        },
    },
    ascii = {
        TITLE         = "WoW Forever",
        BUTTON        = "Zawolaj Ekipe",
        NOTE_HINT     = "Notatka (opcjonalnie)...",
        TOOLTIP_TITLE = "Zawolaj Ekipe",
        TOOLTIP_TEXT  = "Wysyla na Discorda informacje o Twojej kolejce/grupie. Interfejs zostanie przeladowany (ReloadUI).",
        TOOLTIP_DRAG  = "Shift + przeciagnij, aby przesunac przycisk.",
        SENDING       = "Wysylam powiadomienie na Discorda...",
        SAVED         = "Powiadomienie zapisane - WoW Forever Watcher wysle je na Discorda.",
        IN_COMBAT     = "Nie mozna zawolac ekipy w trakcie walki - sprobuj po walce.",
        PANEL_SHOWN   = "Panel pokazany.",
        PANEL_HIDDEN  = "Panel ukryty. Wpisz /wf, aby go przywrocic.",
        ASCII_ON      = "Tryb bez polskich znakow: WLACZONY.",
        ASCII_OFF     = "Tryb bez polskich znakow: WYLACZONY.",
        RESET         = "Pozycje panelu i przyciskow zostaly zresetowane.",
        PREVIEW       = "Podglad danych (nic nie zostalo wyslane):",
        HELP          = {
            "Komendy:",
            "  /wf - pokaz/ukryj panel",
            "  /wf send [notatka] - zawolaj ekipe od razu",
            "  /wf test - podglad danych bez wysylania",
            "  /wf ascii - interfejs bez polskich znakow",
            "  /wf reset - zresetuj pozycje panelu i przyciskow",
        },
    },
}

local function T(key)
    local useAscii = WoWForeverDB and WoWForeverDB.settings and WoWForeverDB.settings.ascii
    local set = useAscii and TEXTS.ascii or TEXTS.utf8
    return set[key] or TEXTS.utf8[key] or key
end

local CHAT_PREFIX = "|cff33ccffWoW Forever:|r "

local function Print(message)
    local frame = DEFAULT_CHAT_FRAME or ChatFrame1
    if frame then
        frame:AddMessage(CHAT_PREFIX .. tostring(message))
    end
end

-- Etykieta przycisku: ikona (zamiast emoji 📢) + tekst.
local function ButtonLabel()
    return "|T" .. ICON .. ":16:16:0:0|t " .. T("BUTTON")
end

------------------------------------------------------------------------
-- 4. STAŁE DANYCH (zawsze UTF-8 – trafiają na Discorda)
------------------------------------------------------------------------

local ACTIVITY_DUNGEON    = "Dungeon"
local ACTIVITY_RAIDFINDER = "Raid Finder"
local ACTIVITY_SCENARIO   = "Scenariusz"
local ACTIVITY_BG         = "Battleground"
local ACTIVITY_PREMADE    = "Premade / Szukam Grupy"

local DEFAULT_ACTIVITY_NAME = "Szukam ludzi do wspólnej gry!"

-- Tryby zwracane przez GetLFGMode()
local LFG_QUEUE_MODES  = { queued = true, proposal = true, rolecheck = true, suspended = true }
local LFG_INSIDE_MODES = { lfgparty = true, abandonedInDungeon = true }

local LFG_STATUS_TEXT = {
    queued             = "W kolejce",
    proposal           = "Grupa znaleziona – akceptacja",
    rolecheck          = "Sprawdzanie ról",
    suspended          = "Kolejka wstrzymana",
    lfgparty           = "Już w instancji – szukamy uzupełnienia",
    abandonedInDungeon = "W instancji",
}

-- Statusy zwracane przez GetBattlefieldStatus()
local BG_STATUS_TEXT = {
    queued = "W kolejce",
    confirm = "Wejście gotowe!",
    active = "Trwa bitwa",
}

------------------------------------------------------------------------
-- 5. BAZA DANYCH (SavedVariables)
------------------------------------------------------------------------

local function InitDB()
    if type(WoWForeverDB) ~= "table" then
        WoWForeverDB = {}
    end
    local db = WoWForeverDB

    if type(db.settings) ~= "table" then
        db.settings = {}
    end
    local s = db.settings
    if s.ascii == nil then s.ascii = false end
    if s.showPanel == nil then s.showPanel = true end
    if type(s.lastNote) ~= "string" then s.lastNote = "" end
    if type(s.attach) ~= "table" then s.attach = {} end

    -- notification_id zmienia się WYŁĄCZNIE w WF:CallTeam().
    -- Zwykłe /reload lub wylogowanie nie dotyka tego pola, więc watcher
    -- nie wyśle duplikatu.
    db.notification_id = tonumber(db.notification_id) or 0
    db.addon_version = ADDON_VERSION
end

------------------------------------------------------------------------
-- 6. ZBIERANIE DANYCH: DUNGEON FINDER (LFG / RDF)
------------------------------------------------------------------------

-- Nazwa dungeona po ID. Retail: GetLFGDungeonInfo(id),
-- 3.3.5a: GetLFGDungeonInfoByID(id) – próbujemy obu.
local function GetDungeonNameByID(dungeonID)
    if type(dungeonID) ~= "number" then
        return nil
    end
    return SafeString(1, GetLFGDungeonInfo, dungeonID)
        or SafeString(1, _G.GetLFGDungeonInfoByID, dungeonID)
end

-- GetLFGQueuedList() zwraca tabelę { [dungeonID] = true } (lub listę ID).
-- Zamieniamy ją na czytelną listę nazw.
local function ExtractDungeonNames(list)
    if type(list) ~= "table" then
        return nil
    end
    local names, seen = {}, {}
    for key, value in pairs(list) do
        local dungeonID
        if type(key) == "number" and value == true then
            dungeonID = key
        elseif type(value) == "number" then
            dungeonID = value
        end
        local name = GetDungeonNameByID(dungeonID)
        if name and not seen[name] then
            seen[name] = true
            tinsert(names, name)
        end
    end
    if #names == 0 then
        return nil
    end
    tsort(names)
    if #names > 3 then
        return tconcat(names, ", ", 1, 3) .. format(" (+%d)", #names - 3)
    end
    return tconcat(names, ", ")
end

-- Nazwa aktualnej instancji (gdy jesteśmy już w środku).
local function GetCurrentInstanceName()
    local name, instanceType = SafeCall(GetInstanceInfo)
    if IsNonEmptyString(name) and instanceType and instanceType ~= "none" then
        return name
    end
    return nil
end

-- Lista kategorii LFG dla nowego API (GetLFGMode(kategoria)).
local function GetLFGCategories()
    local list = {}
    local function add(category, kind)
        if type(category) == "number" then
            tinsert(list, { category, kind })
        end
    end
    if WF.API.lfgCategories then
        add(LE_LFG_CATEGORY_LFD, ACTIVITY_DUNGEON)
        add(LE_LFG_CATEGORY_RF, ACTIVITY_RAIDFINDER)
        add(LE_LFG_CATEGORY_LFR, ACTIVITY_RAIDFINDER)
        add(LE_LFG_CATEGORY_FLEXRAID, ACTIVITY_RAIDFINDER)
        add(LE_LFG_CATEGORY_SCENARIO, ACTIVITY_SCENARIO)
        add(LE_LFG_CATEGORY_BATTLEFIELD, ACTIVITY_BG)
        add(LE_LFG_CATEGORY_WORLDPVP, ACTIVITY_BG)
    else
        -- Klient z nowym API grup, ale bez globalnych stałych kategorii.
        add(1, ACTIVITY_DUNGEON)
        add(2, ACTIVITY_RAIDFINDER)
        add(3, ACTIVITY_RAIDFINDER)
        add(4, ACTIVITY_SCENARIO)
    end
    return list
end

local function MakeLFGActivity(kind, name, mode)
    if not name and LFG_INSIDE_MODES[mode] then
        name = GetCurrentInstanceName()
    end
    if not name then
        if kind == ACTIVITY_DUNGEON then
            name = "Losowy dungeon (Dungeon Finder)"
        else
            name = kind
        end
    end
    return { type = kind, name = name, status = LFG_STATUS_TEXT[mode] or "" }
end

-- Zwraca: aktywnaKolejka, jużWInstancji (każde może być nil).
local function CollectLFG()
    if type(GetLFGMode) ~= "function" then
        return nil, nil
    end

    local queued, inside

    if WF.isLegacyClient then
        -- STARE API (3.3.5a): GetLFGMode() bez argumentów.
        local mode = SafeCall(GetLFGMode)
        if mode and (LFG_QUEUE_MODES[mode] or LFG_INSIDE_MODES[mode]) then
            local name = ExtractDungeonNames(SafeCall(GetLFGQueuedList))
            if not name and LFDQueueFrame then
                name = GetDungeonNameByID(tonumber(LFDQueueFrame.type))
            end
            if not name then
                -- 3.3.5a: GetLFGQueueStats() -> hasData, leaderNeeds, tankNeeds,
                -- healerNeeds, dpsNeeds, instanceType, instanceName, ...
                name = SafeString(7, GetLFGQueueStats)
            end
            local activity = MakeLFGActivity(ACTIVITY_DUNGEON, name, mode)
            if LFG_QUEUE_MODES[mode] then queued = activity else inside = activity end
        end
    else
        -- NOWE API: GetLFGMode(kategoria) dla każdej kategorii.
        for _, entry in ipairs(GetLFGCategories()) do
            local category, kind = entry[1], entry[2]
            local mode = SafeCall(GetLFGMode, category)
            if mode and (LFG_QUEUE_MODES[mode] or LFG_INSIDE_MODES[mode]) then
                local name = ExtractDungeonNames(SafeCall(GetLFGQueuedList, category, {}))
                if not name then
                    -- Retail: GetLFGQueueStats(cat) -> hasData, leaderNeeds, tankNeeds,
                    -- healerNeeds, dpsNeeds, totalTanks, totalHealers, totalDPS,
                    -- instanceType, instanceSubType, instanceName, ...
                    name = SafeString(11, GetLFGQueueStats, category)
                end
                local activity = MakeLFGActivity(kind, name, mode)
                if LFG_QUEUE_MODES[mode] then
                    queued = queued or activity
                else
                    inside = inside or activity
                end
            end
        end
    end

    return queued, inside
end

------------------------------------------------------------------------
-- 7. ZBIERANIE DANYCH: BATTLEGROUNDY
------------------------------------------------------------------------

-- Zwraca: kolejkaBG, trwającaBitwa (każde może być nil).
local function CollectBattleground()
    if type(GetBattlefieldStatus) ~= "function" then
        return nil, nil
    end

    local maxQueues = SafeCall(GetMaxBattlefieldID) or MAX_BATTLEFIELD_QUEUES or 3
    local queued, active

    for i = 1, maxQueues do
        local status, mapName = SafeCall(GetBattlefieldStatus, i)
        if status == "queued" or status == "confirm" or status == "active" then
            local activity = {
                type = ACTIVITY_BG,
                name = IsNonEmptyString(mapName) and mapName or "Battleground",
                status = BG_STATUS_TEXT[status] or "",
            }
            if status == "active" then
                active = active or activity
            else
                -- "confirm" (wejście gotowe) ma pierwszeństwo przed "queued"
                if not queued or status == "confirm" then
                    queued = activity
                end
            end
        end
    end

    return queued, active
end

------------------------------------------------------------------------
-- 8. ZBIERANIE DANYCH: PREMADE GROUP FINDER (C_LFGList)
------------------------------------------------------------------------

local function GetActivityFullName(activityID)
    if type(activityID) ~= "number" or type(C_LFGList) ~= "table" then
        return nil
    end
    local info = SafeCall(C_LFGList.GetActivityInfoTable, activityID)
    if type(info) == "table" and IsNonEmptyString(info.fullName) then
        return info.fullName
    end
    -- Starsze wersje: C_LFGList.GetActivityInfo(id) -> fullName, ...
    return SafeString(1, C_LFGList.GetActivityInfo, activityID)
end

-- Wyciąga activityID z tabeli wpisu (różne wersje API: activityID / activityIDs).
local function ActivityIDFromInfo(info)
    if type(info) ~= "table" then
        return nil
    end
    if type(info.activityID) == "number" then
        return info.activityID
    end
    if type(info.activityIDs) == "table" then
        return info.activityIDs[1]
    end
    return nil
end

local function CollectPremade()
    if not WF.API.lfgList then
        return nil
    end

    -- a) Mamy własną grupę wystawioną w Premade Group Finderze
    --    (na WoW Forever – w Group Finderze w stylu Vanilla, ten sam C_LFGList).
    local hasEntry = SafeCall(C_LFGList.HasActiveEntryInfo)
    if hasEntry ~= false then
        local first, second = SafeCall(C_LFGList.GetActiveEntryInfo)
        local activityID
        if type(first) == "table" then
            activityID = ActivityIDFromInfo(first)        -- nowe API (tabela)
        elseif first == true then
            activityID = second                          -- stare API (active, activityID, ...)
        end
        if activityID or type(first) == "table" then
            return {
                type = ACTIVITY_PREMADE,
                name = GetActivityFullName(activityID) or "Własna grupa w Group Finderze",
                status = "Grupa wystawiona – szukamy ludzi",
            }
        end
    end

    -- b) Aplikujemy do cudzych grup.
    local applications = SafeCall(C_LFGList.GetApplications)
    if type(applications) == "table" and #applications > 0 then
        local result = SafeCall(C_LFGList.GetSearchResultInfo, applications[1])
        local name = GetActivityFullName(ActivityIDFromInfo(result))
        return {
            type = ACTIVITY_PREMADE,
            name = name or "Szukam grupy w Group Finderze",
            status = format("Aplikuję do grup: %d", #applications),
        }
    end

    return nil
end

------------------------------------------------------------------------
-- 9. ZBIERANIE DANYCH: AKTYWNOŚĆ (priorytety)
------------------------------------------------------------------------

function WF:DetectActivity()
    local lfgQueued, lfgInside = CollectLFG()
    local bgQueued, bgActive = CollectBattleground()
    local premade = CollectPremade()

    -- Priorytet: aktywna kolejka > premade > już w środku > nic (domyślny tekst)
    return lfgQueued
        or bgQueued
        or premade
        or lfgInside
        or bgActive
        or { type = ACTIVITY_PREMADE, name = DEFAULT_ACTIVITY_NAME, status = "" }
end

------------------------------------------------------------------------
-- 10. ZBIERANIE DANYCH: ROLE
------------------------------------------------------------------------

local ROLE_ORDER = { "TANK", "HEALER", "DAMAGER" }

-- Zamienia flagi tank/healer/dps na listę tokenów w stałej kolejności.
local function RolesFromFlags(tank, healer, dps)
    local roles = {}
    if tank then tinsert(roles, "TANK") end
    if healer then tinsert(roles, "HEALER") end
    if dps then tinsert(roles, "DAMAGER") end
    return roles
end

-- Rola przypisana w grupie.
-- Retail: UnitGroupRolesAssigned() -> "TANK"/"HEALER"/"DAMAGER"/"NONE"
-- 3.3.5a: UnitGroupRolesAssigned() -> isTank, isHealer, isDamage
local function AssignedRoles()
    local a, b, c = SafeCall(UnitGroupRolesAssigned, "player")
    if type(a) == "string" then
        if a == "TANK" or a == "HEALER" or a == "DAMAGER" then
            return { a }
        end
        return {}
    end
    return RolesFromFlags(a, b, c)
end

-- Role zaznaczone w Dungeon Finderze. Oba API: leader, tank, healer, dps.
local function LFGRoles()
    local leader, tank, healer, dps = SafeCall(GetLFGRoles)
    return RolesFromFlags(tank, healer, dps), leader and true or false
end

-- Rola wynikająca z aktualnej specjalizacji (tylko nowe API).
local function SpecRoles()
    if not WF.API.specs then
        return {}
    end
    local spec = SafeCall(GetSpecialization)
    if not spec then
        return {}
    end
    local role = SafeCall(GetSpecializationRole, spec)
    if role == "TANK" or role == "HEALER" or role == "DAMAGER" then
        return { role }
    end
    return {}
end

-- Zwraca: listaRól (np. {"TANK","DAMAGER"}), czyChętnyNaLidera
function WF:CollectRoles(activity)
    local lfgRoles, isLeader = LFGRoles()

    local candidates = {}
    if activity and activity.type == ACTIVITY_BG and WF.API.pvpRoles then
        -- Battleground: role z okna PvP
        tinsert(candidates, RolesFromFlags(SafeCall(GetPVPRoles)))
    end
    if activity and activity.status ~= "" and activity.type ~= ACTIVITY_BG then
        -- W kolejce LFG liczą się role zaznaczone przy zapisie
        tinsert(candidates, lfgRoles)
    end
    tinsert(candidates, AssignedRoles())
    tinsert(candidates, lfgRoles)
    tinsert(candidates, SpecRoles())

    for _, roles in ipairs(candidates) do
        if #roles > 0 then
            return roles, isLeader
        end
    end
    return {}, isLeader
end

------------------------------------------------------------------------
-- 11. ZBIERANIE DANYCH: GRUPA
------------------------------------------------------------------------

local function UnitDisplayName(unit)
    -- WoW Forever: postacie mają imię + nazwisko, a zamiast realmów są rulesety.
    -- Pełną nazwę (jak w DBM na Forever) zwraca GetUnitName().
    if WF.isForever then
        local full = SafeCall(GetUnitName, unit, true)
        if IsNonEmptyString(full) and full ~= UNKNOWNOBJECT then
            return full
        end
    end
    local name, realm = SafeCall(UnitName, unit)
    if not IsNonEmptyString(name) or name == UNKNOWNOBJECT or name == UNKNOWN then
        return nil
    end
    if IsNonEmptyString(realm) then
        return name .. "-" .. realm
    end
    return name
end

local function IsPlayerInRaid()
    if type(IsInRaid) == "function" then
        return SafeCall(IsInRaid) and true or false
    end
    return (SafeCall(GetNumRaidMembers) or 0) > 0     -- 3.3.5a
end

function WF:CollectGroup()
    local members = {}
    local inRaid = IsPlayerInRaid()

    if inRaid then
        local count = SafeCall(GetNumGroupMembers) or SafeCall(GetNumRaidMembers) or 0
        for i = 1, count do
            local name = UnitDisplayName("raid" .. i)
            if name then tinsert(members, name) end
        end
    else
        tinsert(members, UnitDisplayName("player") or "?")
        -- Retail: GetNumSubgroupMembers() (bez gracza)
        -- 3.3.5a: GetNumPartyMembers()   (bez gracza)
        local count = SafeCall(GetNumSubgroupMembers) or SafeCall(GetNumPartyMembers) or 0
        for i = 1, count do
            local name = UnitDisplayName("party" .. i)
            if name then tinsert(members, name) end
        end
    end

    local current = #members
    if current < 1 then current = 1 end

    local maxSize = 5
    if inRaid then
        maxSize = 40
        local _, instanceType, _, _, maxPlayers = SafeCall(GetInstanceInfo)
        if (instanceType == "raid" or instanceType == "pvp") and tonumber(maxPlayers) and maxPlayers > 0 then
            maxSize = maxPlayers
        end
    end
    if current > maxSize then maxSize = current end

    return {
        current = current,
        max = maxSize,
        members = members,
        isRaid = inRaid,
    }
end

------------------------------------------------------------------------
-- 12. NOTATKA I KOMPLETNY PAKIET DANYCH
------------------------------------------------------------------------

local function CleanNote(note)
    if type(note) ~= "string" then
        return ""
    end
    note = string.gsub(note, "||", "|")                          -- "|" wpisany w okno
    note = string.gsub(note, "|c%x%x%x%x%x%x%x%x", "")            -- kolory
    note = string.gsub(note, "|r", "")
    note = string.gsub(note, "|H.-|h(.-)|h", "%1")                -- linki do przedmiotów itp.
    note = string.gsub(note, "|T.-|t", "")                        -- ikonki
    note = string.match(note, "^%s*(.-)%s*$") or ""
    if #note > MAX_NOTE_BYTES then
        note = string.sub(note, 1, MAX_NOTE_BYTES)
        -- nie zostawiamy uciętego znaku UTF-8 na końcu
        note = string.gsub(note, "[\192-\255][\128-\191]*$", "")
    end
    return note
end

function WF:CollectData(note)
    local db = WoWForeverDB

    -- Unikalny znacznik czasu. Gdyby ktoś kliknął dwa razy w tej samej
    -- sekundzie, ID i tak będzie rosło.
    local now = time()
    local lastId = tonumber(db.notification_id) or 0
    local notificationId = now
    if notificationId <= lastId then
        notificationId = lastId + 1
    end

    local classLocalized, classToken = SafeCall(UnitClass, "player")
    local activity = WF:DetectActivity()
    local roles, isLeader = WF:CollectRoles(activity)
    local group = WF:CollectGroup()

    return {
        notification_id   = notificationId,
        created_at        = now,

        player_name       = UnitDisplayName("player") or SafeCall(UnitName, "player") or "?",
        player_realm      = SafeCall(GetRealmName) or "",  -- na Forever: nazwa rulesetu
        player_class      = classToken or "UNKNOWN",      -- np. WARRIOR, MAGE
        player_class_name = classLocalized or "",         -- nazwa w języku klienta
        player_level      = SafeCall(UnitLevel, "player") or 0,
        player_faction    = SafeCall(UnitFactionGroup, "player") or "",

        player_role       = roles,                        -- np. { "TANK", "DAMAGER" }
        player_role_text  = tconcat(roles, ","),
        is_leader         = isLeader,

        activity_type     = activity.type,
        activity_name     = activity.name,
        activity_status   = activity.status or "",

        group_size        = format("%d/%d", group.current, group.max),
        group_current     = group.current,
        group_max         = group.max,
        group_members     = group.members,
        group_is_raid     = group.isRaid,

        custom_note       = CleanNote(note),

        client_version    = WF.clientVersion,
        client_toc        = WF.clientToc,
        client_flavor     = WF.isForever and "Forever" or (WF.isLegacyClient and "Legacy" or "Mainline"),
        addon_version     = ADDON_VERSION,
    }
end

------------------------------------------------------------------------
-- 13. GŁÓWNA AKCJA: "ZAWOŁAJ EKIPĘ"
------------------------------------------------------------------------

-- Aktualna treść notatki z panelu (lub zapamiętana).
function WF:GetCurrentNote()
    if WF.noteBox then
        return WF.noteBox:GetText() or ""
    end
    return (WoWForeverDB and WoWForeverDB.settings.lastNote) or ""
end

function WF:CallTeam(note)
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        Print(T("IN_COMBAT"))
        return
    end

    InitDB()
    local db = WoWForeverDB
    local data = WF:CollectData(note)

    -- To JEDYNE miejsce, w którym zmienia się notification_id.
    db.notification = data
    db.notification_id = data.notification_id
    db.settings.lastNote = ""      -- notatka "zużyta"
    db.justSent = true             -- po przeładowaniu wyświetlimy potwierdzenie

    Print(T("SENDING"))

    -- ReloadUI() wymusza natychmiastowy zapis SavedVariables na dysk.
    ReloadUI()
end

-- Podgląd na czacie bez wysyłania (/wf test).
function WF:PrintPreview()
    local data = WF:CollectData(WF:GetCurrentNote())
    Print(T("PREVIEW"))
    local lines = {
        format("  Postać: %s (Lvl %s %s) – %s", data.player_name, tostring(data.player_level),
            data.player_class, data.player_realm),
        format("  Rola: %s%s", data.player_role_text ~= "" and data.player_role_text or "brak",
            data.is_leader and " (lider)" or ""),
        format("  Aktywność: %s – %s", data.activity_type, data.activity_name),
        format("  Status: %s", data.activity_status ~= "" and data.activity_status or "-"),
        format("  Grupa: %s (%s)", data.group_size, tconcat(data.group_members, ", ")),
        format("  Notatka: %s", data.custom_note ~= "" and data.custom_note or "-"),
        format("  Klient: %s (TOC %s, %s)", data.client_version, tostring(data.client_toc),
            data.client_flavor),
    }
    for _, line in ipairs(lines) do
        Print(line)
    end
end

------------------------------------------------------------------------
-- 14. INTERFEJS: PRZESUWALNY PANEL
------------------------------------------------------------------------

local BACKDROP = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local function ShowButtonTooltip(owner, withDragHint)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:AddLine(T("TOOLTIP_TITLE"), 1, 0.82, 0)
    GameTooltip:AddLine(T("TOOLTIP_TEXT"), 1, 1, 1, true)
    if withDragHint then
        GameTooltip:AddLine(T("TOOLTIP_DRAG"), 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
end

local function HideTooltip()
    GameTooltip:Hide()
end

function WF:UpdatePlaceholder()
    if not WF.noteBox or not WF.noteHint then return end
    local text = WF.noteBox:GetText() or ""
    if text == "" and not WF.noteBox.hasFocus then
        WF.noteHint:Show()
    else
        WF.noteHint:Hide()
    end
end

function WF:SavePanelPosition()
    if not WF.panel then return end
    local point, _, relativePoint, x, y = WF.panel:GetPoint()
    WoWForeverDB.settings.panelPoint = { point or "CENTER", relativePoint or "CENTER", x or 0, y or 0 }
end

function WF:RestorePanelPosition()
    if not WF.panel then return end
    local p = WoWForeverDB.settings.panelPoint
    WF.panel:ClearAllPoints()
    if type(p) == "table" and p[1] then
        WF.panel:SetPoint(p[1], UIParent, p[2] or p[1], tonumber(p[3]) or 0, tonumber(p[4]) or 0)
    else
        WF.panel:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
    end
end

function WF:CreateMainPanel()
    if WF.panel then return WF.panel end

    -- Od 9.0 SetBackdrop wymaga szablonu "BackdropTemplate"; starsze klienty go nie mają.
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    local panel = CreateFrame("Frame", "WoWForeverPanel", UIParent, template)
    panel:SetWidth(240)
    panel:SetHeight(100)
    panel:SetFrameStrata("MEDIUM")
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        WF:SavePanelPosition()
    end)
    if panel.SetBackdrop then
        panel:SetBackdrop(BACKDROP)
        panel:SetBackdropColor(0.05, 0.05, 0.08, 0.92)
        panel:SetBackdropBorderColor(0.55, 0.6, 0.75, 1)
    end

    -- Nagłówek: ikona + tytuł
    local icon = panel:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    icon:SetWidth(16)
    icon:SetHeight(16)
    icon:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -9)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    title:SetText(T("TITLE"))
    WF.panelTitle = title

    -- Przycisk zamknięcia (ukrywa panel; /wf przywraca)
    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 1, 1)
    close:SetScript("OnClick", function() WF:SetPanelShown(false) end)

    -- Pole na opcjonalną notatkę
    local note = CreateFrame("EditBox", "WoWForeverNoteBox", panel, "InputBoxTemplate")
    note:SetWidth(206)
    note:SetHeight(20)
    note:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -32)
    note:SetAutoFocus(false)
    note:SetMaxLetters(120)
    note:SetText(WoWForeverDB.settings.lastNote or "")
    note:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        WF:CallTeam(self:GetText())
    end)
    note:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- HookScript zachowuje zachowanie z szablonu InputBoxTemplate
    note:HookScript("OnTextChanged", function(self)
        WoWForeverDB.settings.lastNote = self:GetText() or ""
        WF:UpdatePlaceholder()
    end)
    note:HookScript("OnEditFocusGained", function(self)
        self.hasFocus = true
        WF:UpdatePlaceholder()
    end)
    note:HookScript("OnEditFocusLost", function(self)
        self.hasFocus = false
        WF:UpdatePlaceholder()
    end)
    WF.noteBox = note

    local hint = note:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", note, "LEFT", 2, 0)
    hint:SetText(T("NOTE_HINT"))
    WF.noteHint = hint

    -- Główny przycisk
    local button = CreateFrame("Button", "WoWForeverCallButton", panel, "UIPanelButtonTemplate")
    button:SetWidth(212)
    button:SetHeight(28)
    button:SetPoint("BOTTOM", panel, "BOTTOM", 0, 12)
    button:SetText(ButtonLabel())
    button:SetScript("OnClick", function() WF:CallTeam(note:GetText()) end)
    button:SetScript("OnEnter", function(self) ShowButtonTooltip(self, false) end)
    button:SetScript("OnLeave", HideTooltip)
    WF.callButton = button

    WF.panel = panel
    WF:RestorePanelPosition()
    WF:UpdatePlaceholder()
    return panel
end

function WF:SetPanelShown(shown)
    WoWForeverDB.settings.showPanel = shown and true or false
    if not WF.panel then return end
    if shown then
        WF.panel:Show()
    else
        WF.panel:Hide()
    end
end

function WF:TogglePanel()
    local shown = not (WF.panel and WF.panel:IsShown())
    WF:SetPanelShown(shown)
    Print(shown and T("PANEL_SHOWN") or T("PANEL_HIDDEN"))
end

------------------------------------------------------------------------
-- 15. INTERFEJS: PRZYCISKI PRZY DUNGEON FINDERZE I BATTLEGROUNDACH
------------------------------------------------------------------------

-- Okna, do których doczepiamy przycisk. "unless" = pomiń, jeśli istnieje
-- któreś z podanych okien (żeby nie dublować przycisku w nowym kliencie,
-- gdzie Dungeon Finder i PvP są zakładkami PVEFrame).
local ATTACH_TARGETS = {
    { name = "PVEFrame" },                                                      -- Retail / nowe Classic
    { name = "LFDParentFrame",   unless = { "PVEFrame" } },                     -- 3.3.5a – Dungeon Finder
    -- Classic oraz WoW Forever: Group Finder w stylu Vanilla
    -- (Blizzard_GroupFinder_VanillaStyle, ładowany na żądanie -> ADDON_LOADED)
    { name = "LFGParentFrame",   unless = { "PVEFrame", "LFDParentFrame" } },
    { name = "PVPParentFrame",   unless = { "PVEFrame" } },                     -- 3.3.5a – PvP / BG
    { name = "PVPFrame",         unless = { "PVEFrame", "PVPParentFrame" } },
    { name = "BattlefieldFrame", unless = { "PVEFrame", "PVPParentFrame" } },   -- okno battlemastera (Classic)
}

-- Domyślna pozycja: nad prawym górnym rogiem okna.
local ATTACH_DEFAULT_POINT = {
    _default       = { "BOTTOMRIGHT", "TOPRIGHT", -30, 2 },
    LFDParentFrame = { "BOTTOMRIGHT", "TOPRIGHT", -40, -10 },
    PVPParentFrame = { "BOTTOMRIGHT", "TOPRIGHT", -40, -10 },
}

WF.attached = {}

local function PositionAttachedButton(button, parent, frameName)
    local saved = WoWForeverDB.settings.attach[frameName]
    button:ClearAllPoints()
    if type(saved) == "table" and tonumber(saved.x) and tonumber(saved.y) then
        button:SetPoint("TOPLEFT", parent, "TOPLEFT", saved.x, saved.y)
    else
        local d = ATTACH_DEFAULT_POINT[frameName] or ATTACH_DEFAULT_POINT._default
        button:SetPoint(d[1], parent, d[2], d[3], d[4])
    end
end

local function CreateAttachedButton(parent, frameName)
    local button = CreateFrame("Button", "WoWForeverAttach" .. frameName, parent, "UIPanelButtonTemplate")
    button:SetWidth(156)
    button:SetHeight(24)
    button:SetFrameLevel((parent:GetFrameLevel() or 1) + 10)
    button:SetText(ButtonLabel())
    PositionAttachedButton(button, parent, frameName)

    -- Shift + przeciągnięcie przesuwa przycisk względem okna Blizzarda.
    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() then
            self.isMoving = true
            self:StartMoving()
        end
    end)
    button:SetScript("OnDragStop", function(self)
        if not self.isMoving then return end
        self.isMoving = false
        self:StopMovingOrSizing()
        if self.SetUserPlaced then self:SetUserPlaced(false) end
        self.movedAt = GetTime()
        local left, top = self:GetLeft(), self:GetTop()
        local pLeft, pTop = parent:GetLeft(), parent:GetTop()
        if left and top and pLeft and pTop then
            WoWForeverDB.settings.attach[frameName] = { x = left - pLeft, y = top - pTop }
        end
        PositionAttachedButton(self, parent, frameName)
    end)

    button:SetScript("OnClick", function(self)
        -- ignorujemy "kliknięcie", które jest końcem przeciągania
        if self.movedAt and GetTime() - self.movedAt < 0.3 then return end
        WF:CallTeam(WF:GetCurrentNote())
    end)
    button:SetScript("OnEnter", function(self) ShowButtonTooltip(self, true) end)
    button:SetScript("OnLeave", HideTooltip)

    return button
end

function WF:TryAttachAll()
    for _, target in ipairs(ATTACH_TARGETS) do
        local frameName = target.name
        local parent = _G[frameName]
        local skip = WF.attached[frameName] ~= nil or type(parent) ~= "table" or not parent.GetObjectType
        if not skip and target.unless then
            for _, other in ipairs(target.unless) do
                if _G[other] then
                    skip = true
                    break
                end
            end
        end
        if not skip then
            WF.attached[frameName] = { button = CreateAttachedButton(parent, frameName), parent = parent }
        end
    end
end

function WF:RefreshTexts()
    if WF.panelTitle then WF.panelTitle:SetText(T("TITLE")) end
    if WF.noteHint then WF.noteHint:SetText(T("NOTE_HINT")) end
    if WF.callButton then WF.callButton:SetText(ButtonLabel()) end
    for _, info in pairs(WF.attached) do
        info.button:SetText(ButtonLabel())
    end
end

function WF:ResetPositions()
    WoWForeverDB.settings.panelPoint = nil
    WoWForeverDB.settings.attach = {}
    WF:RestorePanelPosition()
    for frameName, info in pairs(WF.attached) do
        PositionAttachedButton(info.button, info.parent, frameName)
    end
    Print(T("RESET"))
end

------------------------------------------------------------------------
-- 16. KOMENDY /wf i /wowforever
------------------------------------------------------------------------

local function PrintHelp()
    for _, line in ipairs(T("HELP")) do
        Print(line)
    end
end

SLASH_WOWFOREVER1 = "/wf"
SLASH_WOWFOREVER2 = "/wowforever"
SlashCmdList["WOWFOREVER"] = function(message)
    InitDB()
    local cmd, rest = string.match(message or "", "^%s*(%S*)%s*(.-)%s*$")
    cmd = string.lower(cmd or "")
    rest = rest or ""

    if cmd == "" or cmd == "toggle" then
        WF:TogglePanel()
    elseif cmd == "send" or cmd == "call" or cmd == "wyslij" or cmd == "zawolaj" then
        if rest ~= "" then
            WF:CallTeam(rest)
        else
            WF:CallTeam(WF:GetCurrentNote())
        end
    elseif cmd == "show" or cmd == "pokaz" then
        WF:SetPanelShown(true)
        Print(T("PANEL_SHOWN"))
    elseif cmd == "hide" or cmd == "ukryj" then
        WF:SetPanelShown(false)
        Print(T("PANEL_HIDDEN"))
    elseif cmd == "test" or cmd == "preview" or cmd == "podglad" then
        WF:PrintPreview()
    elseif cmd == "ascii" then
        WoWForeverDB.settings.ascii = not WoWForeverDB.settings.ascii
        WF:RefreshTexts()
        Print(WoWForeverDB.settings.ascii and T("ASCII_ON") or T("ASCII_OFF"))
    elseif cmd == "reset" then
        WF:ResetPositions()
    else
        PrintHelp()
    end
end

------------------------------------------------------------------------
-- 17. ZDARZENIA
------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            InitDB()   -- SavedVariables są już wczytane
        end
        -- Okna ładowane na żądanie (np. Blizzard_PVPUI) – próbujemy doczepić przycisk.
        if WF.ready then
            WF:TryAttachAll()
        end
    elseif event == "PLAYER_LOGIN" then
        InitDB()
        WF:CreateMainPanel()
        WF:SetPanelShown(WoWForeverDB.settings.showPanel)
        WF:TryAttachAll()
        WF.ready = true

        if WoWForeverDB.justSent then
            WoWForeverDB.justSent = nil
            Print(T("SAVED"))
        end
    end
end)
