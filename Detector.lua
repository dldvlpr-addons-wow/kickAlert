-- Detector.lua
-- Alerte "KICK" quand la cible (ou le focus) lance un sort interruptible ET que
-- TON interrupt est réellement disponible. Logique reprise de
-- MyBossSuite/Modules/InterruptAlert/InterruptAlert.lua, sans la data WCL ni la
-- rotation de groupe.
--
-- Les trois conditions sont vérifiées ensemble, en continu pendant l'incantation.
-- Un kick qui revient de cooldown au milieu du cast déclenche l'alerte, et un
-- cast protégé (`notInterruptible`) n'en déclenche jamais.
local _, NS = ...
local L = NS.L

local Detector = CreateFrame("Frame")
NS.Detector = Detector

-- 0.15s : assez fin pour attraper la fin d'un cooldown au milieu d'un cast,
-- assez lâche pour ne rien coûter. Le ticker ne tourne que pendant une incantation.
local POLL_INTERVAL = 0.15

-- Durée de vie d'une incantation déduite du combat log, quand le client ne sait
-- pas répondre à UnitCastingInfo sur une unité hostile.
local FALLBACK_CAST_MAX = 6

--------------------------------------------------------------------------------
-- Sorts d'interruption
--------------------------------------------------------------------------------
-- Table par classe, plusieurs ids par classe : le bon est celui que le joueur
-- connaît réellement (`NS.KnowsSpell` couvre aussi les rangs Classic).

local INTERRUPTS = {
    WARRIOR     = { 6552, 72 },                   -- Pummel, Shield Bash
    ROGUE       = { 1766 },                       -- Kick
    MAGE        = { 2139 },                       -- Counterspell
    SHAMAN      = { 57994, 8042 },                -- Wind Shear, Earth Shock
    PRIEST      = { 15487 },                      -- Silence
    DRUID       = { 106839, 80965, 16979 },       -- Skull Bash, Feral Charge
    PALADIN     = { 96231, 31935 },               -- Rebuke, Avenger's Shield
    DEATHKNIGHT = { 47528, 47476 },               -- Mind Freeze, Strangulate
    HUNTER      = { 147362, 187707, 34490 },      -- Counter Shot, Muzzle, Silencing Shot
    WARLOCK     = { 19647, 119910, 132409 },      -- Spell Lock (familier)
    MONK        = { 116705 },                     -- Spear Hand Strike
    DEMONHUNTER = { 183752 },                     -- Disrupt
    EVOKER      = { 351338 },                     -- Quell
}
Detector.INTERRUPTS = INTERRUPTS

-- Cooldown de base par sort, en secondes. Ne sert que lorsque le client rend le cooldown
-- secret (moteur 12.x en combat) : le détecteur déduit alors le cooldown du dernier lancer
-- du joueur. Valeurs Classic (rangs de Forever) ; RETAIL_COOLDOWNS corrige les ids communs
-- dont la durée diffère sur retail. Une durée lue hors combat (NS.lastCooldownDuration)
-- prime toujours sur ces tables : talents et rangs sont ainsi rattrapés.
local BASE_COOLDOWNS = {
    [6552] = 10, [72] = 12,                      -- Pummel, Shield Bash
    [1766] = 10,                                 -- Kick
    [2139] = 30,                                 -- Counterspell
    [57994] = 12, [8042] = 6,                    -- Wind Shear, Earth Shock
    [15487] = 45,                                -- Silence
    [106839] = 15, [80965] = 10, [16979] = 15,   -- Skull Bash, Feral Charge
    [96231] = 15, [31935] = 15,                  -- Rebuke, Avenger's Shield
    [47528] = 15, [47476] = 60,                  -- Mind Freeze, Strangulate
    [147362] = 24, [187707] = 15, [34490] = 20,  -- Counter Shot, Muzzle, Silencing Shot
    [19647] = 24, [119910] = 24, [132409] = 24,  -- Spell Lock
    [116705] = 15,                               -- Spear Hand Strike
    [183752] = 15,                               -- Disrupt
    [351338] = 40,                               -- Quell
}
local RETAIL_COOLDOWNS = { [6552] = 15, [1766] = 15, [2139] = 24 }
local DEFAULT_COOLDOWN = 15

