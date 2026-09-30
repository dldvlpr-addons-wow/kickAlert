-- tests/run_tests.lua
-- Tests headless : lua5.1 tests/run_tests.lua [--no-c-timer] [--retail]
--
-- Les fichiers se chargent dans l'ordre du .toc, avec le même vararg
-- (addonName, ns) que le client, puis on pilote le temps et les events à la
-- main. Le mock est celui de MyBossSuite (tests/wow_mock.lua), complété ici des
-- méthodes que KickAlert utilise en plus.

-- Le client WoW tourne en Lua 5.1, où `unpack` est un global. Sur un interpréteur
-- 5.2+ il a migré dans table : on le réexpose pour que le mock s'exécute pareil.
unpack = unpack or table.unpack

package.path = "tests/?.lua;" .. package.path
require("wow_mock")

--------------------------------------------------------------------------------
-- Compléments du mock
--------------------------------------------------------------------------------

local useNativeTimers, retail = true, false
for _, argument in ipairs({ ... }) do
    if argument == "--no-c-timer" then useNativeTimers = false end
    if argument == "--retail" then retail = true end
end

-- Locale/Locale.lua lit GetLocale() pour choisir la langue du client. Le mock ne
-- l'expose pas : on force enUS, la base de repli, comme sur un client anglais.
GetLocale = GetLocale or function() return "enUS" end

-- Compat.lua capture _G.PlaySound dans un local au chargement : pour simuler un
-- son injouable il faut remplacer le global ici, pas après coup. Mock.soundWillPlay
-- reproduit le contrat du client (PlaySound renvoie willPlay).
-- Constantes SOUNDKIT relevées sur un vrai client (/ka sounds) : sans elles, les
-- presets ne résolvent pas et le test d'unicité des sons ne vérifie plus rien.
for name, id in pairs({
    RAID_WARNING = 8959, READY_CHECK = 8960, RAID_BOSS_EMOTE_WARNING = 12197,
    ALARM_CLOCK_WARNING_1 = 18871, ALARM_CLOCK_WARNING_2 = 12867,
    UI_GARRISON_TOAST_INVASION_ALERT = 44292, GM_CHAT_WARNING = 15273,
    IG_MAINMENU_OPTION_CHECKBOX_ON = 856,
}) do
    _G.SOUNDKIT[name] = _G.SOUNDKIT[name] or id
end

-- Valeurs secrètes (moteur 12.x) : une table à métatable qui lève sur l'arithmétique, la
-- comparaison ordonnée et l'indexation, comme le client. `==` entre une table et un nombre
-- rend false sans lever en Lua : ce cas-là n'est pas reproductible ici. issecretvalue n'est
-- posée que par la suite « Valeurs secrètes » : au chargement, sa présence signifierait
-- « combat log interdit » et le repli combat log ne serait plus testé.
local SecretMeta = {}
for _, op in ipairs({ "__add", "__sub", "__mul", "__div", "__unm", "__lt", "__le", "__len", "__call", "__index" }) do
    SecretMeta[op] = function() error("attempt to use a secret value") end
end
function Mock.Secret(value) return setmetatable({ value = value }, SecretMeta) end
function Mock.IsSecret(v) return getmetatable(v) == SecretMeta end

local realPlaySound = _G.PlaySound
Mock.soundWillPlay = true
_G.PlaySound = function(id, channel)
    realPlaySound(id, channel)
    return Mock.soundWillPlay
end

local FrameMeta = getmetatable(CreateFrame("Frame"))
local function NoOp() end
-- Le panneau d'options vit dans un ScrollFrame : le mock ignore ces méthodes,
-- seul compte le fait que Config.lua les appelle sans erreur.
-- IsVisible() du mock ignorait les parents et se comportait comme IsShown() :
-- c'est précisément ce qui avait laissé passer l'aperçu resté à l'écran après
-- fermeture de la fenêtre Options. Ici il remonte la chaîne, comme le client.
function FrameMeta:IsVisible()
    if self.shown ~= true then return false end
    local parent = self.parent
    while parent do
        if parent.shown == false then return false end
        parent = parent.parent
    end
    return true
end

FrameMeta.SetScrollChild = FrameMeta.SetScrollChild or NoOp
FrameMeta.SetVerticalScroll = FrameMeta.SetVerticalScroll or NoOp
FrameMeta.GetVerticalScroll = FrameMeta.GetVerticalScroll or function() return 0 end
FrameMeta.GetVerticalScrollRange = FrameMeta.GetVerticalScrollRange or function() return 0 end
for _, name in ipairs({ "SetAutoFocus", "ClearFocus", "SetValueStep", "SetObeyStepOnDrag" }) do
    FrameMeta[name] = FrameMeta[name] or NoOp
end
-- Dégradés : ancienne API (SetGradientAlpha) en classic, SetGradient + CreateColor en retail.
Mock.gradients = 0
if retail then
    FrameMeta.SetGradient = function() Mock.gradients = Mock.gradients + 1 end
    _G.CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
else
    FrameMeta.SetGradientAlpha = function() Mock.gradients = Mock.gradients + 1 end
