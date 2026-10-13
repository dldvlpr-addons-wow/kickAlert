-- Alerts.lua
-- Trois alertes indépendantes : texte déplaçable, halo sur les bords de l'écran, son.
-- Chacune écoute CAST_START / CAST_STOP et lit ses propres réglages dans NS.db.
-- Règle reprise de MyBossSuite : le son ne doit jamais pouvoir casser le visuel.
local _, NS = ...

local sin, pi = math.sin, math.pi

-- Aperçu : visible en mode unlock et pendant que le panneau d'options est ouvert.
-- IsVisible() et non IsShown() : fermer la fenêtre Options masque le parent sans
-- jamais appeler Hide() sur notre panneau, donc IsShown() y resterait vrai et
-- l'aperçu (texte + halo) ne s'éteindrait plus.
function NS.PreviewActive()
    return NS.unlocked or (NS.optionsPanel ~= nil and NS.optionsPanel:IsVisible()) or false
end

---------------------------------------------------------------------------
-- Texte
---------------------------------------------------------------------------
local Text = CreateFrame("Frame", "KickAlertText", UIParent)
NS.Text = Text
NS.Mixin(Text, NS.AnchorMixin)
Text.anchorKey = "Text"
Text.defaultPoint = "CENTER"
Text.defaultY = 180
Text:SetSize(200, 60)
Text:SetFrameStrata("HIGH")
Text:Hide()

-- Le texte vit dans un conteneur centré : la pulsation d'échelle part du centre,
-- pas du point d'ancrage (TOPLEFT après un drag).
Text.holder = CreateFrame("Frame", nil, Text)
Text.holder:SetPoint("CENTER")
Text.holder:SetSize(1, 1)
Text.label = Text.holder:CreateFontString(nil, "OVERLAY")
Text.label:SetPoint("CENTER")

Text.background = Text:CreateTexture(nil, "BACKGROUND")
Text.background:SetAllPoints()
NS.SetSolidColor(Text.background, 0, 0, 0, 0.5)
Text.background:Hide()

--- Police, texte et couleur d'un FontString d'alerte (texte central et nameplates).
function NS.StyleLabel(label, cfg, defaultFont, text)
    -- Chaîne vide et non nil : depuis 10.0 SetFont exige les flags.
    local outline = cfg.outline ~= "NONE" and cfg.outline or ""
    -- Police avant texte : SetText sans police est une erreur sur les clients récents.
    label:SetFont(cfg.font, cfg.size, outline)
    if not label:GetFont() then
        -- Chemin de police invalide (LibSharedMedia disparu) : repli Blizzard.
        label:SetFont(defaultFont, cfg.size, outline)
    end
    label:SetText(text)
    label:SetTextColor(cfg.color.r, cfg.color.g, cfg.color.b, cfg.color.a)
end

function Text:Apply()
    local cfg = NS.db.text
    NS.StyleLabel(self.label, cfg, NS.DEFAULTS.text.font, cfg.label ~= "" and cfg.label or "KICK")
    local width = self.label.GetStringWidth and self.label:GetStringWidth() or cfg.size * 4
    local height = self.label.GetStringHeight and self.label:GetStringHeight() or cfg.size
    self:SetSize(math.max(width + 20, 60), height + 20)
    self:SetScript("OnUpdate", cfg.pulse and self.OnUpdate or nil)
    self.holder:SetScale(1)
end

function Text:OnUpdate()
    -- Pulsation d'échelle : ±12 % autour de 1.
    self.holder:SetScale(1 + 0.12 * sin(GetTime() * NS.db.text.pulseSpeed * 2 * pi))
end

function Text:Refresh()
    -- En mode unlock le texte reste visible même désactivé : il faut pouvoir le placer.
    if (NS.unlocked or NS.db.text.enabled) and (NS.PreviewActive() or self.active) then
        self:Apply()
        self:Show()
        NS.WatchPreview()
    else
        self:Hide()
    end
end

NS:On("DB_READY", function()
    Text:EnablePositioning()
    Text:LoadAnchor()
    Text:Apply()
end)
NS:On("CAST_START", function() Text.active = true; Text:Refresh() end)
NS:On("CAST_STOP", function() Text.active = false; Text:Refresh() end)
NS:On("UNLOCK", function(unlocked)
    Text:EnableMouse(unlocked)
    if unlocked then Text.background:Show() else Text.background:Hide() end
    Text:Refresh()
end)
NS:On("RESET_ANCHORS", function() Text:ResetAnchor() end)

