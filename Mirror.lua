-- Mirror.lua
-- Doubles de la table SavedVariables, pour un client qui ne la relit pas.
-- WoW Forever 1.60 écrit les SavedVariables de compte mais ne les relit jamais (ni au
-- /reload, ni au démarrage). Ce qu'il relit, vérifié en jeu :
--   1. WTF/SavedVariables/Blizzard_AddOnList.lua (global g_addonCategoriesCollapsed) : la
--      table de réglages y est rangée telle quelle sous la clé HOST_KEY, sans copie. Survit au
--      /reload et à la fermeture du jeu.
--   2. config-cache.wtf : les CVars enregistrées par l'addon y survivent au /reload seulement
--      (jamais écrites sur disque). La table, réduite à ce qui diffère des défauts, y est
--      recopiée en tranches de CHUNK caractères (4000 vérifié en jeu).
-- Au chargement : SavedVariables non vide, sinon table hôte, sinon miroir CVar.
--
-- Format : MIR1:chemin.a.b=n12;chemin.c=b1;chemin.d=sTexte;chemin.e=t (table vide)
-- Clé numérique : `#3`. Les caractères de structure (% ; = . # |) , les guillemets,
-- l'antislash et les non imprimables sont échappés en %XX. Jamais de loadstring.
local ADDON_NAME, NS = ...

local Mirror = {}
NS.Mirror = Mirror

Mirror.CVAR = ADDON_NAME .. "Mirror"
Mirror.SLOTS = 8
Mirror.CHUNK = 4000
Mirror.PREFIX = "MIR1:"
Mirror.HOST = "g_addonCategoriesCollapsed"   -- SavedVariables de Blizzard_AddOnList, relue par ce client
Mirror.HOST_KEY = ADDON_NAME

local lastText, registered
local watched, watchedDefaults

--------------------------------------------------------------------------------
-- Sérialisation
--------------------------------------------------------------------------------

local function Escape(text)
    return (tostring(text):gsub('[%%;=%.#|"\\%c]', function(c) return string.format("%%%02X", c:byte()) end))
end

local function Unescape(text)
    return (text:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

local function EncodeKey(key)
    if type(key) == "number" then return "#" .. Escape(string.format("%.14g", key)) end
    return Escape(key)
end

local function DecodeKey(part)
    if part:sub(1, 1) == "#" then return tonumber(Unescape(part:sub(2))) end
    return Unescape(part)
end

local function KeyLess(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) == "number"
end

local function Flatten(value, path, out)
    if type(value) == "table" then
        local keys = {}
        for key in pairs(value) do
            if type(key) == "string" or type(key) == "number" then keys[#keys + 1] = key end
        end
        table.sort(keys, KeyLess)
        if next(value) == nil and path ~= "" then out[#out + 1] = path .. "=t" end
        for _, key in ipairs(keys) do
            Flatten(value[key], path == "" and EncodeKey(key) or (path .. "." .. EncodeKey(key)), out)
        end
    elseif type(value) == "boolean" then
        out[#out + 1] = path .. "=b" .. (value and "1" or "0")
    elseif type(value) == "number" then
        out[#out + 1] = path .. "=n" .. string.format("%.14g", value)
    elseif type(value) == "string" then
        out[#out + 1] = path .. "=s" .. Escape(value)
    end
end

function Mirror.Serialize(tbl)
    local out = {}
    Flatten(tbl, "", out)
    return Mirror.PREFIX .. table.concat(out, ";")
end

--- Chaîne -> table, ou nil (préfixe ou contenu illisible).
function Mirror.Deserialize(text)
    if type(text) ~= "string" or text:sub(1, #Mirror.PREFIX) ~= Mirror.PREFIX then return nil end
    local result = {}
    for pair in (text:sub(#Mirror.PREFIX + 1) .. ";"):gmatch("([^;]*);") do
        if pair ~= "" then
            local path, kind, raw = pair:match("^([^=]+)=([bnst])(.*)$")
            if not path then return nil end
            local value
            if kind == "t" then value = {}
            elseif kind == "b" then value = raw == "1"
            elseif kind == "n" then value = tonumber(raw)
            else value = Unescape(raw) end
            if value == nil then return nil end
            local parts = {}
            for part in path:gmatch("[^%.]+") do parts[#parts + 1] = DecodeKey(part) end
            if #parts == 0 then return nil end
            local node = result
            for i = 1, #parts - 1 do
                if parts[i] == nil then return nil end
                if type(node[parts[i]]) ~= "table" then node[parts[i]] = {} end
                node = node[parts[i]]
            end
            if parts[#parts] == nil then return nil end
            node[parts[#parts]] = value
        end
    end
    return result
end

--- Copie de `value` sans les scalaires égaux à `defaults` (le chargement les recrée).
local function Prune(value, defaults)
    local out = {}
    for key, child in pairs(value) do
        local default
        if type(defaults) == "table" then default = defaults[key] end   -- pas de `and/or` : false est un défaut
        if type(child) == "table" then
            local pruned = Prune(child, default)
            if next(pruned) ~= nil then out[key] = pruned end
        elseif child ~= default then
            out[key] = child
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- CVars
--------------------------------------------------------------------------------

local function Api()
    local api = _G.C_CVar
    if api and api.RegisterCVar and api.GetCVar and api.SetCVar then return api end
    return nil
end

--- Enregistre les tranches (une fois par session, avant toute lecture). false si l'API manque.
function Mirror:Register()
    local api = Api()
    if not api then return false end
    if registered then return true end
    -- Un client qui refuse l'enregistrement : miroir inerte, plutôt qu'une erreur toutes les 5 s.
    for i = 1, self.SLOTS do
        if not pcall(api.RegisterCVar, self.CVAR .. i, "") then return false end
    end
    registered = true
    return true
end

--- Table reconstruite depuis le miroir, ou nil.
function Mirror:Read()
    if not self:Register() then return nil end
    local parts = {}
    for i = 1, self.SLOTS do
        local chunk = C_CVar.GetCVar(self.CVAR .. i)
        if type(chunk) ~= "string" or chunk == "" then break end
        parts[#parts + 1] = chunk
    end
    if #parts == 0 then return nil end
    local text = table.concat(parts)
    local saved = self.Deserialize(text)
    if saved then lastText = text end
    return saved
end

--- Recopie `tbl` (moins les défauts) si elle a changé depuis la dernière écriture. true si écrit.
-- Trop grande pour les tranches, ou écriture refusée : rien n'est retenu, on réessaie plus tard.
function Mirror:Write(tbl, defaults)
    if type(tbl) ~= "table" or not self:Register() then return false end
    local text = self.Serialize(Prune(tbl, defaults))
    if text == lastText or #text > self.SLOTS * self.CHUNK then return false end
    if not self.Deserialize(text) then return false end   -- illisible (nan, clé vide) : ne pas remplacer un miroir sain
    local written = true
    for i = 1, self.SLOTS do
        local chunk = text:sub((i - 1) * self.CHUNK + 1, i * self.CHUNK)
        if C_CVar.SetCVar(self.CVAR .. i, chunk) == false then written = false end
    end
    if written then lastText = text end
    return written
end

local function Host()
    local host = _G[Mirror.HOST]
    if type(host) == "table" then return host end
    return nil
end

--- Range la table dans la sauvegarde hôte (référence, pas copie). false si l'hôte manque.
function Mirror:Host(tbl)
    local host = Host()
    if not host then return false end
    host[self.HOST_KEY] = tbl
    return true
end

--- La table sauvegardée telle quelle ; absente ou vide : la table hôte, sinon le miroir CVar.
function Mirror:Load(saved)
    if type(saved) == "table" and next(saved) ~= nil then return saved end
    local host = Host()
    local hosted = host and host[self.HOST_KEY]
    if type(hosted) == "table" and next(hosted) ~= nil then return hosted end
    return self:Read() or saved
end

--- Recopie `tbl` toutes les 5 s si elle a changé, et à la déconnexion.
-- OnUpdate plutôt que C_Timer : présent sur tous les clients.
if not _G.CreateFrame then return end   -- selfcheck hors client : logique pure seulement
local watcher = CreateFrame("Frame")
local elapsedSince = 0
watcher:SetScript("OnUpdate", function(_, elapsed)
    elapsedSince = elapsedSince + elapsed
    if elapsedSince < 5 then return end
    elapsedSince = 0
    Mirror:Flush()
end)
watcher:SetScript("OnEvent", function() Mirror:Flush() end)

function Mirror:Watch(tbl, defaults)
    watched, watchedDefaults = tbl, defaults
    watcher:RegisterEvent("PLAYER_LOGOUT")
    self:Flush()
end

--- Rebranche la table hôte (Blizzard peut recréer la sienne) et recopie le miroir CVar.
function Mirror:Flush()
    if not watched then return false end
    self:Host(watched)
    return self:Write(watched, watchedDefaults)
end