end
FrameMeta.GetStringWidth  = FrameMeta.GetStringWidth  or function(self) return (self.fontSize or 12) * 3 end
FrameMeta.GetStringHeight = FrameMeta.GetStringHeight or function(self) return self.fontSize or 12 end

--------------------------------------------------------------------------------
-- Framework minimal
--------------------------------------------------------------------------------

local passed, failed = 0, 0
local function say(line) io.write(line, "\n") end
local function suite(name) say("\n== " .. name) end

local function ok(condition, label)
    if condition then
        passed = passed + 1
        say("  ok   " .. label)
    else
        failed = failed + 1
        say("  FAIL " .. label)
    end
end

local function equal(actual, expected, label)
    ok(actual == expected, ("%s (attendu %s, obtenu %s)"):format(label, tostring(expected), tostring(actual)))
end

--------------------------------------------------------------------------------
-- Chargement
--------------------------------------------------------------------------------

-- Même ordre que KickAlert.toc : les locales d'abord, enUS en premier (base des fallbacks).
local FILES = {
    "Locale/enUS.lua", "Locale/frFR.lua", "Locale/deDE.lua", "Locale/esES.lua",
    "Locale/esMX.lua", "Locale/itIT.lua", "Locale/ptBR.lua", "Locale/ruRU.lua",
    "Locale/koKR.lua", "Locale/zhCN.lua", "Locale/zhTW.lua",
    "Locale/Locale.lua",
    "Compat.lua", "Mirror.lua", "Core.lua", "Alerts.lua", "Detector.lua", "Nameplates.lua", "Config.lua",
}

-- CVars enregistrées par l'addon et table hôte Blizzard (Mirror.lua) : le mock n'en a pas.
Mock.cvars = {}
_G.g_addonCategoriesCollapsed = {}
_G.C_CVar = {
    RegisterCVar = function(name, default)
        if Mock.cvars[name] == nil then Mock.cvars[name] = tostring(default) end
    end,
    GetCVar = function(name) return Mock.cvars[name] end,
    SetCVar = function(name, value)
        if Mock.cvars[name] == nil then return false end
        Mock.cvars[name] = tostring(value)
        return true
    end,
}

Mock.InstallTimerAPI(useNativeTimers)
if retail then Mock.InstallRetail() end

local ns = {}
for _, file in ipairs(FILES) do
    local chunk = assert(loadfile(file))
    chunk("KickAlert", ns)
end
Mock.FireEvent("ADDON_LOADED", "KickAlert")

local BOSS_GUID   = "Creature-0-1-2-3-10184-000001"
local PLAYER_GUID = "Player-0-0001"
local Text, Aura, Detector = ns.Text, ns.Aura, ns.Detector

local function StartCast(spellId, notInterruptible)
    Mock.SetCast("target", spellId, notInterruptible)
    Mock.FireEvent("UNIT_SPELLCAST_START", "target")
end

local function StopCast()
    Mock.SetCast("target", nil)
    Mock.FireEvent("UNIT_SPELLCAST_STOP", "target")
end

--------------------------------------------------------------------------------

suite("Compat")
equal(ns.has.nativeTimers, useNativeTimers, "détection de C_Timer")
equal(ns.flavor, retail and "retail" or "vanilla", "flavor détecté")
ok(ns.db ~= nil and ns.db.text.label == "KICK", "SavedVariables initialisées avec les défauts")
ok(ns.KnowsSpell(1766), "KnowsSpell : sort du grimoire")
equal(ns.KnowsSpell(2139), false, "KnowsSpell : sort inconnu")
equal(ns.GetSpellRemaining(1766), 0, "kick prêt = 0")

Mock.SetCast("target", 17086, true)
local castName, _, _, _, castProtected, castSpell = ns.GetCastInfo("target")
equal(castName, "Flame Breath", "GetCastInfo : nom")
equal(castProtected, true, "GetCastInfo : cast protégé")
equal(castSpell, 17086, "GetCastInfo : spellId")
Mock.legacyCastInfo = true
castName, _, _, _, castProtected, castSpell = ns.GetCastInfo("target")
equal(castProtected, false, "GetCastInfo (Classic Era) : pas de notInterruptible = interruptible")
equal(castSpell, 17086, "GetCastInfo (Classic Era) : spellId lu malgré le décalage")
Mock.legacyCastInfo = false
Mock.SetCast("target", nil)

suite("Détection")
equal(Detector.interruptSpell, 1766, "interrupt de la classe détecté dans le grimoire")

Mock.units.target = { guid = BOSS_GUID, name = "Onyxia", health = 100, healthMax = 100 }
Mock.FireEvent("PLAYER_TARGET_CHANGED")