function Detector:ResolveInterrupt()
    local previous = self.interruptSpell
    local override = NS.db and NS.db.spellId
    if override then
        self.interruptSpell = override
        self.interruptName  = NS.GetSpellName(override) or tostring(override)
    else
        local _, class = UnitClass("player")
        local candidates = INTERRUPTS[class or ""] or {}
        self.interruptSpell, self.interruptName = nil, nil
        for i = 1, #candidates do
            if NS.KnowsSpell(candidates[i]) then
                self.interruptSpell = candidates[i]
                self.interruptName  = NS.GetSpellName(candidates[i])
                break
            end
        end
    end
    -- Autre sort suivi : le lancer mémorisé pour le cooldown déduit ne le concerne pas.
    -- SPELLS_CHANGED re-résout souvent le même sort : on ne l'oublie pas dans ce cas.
    if self.interruptSpell ~= previous then self.interruptUsedAt = nil end
    return self.interruptSpell
end

--- Cooldown de base du kick suivi, pour le cooldown déduit.
function Detector:BaseCooldown()
    local id = self.interruptSpell
    return NS.lastCooldownDuration[id]
        or (NS.isRetail and not NS.isForever and RETAIL_COOLDOWNS[id])
        or BASE_COOLDOWNS[id]
        or DEFAULT_COOLDOWN
end

--- Cooldown restant du kick. nil = pas d'interrupt connu. Second retour : "api" quand le
-- client l'a rendu, "deduced" quand il le garde secret (moteur 12.x en combat) : le
-- cooldown est alors déduit du dernier lancer du joueur (UNIT_SPELLCAST_SUCCEEDED sur
-- "player", jamais secret), ou considéré prêt tant qu'aucun lancer n'a été vu.
function Detector:InterruptRemaining()
    if not self.interruptSpell then return nil end
    local remaining, secret = NS.GetSpellRemaining(self.interruptSpell)
    if not secret then return remaining, "api" end
    if not self.interruptUsedAt then return 0, "deduced" end
    remaining = self.interruptUsedAt + self:BaseCooldown() - GetTime()
    return remaining > 0 and remaining or 0, "deduced"
end

--- Lancer réussi d'un sort par le joueur : si c'est le kick suivi (id exact ou même nom,
-- pour les rangs Classic), son cooldown part maintenant.
function Detector:NoteInterruptCast(spellId)
    if not self.interruptSpell or not spellId or NS.IsSecret(spellId) then return end
    if spellId ~= self.interruptSpell and NS.GetSpellName(spellId) ~= self.interruptName then return end
    self.interruptUsedAt = GetTime()
    self:Evaluate()
end

