-- Compat.lua
-- Couche d'abstraction API, reprise de MyBossSuite/Core/Compat.lua (partie utile
-- au kick). AUCUN autre fichier n'appelle une API qui diffère entre versions du
-- client : tout passe par ici.
--
-- Règle : le flavor sert au branchement de *data*, la feature-detection sert au
-- branchement d'*API*. Un patch Classic qui backporte une fonction ne doit rien
-- casser.
local ADDON_NAME, NS = ...
_G.KickAlert = NS
NS.addonName = ADDON_NAME

--------------------------------------------------------------------------------
-- Flavor
--------------------------------------------------------------------------------

local projectId = _G.WOW_PROJECT_ID

local function IsProject(constant)
    local value = _G[constant]
    return value ~= nil and projectId == value
end

local function FlavorFromInterface()
    -- Filet de secours pour les builds où WOW_PROJECT_ID n'existe pas.
    local _, _, _, iface = GetBuildInfo()
    iface = tonumber(iface) or 0
    if iface >= 100000 then return "retail" end
    if iface >= 50000 then return "mists" end
    if iface >= 40000 then return "cata" end
    if iface >= 30000 then return "wrath" end
    if iface >= 20000 then return "tbc" end
    return "vanilla"
end

NS.flavor = (projectId and (
       (IsProject("WOW_PROJECT_MAINLINE") and "retail")
    or (IsProject("WOW_PROJECT_CLASSIC") and "vanilla")
    or (IsProject("WOW_PROJECT_BURNING_CRUSADE_CLASSIC") and "tbc")
    or (IsProject("WOW_PROJECT_WRATH_CLASSIC") and "wrath")
    or (IsProject("WOW_PROJECT_CATACLYSM_CLASSIC") and "cata")
    or (IsProject("WOW_PROJECT_MISTS_CLASSIC") and "mists")
)) or FlavorFromInterface()

NS.isRetail = (NS.flavor == "retail")