local soundsBefore = #Mock.sounds
StartCast(17086, false)
ok(Text:IsShown(), "cast interruptible : texte affiché")
equal(Text.label:GetText(), "KICK", "texte KICK")
ok(Aura:IsShown(), "cast interruptible : halo affiché")
ok(Mock.gradients > 0, "halo : dégradé appliqué via l'API du client")
equal(#Mock.sounds, soundsBefore + 1, "cast interruptible : son joué une fois")

StartCast(17086, true)
equal(Text:IsShown(), false, "cast devenu protégé : alerte retirée")
StopCast()
StartCast(17086, false)
ok(Text:IsShown(), "cast interruptible : alerte de nouveau")

soundsBefore = #Mock.sounds
Mock.Advance(3)
ok(Text:IsShown(), "l'alerte reste tant que l'incantation dure")
equal(#Mock.sounds, soundsBefore, "le ticker ne rejoue pas le son")

StopCast()
equal(Text:IsShown(), false, "alerte retirée à la fin de l'incantation")
equal(Aura:IsShown(), false, "halo retiré à la fin de l'incantation")

Mock.cooldowns[1766] = { start = Mock.now, duration = 15 }
StartCast(17086, false)
equal(Text:IsShown(), false, "kick en cooldown : aucune alerte")
Mock.cooldowns[1766] = nil
Mock.Advance(0.4)
ok(Text:IsShown(), "alerte dès que le kick revient, sans nouvel event (ticker)")

Mock.outOfRange = true
Mock.Advance(0.4)
equal(Text:IsShown(), false, "hors de portée : alerte retirée")
Mock.outOfRange = false
Mock.Advance(0.4)
ok(Text:IsShown(), "de retour à portée : alerte de nouveau")

ns.db.onlyWhenReady = false
Mock.cooldowns[1766] = { start = Mock.now, duration = 15 }
Detector:ClearAlert()
equal(Text:IsShown(), false, "alerte effacée manuellement")
Mock.Advance(0.4)
ok(Text:IsShown(), "option 'kick dispo requis' désactivée : alerte neuve malgré le cooldown")
Mock.cooldowns[1766] = nil
ns.db.onlyWhenReady = true
StopCast()

-- Repli combat log, pour les clients où UnitCastingInfo ne répond rien.
Mock.FireCombatLog("SPELL_CAST_START", BOSS_GUID, PLAYER_GUID, 18435, "Fireball Volley")
ok(Text:IsShown(), "repli combat log : alerte sur SPELL_CAST_START")
Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 18435, "Fireball Volley")
equal(Text:IsShown(), false, "repli combat log : alerte retirée au SUCCESS")

-- Cast raté (SPELL_CAST_FAILED jamais loggé pour un PNJ) puis nouveau cast : deux incantations, deux sons.
Mock.Advance(0.5)
soundsBefore = #Mock.sounds
Mock.FireCombatLog("SPELL_CAST_START", BOSS_GUID, PLAYER_GUID, 18435, "Fireball Volley")
Mock.Advance(0.5)
Mock.FireCombatLog("SPELL_CAST_START", BOSS_GUID, PLAYER_GUID, 18435, "Fireball Volley")
equal(#Mock.sounds, soundsBefore + 2, "repli combat log : cast raté puis nouveau cast = nouveau son")
Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 18435, "Fireball Volley")
equal(Text:IsShown(), false, "repli combat log : alerte retirée après le second cast")

Mock.Advance(0.5)
ns.db.sound.throttle = 0
soundsBefore = #Mock.sounds
Mock.SetCast("target", 18435, false)
Mock.FireCombatLog("SPELL_CAST_START", BOSS_GUID, PLAYER_GUID, 18435, "Fireball Volley")
Mock.FireEvent("UNIT_SPELLCAST_START", "target")
ok(Text:IsShown(), "cast vu par l'API et par le combat log : alerte")
equal(#Mock.sounds, soundsBefore + 1, "cast vu par l'API et par le combat log : un seul son, même sans throttle")
ns.db.sound.throttle = 0.4
Mock.SetCast("target", nil)
Mock.FireEvent("UNIT_SPELLCAST_INTERRUPTED", "target")
equal(Text:IsShown(), false, "cast annulé côté client : pas d'incantation fantôme via le repli")
Mock.Advance(0.5)
equal(Text:IsShown(), false, "... et le ticker ne la ressort pas")

Mock.FireCombatLog("SPELL_CAST_START", "Creature-0-1-2-3-99999-000009", PLAYER_GUID, 18435, "Autre")
equal(Text:IsShown(), false, "incantation d'une autre unité : ignorée")

-- Sans cible ni focus, un SPELL_CAST_START sans source (nil == nil) ne doit pas écrire casts[nil].
local savedTarget = Mock.units.target
Mock.units.target = nil
Mock.FireEvent("PLAYER_TARGET_CHANGED")
local noSourceOk = pcall(Mock.FireCombatLog, "SPELL_CAST_START", nil, PLAYER_GUID, 18435, "Sans source")
ok(noSourceOk and not Text:IsShown(), "combat log sans source ni cible : ignoré sans erreur")
Mock.units.target = savedTarget
Mock.FireEvent("PLAYER_TARGET_CHANGED")

Mock.legacyCastInfo = true
StartCast(17086, false)
ok(Text:IsShown(), "Classic Era (sans notInterruptible) : alerte")
Mock.legacyCastInfo = false
StopCast()

Mock.FireEvent("PLAYER_REGEN_ENABLED")
equal(Detector.poll, nil, "fin de combat : ticker arrêté")

suite("Alertes indépendantes")
ns.db.text.enabled = false
ns.db.sound.enabled = false
soundsBefore = #Mock.sounds
StartCast(17086, false)
equal(Text:IsShown(), false, "texte désactivé : pas de texte")
ok(Aura:IsShown(), "texte désactivé : le halo s'affiche quand même")
equal(#Mock.sounds, soundsBefore, "son désactivé : silence")
StopCast()
ns.db.text.enabled = true
ns.db.sound.enabled = true
ns.db.aura.enabled = false
StartCast(17086, false)
ok(Text:IsShown(), "halo désactivé : le texte s'affiche quand même")
equal(Aura:IsShown(), false, "halo désactivé : pas de halo")
StopCast()
ns.db.aura.enabled = true

ns.db.text.label = "STOP ÇA"
ns.db.text.size = 64
StartCast(17086, false)
equal(Text.label:GetText(), "STOP ÇA", "mot affiché configurable")
equal(select(2, Text.label:GetFont()), 64, "taille de police configurable")
StopCast()
ns.db.text.label = "KICK"
-- Contour « Aucun » : SetFont exige une chaîne pour les flags depuis 10.0, jamais nil.
ns.db.text.outline = "NONE"
StartCast(17086, false)
equal(select(3, Text.label:GetFont()), "", "contour Aucun : flags vide, pas nil")
StopCast()
ns.db.text.outline = "OUTLINE"

suite("Commandes")
SlashCmdList.KICKALERT("spell 2139")
equal(Detector.interruptSpell, 2139, "/ka spell <id>")
SlashCmdList.KICKALERT("spell auto")
equal(Detector.interruptSpell, 1766, "/ka spell auto")

-- /ka status : une ligne sur l'incantation de la cible quand elle lance quelque chose.
equal(#Detector:StatusLines(), 4, "/ka status : 4 lignes sans incantation")
StartCast(17086, true)
local statusLines = Detector:StatusLines()
equal(#statusLines, 5, "/ka status : ligne d'incantation quand la cible lance un sort")
ok(statusLines[5]:find("Flame Breath", 1, true) ~= nil, "/ka status : nom du sort")
ok(statusLines[5]:find(ns.L.SHIELD_API, 1, true) ~= nil, "/ka status : source de l'état protégé")
StopCast()
Mock.FireCombatLog("SPELL_CAST_START", BOSS_GUID, PLAYER_GUID, 18435, "Fireball Volley")
statusLines = Detector:StatusLines()
ok(#statusLines == 5 and statusLines[5]:find("Fireball Volley", 1, true) ~= nil,
    "/ka status : incantation vue seulement par le combat log")
ok(statusLines[5]:find(ns.L.SHIELD_UNKNOWN, 1, true) ~= nil, "/ka status : état protégé inconnu via le combat log")
Mock.FireCombatLog("SPELL_CAST_SUCCESS", BOSS_GUID, PLAYER_GUID, 18435, "Fireball Volley")

-- Bouclier mémorisé pour « target » : oublié quand le token désigne une autre unité.
Mock.FireEvent("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "target")
equal(ns.castShield.target, true, "NOT_INTERRUPTIBLE mémorisé pour la cible")
Mock.FireEvent("PLAYER_TARGET_CHANGED")
equal(ns.castShield.target, nil, "changement de cible : bouclier de l'ancienne cible oublié")

SlashCmdList.KICKALERT("unlock")
ok(Text:IsShown(), "/ka unlock : texte visible pour le déplacement")
SlashCmdList.KICKALERT("lock")
equal(Text:IsShown(), false, "/ka lock : texte masqué")

SlashCmdList.KICKALERT("test")
ok(Text:IsShown() and Aura:IsShown(), "/ka test : les alertes s'affichent")
Mock.Advance(3.2)
equal(Text:IsShown(), false, "/ka test : fin après 3 secondes")

Text:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100, -200)
Text:SaveAnchor()
equal(ns.db.anchors.Text.x, 100, "position du texte sauvée")
SlashCmdList.KICKALERT("reset")
equal(ns.db.anchors.Text, nil, "/ka reset : position oubliée")

suite("Nameplates")
local Nameplate = ns.Nameplate

Mock.AddNamePlate("nameplate3", "Creature-0-1-2-3-40000-000001")
Mock.SetCast("nameplate3", 17086, false)
Mock.FireEvent("UNIT_SPELLCAST_START", "nameplate3")
ok(Nameplate:GetFrame("nameplate3"):IsShown(), "cast interruptible sur nameplate : indicateur affiché")
equal(Nameplate:GetFrame("nameplate3").label:GetText(), "KICK", "texte KICK sur la nameplate")

Mock.SetCast("nameplate3", 17086, true)
Mock.FireEvent("UNIT_SPELLCAST_START", "nameplate3")
equal(Nameplate:GetFrame("nameplate3"):IsShown(), false, "cast protégé sur nameplate : rien affiché")

Mock.SetCast("nameplate3", 17086, false)
Mock.FireEvent("UNIT_SPELLCAST_START", "nameplate3")
ok(Nameplate:GetFrame("nameplate3"):IsShown(), "de nouveau interruptible : réaffiché")
Mock.SetCast("nameplate3", nil)
Mock.FireEvent("UNIT_SPELLCAST_STOP", "nameplate3")
equal(Nameplate:GetFrame("nameplate3"):IsShown(), false, "fin de l'incantation : masqué")

Mock.SetCast("nameplate3", 17086, false)
Mock.FireEvent("UNIT_SPELLCAST_START", "nameplate3")
Mock.SetCast("nameplate3", nil)
Mock.FireEvent("UNIT_SPELLCAST_INTERRUPTED", "nameplate3")
equal(Nameplate:GetFrame("nameplate3"):IsShown(), false, "incantation interrompue : masqué")

Mock.AddNamePlate("nameplate4", "Player-0-0099", { friendly = true })
Mock.SetCast("nameplate4", 17086, false)
Mock.FireEvent("UNIT_SPELLCAST_START", "nameplate4")
equal(Nameplate:GetFrame("nameplate4"):IsShown(), false, "unité amicale : jamais affiché")

Mock.SetCast("nameplate3", 17086, false)
Mock.FireEvent("UNIT_SPELLCAST_START", "nameplate3")
Mock.RemoveNamePlate("nameplate3")
equal(Nameplate:GetFrame("nameplate3"):IsShown(), false, "nameplate retirée : masqué")

local framesBefore = #Mock.frames
Mock.AddNamePlate("nameplate3", "Creature-0-1-2-3-40001-000002")
Mock.SetCast("nameplate3", 17086, false)
Mock.FireEvent("UNIT_SPELLCAST_START", "nameplate3")
ok(Nameplate:GetFrame("nameplate3"):IsShown(), "nameplate réapparue (autre GUID) : réaffiché")
-- +1 seul : le nouveau frame nameplate mocké, l'indicateur est réutilisé depuis le pool.
equal(#Mock.frames, framesBefore + 1, "l'indicateur est réutilisé, pas recréé")
equal(Nameplate:GetFrame("nameplate3").parent, Mock.namePlates.nameplate3,
    "indicateur ré-ancré sur la nouvelle nameplate")
Mock.SetCast("nameplate3", nil)
Mock.FireEvent("UNIT_SPELLCAST_STOP", "nameplate3")

ns.db.nameplate.enabled = false
Mock.SetCast("nameplate3", 17086, false)
Mock.FireEvent("UNIT_SPELLCAST_START", "nameplate3")
equal(Nameplate:GetFrame("nameplate3"):IsShown(), false, "module désactivé : jamais affiché")
ns.db.nameplate.enabled = true
Nameplate:RefreshAll()
ok(Nameplate:GetFrame("nameplate3"):IsShown(), "module réactivé : réapparaît sans attendre le prochain event de cast")
Mock.SetCast("nameplate3", nil)
Mock.FireEvent("UNIT_SPELLCAST_STOP", "nameplate3")

ns.db.nameplate.text.label = "GO"
ns.db.nameplate.text.size = 20
Mock.SetCast("nameplate3", 17086, false)
Mock.FireEvent("UNIT_SPELLCAST_START", "nameplate3")
equal(Nameplate:GetFrame("nameplate3").label:GetText(), "GO", "mot affiché configurable")
equal(select(2, Nameplate:GetFrame("nameplate3").label:GetFont()), 20, "taille configurable")
ns.db.nameplate.text.outline = "NONE"
Mock.FireEvent("UNIT_SPELLCAST_DELAYED", "nameplate3")
equal(select(3, Nameplate:GetFrame("nameplate3").label:GetFont()), "", "contour Aucun : flags vide, pas nil")
ns.db.nameplate.text.outline = "OUTLINE"
Mock.SetCast("nameplate3", nil)
Mock.FireEvent("UNIT_SPELLCAST_STOP", "nameplate3")
ns.db.nameplate.text.label = "KICK"
ns.db.nameplate.text.size = 14

--------------------------------------------------------------------------------

suite("Aperçu du panneau d'options")
-- Reproduit la fermeture de la fenêtre Options : le client masque la fenêtre
-- parente, jamais notre panneau. L'aperçu doit malgré tout s'éteindre.
local optionsWindow = CreateFrame("Frame")
local panel = ns.optionsPanel
ok(panel ~= nil, "panneau d'options enregistré")
panel:SetParent(optionsWindow)
optionsWindow:Show()
panel:Show()
Text:Refresh()
Aura:Refresh()
ok(Text:IsShown(), "panneau ouvert : aperçu du texte")
ok(Aura:IsShown(), "panneau ouvert : aperçu du halo")

optionsWindow:Hide()   -- notre panneau reste « shown », comme dans le jeu
ok(panel.shown == true, "le panneau lui-même n'a pas reçu Hide()")
Text:Refresh()
Aura:Refresh()
equal(Text:IsShown(), false, "fenêtre Options fermée : texte retiré")
equal(Aura:IsShown(), false, "fenêtre Options fermée : halo retiré")

-- Cas réel : /ka test pendant que le panneau est ouvert, puis fermeture APRÈS la
-- fin des 3 s. WoW ne propage pas OnHide aux enfants, donc rien ne réévalue
-- l'aperçu — seul le veilleur peut éteindre le texte resté à l'écran.
optionsWindow:Show()
panel:Show()
ns:Fire("CAST_START", "test", "Preview", 0)
ok(Text:IsShown(), "aperçu + test : texte affiché")
ns:Fire("CAST_STOP")
ok(Text:IsShown(), "test fini, panneau encore ouvert : l'aperçu prend le relais")

optionsWindow:Hide()   -- aucun OnHide, aucun event : le veilleur est seul juge
ok(Text:IsShown(), "juste après fermeture, avant le tick du veilleur")
Mock.Advance(0.25)
equal(Text:IsShown(), false, "le veilleur retire le texte après fermeture")
equal(Aura:IsShown(), false, "le veilleur retire le halo après fermeture")
panel:Hide()

--------------------------------------------------------------------------------

suite("Son")
equal(ns.PlayAlertSound("raidwarning"), true, "preset résolu et joué")
equal(Mock.sounds[#Mock.sounds].kit, 1, "id SOUNDKIT correct")
equal(ns.PlayAlertSound(nil), false, "son absent")
equal(ns.PlayAlertSound(""), false, "son vide")

-- PlaySound ne lève pas d'erreur sur un id inconnu : il renvoie false. C'est cette
-- valeur, et non l'absence d'erreur, qui dit si quelque chose a été joué.
Mock.soundWillPlay = false
equal(ns.PlayAlertSound(123456), false, "id injouable : échec signalé, pas masqué")
equal(ns.PlayAlertSound("raidwarning"), false, "preset muet : échec signalé après tous les candidats")
Mock.soundWillPlay = true

-- Le mock n'expose pas MURLOC_AGGRO, comme le client Forever : ce preset ne doit
-- pas être proposé, sinon l'utilisateur choisit un son muet.
local available = ns.AvailableSoundPresets()
local offered = {}
for _, name in ipairs(available) do offered[name] = true end
ok(offered.raidwarning, "preset disponible proposé")
equal(offered.murloc, nil, "preset non résolvable retiré de la liste")
for _, name in ipairs(available) do
    ok(ns.ResolveSoundKit(name) ~= nil, "preset proposé et résolvable : " .. name)
end

-- Le vrai symptôme n'était pas « muet » mais « joue le son d'un autre » : murloc
-- se rabattait sur RAID_WARNING. Deux presets proposés ne doivent jamais aboutir
-- au même son, sinon la liste ment sur ce qu'elle offre.
local seen = {}
for _, name in ipairs(available) do
    local id = ns.ResolveSoundKit(name)
    equal(seen[id], nil, "aucun autre preset ne joue déjà le son de " .. name)
    seen[id] = name
end
equal(ns.ResolveSoundKit("murloc"), nil, "murloc ne se rabat pas sur une autre famille")

local diagnostic = ns.SoundDiagnostic()
ok(#diagnostic > 1, "/ka sounds liste l'état des presets")
ok(diagnostic[1]:find("SOUNDKIT"), "/ka sounds annonce le nombre de constantes")
ok(#ns.SoundDiagnostic("raid") > 1, "/ka sounds <motif> trouve les constantes correspondantes")
equal(#ns.SoundDiagnostic("zzzz"), 1, "/ka sounds <motif> sans résultat le dit")

--------------------------------------------------------------------------------

suite("Langue")
-- Anglais par défaut, quelle que soit la langue du client : c'est un choix explicite,
-- pas le résultat du mock (qui renvoie justement enUS).
equal(ns.DEFAULTS.locale, "enUS", "défaut = anglais, pas auto")
equal(ns.db.locale, "enUS", "SavedVariables neuves : anglais")
-- Le mock renvoie enUS : c'est la langue « client » vue par NS.ClientLocale().
equal(ns.ClientLocale(), "enUS", "langue du client détectée")
equal(ns.SetLocale("auto"), "enUS", "auto suit le client")
equal(ns.L.CFG_LANGUAGE, ns.locales.enUS.CFG_LANGUAGE, "auto : libellés en anglais")

local L = ns.L  -- référence capturée comme le font Core.lua et Config.lua
equal(ns.SetLocale("frFR"), "frFR", "langue forcée appliquée")
equal(L.CFG_LANGUAGE, ns.locales.frFR.CFG_LANGUAGE, "la table L est remplie sur place, pas remplacée")
ok(L.CFG_LANGUAGE ~= ns.locales.enUS.CFG_LANGUAGE, "les libellés ont bien changé de langue")

-- Une clé absente d'une traduction doit rester lisible plutôt que nil.
ns.locales.frFR.CFG_LANGUAGE = nil
ns.SetLocale("frFR")
equal(L.CFG_LANGUAGE, ns.locales.enUS.CFG_LANGUAGE, "clé non traduite : repli sur enUS")

equal(ns.SetLocale("xxXX"), "enUS", "code inconnu : repli sur enUS")
equal(ns.SetLocale(nil), "enUS", "locale nil : traitée comme auto")

for _, entry in ipairs(ns.LOCALE_ORDER) do
    ok(ns.locales[entry.code] ~= nil, "locale proposée et chargée : " .. entry.code)
end
equal(ns.LocaleName("frFR"), "Français", "nom lisible d'une langue")

--------------------------------------------------------------------------------

suite("Valeurs secrètes (moteur 12.x : retail, WoW Forever)")
_G.issecretvalue = Mock.IsSecret
ns.lastCooldownDuration[1766] = nil  -- durée apprise par la suite « Détection »
Mock.units.target = { guid = BOSS_GUID, name = "Onyxia", health = 100, healthMax = 100 }
Mock.FireEvent("PLAYER_TARGET_CHANGED")
ns.db.spellId = nil
Detector:ResolveInterrupt()
Detector.interruptUsedAt = nil
Detector:ClearAlert()

-- Cooldown du kick secret (en combat) : Compat rend nil + true, sans comparer.
Mock.cooldowns[1766] = { start = Mock.Secret(Mock.now), duration = Mock.Secret(10) }
local secretRemaining, secretFlag = ns.GetSpellRemaining(1766)
ok(secretRemaining == nil and secretFlag == true, "GetSpellRemaining : cooldown secret = nil, true")
local savedIsSpellKnown = _G.IsSpellKnown
_G.IsSpellKnown = nil
ok(ns.KnowsSpell(1766), "KnowsSpell : repli par nom sans comparaison sur un startTime secret")
_G.IsSpellKnown = savedIsSpellKnown

StartCast(17086, false)
ok(Text:IsShown(), "cooldown secret, aucun kick vu : alerte (kick supposé prêt)")
Mock.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-guid", 1766)
equal(Text:IsShown(), false, "kick lancé par le joueur : cooldown déduit, alerte retirée")
equal(Detector:BaseCooldown(), retail and 15 or 10, "cooldown de base selon la saveur")
ok(Detector:StatusLines()[2]:find(ns.L.COOLDOWN_DEDUCED:format(Detector:BaseCooldown()), 1, true) ~= nil,
    "/ka status : cooldown déduit signalé")
Mock.Advance(Detector:BaseCooldown() - 1)
equal(Text:IsShown(), false, "cooldown déduit encore en cours")
Mock.Advance(1.2)
ok(Text:IsShown(), "cooldown déduit écoulé : alerte")

-- Une durée lue hors combat prime sur la table de base.
Mock.cooldowns[1766] = { start = Mock.now, duration = 12 }
Mock.Advance(0.2)
equal(ns.lastCooldownDuration[1766], 12, "durée lisible mémorisée")
Mock.cooldowns[1766] = { start = Mock.Secret(Mock.now), duration = Mock.Secret(12) }
equal(Detector:BaseCooldown(), 12, "durée lue hors combat prioritaire sur la table")

-- Rang supérieur (autre id, même nom) reconnu ; le kick d'une autre unité ignoré.
Mock.spells[1767] = { name = "Kick", icon = "icon-1767" }
Detector.interruptUsedAt = nil
Mock.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-guid", 1767)
ok(Detector.interruptUsedAt ~= nil, "rang supérieur du kick (même nom) reconnu")
Detector.interruptUsedAt = 5
Mock.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "target", "cast-guid", 1766)
equal(Detector.interruptUsedAt, 5, "kick lancé par la cible : ignoré")
-- `Mock.Secret ~= 1766` ne lève pas en Lua pur : un espion sur GetSpellName prouve que la
-- garde IsSecret coupe avant toute lecture du spellId.
local realGetSpellName = ns.GetSpellName
ns.GetSpellName = function(id)
    if Mock.IsSecret(id) then error("GetSpellName a reçu un spellId secret") end
    return realGetSpellName(id)
end
Mock.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-guid", Mock.Secret(1766))
equal(Detector.interruptUsedAt, 5, "spellId secret : ignoré sans comparer")
ns.GetSpellName = realGetSpellName
Mock.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "pet", "cast-guid", 1767)
ok(Detector.interruptUsedAt ~= 5, "kick lancé par le familier (Spell Lock) : reconnu")
Mock.spells[1767] = nil
-- Sort suivi changé : le lancer mémorisé ne le concerne plus. Même sort re-résolu : gardé.
Detector.interruptUsedAt = 5
Detector:ResolveInterrupt()
equal(Detector.interruptUsedAt, 5, "SPELLS_CHANGED, même sort : lancer mémorisé gardé")
SlashCmdList.KICKALERT("spell 2139")
equal(Detector.interruptUsedAt, nil, "/ka spell <autre id> : lancer mémorisé oublié")
SlashCmdList.KICKALERT("spell auto")

-- notInterruptible secret : seul l'événement NOT_INTERRUPTIBLE / INTERRUPTIBLE fait foi.
Mock.SetCast("target", 17086, false)
Mock.casts.target.notInterruptible = Mock.Secret(true)
local _, _, _, _, protected, _, _, shieldSource = ns.GetCastInfo("target")
ok(protected == false and shieldSource == "unknown", "notInterruptible secret sans événement : interruptible, source unknown")
Mock.FireEvent("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "target")
_, _, _, _, protected, _, _, shieldSource = ns.GetCastInfo("target")
ok(protected == true and shieldSource == "event", "NOT_INTERRUPTIBLE reçu : protégé, source event")
Mock.FireEvent("UNIT_SPELLCAST_INTERRUPTIBLE", "target")
_, _, _, _, protected, _, _, shieldSource = ns.GetCastInfo("target")
ok(protected == false and shieldSource == "event", "INTERRUPTIBLE reçu : interruptible, source event")

StopCast()
Mock.cooldowns[1766] = nil
ns.lastCooldownDuration[1766] = nil
Detector.interruptUsedAt = nil

suite("Miroir CVar (SavedVariables jamais relues sur WoW Forever)")
local Mirror = ns.Mirror
ns.db.text.size = 60
ns.db.locale = "frFR"
ns.db.spellId = 1766
ns.db.anchors.text = { point = "TOP", relTo = "UIParent", relPoint = "TOP", x = 0, y = -120 }
ok(Mirror:Flush(), "écriture quand la table a changé")
equal(Mirror:Flush(), false, "rien ne change : pas de réécriture")
local mirrorText = Mock.cvars.KickAlertMirror1
ok(mirrorText:find("text.size=n60", 1, true) ~= nil, "réglage modifié recopié")
equal(mirrorText:find("text.label", 1, true), nil, "valeur par défaut non recopiée")
g_addonCategoriesCollapsed.KickAlert = nil      -- chemin miroir CVar seul
local restored = Mirror:Load(nil)
equal(restored.text.size, 60, "taille restaurée depuis le miroir")
equal(restored.locale, "frFR", "langue restaurée")
equal(restored.spellId, 1766, "sort forcé restauré")
equal(restored.anchors.text.y, -120, "ancrage restauré")
equal(restored.text.label, nil, "défauts absents du miroir (CopyDefaults les recrée)")
equal(Mirror:Load({ locale = "deDE" }).locale, "deDE", "SavedVariables non vide : prioritaire")
ns.db.text.size = 48
Mock.Advance(5.1)
equal(Mock.cvars.KickAlertMirror1:find("text.size", 1, true), nil, "recopié par le ticker OnUpdate")
ns.db.text.size = 50
Mock.FireEvent("PLAYER_LOGOUT")
ok(Mock.cvars.KickAlertMirror1:find("text.size=n50", 1, true) ~= nil, "recopié à PLAYER_LOGOUT")
-- Découpage : tranches courtes, recollage sans perte, refus au-delà de la capacité.
local chunk = Mirror.CHUNK
Mirror.CHUNK = 24
ns.db.text.size = 51
ok(Mirror:Flush(), "écriture en plusieurs tranches")
ok(Mock.cvars.KickAlertMirror2 ~= "", "deuxième tranche remplie")
g_addonCategoriesCollapsed.KickAlert = nil
equal(Mirror:Load(nil).text.size, 51, "tranches recollées")
ns.db.text.label = string.rep("x", 300)
equal(Mirror:Flush(), false, "trop grand : refusé, miroir précédent conservé")
ns.db.text.label = "KICK"
Mirror.CHUNK = chunk
-- Échappement : guillemets et antislash (config-cache.wtf stocke la valeur entre guillemets), clés numériques.
local text = Mirror.Serialize({ note = 'dit "heal" \\ ok', list = { "a", "b" }, empty = {} })
equal(text, 'MIR1:empty=t;list.#1=sa;list.#2=sb;note=sdit %22heal%22 %5C ok', "format")
local back = Mirror.Deserialize(text)
equal(back.note, 'dit "heal" \\ ok', "chaîne rendue")
equal(back.list[2], "b", "clé numérique rendue")
equal(#back.list, 2, "séquence intacte")
equal(Mirror.Deserialize("MIR1:x=q1"), nil, "genre inconnu refusé")
equal(Mirror.Deserialize("FUI1:x=n1"), nil, "préfixe étranger refusé")
-- /ka wipe : table vidée sur place, défauts recopiés, miroir réécrit.
ns.db.text.size = 61
Mirror:Flush()
SlashCmdList.KICKALERT("wipe")
equal(ns.db.text.size, 48, "wipe : défauts rétablis")
equal(ns.db, KickAlertDB, "wipe : même table (les modules gardent leur référence)")
equal(g_addonCategoriesCollapsed.KickAlert, KickAlertDB, "table hôte : même table que KickAlertDB")
-- Priorité au chargement : SavedVariables > table hôte > miroir CVar.
g_addonCategoriesCollapsed.KickAlert = { text = { size = 33 } }
equal(Mirror:Load(nil).text.size, 33, "table hôte prioritaire sur le miroir CVar")
equal(Mirror:Load({ text = { size = 34 } }).text.size, 34, "SavedVariables prioritaire sur la table hôte")
ns.db.text.size = 49
Mirror:Flush()
g_addonCategoriesCollapsed.KickAlert = {}
equal(Mirror:Load(nil).text.size, 49, "table hôte vide : repli sur le miroir CVar")
g_addonCategoriesCollapsed = {}
Mirror:Flush()
equal(g_addonCategoriesCollapsed.KickAlert, KickAlertDB, "table hôte recréée par Blizzard : rebranchée au flush")
ns.db.text.size = 48
Mirror:Flush()
equal(Mock.cvars.KickAlertMirror1:find("text.size", 1, true), nil, "wipe : miroir réécrit sans le réglage")

--------------------------------------------------------------------------------

say(("\n%d ok, %d échec(s)"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