-- Frame à part : Detector filtre UNIT_SPELLCAST_SUCCEEDED sur target/focus (RegisterUnitEvent
-- remplace la liste d'unités à chaque appel), et le joueur n'est pas une unité surveillée.
-- "pet" : Spell Lock est lancé par le familier du démoniste. Ses sorts restent lisibles.
local playerCasts = CreateFrame("Frame")
playerCasts:SetScript("OnEvent", function(_, _, unit, _, spellId)
    -- Sans RegisterUnitEvent (vieux clients), l'event arrive pour toutes les unités.
    if unit == "player" or unit == "pet" then Detector:NoteInterruptCast(spellId) end
end)

--------------------------------------------------------------------------------
-- Incantations lues dans le combat log
--------------------------------------------------------------------------------
-- Repli pour les clients où UnitCastingInfo ne répond rien sur une unité hostile.
-- Le combat log ne dit pas si le sort est protégé : on assume interruptible
-- plutôt que de rater le kick.

local casts = {}   -- [guid] = { name, spellId, expires }

-- Numéro de cast par unité surveillée ("target", "focus"), incrémenté à chaque START.
-- Sert de signature à Detector:ShowAlert.
local castSerial = {}
local castStartedAt = {}

--- Une incantation vue par l'API (UNIT_SPELLCAST_START) et par le combat log
-- (SPELL_CAST_START) arrive dans la même frame : GetTime() y est constant, un seul numéro.
local function NoteCastStart(unit)
    local now = GetTime()
    if castStartedAt[unit] == now then return end
    castStartedAt[unit] = now
    castSerial[unit] = (castSerial[unit] or 0) + 1
end

-- Un GUID secret (moteur 12.x) ne peut pas servir de clé de table.
local function ClearCast(guid)
    if guid and not NS.IsSecret(guid) then casts[guid] = nil end
end

function Detector:FallbackCast(guid)
    if not guid or NS.IsSecret(guid) then return nil end
    local cast = casts[guid]
    if not cast then return nil end
    if GetTime() > cast.expires then
        casts[guid] = nil
        return nil
    end
    return cast.name, cast.spellId
end

--- GUID des unités surveillées, mis à jour sur changement de cible / focus.
-- Le combat log les compare directement : aucun appel d'API dans le chemin chaud.
function Detector:UpdateWatchedGUIDs()
    self.targetGUID = UnitExists("target") and UnitGUID("target") or nil
    self.focusGUID  = NS.has.focus and NS.db.watchFocus ~= false
        and UnitExists("focus") and UnitGUID("focus") or nil
    for guid in pairs(casts) do
        if guid ~= self.targetGUID and guid ~= self.focusGUID then casts[guid] = nil end
    end
end

local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo

local function OnCombatLog()
    local _, sub, _, srcGUID, _, _, _, dstGUID, _, _, _, spellId, spellName = CombatLogGetCurrentEventInfo()
    if sub == "SPELL_CAST_START" then
        -- `not srcGUID` : sans cible ni focus, nil == nil passerait le garde et écrirait casts[nil].
        if not srcGUID or (srcGUID ~= Detector.targetGUID and srcGUID ~= Detector.focusGUID) then return end
        casts[srcGUID] = {
            name    = spellName or NS.GetSpellName(spellId) or "?",
            spellId = spellId,
            expires = GetTime() + FALLBACK_CAST_MAX,
        }
        -- Nouveau numéro de cast : un cast raté (jamais loggé pour un PNJ) suivi d'un autre
        -- doit redéclencher l'alerte, pas garder la signature du précédent.
        if srcGUID == Detector.targetGUID then NoteCastStart("target") end
        if srcGUID == Detector.focusGUID  then NoteCastStart("focus") end
        Detector:Wake()
    elseif sub == "SPELL_CAST_SUCCESS" or sub == "SPELL_CAST_FAILED" then
        if casts[srcGUID] then
            ClearCast(srcGUID)
            Detector:Evaluate()
        end
    elseif sub == "SPELL_INTERRUPT" then
        -- dstGUID : c'est l'unité interrompue, pas l'interrupteur.
        if casts[dstGUID] then ClearCast(dstGUID) end
        Detector:Evaluate()
    elseif sub == "UNIT_DIED" then
        ClearCast(dstGUID)
    end
end

--------------------------------------------------------------------------------
-- Évaluation
--------------------------------------------------------------------------------

local WATCH_UNITS = { "target", "focus" }

--- Première incantation interruptible trouvée sur les unités surveillées.
-- Retourne unit, name, spellId. L'API du client fait foi ; le combat log ne
-- sert que là où elle ne répond rien.
function Detector:FindCast()
    for i = 1, #WATCH_UNITS do
        local unit = WATCH_UNITS[i]
        if (unit ~= "focus" or (NS.has.focus and NS.db.watchFocus ~= false))
            and UnitExists(unit) and NS.CanAttackUnit(unit) then
            local name, _, _, _, notInterruptible, spellId = NS.GetCastInfo(unit)
            if name then
                if not notInterruptible then return unit, name, spellId end
            else
                local fallbackName, fallbackSpell = self:FallbackCast(UnitGUID(unit))
                if fallbackName then return unit, fallbackName, fallbackSpell end
            end
        end
    end
    return nil
end

function Detector:InRange(unit)
    if not self.interruptName or not NS.IsSpellInRange then return true end
    -- 0 = hors de portée, 1 = à portée, nil = le client ne sait pas : seul le 0 franc bloque.
    return NS.IsSpellInRange(self.interruptName, unit) ~= 0
end

function Detector:Evaluate()
    if not NS.db then return end
    if _G.UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then
        self:ClearAlert()
        return self:Sleep()
    end

    local unit, name, spellId = self:FindCast()
    if not unit then
        self:ClearAlert()
        return self:Sleep()
    end

    -- Une incantation est en cours : le ticker tourne, même sans alerte affichée,
    -- pour attraper la fin du cooldown ou l'entrée en portée.
    self:EnsurePolling()

    local remaining = self:InterruptRemaining()
    local ready = (remaining ~= nil and remaining <= 0)
    if NS.db.onlyWhenReady ~= false and not ready then return self:ClearAlert() end
    if NS.db.checkRange ~= false and not self:InRange(unit) then return self:ClearAlert() end

    self:ShowAlert(unit, name, spellId)
end

--- Une signature par incantation : le même cast ne doit pas rejouer le son à chaque tick.
-- `castSerial` (déclaré avec le repli combat log) est incrémenté à chaque START, qu'il vienne
-- du client ou du combat log : nom et spellId peuvent être des valeurs secrètes (moteur 12.x)
-- et ne servent donc pas de clé.
function Detector:ShowAlert(unit, name, spellId)
    local signature = unit .. "|" .. (castSerial[unit] or 0)
    if self.showing == signature then return end
    self.showing = signature
    NS:Fire("CAST_START", unit, name, spellId)
end

function Detector:ClearAlert()
    if not self.showing then return end
    self.showing = nil
    NS:Fire("CAST_STOP")
end

--------------------------------------------------------------------------------
-- Ticker
--------------------------------------------------------------------------------

function Detector:EnsurePolling()
    if self.poll then return end
    self.poll = NS.Timer.NewTicker(POLL_INTERVAL, function() Detector:Evaluate() end)
end

function Detector:Wake()
    self:EnsurePolling()
    self:Evaluate()
end

function Detector:Sleep()
    if not self.poll then return end
    self.poll:Cancel()
    self.poll = nil
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function IsWatched(unit)
    return unit == "target" or unit == "focus"
end

Detector:SetScript("OnEvent", function(self, event, unit)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        OnCombatLog()
    elseif event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_FOCUS_CHANGED" then
        self:UpdateWatchedGUIDs()
        self:ClearAlert()
        self:Wake()
    elseif event == "PLAYER_REGEN_ENABLED" then
        self:ClearAlert()
        self:Sleep()
    elseif event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" then
        self:ResolveInterrupt()
    elseif event == "PLAYER_ENTERING_WORLD" then
        self:ResolveInterrupt()
        self:UpdateWatchedGUIDs()
        self:Wake()
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP"
        or event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_INTERRUPTED"
        or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_EMPOWER_STOP" then
        if not IsWatched(unit) then return end
        -- Le client a vu la fin de l'incantation : l'entrée du repli combat log pour
        -- cette unité n'a plus lieu d'être (SPELL_CAST_FAILED n'est jamais loggé pour un PNJ).
        ClearCast(UnitGUID(unit))
        self:Evaluate()
    elseif IsWatched(unit) then
        -- START, CHANNEL_START, DELAYED, INTERRUPTIBLE, NOT_INTERRUPTIBLE, EMPOWER_START
        if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START"
            or event == "UNIT_SPELLCAST_EMPOWER_START" then
            NoteCastStart(unit)
        end
        self:Wake()
    end
end)

--------------------------------------------------------------------------------
-- État lisible (/ka status)
--------------------------------------------------------------------------------

function Detector:StatusLines()
    local remaining, cooldownSource = self:InterruptRemaining()
    local spell = self.interruptSpell
        and ("%s (%d)"):format(self.interruptName or "?", self.interruptSpell)
        or ("|cffff5555" .. L.STATUS_NONE .. "|r")
    local yes, no = L.STATUS_YES, L.STATUS_NO
    local lines = {
        L.STATUS_INTERRUPT:format(spell) .. (NS.db.spellId and (" |cffaaaaaa" .. L.STATUS_FORCED .. "|r") or ""),
        L.STATUS_AVAILABLE:format(
            remaining == nil and "?" or (remaining <= 0 and yes or L.STATUS_IN:format(remaining)))
            .. (cooldownSource == "deduced"
                and (" |cffaaaaaa" .. L.COOLDOWN_DEDUCED:format(self:BaseCooldown()) .. "|r") or ""),
        L.STATUS_FLAGS:format(
            NS.db.watchFocus ~= false and yes or no,
            NS.db.checkRange ~= false and yes or no,
            NS.db.onlyWhenReady ~= false and yes or no),
        L.STATUS_SOURCE:format(
            NS.has.unitCastInfo and (NS.hasCombatLog and L.SOURCE_API_CLEU or L.SOURCE_API_ONLY)
            or (NS.hasCombatLog and L.SOURCE_CLEU_ONLY or ("|cffff5555" .. L.SOURCE_NONE .. "|r"))),
    }
    -- Cible en incantation : d'où vient l'état « protégé ». Sur moteur 12.x la valeur est
    -- secrète et "unknown" signale le cas où l'alerte part sans pouvoir trancher.
    if UnitExists("target") then
        local name, _, _, _, notInterruptible, _, _, shieldSource = NS.GetCastInfo("target")
        if not name then
            -- Client sans UnitCastingInfo : seul le combat log voit l'incantation, sans état protégé.
            name, notInterruptible, shieldSource = self:FallbackCast(UnitGUID("target")), false, "unknown"
        end
        if name then
            local sourceLabel = shieldSource == "api" and L.SHIELD_API
                or shieldSource == "event" and L.SHIELD_EVENT
                or ("|cffff5555" .. L.SHIELD_UNKNOWN .. "|r")
            -- Nom secret (12.x) : affichable par SetText, pas par string.format.
            local shownName = NS.IsSecret(name) and "?" or name
            lines[#lines + 1] = L.STATUS_TARGET_CAST:format(shownName, notInterruptible and yes or no, sourceLabel)
        end
    end
    return lines
end

--------------------------------------------------------------------------------
-- Démarrage
--------------------------------------------------------------------------------

NS:On("DB_READY", function()
    Detector:ResolveInterrupt()

    for _, event in ipairs({
        "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "PLAYER_REGEN_ENABLED",
        "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB", "PLAYER_ENTERING_WORLD",
        -- Enregistré même quand UnitCastingInfo existe : sur les clients les plus
        -- anciens l'API répond nil sur une unité hostile, seul le combat log voit l'incantation.
        "COMBAT_LOG_EVENT_UNFILTERED",
    }) do
        NS.RegisterEventSafe(Detector, event)
    end

    for _, event in ipairs({
        "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_DELAYED",
        "UNIT_SPELLCAST_INTERRUPTIBLE", "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
        "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_SUCCEEDED",
        "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED",
        "UNIT_SPELLCAST_EMPOWER_START", "UNIT_SPELLCAST_EMPOWER_STOP", -- retail (évocateur)
    }) do
        -- RegisterUnitEvent limite le coût aux unités surveillées quand il existe.
        NS.RegisterEventSafe(Detector, event, "target", "focus")
    end

    NS.RegisterEventSafe(playerCasts, "UNIT_SPELLCAST_SUCCEEDED", "player", "pet")

    Detector:UpdateWatchedGUIDs()
    Detector:Wake()
end)