---------------------------------------------------------------------------
-- Halo (aura sur les 4 bords de l'écran)
---------------------------------------------------------------------------
local Aura = CreateFrame("Frame", "KickAlertAura", UIParent)
NS.Aura = Aura
Aura:SetAllPoints(UIParent)
Aura:SetFrameStrata("MEDIUM")
Aura:SetFrameLevel(0)
-- Plein écran : ne doit jamais intercepter un clic ni gêner le jeu.
Aura:EnableMouse(false)
Aura:Hide()

Aura.edges = {}
for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    local tex = Aura:CreateTexture(nil, "ARTWORK")
    NS.SetSolidColor(tex, 1, 1, 1, 1)
    Aura.edges[side] = tex
end
Aura.edges.TOP:SetPoint("TOPLEFT")
Aura.edges.TOP:SetPoint("TOPRIGHT")
Aura.edges.BOTTOM:SetPoint("BOTTOMLEFT")
Aura.edges.BOTTOM:SetPoint("BOTTOMRIGHT")
Aura.edges.LEFT:SetPoint("TOPLEFT")
Aura.edges.LEFT:SetPoint("BOTTOMLEFT")
Aura.edges.RIGHT:SetPoint("TOPRIGHT")
Aura.edges.RIGHT:SetPoint("BOTTOMRIGHT")

function Aura:Apply()
    local cfg = NS.db.aura
    local c = cfg.color
    local t = cfg.thickness
    self.edges.TOP:SetHeight(t)
    self.edges.BOTTOM:SetHeight(t)
    self.edges.LEFT:SetWidth(t)
    self.edges.RIGHT:SetWidth(t)
    -- Opaque au bord de l'écran, transparent vers le centre.
    NS.SetGradient(self.edges.TOP,    "VERTICAL",   c.r, c.g, c.b, 0,   c.a)
    NS.SetGradient(self.edges.BOTTOM, "VERTICAL",   c.r, c.g, c.b, c.a, 0)
    NS.SetGradient(self.edges.LEFT,   "HORIZONTAL", c.r, c.g, c.b, c.a, 0)
    NS.SetGradient(self.edges.RIGHT,  "HORIZONTAL", c.r, c.g, c.b, 0,   c.a)
    self:SetScript("OnUpdate", cfg.pulse and self.OnUpdate or nil)
    self:SetAlpha(1)
end

function Aura:OnUpdate()
    -- Pulsation d'alpha entre 0.3 et 1.
    self:SetAlpha(0.65 + 0.35 * sin(GetTime() * NS.db.aura.pulseSpeed * 2 * pi))
end

function Aura:Refresh()
    if NS.db.aura.enabled and (NS.PreviewActive() or self.active) then
        self:Apply()
        self:Show()
        NS.WatchPreview()
    else
        self:Hide()
    end
end

NS:On("DB_READY", function() Aura:Apply() end)
NS:On("CAST_START", function() Aura.active = true; Aura:Refresh() end)
NS:On("CAST_STOP", function() Aura.active = false; Aura:Refresh() end)
NS:On("UNLOCK", function() Aura:Refresh() end)

---------------------------------------------------------------------------
-- Fin de l'aperçu
---------------------------------------------------------------------------
-- Masquer la fenêtre Options ne déclenche pas OnHide sur notre panneau : WoW ne
-- propage pas OnHide aux enfants. Plus rien ne réévaluait donc PreviewActive() et
-- l'aperçu restait à l'écran une fois la fenêtre fermée. Ce veilleur ne tourne que
-- pendant l'aperçu et s'arrête de lui-même.
local previewWatcher = CreateFrame("Frame")
previewWatcher:Hide()
local sincePoll = 0
previewWatcher:SetScript("OnUpdate", function(self, elapsed)
    sincePoll = sincePoll + (elapsed or 0)
    if sincePoll < 0.2 then return end
    sincePoll = 0
    if not NS.PreviewActive() then
        self:Hide()
        Text:Refresh()
        Aura:Refresh()
    end
end)

--- Surveille la fin de l'aperçu. Appelé par les Refresh qui viennent d'afficher
-- quelque chose : sans alerte réelle en cours, seul l'aperçu les maintient.
function NS.WatchPreview()
    if NS.PreviewActive() then
        sincePoll = 0
        previewWatcher:Show()
    end
end

---------------------------------------------------------------------------
-- Son
---------------------------------------------------------------------------
local Sound = { lastPlayed = nil }
NS.Sound = Sound

--- Joue le son configuré. force = sans throttle (bouton de test).
function Sound:Play(force)
    local cfg = NS.db.sound
    local now = GetTime()
    if not force and self.lastPlayed and now - self.lastPlayed < (tonumber(cfg.throttle) or 0) then
        return false
    end
    if not force then self.lastPlayed = now end
    return NS.PlayAlertSound(cfg.sound, "Master")
end

NS:On("CAST_START", function()
    if NS.db.sound.enabled then Sound:Play() end
end)