-- WoW Forever (1.60.x) : moteur 12.x avec les données Classic (rangs, cooldowns d'époque).
-- Aucune constante WOW_PROJECT_* ne le désigne : seul le numéro d'interface (16001) le distingue.
local _, _, _, interfaceVersion = GetBuildInfo()
interfaceVersion = tonumber(interfaceVersion) or 0
NS.isForever = interfaceVersion >= 16000 and interfaceVersion < 20000

--------------------------------------------------------------------------------
-- Détection d'events
--------------------------------------------------------------------------------
-- RegisterEvent lève une erreur sur un event inconnu : c'est le seul test fiable
-- de la présence d'un event, et il survit aux backports.

local probe = CreateFrame("Frame")
local eventExists = {}

-- Moteur 12.x (Midnight, WoW Forever 1.60) : COMBAT_LOG_EVENT_UNFILTERED est interdit aux addons.
-- Le sonder déclenche le popup ADDON_ACTION_FORBIDDEN même sous pcall : on l'exclut sans le tester.
NS.hasCombatLog = not (C_DamageMeter or issecretvalue or (C_CombatLog and C_CombatLog.SetFilteredEventsEnabled))
if not NS.hasCombatLog then
    eventExists.COMBAT_LOG_EVENT_UNFILTERED = false
    eventExists.COMBAT_LOG_EVENT = false
end

function NS.EventExists(event)
    local cached = eventExists[event]
    if cached ~= nil then return cached end
    local ok = pcall(probe.RegisterEvent, probe, event)
    if ok then pcall(probe.UnregisterEvent, probe, event) end
    eventExists[event] = ok
    return ok
end

--- Enregistre un event s'il existe sur ce client. Avec des unités : RegisterUnitEvent
-- (filtrage côté client), repli RegisterEvent quand il manque. Retourne true si enregistré.
function NS.RegisterEventSafe(frame, event, ...)
    if not NS.EventExists(event) then return false end
    if frame.RegisterUnitEvent and select("#", ...) > 0 then
        if pcall(frame.RegisterUnitEvent, frame, event, ...) then return true end
    end
    frame:RegisterEvent(event)
    return true
end

--------------------------------------------------------------------------------
-- Valeurs secrètes (moteur 12.x : retail et WoW Forever)
--------------------------------------------------------------------------------
-- Affichables, mais ni comparables ni testables (booléen) ni utilisables en clé de table.
-- Chaque fonction de Compat qui peut en recevoir une rend nil pour « le client refuse de
-- répondre », et l'appelant s'abstient.

-- Résolue à l'appel : issecretvalue n'existe pas sur les clients d'avant 12.0, et la suite
-- de tests la pose après le chargement.
local function isSecret(value)
    local issecretvalue = _G.issecretvalue
    return issecretvalue ~= nil and issecretvalue(value)
end
NS.IsSecret = isSecret

--------------------------------------------------------------------------------
-- Spell API
--------------------------------------------------------------------------------
-- C_Spell.* introduit en 11.0 retail, backporté partiellement en Classic.

-- Retourne nil quand le sort est inconnu du client : c'est ce qui permet de
-- distinguer "cooldown à zéro" de "sort absent du grimoire".
NS.GetSpellCooldown = (C_Spell and C_Spell.GetSpellCooldown)
    and function(id)
        local info = C_Spell.GetSpellCooldown(id)
        if not info then return nil end
        return info.startTime, info.duration, info.isEnabled
    end
    or _G.GetSpellCooldown

NS.GetSpellInfo = (C_Spell and C_Spell.GetSpellInfo)
    and function(id)
        local info = C_Spell.GetSpellInfo(id)
        if not info then return nil end
        return info.name, nil, info.iconID, info.castTime
    end
    or _G.GetSpellInfo

NS.GetSpellTexture = (C_Spell and C_Spell.GetSpellTexture)
    or _G.GetSpellTexture
    or function(id) return (select(3, NS.GetSpellInfo(id))) end

function NS.GetSpellName(id)
    local name = NS.GetSpellInfo(id)
    return name
end

--- Le joueur connaît-il ce sort ?
-- `IsSpellKnown` teste un id exact : en Classic, un sort a un id par rang et
-- l'id du rang 1 ne dit rien du rang 6 appris. Le repli par nom couvre tous les
-- rangs d'un coup, puisque le grimoire est indexé par nom.
function NS.KnowsSpell(spellId)
    if not spellId then return false end
    if _G.IsPlayerSpell and IsPlayerSpell(spellId) then return true end
    if _G.IsSpellKnown and IsSpellKnown(spellId) then return true end
    if C_SpellBook and C_SpellBook.IsSpellKnown and C_SpellBook.IsSpellKnown(spellId) then return true end
    local name = NS.GetSpellName(spellId)
    if not name then return false end
    -- Test booléen et non `~= nil` : sur moteur 12.x en combat, le startTime rendu est une
    -- valeur secrète, que l'on peut tester mais pas comparer.
    if NS.GetSpellCooldown(name) then return true end
    return false
end

-- Dernière durée de cooldown lisible, par sort. Sur moteur 12.x (retail, WoW Forever) le
-- cooldown d'un sort du joueur devient secret en combat (C_Secrets.ShouldCooldownsBeSecret) :
-- cette durée, relevée hors combat, sert de base au cooldown déduit par le détecteur.
NS.lastCooldownDuration = {}

--- Cooldown restant d'un sort, en secondes. 0 = prêt. nil = sort inconnu.
-- Second retour true : le client rend un cooldown secret (moteur 12.x en combat), le
-- premier retour est alors nil et l'appelant décide seul.
-- Le GCD (durée <= 1.5s) ne compte pas comme un cooldown : un kick reste
-- annoncé comme disponible pendant le GCD, sinon l'alerte clignote à chaque sort lancé.
function NS.GetSpellRemaining(spellId)
    local start, duration = NS.GetSpellCooldown(spellId)
    if not start then return nil end
    if isSecret(start) or isSecret(duration) then return nil, true end
    if start == 0 or duration == 0 or duration <= 1.5 then return 0 end
    NS.lastCooldownDuration[spellId] = duration
    local remaining = start + duration - GetTime()
    return remaining > 0 and remaining or 0
end

--------------------------------------------------------------------------------
-- Incantations
--------------------------------------------------------------------------------
-- Forme unique quelle que soit la version :
--   name, icon, startMs, endMs, notInterruptible, spellId, isChannel
-- Le nombre de valeurs rendues varie selon le client. Classic Era n'a pas de
-- `notInterruptible` : le spellId y occupe la case où les autres clients mettent
-- le booléen. On lit donc par type.
--   cast    retail : name, text, texture, start, end, isTradeSkill, castID, notInterruptible, spellId
--   cast    era    : name, text, texture, start, end, isTradeSkill, castID, spellId
--   channel retail : name, text, texture, start, end, isTradeSkill, notInterruptible, spellId
--   channel era    : name, text, texture, start, end, isTradeSkill, spellId

local UnitCastingInfo = _G.UnitCastingInfo
local UnitChannelInfo = _G.UnitChannelInfo

-- Moteur 12.x (Midnight, WoW Forever 1.60) : sur une unité autre que le joueur, UnitCastingInfo
-- rend des valeurs secrètes (hors combat aussi : C_Secrets.ShouldUnitSpellCastingBeSecret("target")
-- est vrai sur Forever 1.60.1.70124). `notInterruptible` secret est remplacé par le seul repli
-- légitime : l'événement NOT_INTERRUPTIBLE / INTERRUPTIBLE reçu pour l'unité. Le bouclier de la
-- barre d'incantation Blizzard n'en est pas un : son état IsShown() hérite du secret.
-- Limite : un cast protégé dès son début n'émet pas NOT_INTERRUPTIBLE : faute d'indice, il passe
-- pour interruptible et l'alerte part. `/ka status` montre, cible en incantation, si ce client
-- rend la valeur secrète et sur quel repli on s'appuie.

-- [unit] = true après NOT_INTERRUPTIBLE, false après INTERRUPTIBLE, nil (aucune info) au cast suivant.
NS.castShield = {}
local shieldFrame = CreateFrame("Frame")
shieldFrame:SetScript("OnEvent", function(_, event, unit)
    -- Le token désigne une autre unité : l'état de l'ancienne ne doit pas masquer une alerte.
    if event == "PLAYER_TARGET_CHANGED" then NS.castShield.target = nil return end
    if event == "PLAYER_FOCUS_CHANGED" then NS.castShield.focus = nil return end
    if not unit then return end
    if event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        NS.castShield[unit] = true
    elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE" then
        NS.castShield[unit] = false
    else
        NS.castShield[unit] = nil
    end
end)
for _, event in ipairs({
    "UNIT_SPELLCAST_INTERRUPTIBLE", "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START",
    "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_CHANNEL_STOP",
    "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "NAME_PLATE_UNIT_REMOVED",
}) do
    pcall(shieldFrame.RegisterEvent, shieldFrame, event)
end

local function ReadCast(isChannel, unit, name, _, texture, startTime, endTime, _, a7, a8, a9)
    if not name then return nil end
    local notInterruptible, spellId
    if isChannel then
        if type(a7) == "number" then spellId = a7 else notInterruptible, spellId = a7, a8 end
    else
        if type(a8) == "number" then spellId = a8 else notInterruptible, spellId = a8, a9 end
    end
    -- shieldSource : "api" (valeur lue), "event" (secrète, repli NOT_INTERRUPTIBLE) ou
    -- "unknown" (secrète, aucun repli : interruptible par défaut). Diagnostic seulement.
    local shieldSource = "api"
    if isSecret(notInterruptible) then
        local fallback = NS.castShield[unit]
        shieldSource = fallback ~= nil and "event" or "unknown"
        notInterruptible = fallback or false
    else
        -- Classic Era ne rend pas ce booléen du tout : rien n'a été « lu ».
        if notInterruptible == nil then shieldSource = "unknown" end
        notInterruptible = notInterruptible == true
    end
    return name, texture, startTime, endTime, notInterruptible, spellId, isChannel, shieldSource
end

function NS.GetCastInfo(unit)
    if UnitCastingInfo then
        local name, texture, startTime, endTime, notInterruptible, spellId, _, shieldSource =
            ReadCast(false, unit, UnitCastingInfo(unit))
        if name then
            return name, texture, startTime, endTime, notInterruptible, spellId, false, shieldSource
        end
    end
    if UnitChannelInfo then
        local name, texture, startTime, endTime, notInterruptible, spellId, _, shieldSource =
            ReadCast(true, unit, UnitChannelInfo(unit))
        if name then
            return name, texture, startTime, endTime, notInterruptible, spellId, true, shieldSource
        end
    end
    return nil
end

--- Portée d'un sort sur une unité : 1 à portée, 0 hors de portée, nil quand le
-- client ne sait pas répondre. C_Spell.IsSpellInRange (11.x) rend un booléen,
-- l'ancienne API un entier : on garde la forme entière partout.
NS.IsSpellInRange = (C_Spell and C_Spell.IsSpellInRange)
    and function(spell, unit)
        local inRange = C_Spell.IsSpellInRange(spell, unit)
        -- Résultat secret (moteur 12.x, unité hostile) : le client ne nous laisse pas trancher.
        if isSecret(inRange) or inRange == nil then return nil end
        return inRange and 1 or 0
    end
    or (_G.IsSpellInRange and function(spell, unit)
        local inRange = _G.IsSpellInRange(spell, unit)
        if isSecret(inRange) then return nil end
        return inRange
    end)

--------------------------------------------------------------------------------
-- Sons
--------------------------------------------------------------------------------
-- Un id de SOUNDKIT (son du client) ou un chemin de fichier (son de l'utilisateur).
-- Les deux passent par pcall : un id absent d'un vieux client ou un fichier
-- manquant ne doit jamais casser l'alerte visuelle qui l'accompagne.

local PlaySound     = _G.PlaySound
local PlaySoundFile = _G.PlaySoundFile

-- Chaîne de repli : le premier nom de SOUNDKIT qui existe sur ce client gagne.
-- Un preset ne liste que des variantes du MÊME son : les noms de constantes
-- changent d'un flavor à l'autre, pas le son attendu. Surtout pas de repli vers
-- une autre famille — « murloc » se rabattait sur RAID_WARNING et trois entrées
-- de la liste jouaient le même son sans que rien ne le dise.
-- Un preset qu'aucun candidat ne résout est retiré de la liste par
-- NS.AvailableSoundPresets() plutôt que joué de travers.
NS.SOUND_PRESETS = {
    raidwarning = { "RAID_WARNING" },
    readycheck  = { "READY_CHECK", "READY_CHECK_WARNING" },
    alarm       = { "UI_RAID_BOSS_WHISPER_WARNING" },
    bossemote   = { "RAID_BOSS_EMOTE_WARNING" },
    alarmclock  = { "ALARM_CLOCK_WARNING_1", "ALARM_CLOCK_WARNING_2", "ALARM_CLOCK_WARNING_3" },
    invasion    = { "UI_GARRISON_TOAST_INVASION_ALERT" },
    gmchat      = { "GM_CHAT_WARNING" },
    ping        = { "IG_MAINMENU_OPTION_CHECKBOX_ON", "IG_MAINMENU_OPEN" },
    murloc      = { "MURLOC_AGGRO", "MURLOC_AGGRO_OLD" },
}
NS.SOUND_PRESET_ORDER = {
    "alarm", "raidwarning", "readycheck", "bossemote",
    "alarmclock", "invasion", "gmchat", "ping", "murloc",
}

function NS.ResolveSoundKit(name)
    local kit = _G.SOUNDKIT
    if not kit then return nil end
    local candidates = NS.SOUND_PRESETS[name]
    if candidates then
        for i = 1, #candidates do
            local id = kit[candidates[i]]
            if id then return id end
        end
        return nil
    end
    return kit[name]
end

--- Joue un son décrit par une valeur de configuration :
--   nombre        -> id de SOUNDKIT brut
--   chemin        -> fichier (contient \ ou / ou finit par .ogg/.mp3/.wav)
--   nom de preset -> NS.SOUND_PRESETS
--   nom de kit    -> SOUNDKIT[nom]
-- Retourne false si rien n'a pu être joué.
--- pcall ne dit que « pas d'erreur » : PlaySound renvoie en plus willPlay, faux
-- quand l'id n'existe pas sur ce client. Sans le lire, un son muet passait pour
-- un succès et aucun repli n'était tenté.
local function Emit(fn, value, channel)
    if not fn then return false end
    local ok, willPlay = pcall(fn, value, channel)
    if not ok then return false end
    -- Les clients les plus anciens ne renvoient rien : on ne peut pas conclure à un échec.
    return willPlay ~= false
end

function NS.PlayAlertSound(sound, channel)
    if not sound then return false end
    channel = channel or "Master"

    if type(sound) == "number" then
        return Emit(PlaySound, sound, channel)
    end
    if type(sound) ~= "string" or sound == "" then return false end

    if sound:find("[\\/]") or sound:lower():find("%.%a%a%a?$") then
        return Emit(PlaySoundFile, sound, channel)
    end

    -- Preset : on essaie chaque candidat jusqu'à ce que l'un se joue réellement.
    -- Les constantes SOUNDKIT ne sont pas les mêmes d'un flavor à l'autre.
    local candidates = NS.SOUND_PRESETS[sound]
    if candidates then
        local kits = _G.SOUNDKIT
        if kits then
            for i = 1, #candidates do
                local id = kits[candidates[i]]
                if id and Emit(PlaySound, id, channel) then return true end
            end
        end
    else
        local kit = NS.ResolveSoundKit(sound)
        if kit and Emit(PlaySound, kit, channel) then return true end
    end

    -- Tout premiers clients : PlaySound prenait un nom de son, pas un id.
    return Emit(PlaySound, sound, channel)
end

--- Diagnostic des sons. Sans argument : état de chaque preset. Avec un motif :
-- les constantes SOUNDKIT dont le nom le contient. Sert à savoir ce qu'un client
-- expose vraiment, les noms n'étant pas les mêmes d'un flavor à l'autre.
function NS.SoundDiagnostic(pattern)
    local kits = _G.SOUNDKIT
    local lines = {}
    if not kits then
        lines[1] = "SOUNDKIT absent sur ce client : seuls les ids numériques et les fichiers marchent."
        return lines
    end

    if pattern and pattern ~= "" then
        local found = {}
        for name, id in pairs(kits) do
            if type(name) == "string" and name:lower():find(pattern:lower(), 1, true) then
                found[#found + 1] = name .. " = " .. tostring(id)
            end
        end
        table.sort(found)
        if #found == 0 then
            lines[1] = "aucune constante SOUNDKIT ne contient : " .. pattern
        else
            lines[1] = #found .. " constante(s) pour : " .. pattern
            for i = 1, #found do lines[#lines + 1] = "  " .. found[i] end
        end
        return lines
    end

    local total = 0
    for _ in pairs(kits) do total = total + 1 end
    lines[1] = "SOUNDKIT : " .. total .. " constantes"
    for _, name in ipairs(NS.SOUND_PRESET_ORDER) do
        local id = NS.ResolveSoundKit(name)
        lines[#lines + 1] = string.format("  %-12s %s", name, id and ("ok (id " .. id .. ")") or "indisponible")
    end
    return lines
end

--- Presets réellement jouables sur ce client, dans l'ordre d'affichage.
-- Sans SOUNDKIT (clients les plus anciens) rien n'est résolvable : on renvoie
-- la liste entière plutôt que de n'offrir aucun choix.
function NS.AvailableSoundPresets()
    local available = {}
    if not _G.SOUNDKIT then
        for i = 1, #NS.SOUND_PRESET_ORDER do available[i] = NS.SOUND_PRESET_ORDER[i] end
        return available
    end
    for _, name in ipairs(NS.SOUND_PRESET_ORDER) do
        if NS.ResolveSoundKit(name) then available[#available + 1] = name end
    end
    if #available == 0 then
        for i = 1, #NS.SOUND_PRESET_ORDER do available[i] = NS.SOUND_PRESET_ORDER[i] end
    end
    return available
end

--------------------------------------------------------------------------------
-- Timers
--------------------------------------------------------------------------------
-- C_Timer.NewTimer n'existe pas sur les tout premiers builds Classic Era.
-- Implémentation maison sur OnUpdate en secours : même interface (:Cancel()).

local Timer = {}
NS.Timer = Timer

local hasNativeTimer = (C_Timer and C_Timer.NewTimer and C_Timer.NewTicker) and true or false
Timer.native = hasNativeTimer

if hasNativeTimer then
    function Timer.NewTimer(delay, callback) return C_Timer.NewTimer(delay, callback) end
    function Timer.NewTicker(interval, callback) return C_Timer.NewTicker(interval, callback) end
else
    local driver = CreateFrame("Frame")
    local tasks = {}
    local TaskMeta = {}
    TaskMeta.__index = TaskMeta
    function TaskMeta:Cancel() self._cancelled = true end
    function TaskMeta:IsCancelled() return self._cancelled == true end

    driver:SetScript("OnUpdate", function(_, elapsed)
        local n = #tasks
        if n == 0 then return end
        for i = n, 1, -1 do
            local task = tasks[i]
            if task._cancelled then
                tremove(tasks, i)
            else
                task._remaining = task._remaining - elapsed
                if task._remaining <= 0 then
                    if task._interval then
                        task._remaining = task._remaining + task._interval
                        if task._remaining <= 0 then task._remaining = task._interval end
                    else
                        task._cancelled = true
                        tremove(tasks, i)
                    end
                    task._callback()
                end
            end
        end
    end)

    local function NewTask(delay, callback, interval)
        local task = setmetatable({
            _remaining = delay, _callback = callback, _interval = interval, _cancelled = false,
        }, TaskMeta)
        tasks[#tasks + 1] = task
        return task
    end
    function Timer.NewTimer(delay, callback) return NewTask(delay, callback, nil) end
    function Timer.NewTicker(interval, callback) return NewTask(interval, callback, interval) end
end

function Timer.After(delay, callback)
    return Timer.NewTimer(delay, callback)
end

--------------------------------------------------------------------------------
-- Rendu
--------------------------------------------------------------------------------

-- SetColorTexture (retail / classic récent) vs SetTexture(r,g,b,a) (vieux clients).
function NS.SetSolidColor(texture, r, g, b, a)
    if texture.SetColorTexture then
        texture:SetColorTexture(r, g, b, a or 1)
    else
        texture:SetTexture(r, g, b, a or 1)
    end
end

-- Dégradé : SetGradientAlpha retiré en 10.0, remplacé par SetGradient(orientation, ColorMixin, ColorMixin).
-- "VERTICAL" : couleur 1 = bas, couleur 2 = haut. "HORIZONTAL" : 1 = gauche, 2 = droite.
function NS.SetGradient(texture, orientation, r, g, b, alphaFrom, alphaTo)
    if texture.SetGradientAlpha then
        texture:SetGradientAlpha(orientation, r, g, b, alphaFrom, r, g, b, alphaTo)
    elseif texture.SetGradient and _G.CreateColor then
        texture:SetGradient(orientation, CreateColor(r, g, b, alphaFrom), CreateColor(r, g, b, alphaTo))
    else
        -- Client sans dégradé : bord plein à l'alpha maximal.
        NS.SetSolidColor(texture, r, g, b, math.max(alphaFrom, alphaTo))
    end
end

--- Mixin : présent sur tous les clients ciblés, copie à plat en secours.
NS.Mixin = _G.Mixin or function(object, ...)
    for i = 1, select("#", ...) do
        for k, v in pairs((select(i, ...))) do object[k] = v end
    end
    return object
end

--------------------------------------------------------------------------------
-- Color picker
--------------------------------------------------------------------------------
-- API SetupColorPickerAndShow depuis 10.2.5, champs directs avant.
-- Ancienne API : le slider d'opacité est inversé (0 = opaque, 1 = transparent).

function NS.OpenColorPicker(color, onChange)
    local picker = _G.ColorPickerFrame
    if not picker then return false end
    local function apply(r, g, b, a)
        color.r, color.g, color.b, color.a = r, g, b, a or 1
        onChange()
    end
    if picker.SetupColorPickerAndShow then
        local function onPick()
            local r, g, b = picker:GetColorRGB()
            apply(r, g, b, picker:GetColorAlpha())
        end
        picker:SetupColorPickerAndShow({
            r = color.r, g = color.g, b = color.b,
            hasOpacity = true, opacity = color.a,
            swatchFunc = onPick, opacityFunc = onPick,
            cancelFunc = function(prev) apply(prev.r, prev.g, prev.b, prev.a) end,
        })
        return true
    end
    local prev = { color.r, color.g, color.b, color.a }
    local function onPick()
        local r, g, b = picker:GetColorRGB()
        local slider = _G.OpacitySliderFrame
        apply(r, g, b, slider and (1 - slider:GetValue()) or color.a)
    end
    -- SetColorRGB déclenche OnColorSelect : à faire avant de brancher func,
    -- sinon apply() tourne avec l'alpha de l'appel précédent.
    picker.func = nil
    picker.opacityFunc = nil
    picker:SetColorRGB(color.r, color.g, color.b)
    picker.hasOpacity = true
    picker.opacity = 1 - color.a
    picker.previousValues = prev
    picker.func = onPick
    picker.opacityFunc = onPick
    picker.cancelFunc = function(p) apply(p[1], p[2], p[3], p[4]) end
    picker:Hide()
    picker:Show()
    return true
end

--------------------------------------------------------------------------------
-- Panneau d'options
--------------------------------------------------------------------------------
-- API Settings depuis 10.0, InterfaceOptions_AddCategory avant.

function NS.RegisterOptionsPanel(panel, name)
    panel.name = name
    NS.optionsPanel = panel
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, name)
        Settings.RegisterAddOnCategory(category)
        NS.optionsCategoryId = category:GetID()
    elseif _G.InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

function NS.OpenOptions()
    if Settings and Settings.OpenToCategory and NS.optionsCategoryId then
        Settings.OpenToCategory(NS.optionsCategoryId)
    elseif _G.InterfaceOptionsFrame_OpenToCategory then
        -- Appel doublé : bug connu de l'ancienne API qui n'ouvre pas la bonne catégorie au 1er appel.
        InterfaceOptionsFrame_OpenToCategory(NS.optionsPanel)
        InterfaceOptionsFrame_OpenToCategory(NS.optionsPanel)
    end
end

--- Polices : 4 polices Blizzard toujours présentes, plus celles de LibSharedMedia
-- si une autre addon l'embarque.
function NS.GetFontList()
    local fonts = {
        { name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
        { name = "Arial Narrow",  path = "Fonts\\ARIALN.TTF" },
        { name = "Morpheus",      path = "Fonts\\MORPHEUS.TTF" },
        { name = "Skurri",        path = "Fonts\\SKURRI.TTF" },
    }
    local LSM = _G.LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM then
        local known = {}
        for _, f in ipairs(fonts) do known[f.path] = true end
        for name, path in pairs(LSM:HashTable("font")) do
            if not known[path] then fonts[#fonts + 1] = { name = name, path = path } end
        end
        table.sort(fonts, function(a, b) return a.name < b.name end)
    end
    return fonts
end

--------------------------------------------------------------------------------
-- Table de capacités
--------------------------------------------------------------------------------

NS.has = {
    -- Sans UnitCastingInfo, l'incantation d'une cible ne se lit que dans le
    -- combat log : le détecteur bascule sur ce repli.
    unitCastInfo   = _G.UnitCastingInfo ~= nil,
    nativeTimers   = hasNativeTimer,
    focus          = NS.EventExists("PLAYER_FOCUS_CHANGED"),
    namePlates     = _G.C_NamePlate ~= nil
        and C_NamePlate.GetNamePlateForUnit ~= nil and C_NamePlate.GetNamePlates ~= nil,
    namePlateUnits = NS.EventExists("NAME_PLATE_UNIT_ADDED"),
}

--------------------------------------------------------------------------------
-- Nameplates
--------------------------------------------------------------------------------

function NS.GetNamePlateForUnit(unit)
    return C_NamePlate and C_NamePlate.GetNamePlateForUnit(unit)
end

function NS.GetNamePlates()
    return (C_NamePlate and C_NamePlate.GetNamePlates()) or {}
end

--- Une unité est-elle une cible de kick valable : hostile et vivante.
function NS.CanAttackUnit(unit)
    if _G.UnitCanAttack and not UnitCanAttack("player", unit) then return false end
    if _G.UnitIsDead and UnitIsDead(unit) then return false end
    return true
end

--------------------------------------------------------------------------------
-- Sortie console
--------------------------------------------------------------------------------

function NS.Print(...)
    print("|cffff5555KickAlert|r: " .. strjoin(" ", tostringall(...)))
end
