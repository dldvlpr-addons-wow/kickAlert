-- Nameplates.lua
-- Affiche "KICK" au-dessus de la nameplate de n'importe quelle cible hostile
-- en train de lancer un sort interruptible, sans avoir besoin de la cibler.
--
-- Purement événementiel, pas de ticker : contrairement à Detector.lua (qui
-- attend un cooldown perso), la seule condition ici est `notInterruptible`,
-- et le client prévient déjà de son changement via UNIT_SPELLCAST_INTERRUPTIBLE
-- / NOT_INTERRUPTIBLE.
local _, NS = ...

local Nameplate = CreateFrame("Frame")
NS.Nameplate = Nameplate

-- [unit token, ex. "nameplate7"] = frame indicateur. Réutilisé, jamais recréé :
-- au plus 40 nameplates visibles en simultané.
local pool = {}

local function GetIndicator(unit)
    local frame = pool[unit]
    if frame then return frame end
    frame = CreateFrame("Frame", nil, UIParent)
    frame:SetSize(1, 1)
    frame.label = frame:CreateFontString(nil, "OVERLAY")
    frame.label:SetPoint("CENTER")
    frame:Hide()
    pool[unit] = frame
    return frame
end

-- Ré-ancre à chaque appel : le frame rendu par GetNamePlateForUnit peut changer
-- d'un NAME_PLATE_UNIT_ADDED à l'autre pour le même token (pool Blizzard).
local function AttachToNameplate(unit, frame)
    local plate = NS.GetNamePlateForUnit(unit)
    if not plate then return false end
    frame:SetParent(plate)
    frame:ClearAllPoints()
    frame:SetPoint("BOTTOM", plate, "TOP", 0, 4)
    return true
end

local function EvaluateUnit(unit)
    local frame = GetIndicator(unit)
    if not NS.db.nameplate.enabled or not UnitExists(unit) or not NS.CanAttackUnit(unit) then
        frame:Hide()
        return
    end
    local name, _, _, _, notInterruptible = NS.GetCastInfo(unit)
    if not name or notInterruptible then
        frame:Hide()
        return
    end
    -- Frame nameplate pas encore prêt (juste après ADDED) : le prochain
    -- UNIT_SPELLCAST_* ou le rattrapage DB_READY réessaiera.
    if not AttachToNameplate(unit, frame) then return end
    local cfg = NS.db.nameplate.text
    NS.StyleLabel(frame.label, cfg, NS.DEFAULTS.nameplate.text.font, cfg.label)
    frame:Show()
end

--- Réévalue tous les indicateurs connus (changement d'option) : y compris ceux
-- masqués, sinon réactiver l'option ne les fait pas réapparaître avant le
-- prochain event de cast sur leur unité.
function Nameplate:RefreshAll()
    for unit in pairs(pool) do
        EvaluateUnit(unit)
    end
end

--- Frame indicateur d'une unité, s'il a déjà été créé (tests, inspection).
function Nameplate:GetFrame(unit)
    return pool[unit]
end

-- Nameplates déjà visibles au moment de l'abonnement (ex. /reload en combat) :
-- DB_READY (ADDON_LOADED) survient à l'écran de chargement, avant toute
-- nameplate. PLAYER_ENTERING_WORLD, lui, survient une fois le monde entré.
local function SyncExistingNameplates()
    for _, plate in ipairs(NS.GetNamePlates()) do
        if plate.namePlateUnitToken then EvaluateUnit(plate.namePlateUnitToken) end
    end
end

Nameplate:SetScript("OnEvent", function(self, event, unit)
    if event == "NAME_PLATE_UNIT_ADDED" then
        EvaluateUnit(unit)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        local frame = pool[unit]
        if frame then frame:Hide() end
    elseif event == "PLAYER_ENTERING_WORLD" then
        SyncExistingNameplates()
    elseif unit and unit:match("^nameplate%d+$") then
        -- START, CHANNEL_START, DELAYED, INTERRUPTIBLE, NOT_INTERRUPTIBLE,
        -- STOP, CHANNEL_STOP, SUCCEEDED, INTERRUPTED, FAILED, EMPOWER_*.
        EvaluateUnit(unit)
    end
end)

NS:On("DB_READY", function()
    if not NS.has.namePlates or not NS.has.namePlateUnits then return end

    NS.RegisterEventSafe(Nameplate, "NAME_PLATE_UNIT_ADDED")
    NS.RegisterEventSafe(Nameplate, "NAME_PLATE_UNIT_REMOVED")
    NS.RegisterEventSafe(Nameplate, "PLAYER_ENTERING_WORLD")
    for _, event in ipairs(NS.UNIT_CAST_EVENTS) do
        -- Sans unité : doit couvrir tous les nameplates, pas seulement target/focus.
        NS.RegisterEventSafe(Nameplate, event)
    end
    -- Pas de nameplate visible à ce stade (ADDON_LOADED survient à l'écran de
    -- chargement) : le rattrapage se fait via PLAYER_ENTERING_WORLD ci-dessus.
end)
