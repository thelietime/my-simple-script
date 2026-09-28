--==============================================================
-- AUTO PICKAXE ENCHANT + PICKAXE SELECTOR + HELIUM FARM CONTROL
--
-- Features
--   • Select a pickaxe from live inventory
--   • Pickaxe list shows:
--       - Pickaxe name
--       - UUID in smaller text
--       - Current enchants
--   • Multi-level enchant targets
--   • Exact required-target stop count
--   • Target/config list auto-saves every time it changes
--   • Reads "Helium-3 Gem" from live inventory
--   • Optional low-Helium farming state:
--       Start Auto Mine below/equal START threshold
--       Stop Auto Mine at/above STOP threshold
--
-- IMPORTANT ABOUT AUTO MINE
--   Confirmed Auto Mine button path:
--   PlayerGui.MainLeft.Left.Tools.AutoMine
--   A separate farm pickaxe can be selected and is saved in config.
--
-- Potassium executor persistence:
--   Petsim99_enchant/<AccountName>.json
--==============================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Network = ReplicatedStorage:WaitForChild("Network")
local RollRemote = Network:WaitForChild("PickaxeEnchantsMachine_Activate")
local ToolSelectRemote = Network:WaitForChild("Tools_SetSelectedTool")

local InventoryCmds = require(
    ReplicatedStorage
        :WaitForChild("Library")
        :WaitForChild("Client")
        :WaitForChild("InventoryCmds")
)

local PickaxeItem = require(
    ReplicatedStorage
        :WaitForChild("Library")
        :WaitForChild("Items")
        :WaitForChild("PickaxeItem")
)

--==============================================================
-- USER CONFIG
--==============================================================

local CONFIG_FOLDER = "Petsim99_enchant"

if makefolder and isfolder and not isfolder(CONFIG_FOLDER) then
    pcall(makefolder, CONFIG_FOLDER)
end

local CONFIG_FILE =
    CONFIG_FOLDER
    .. "/"
    .. Player.Name
    .. ".json"

local HELIUM_ITEM_NAME = "Helium-3 Gem"

local ROLL_DELAY = 0.25
local INVENTORY_REFRESH_DELAY = 0.4

local AUTO_MINE_BUTTON_PATH = {"MainLeft", "Left", "Tools", "AutoMine"}

-- If the Auto Mine button is a simple toggle without ON/OFF text,
-- this script assumes it starts OFF and tracks only clicks made by this script.
local ASSUME_AUTO_MINE_STARTS_OFF = true

--==============================================================
-- ENCHANT DATA
--==============================================================

local Roman = {
    [1] = "I",
    [2] = "II",
    [3] = "III",
    [4] = "IV",
    [5] = "V",
}

local EnchantInfo = {
    ["Lucky"] = {Remote = "Lucky", Internal = "Lucky", MaxTier = 5},
    ["Fortune"] = {Remote = "Fortune", Internal = "Fortune", MaxTier = 5},
    ["Power Ball"] = {Remote = "Power Ball", Internal = "Power Ball", MaxTier = 5},
    ["Gravity"] = {Remote = "Gravity", Internal = "Gravity", MaxTier = 2},
    ["X-Ray"] = {Remote = "XRay", Internal = "XRay", MaxTier = 1},
    ["Explosive"] = {Remote = "Explosive", Internal = "Explosive", MaxTier = 5},
    ["Fracture"] = {Remote = "Fracture", Internal = "Fracture", MaxTier = 5},
    ["Lightning"] = {Remote = "Lightning", Internal = "Lightning", MaxTier = 5},
    ["More Coins"] = {Remote = "More Coins", Internal = "More Coins", MaxTier = 5},
    ["Damage"] = {Remote = "Damage", Internal = "Damage", MaxTier = 5},
    ["Player Speed"] = {Remote = "Player Speed", Internal = "Player Speed", MaxTier = 5},
    ["Gem Upgrade"] = {Remote = "Gem Upgrade", Internal = "Gem Upgrade", MaxTier = 5},
    ["Diamond Farmer"] = {Remote = "Diamond Farmer", Internal = "Diamond Farmer", MaxTier = 5},
    ["Replenish"] = {Remote = "Replenish", Internal = "Replenish", MaxTier = 5},
}

local EnchantOrder = {
    "Lucky",
    "Fortune",
    "Power Ball",
    "Gravity",
    "X-Ray",
    "Explosive",
    "Fracture",
    "Lightning",
    "More Coins",
    "Damage",
    "Player Speed",
    "Gem Upgrade",
    "Diamond Farmer",
    "Replenish",
}

--==============================================================
-- STATE
--==============================================================

-- Each combo is a full AND requirement set.
-- Auto Roll stops when ANY combo is fully matched.
-- Example:
-- Combos[1] = {
--     ["Gem Upgrade"] = {[3]=true,[4]=true,[5]=true},
--     ["Fortune"] = {[5]=true},
-- }
local Combos = {}
local ComboBuilder = {}

local SelectedEnchant = "Damage"
local SelectedLevels = {[5] = true}
local SelectedPickaxeUUID = nil
local FarmPickaxeUUID = nil

local AutoRolling = false
local RollCount = 0

local AutoFarmEnabled = false
local FarmStartBelow = 100
local FarmStopAt = 500
local FarmingForHelium = false
local ScriptAutoMineState = ASSUME_AUTO_MINE_STARTS_OFF and false or nil

local WebhookEnabled = false
local WebhookUrl = ""
local WebhookMentionEnabled = false
local WebhookUserId = ""

-- Saved per-account UI/settings state.
local SavedActivePage = "Auto Roll"
local SavedWindowPosition = nil
local ResumeAutoRoll = false

-- Roll counter fingerprint tracking.
local CountedPickaxeUUID = nil
local LastCountedEnchantFingerprint = nil

local CachedStore = nil
local LastHeliumAmount = 0

--==============================================================
-- BASIC HELPERS
--==============================================================

local function makeCorner(obj, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 6)
    c.Parent = obj
    return c
end

local function displayEnchantName(id)
    if id == "XRay" then
        return "X-Ray"
    end
    return id
end

local function formatNumber(value)
    value = tonumber(value) or 0

    if value >= 1e9 then
        return string.format("%.2fb", value / 1e9)
    elseif value >= 1e6 then
        return string.format("%.2fm", value / 1e6)
    elseif value >= 1e3 then
        return string.format("%.1fk", value / 1e3)
    end

    return tostring(math.floor(value))
end

local function trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$")
end

local function normalizeText(s)
    return string.lower(trim(tostring(s or "")))
end

--==============================================================
-- INVENTORY STORE
--==============================================================

local function looksLikeStore(tbl)
    if typeof(tbl) ~= "table" then
        return false
    end

    if typeof(rawget(tbl, "_byUID")) == "table" then
        return true
    end

    local byType = rawget(tbl, "_byType")

    return typeof(byType) == "table"
        and typeof(byType.Tool) == "table"
        and typeof(byType.Tool._byUID) == "table"
end

local function recursiveStoreSearch(tbl, visited, depth)
    if typeof(tbl) ~= "table" then
        return nil
    end

    visited = visited or {}
    depth = depth or 0

    if depth > 8 or visited[tbl] then
        return nil
    end

    visited[tbl] = true

    if looksLikeStore(tbl) then
        return tbl
    end

    for _, value in pairs(tbl) do
        if typeof(value) == "table" then
            local found = recursiveStoreSearch(value, visited, depth + 1)
            if found then
                return found
            end
        end
    end

    return nil
end

local function findInventoryStore()
    if CachedStore and looksLikeStore(CachedStore) then
        return CachedStore
    end

    local getUps = (debug and debug.getupvalues) or getupvalues
    if not getUps then
        return nil
    end

    local ok, upvalues = pcall(getUps, InventoryCmds.State)

    if not ok or typeof(upvalues) ~= "table" then
        return nil
    end

    for _, value in pairs(upvalues) do
        if typeof(value) == "table" then
            local store = recursiveStoreSearch(value, {}, 0)

            if store then
                CachedStore = store
                return store
            end
        end
    end

    return nil
end

local function getItemByUUID(uuid)
    if not uuid then
        return nil
    end

    local store = findInventoryStore()

    if not store then
        return nil
    end

    if typeof(store._byUID) == "table" and store._byUID[uuid] then
        return store._byUID[uuid]
    end

    if typeof(store._byType) == "table"
        and typeof(store._byType.Tool) == "table"
        and typeof(store._byType.Tool._byUID) == "table"
    then
        return store._byType.Tool._byUID[uuid]
    end

    return nil
end

local function getItemId(item)
    if typeof(item) ~= "table" then
        return nil
    end

    local data = rawget(item, "_data")

    if typeof(data) == "table" then
        return data.id or data._id or data.Id
    end

    return rawget(item, "id") or rawget(item, "_id")
end

local function getItemUUID(item)
    if typeof(item) ~= "table" then
        return nil
    end

    return rawget(item, "_uid")
        or rawget(item, "uid")
        or rawget(item, "UUID")
end

local function getItemAmount(item)
    if typeof(item) ~= "table" then
        return 0
    end

    local methodNames = {
        "GetAmount",
        "Amount",
        "GetQuantity",
        "GetCount",
    }

    for _, name in ipairs(methodNames) do
        local fn = rawget(item, name)

        if typeof(fn) == "function" then
            local ok, result = pcall(fn, item)

            if ok and tonumber(result) then
                return tonumber(result)
            end
        end
    end

    local directFields = {
        "_amount",
        "_am",
        "amount",
        "Amount",
        "_quantity",
        "quantity",
        "Quantity",
        "_count",
        "count",
        "Count",
    }

    for _, key in ipairs(directFields) do
        local value = rawget(item, key)

        if tonumber(value) then
            return tonumber(value)
        end
    end

    local data = rawget(item, "_data")

    if typeof(data) == "table" then
        for _, key in ipairs(directFields) do
            local value = rawget(data, key)

            if tonumber(value) then
                return tonumber(value)
            end
        end
    end

    -- Stack inventory objects may omit an explicit amount when they represent x1.
    return 1
end

--==============================================================
-- PICKAXES
--==============================================================

local function isPickaxeItem(item)
    local id = getItemId(item)

    if not id then
        return false
    end

    local dir = PickaxeItem.Directory

    if typeof(dir) == "table" and typeof(dir[id]) == "table" then
        return dir[id].Type == "Pickaxe"
            or string.find(string.lower(tostring(id)), "pickaxe", 1, true) ~= nil
    end

    return string.find(string.lower(tostring(id)), "pickaxe", 1, true) ~= nil
end

local function getPickaxeDisplayName(item)
    local id = getItemId(item)

    if not id then
        return "Unknown Pickaxe"
    end

    local dir = PickaxeItem.Directory

    if typeof(dir) == "table" and typeof(dir[id]) == "table" then
        return dir[id].DisplayName or id
    end

    return id
end

local function getAllPickaxes()
    local store = findInventoryStore()
    local results = {}

    if not store then
        return results
    end

    local source = nil

    if typeof(store._byType) == "table"
        and typeof(store._byType.Tool) == "table"
        and typeof(store._byType.Tool._byUID) == "table"
    then
        source = store._byType.Tool._byUID
    elseif typeof(store._byUID) == "table" then
        source = store._byUID
    end

    if typeof(source) ~= "table" then
        return results
    end

    for uuid, item in pairs(source) do
        if isPickaxeItem(item) then
            table.insert(results, {
                UUID = tostring(uuid),
                Item = item,
                Name = getPickaxeDisplayName(item),
            })
        end
    end

    table.sort(results, function(a, b)
        if a.Name == b.Name then
            return a.UUID < b.UUID
        end

        return a.Name < b.Name
    end)

    return results
end

local function getCurrentEnchants(uuid)
    local item = getItemByUUID(uuid)

    if not item then
        return {}
    end

    local ok, enchants = pcall(function()
        return item._data._uq.ch
    end)

    if not ok or typeof(enchants) ~= "table" then
        return {}
    end

    return enchants
end

local function enchantFingerprint(uuid)
    local result = {}

    for _, enchant in ipairs(getCurrentEnchants(uuid)) do
        result[#result + 1] =
            tostring(enchant.id)
            .. ":"
            .. tostring(enchant.tn)
    end

    table.sort(result)

    return table.concat(result, "|")
end

local function currentEnchantsText(uuid)
    local parts = {}

    for _, enchant in ipairs(getCurrentEnchants(uuid)) do
        local name = displayEnchantName(enchant.id)

        if enchant.id == "XRay" then
            parts[#parts + 1] = name
        else
            parts[#parts + 1] =
                name
                .. " "
                .. (Roman[enchant.tn] or tostring(enchant.tn))
        end
    end

    if #parts == 0 then
        return "No enchants"
    end

    return table.concat(parts, ", ")
end

local function getSelectedPickaxe()
    if not SelectedPickaxeUUID then
        return nil
    end

    local item = getItemByUUID(SelectedPickaxeUUID)

    if not item then
        return nil
    end

    return {
        UUID = SelectedPickaxeUUID,
        Item = item,
        Name = getPickaxeDisplayName(item),
    }
end


local function getFarmPickaxe()
    if not FarmPickaxeUUID then
        return nil
    end

    local item = getItemByUUID(FarmPickaxeUUID)

    if not item or not isPickaxeItem(item) then
        return nil
    end

    return {
        UUID = FarmPickaxeUUID,
        Item = item,
        Name = getPickaxeDisplayName(item),
    }
end


--==============================================================
-- WEBHOOK
--==============================================================

local function getRequestFunction()
    if request then
        return request
    end

    if http_request then
        return http_request
    end

    if syn and syn.request then
        return syn.request
    end

    if http and http.request then
        return http.request
    end

    return nil
end

local function sendWebhook(reason, comboIndex, matchedNames, force)
    if not WebhookEnabled and not force then
        return false, "Webhook is disabled"
    end

    if WebhookUrl == "" then
        return false, "Webhook URL is empty"
    end

    local requestFunction = getRequestFunction()

    if not requestFunction then
        return false, "Executor HTTP request function not found"
    end

    local selected = getSelectedPickaxe()
    local mention = ""

    if WebhookMentionEnabled and WebhookUserId ~= "" then
        mention = "<@" .. WebhookUserId .. "> "
    end

    local lines = {
        mention .. "**" .. tostring(reason or "Auto Enchant") .. "**",
        "Account: ||" .. Player.Name .. "||",
        "Pickaxe: " .. (selected and selected.Name or "Unknown"),
        "Enchant: " .. currentEnchantsText(SelectedPickaxeUUID),
    }

    if comboIndex and comboIndex > 0 then
        lines[#lines + 1] = "Combo: #" .. tostring(comboIndex)
    end

    if typeof(matchedNames) == "table" and #matchedNames > 0 then
        lines[#lines + 1] = "Matched: " .. table.concat(matchedNames, " + ")
    end

    local body = HttpService:JSONEncode({
        content = table.concat(lines, "\n"),
    })

    local ok, response = pcall(function()
        return requestFunction({
            Url = WebhookUrl,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
            },
            Body = body,
        })
    end)

    if not ok then
        return false, tostring(response)
    end

    local status =
        tonumber(response and (response.StatusCode or response.Status))

    if status and status >= 200 and status < 300 then
        return true
    end

    if status == nil then
        return true
    end

    return false, "HTTP " .. tostring(status)
end

--==============================================================
-- HELIUM-3 GEM
--==============================================================

local function getHeliumAmount()
    local store = findInventoryStore()

    if not store or typeof(store._byUID) ~= "table" then
        return 0
    end

    local total = 0
    local found = false

    for _, item in pairs(store._byUID) do
        if getItemId(item) == HELIUM_ITEM_NAME then
            total += getItemAmount(item)
            found = true
        end
    end

    if found then
        return total
    end

    -- Fallback search through byType in case _byUID does not expose this class.
    if typeof(store._byType) == "table" then
        local visited = {}

        local function scan(tbl, depth)
            if typeof(tbl) ~= "table" or visited[tbl] or depth > 5 then
                return
            end

            visited[tbl] = true

            for _, value in pairs(tbl) do
                if typeof(value) == "table" then
                    if getItemId(value) == HELIUM_ITEM_NAME then
                        total += getItemAmount(value)
                        found = true
                    else
                        scan(value, depth + 1)
                    end
                end
            end
        end

        scan(store._byType, 0)
    end

    return total
end

--==============================================================
-- COMBO / STOP LOGIC
-- Every enchant inside one combo is required (AND).
-- Different combos are alternatives (OR).
--==============================================================

local function comboCount()
    return #Combos
end

local function selectedLevelCount()
    local n = 0

    for _, enabled in pairs(SelectedLevels) do
        if enabled then
            n += 1
        end
    end

    return n
end

local function cloneLevelSet(source)
    local out = {}

    for tier, enabled in pairs(source or {}) do
        if enabled then
            out[tier] = true
        end
    end

    return out
end

local function cloneCombo(source)
    local out = {}

    for id, levels in pairs(source or {}) do
        out[id] = cloneLevelSet(levels)
    end

    return out
end

local function levelsToText(levelSet, internalId)
    if internalId == "XRay" then
        return "I"
    end

    local parts = {}

    for tier = 1, 5 do
        if levelSet and levelSet[tier] then
            parts[#parts + 1] = Roman[tier] or tostring(tier)
        end
    end

    return #parts > 0 and table.concat(parts, "/") or "None"
end

local function comboRequirementCount(combo)
    local n = 0

    for _ in pairs(combo or {}) do
        n += 1
    end

    return n
end

local function comboToText(combo)
    local parts = {}

    for internalId, levels in pairs(combo or {}) do
        parts[#parts + 1] =
            displayEnchantName(internalId)
            .. " "
            .. levelsToText(levels, internalId)
    end

    table.sort(parts)

    return #parts > 0 and table.concat(parts, " + ") or "Empty combo"
end

local function checkCombos(uuid)
    local currentById = {}

    for _, enchant in ipairs(getCurrentEnchants(uuid)) do
        currentById[enchant.id] = enchant.tn
    end

    local bestIndex = 0
    local bestMatched = 0
    local bestTotal = 0
    local bestNames = {}

    for comboIndex, combo in ipairs(Combos) do
        local total = 0
        local matched = 0
        local matchedNames = {}

        for internalId, allowedLevels in pairs(combo) do
            total += 1

            local currentTier = currentById[internalId]

            if currentTier and allowedLevels[currentTier] == true then
                matched += 1
                matchedNames[#matchedNames + 1] =
                    displayEnchantName(internalId)
                    .. " "
                    .. (Roman[currentTier] or tostring(currentTier))
            end
        end

        table.sort(matchedNames)

        if total > 0 and matched == total then
            return true, comboIndex, matched, total, matchedNames
        end

        if matched > bestMatched
            or (
                matched == bestMatched
                and total > 0
                and (bestTotal == 0 or total < bestTotal)
            )
        then
            bestIndex = comboIndex
            bestMatched = matched
            bestTotal = total
            bestNames = matchedNames
        end
    end

    return false, bestIndex, bestMatched, bestTotal, bestNames
end

--==============================================================
-- SAVE / LOAD CONFIG
-- One file per Roblox account:
-- Petsim99_enchant/<AccountName>.json
--==============================================================

local function serializeLevels(levelSet)
    local list = {}

    for tier = 1, 5 do
        if levelSet and levelSet[tier] then
            list[#list + 1] = tier
        end
    end

    return list
end

local function deserializeLevels(list)
    local out = {}

    if typeof(list) == "table" then
        for _, tier in ipairs(list) do
            tier = tonumber(tier)

            if tier then
                out[tier] = true
            end
        end
    end

    return out
end

local function serializeCombo(combo)
    local list = {}

    for id, levels in pairs(combo or {}) do
        list[#list + 1] = {
            id = id,
            levels = serializeLevels(levels),
        }
    end

    table.sort(list, function(a, b)
        return tostring(a.id) < tostring(b.id)
    end)

    return list
end

local function deserializeCombo(list)
    local combo = {}

    if typeof(list) ~= "table" then
        return combo
    end

    for _, entry in ipairs(list) do
        if typeof(entry) == "table"
            and typeof(entry.id) == "string"
            and typeof(entry.levels) == "table"
        then
            local levels = deserializeLevels(entry.levels)

            if next(levels) then
                combo[entry.id] = levels
            end
        end
    end

    return combo
end

local function serializeCombos()
    local out = {}

    for _, combo in ipairs(Combos) do
        out[#out + 1] = serializeCombo(combo)
    end

    return out
end

local function serializeWindowPosition()
    if typeof(SavedWindowPosition) ~= "UDim2" then
        return nil
    end

    return {
        xScale = SavedWindowPosition.X.Scale,
        xOffset = SavedWindowPosition.X.Offset,
        yScale = SavedWindowPosition.Y.Scale,
        yOffset = SavedWindowPosition.Y.Offset,
    }
end

local function saveConfig()
    if not writefile then
        return false
    end

    if makefolder and isfolder and not isfolder(CONFIG_FOLDER) then
        pcall(makefolder, CONFIG_FOLDER)
    end

    local data = {
        version = 6,

        accountName = Player.Name,
        userId = Player.UserId,

        selectedPickaxeUUID = SelectedPickaxeUUID,
        farmPickaxeUUID = FarmPickaxeUUID,

        selectedEnchant = SelectedEnchant,
        selectedLevels = serializeLevels(SelectedLevels),

        comboBuilder = serializeCombo(ComboBuilder),
        combos = serializeCombos(),

        autoRollEnabled = AutoRolling,
        autoFarmEnabled = AutoFarmEnabled,
        farmStartBelow = FarmStartBelow,
        farmStopAt = FarmStopAt,

        webhookEnabled = WebhookEnabled,
        webhookUrl = WebhookUrl,
        webhookMentionEnabled = WebhookMentionEnabled,
        webhookUserId = WebhookUserId,

        activePage = SavedActivePage,
        windowPosition = serializeWindowPosition(),
    }

    local ok, encoded =
        pcall(
            HttpService.JSONEncode,
            HttpService,
            data
        )

    if not ok then
        return false
    end

    return pcall(
        writefile,
        CONFIG_FILE,
        encoded
    )
end

local function loadConfig()
    if not readfile or not isfile or not isfile(CONFIG_FILE) then
        return
    end

    local okRead, raw = pcall(readfile, CONFIG_FILE)

    if not okRead then
        return
    end

    local okDecode, data =
        pcall(
            HttpService.JSONDecode,
            HttpService,
            raw
        )

    if not okDecode or typeof(data) ~= "table" then
        return
    end

    if typeof(data.selectedPickaxeUUID) == "string" then
        SelectedPickaxeUUID = data.selectedPickaxeUUID
    end

    if typeof(data.farmPickaxeUUID) == "string" then
        FarmPickaxeUUID = data.farmPickaxeUUID
    end

    if typeof(data.selectedEnchant) == "string"
        and EnchantInfo[data.selectedEnchant]
    then
        SelectedEnchant = data.selectedEnchant
    end

    local loadedLevels = deserializeLevels(data.selectedLevels)

    if next(loadedLevels) then
        SelectedLevels = loadedLevels
    end

    Combos = {}

    if typeof(data.combos) == "table" then
        for _, rawCombo in ipairs(data.combos) do
            local combo = deserializeCombo(rawCombo)

            if next(combo) then
                Combos[#Combos + 1] = combo
            end
        end
    elseif typeof(data.targets) == "table" then
        -- Migrate the old target system into one full combo.
        local oldCombo = deserializeCombo(data.targets)

        if next(oldCombo) then
            Combos[1] = oldCombo
        end
    end

    ComboBuilder = deserializeCombo(data.comboBuilder)

    ResumeAutoRoll = data.autoRollEnabled == true
    AutoFarmEnabled = data.autoFarmEnabled == true

    if tonumber(data.farmStartBelow) then
        FarmStartBelow = math.max(0, math.floor(tonumber(data.farmStartBelow)))
    end

    if tonumber(data.farmStopAt) then
        FarmStopAt = math.max(
            FarmStartBelow,
            math.floor(tonumber(data.farmStopAt))
        )
    end

    WebhookEnabled = data.webhookEnabled == true
    WebhookMentionEnabled = data.webhookMentionEnabled == true

    if typeof(data.webhookUrl) == "string" then
        WebhookUrl = data.webhookUrl
    end

    if typeof(data.webhookUserId) == "string" then
        WebhookUserId = data.webhookUserId
    end

    if data.activePage == "Auto Roll"
        or data.activePage == "Auto Farm"
        or data.activePage == "Misc"
    then
        SavedActivePage = data.activePage
    end

    if typeof(data.windowPosition) == "table" then
        local p = data.windowPosition

        if tonumber(p.xScale)
            and tonumber(p.xOffset)
            and tonumber(p.yScale)
            and tonumber(p.yOffset)
        then
            SavedWindowPosition =
                UDim2.new(
                    tonumber(p.xScale),
                    tonumber(p.xOffset),
                    tonumber(p.yScale),
                    tonumber(p.yOffset)
                )
        end
    end
end

loadConfig()

-- Count a roll only when the selected pickaxe's enchant data actually changes.
local function resetEnchantChangeCounter(uuid)
    CountedPickaxeUUID = uuid

    if uuid then
        LastCountedEnchantFingerprint = enchantFingerprint(uuid)
    else
        LastCountedEnchantFingerprint = nil
    end
end

local function recordEnchantChange(uuid)
    if not uuid then
        return false
    end

    local fingerprint = enchantFingerprint(uuid)

    if CountedPickaxeUUID ~= uuid then
        CountedPickaxeUUID = uuid
        LastCountedEnchantFingerprint = fingerprint
        return false
    end

    if LastCountedEnchantFingerprint == nil then
        LastCountedEnchantFingerprint = fingerprint
        return false
    end

    if fingerprint ~= LastCountedEnchantFingerprint then
        LastCountedEnchantFingerprint = fingerprint
        RollCount += 1
        return true
    end

    return false
end


--==============================================================
-- PORTABLE CONFIG EXPORT / IMPORT
-- Export uses pickaxe names instead of account-specific UUIDs.
-- Grouped to keep Luau top-level local-register use low.
--==============================================================

local ConfigTransfer = {}

function ConfigTransfer.findPickaxeUUIDByName(name)
    if typeof(name) ~= "string" or name == "" then
        return nil
    end

    local wanted = name:lower()

    for _, info in ipairs(getAllPickaxes()) do
        if tostring(info.Name):lower() == wanted then
            return info.UUID
        end
    end

    return nil
end

function ConfigTransfer.pickaxeName(uuid)
    if not uuid then
        return nil
    end

    local item = getItemByUUID(uuid)

    if not item or not isPickaxeItem(item) then
        return nil
    end

    return getPickaxeDisplayName(item)
end

function ConfigTransfer.build()
    return {
        format = "Petsim99_enchant_portable",
        version = 1,

        rollPickaxeName =
            ConfigTransfer.pickaxeName(
                SelectedPickaxeUUID
            ),

        farmPickaxeName =
            ConfigTransfer.pickaxeName(
                FarmPickaxeUUID
            ),

        selectedEnchant = SelectedEnchant,
        selectedLevels = serializeLevels(SelectedLevels),

        comboBuilder = serializeCombo(ComboBuilder),
        combos = serializeCombos(),

        autoRollEnabled = AutoRolling,
        autoFarmEnabled = AutoFarmEnabled,

        farmStartBelow = FarmStartBelow,
        farmStopAt = FarmStopAt,

        webhookEnabled = WebhookEnabled,
        webhookUrl = WebhookUrl,
        webhookMentionEnabled = WebhookMentionEnabled,
        webhookUserId = WebhookUserId,

        activePage = SavedActivePage,
    }
end

function ConfigTransfer.export()
    local ok, encoded =
        pcall(
            HttpService.JSONEncode,
            HttpService,
            ConfigTransfer.build()
        )

    if not ok then
        return false, "Could not encode config"
    end

    if setclipboard then
        local copied = pcall(setclipboard, encoded)

        if copied then
            return true, encoded
        end
    end

    if toclipboard then
        local copied = pcall(toclipboard, encoded)

        if copied then
            return true, encoded
        end
    end

    return false, encoded
end

function ConfigTransfer.apply(data)
    if typeof(data) ~= "table" then
        return false, "Config is not a JSON object"
    end

    if data.format
        and data.format ~= "Petsim99_enchant_portable"
    then
        return false, "Unknown config format"
    end

    if typeof(data.selectedEnchant) == "string"
        and EnchantInfo[data.selectedEnchant]
    then
        SelectedEnchant = data.selectedEnchant
    end

    local importedLevels = deserializeLevels(data.selectedLevels)

    if next(importedLevels) then
        SelectedLevels = importedLevels
    end

    if typeof(data.combos) == "table" then
        local importedCombos = {}

        for _, rawCombo in ipairs(data.combos) do
            local combo = deserializeCombo(rawCombo)

            if next(combo) then
                importedCombos[#importedCombos + 1] = combo
            end
        end

        Combos = importedCombos
    end

    if typeof(data.comboBuilder) == "table" then
        ComboBuilder = deserializeCombo(data.comboBuilder)
    else
        ComboBuilder = {}
    end

    if tonumber(data.farmStartBelow) then
        FarmStartBelow =
            math.max(
                0,
                math.floor(
                    tonumber(data.farmStartBelow)
                )
            )
    end

    if tonumber(data.farmStopAt) then
        FarmStopAt =
            math.max(
                FarmStartBelow,
                math.floor(
                    tonumber(data.farmStopAt)
                )
            )
    end

    if typeof(data.webhookUrl) == "string" then
        WebhookUrl = data.webhookUrl
    end

    if typeof(data.webhookUserId) == "string" then
        WebhookUserId = data.webhookUserId
    end

    WebhookEnabled = data.webhookEnabled == true
    WebhookMentionEnabled = data.webhookMentionEnabled == true
    AutoFarmEnabled = data.autoFarmEnabled == true
    ResumeAutoRoll = data.autoRollEnabled == true

    if data.activePage == "Auto Roll"
        or data.activePage == "Auto Farm"
        or data.activePage == "Misc"
    then
        SavedActivePage = data.activePage
    end

    if typeof(data.rollPickaxeName) == "string" then
        local mapped =
            ConfigTransfer.findPickaxeUUIDByName(
                data.rollPickaxeName
            )

        if mapped then
            SelectedPickaxeUUID = mapped
        end
    end

    if typeof(data.farmPickaxeName) == "string" then
        local mapped =
            ConfigTransfer.findPickaxeUUIDByName(
                data.farmPickaxeName
            )

        if mapped then
            FarmPickaxeUUID = mapped
        end
    end

    RollCount = 0
    resetEnchantChangeCounter(SelectedPickaxeUUID)
    saveConfig()

    return true
end

function ConfigTransfer.import(raw)
    if typeof(raw) ~= "string"
        or raw:gsub("%s+", "") == ""
    then
        return false, "Paste exported JSON first"
    end

    local ok, data =
        pcall(
            HttpService.JSONDecode,
            HttpService,
            raw
        )

    if not ok then
        return false, "Invalid JSON"
    end

    return ConfigTransfer.apply(data)
end

function exportPortableConfig()
    return ConfigTransfer.export()
end

function importPortableConfig(raw)
    return ConfigTransfer.import(raw)
end

--==============================================================
-- REMOTE ROLL
--==============================================================

local function makeFalseArray(count)
    local t = {}

    for i = 1, count do
        t[i] = false
    end

    return t
end

local function createRollData()
    local result = {}

    for _, display in ipairs(EnchantOrder) do
        local info = EnchantInfo[display]
        result[info.Remote] = makeFalseArray(info.MaxTier)
    end

    return result
end

local function waitForEnchantUpdate(uuid, oldFingerprint)
    local started = os.clock()

    while os.clock() - started < 2 do
        if enchantFingerprint(uuid) ~= oldFingerprint then
            return true
        end

        task.wait(0.04)
    end

    return false
end

--==============================================================
-- FARM PICKAXE EQUIP
-- Uses the game's actual Tools_SetSelectedTool RemoteFunction.
--==============================================================

local function equipFarmPickaxe()
    local selected = getFarmPickaxe()

    if not selected then
        return false, "select a valid farm pickaxe"
    end

    local ok, result = pcall(function()
        return ToolSelectRemote:InvokeServer(
            "Pickaxe",
            selected.UUID
        )
    end)

    if not ok then
        return false, "Tools_SetSelectedTool failed: " .. tostring(result)
    end

    -- Some RemoteFunctions return nil on success, so only an explicit
    -- boolean false is treated as a rejected equip.
    if result == false then
        return false, "server rejected farm pickaxe equip"
    end

    task.wait(0.15)

    return true, "equipped " .. selected.Name
end

--==============================================================
-- AUTO MINE CONTROL
-- Exact state indicators:
--   AutoMine.StatusOn.Visible  == true -> enabled
--   AutoMine.StatusOff.Visible == true -> disabled
--==============================================================

local function getAutoMineRoot()
    local ok, root = pcall(function()
        return PlayerGui
            :WaitForChild("MainLeft", 2)
            :WaitForChild("Left", 2)
            :WaitForChild("Tools", 2)
            :WaitForChild("AutoMine", 2)
    end)

    if not ok then
        return nil
    end

    return root
end

local function getAutoMineButton()
    local root = getAutoMineRoot()

    if not root then
        return nil
    end

    if root:IsA("GuiButton") then
        return root
    end

    return root:FindFirstChildWhichIsA("GuiButton", true)
end

local function getAutoMineState()
    local root = getAutoMineRoot()

    if not root then
        return nil
    end

    local on = root:FindFirstChild("StatusOn")
    local off = root:FindFirstChild("StatusOff")

    if on and on:IsA("GuiObject") and on.Visible == true then
        return true
    end

    if off and off:IsA("GuiObject") and off.Visible == true then
        return false
    end

    return nil
end

local function waitForAutoMineState(desiredState, timeout)
    local started = os.clock()

    repeat
        local state = getAutoMineState()

        if state == desiredState then
            ScriptAutoMineState = state
            return true
        end

        task.wait(0.04)
    until os.clock() - started >= (timeout or 0.6)

    return false
end

local function fireSignalOnce(signal)
    if not signal then
        return false
    end

    if firesignal then
        local ok = pcall(firesignal, signal)

        if ok then
            return true
        end
    end

    return false
end

local function fireConnectionsOnce(signal)
    if not signal or not getconnections then
        return false
    end

    local ok, connections =
        pcall(getconnections, signal)

    if not ok or typeof(connections) ~= "table" then
        return false
    end

    local fired = false

    for _, connection in ipairs(connections) do
        if connection.Function then
            if pcall(connection.Function) then
                fired = true
            end
        elseif connection.Fire then
            if pcall(function()
                connection:Fire()
            end) then
                fired = true
            end
        end
    end

    return fired
end

local function virtualMouseClick(button)
    if not button or not button:IsA("GuiButton") then
        return false
    end

    local pos = button.AbsolutePosition
    local size = button.AbsoluteSize

    if size.X <= 0 or size.Y <= 0 then
        return false
    end

    local x = math.floor(pos.X + size.X / 2)
    local y = math.floor(pos.Y + size.Y / 2)

    local ok = pcall(function()
        local vim = Instance.new("VirtualInputManager")

        vim:SendMouseButtonEvent(
            x,
            y,
            0,
            true,
            game,
            0
        )

        task.wait(0.05)

        vim:SendMouseButtonEvent(
            x,
            y,
            0,
            false,
            game,
            0
        )

        vim:Destroy()
    end)

    return ok
end

local function tryAutoMineMethod(button, desiredState, method)
    local fired = false

    if method == "MouseButton1Click" then
        fired =
            fireSignalOnce(
                button.MouseButton1Click
            )

    elseif method == "Activated" then
        fired =
            fireSignalOnce(
                button.Activated
            )

    elseif method == "VirtualMouse" then
        fired =
            virtualMouseClick(button)

    elseif method == "ConnectionsClick" then
        fired =
            fireConnectionsOnce(
                button.MouseButton1Click
            )

    elseif method == "ConnectionsActivated" then
        fired =
            fireConnectionsOnce(
                button.Activated
            )

    elseif method == "FireClick" then
        if fireclick then
            fired =
                pcall(
                    fireclick,
                    button
                )
        end
    end

    if not fired then
        return false
    end

    -- IMPORTANT:
    -- A method is only considered successful if StatusOn/StatusOff
    -- confirms that Auto Mine actually changed to the requested state.
    return waitForAutoMineState(
        desiredState,
        0.65
    )
end

local function setAutoMine(desiredState)
    local root = getAutoMineRoot()

    if not root then
        return false, "AutoMine path not found"
    end

    local button = getAutoMineButton()

    if not button then
        return false,
            "AutoMine exists but no GuiButton was found"
    end

    local current = getAutoMineState()

    if current == desiredState then
        ScriptAutoMineState = current

        return true,
            desiredState and "ON" or "OFF"
    end

    local methods = {
        "MouseButton1Click",
        "Activated",
        "VirtualMouse",
        "ConnectionsClick",
        "ConnectionsActivated",
        "FireClick",
    }

    for _, method in ipairs(methods) do
        -- Re-check before each method in case the previous UI action
        -- changed state slightly after its timeout.
        if getAutoMineState() == desiredState then
            ScriptAutoMineState = desiredState

            return true,
                desiredState and "ON" or "OFF"
        end

        if tryAutoMineMethod(
            button,
            desiredState,
            method
        ) then
            return true,
                desiredState and "ON" or "OFF"
        end

        task.wait(0.05)
    end

    local on = root:FindFirstChild("StatusOn")
    local off = root:FindFirstChild("StatusOff")

    local onVisible =
        on
        and on:IsA("GuiObject")
        and on.Visible

    local offVisible =
        off
        and off:IsA("GuiObject")
        and off.Visible

    return false,
        "AutoMine click failed"
        .. " | button="
        .. button.ClassName
        .. " | StatusOn="
        .. tostring(onVisible)
        .. " | StatusOff="
        .. tostring(offVisible)
end

--==============================================================
-- ENCHANT MACHINE TELEPORT
-- Target: PickaxeEnchants.Arrow
--==============================================================

local function getEnchantMachineArrow()
    local ok, arrow = pcall(function()
        return workspace
            :WaitForChild("__THINGS", 2)
            :WaitForChild("__INSTANCE_CONTAINER", 2)
            :WaitForChild("Active", 2)
            :WaitForChild("SpaceMiningEvent", 2)
            :WaitForChild("INTERACT", 2)
            :WaitForChild("Machines", 2)
            :WaitForChild("PickaxeEnchants", 2)
            :WaitForChild("Arrow", 2)
    end)

    if not ok or not arrow then
        return nil
    end

    if arrow:IsA("BasePart") then
        return arrow
    end

    return arrow:FindFirstChildWhichIsA("BasePart", true)
end

local function teleportToEnchantMachine()
    local arrow = getEnchantMachineArrow()

    if not arrow then
        return false, "PickaxeEnchants.Arrow not found"
    end

    for attempt = 1, 10 do
        local character = Player.Character

        if not character then
            Player.CharacterAdded:Wait()
            character = Player.Character
        end

        local root =
            character
            and character:FindFirstChild("HumanoidRootPart")

        if character and root then
            local target =
                arrow.CFrame
                * CFrame.new(0, 3.5, 0)

            pcall(function()
                character:PivotTo(target)
            end)

            task.wait(0.25)

            root =
                character:FindFirstChild("HumanoidRootPart")

            if root
                and (root.Position - arrow.Position).Magnitude <= 10
            then
                return true
            end
        end

        task.wait(0.15)
    end

    return false, "teleport verification failed"
end

--==============================================================
-- GUI - MULTI PAGE
--==============================================================

Old = PlayerGui:FindFirstChild("AutoEnchantFarmUI")

if Old then
    Old:Destroy()
end

Screen = Instance.new("ScreenGui")
Screen.Name = "AutoEnchantFarmUI"
Screen.ResetOnSpawn = false
Screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
Screen.Parent = PlayerGui

Main = Instance.new("Frame")
Main.AnchorPoint = Vector2.new(0.5, 0.5)
Main.Size = UDim2.fromOffset(470, 570)
Main.Position =
    SavedWindowPosition
    or UDim2.new(0.5, 0, 0.5, 0)

SavedWindowPosition = Main.Position
Main.BackgroundColor3 = Color3.fromRGB(22, 22, 27)
Main.BorderSizePixel = 0
Main.ClipsDescendants = false
Main.Parent = Screen
makeCorner(Main, 10)

MainStroke = Instance.new("UIStroke")
MainStroke.Color = Color3.fromRGB(65, 65, 75)
MainStroke.Parent = Main

Header = Instance.new("Frame")
Header.Size = UDim2.new(1, 0, 0, 44)
Header.BackgroundTransparency = 1
Header.Parent = Main

Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -105, 1, 0)
Title.Position = UDim2.fromOffset(14, 0)
Title.BackgroundTransparency = 1
Title.Text = "Auto Roll"
Title.TextColor3 = Color3.fromRGB(240, 240, 245)
Title.TextSize = 18
Title.Font = Enum.Font.GothamBold
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = Header

Close = Instance.new("TextButton")
Close.Size = UDim2.fromOffset(32, 32)
Close.Position = UDim2.new(1, -39, 0, 6)
Close.BackgroundColor3 = Color3.fromRGB(42, 42, 48)
Close.Text = "×"
Close.TextColor3 = Color3.new(1, 1, 1)
Close.TextSize = 20
Close.Font = Enum.Font.GothamBold
Close.Parent = Header
makeCorner(Close)

-- Page/menu button. The icon is drawn from Frames to look like the
-- fullscreen/window icon supplied by the user.
PageButton = Instance.new("TextButton")
PageButton.Size = UDim2.fromOffset(32, 32)
PageButton.Position = UDim2.new(1, -76, 0, 6)
PageButton.BackgroundColor3 = Color3.fromRGB(42, 42, 48)
PageButton.Text = ""
PageButton.AutoButtonColor = true
PageButton.Parent = Header
makeCorner(PageButton)

function iconPart(size, position)
    local p = Instance.new("Frame")
    p.Size = size
    p.Position = position
    p.BorderSizePixel = 0
    p.BackgroundColor3 = Color3.fromRGB(235, 235, 240)
    p.Parent = PageButton
    return p
end

-- Four "open square" corners.
iconPart(UDim2.fromOffset(7, 2), UDim2.fromOffset(8, 8))
iconPart(UDim2.fromOffset(2, 7), UDim2.fromOffset(8, 8))

iconPart(UDim2.fromOffset(7, 2), UDim2.fromOffset(17, 8))
iconPart(UDim2.fromOffset(2, 7), UDim2.fromOffset(22, 8))

iconPart(UDim2.fromOffset(7, 2), UDim2.fromOffset(8, 22))
iconPart(UDim2.fromOffset(2, 7), UDim2.fromOffset(8, 17))

iconPart(UDim2.fromOffset(7, 2), UDim2.fromOffset(17, 22))
iconPart(UDim2.fromOffset(2, 7), UDim2.fromOffset(22, 17))

PageMenu = Instance.new("Frame")
PageMenu.Size = UDim2.fromOffset(150, 121)
PageMenu.Position = UDim2.new(1, -191, 0, 42)
PageMenu.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
PageMenu.BorderSizePixel = 0
PageMenu.Visible = false
PageMenu.ZIndex = 200
PageMenu.Parent = Main
makeCorner(PageMenu, 7)

PageMenuStroke = Instance.new("UIStroke")
PageMenuStroke.Color = Color3.fromRGB(63, 63, 74)
PageMenuStroke.Parent = PageMenu

PageMenuLayout = Instance.new("UIListLayout")
PageMenuLayout.Padding = UDim.new(0, 4)
PageMenuLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
PageMenuLayout.VerticalAlignment = Enum.VerticalAlignment.Center
PageMenuLayout.Parent = PageMenu

function makePageMenuButton(text)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -8, 0, 33)
    b.BackgroundColor3 = Color3.fromRGB(38, 38, 45)
    b.TextColor3 = Color3.fromRGB(235, 235, 240)
    b.Text = text
    b.TextSize = 12
    b.Font = Enum.Font.GothamBold
    b.ZIndex = 201
    b.Parent = PageMenu
    makeCorner(b, 5)
    return b
end

RollPageButton = makePageMenuButton("Auto Roll")
FarmPageButton = makePageMenuButton("Auto Farm")
MiscPageButton = makePageMenuButton("Misc")

RollPage = Instance.new("Frame")
RollPage.Name = "AutoRollPage"
RollPage.Size = UDim2.new(1, 0, 1, -44)
RollPage.Position = UDim2.fromOffset(0, 44)
RollPage.BackgroundTransparency = 1
RollPage.Parent = Main

FarmPage = Instance.new("Frame")
FarmPage.Name = "AutoFarmPage"
FarmPage.Size = UDim2.new(1, 0, 1, -44)
FarmPage.Position = UDim2.fromOffset(0, 44)
FarmPage.BackgroundTransparency = 1
FarmPage.Visible = false
FarmPage.Parent = Main

MiscPage = Instance.new("Frame")
MiscPage.Name = "MiscPage"
MiscPage.Size = UDim2.new(1, 0, 1, -44)
MiscPage.Position = UDim2.fromOffset(0, 44)
MiscPage.BackgroundTransparency = 1
MiscPage.Visible = false
MiscPage.Parent = Main

ActivePage = "Auto Roll"

PAGE_SIZES = {
    ["Auto Roll"] = Vector2.new(470, 675),
    ["Auto Farm"] = Vector2.new(470, 405),
    ["Misc"] = Vector2.new(470, 650),
}

PickaxePopup = nil
FarmPickaxePopup = nil
LevelPopup = nil
EnchantPopup = nil

function closePopups()
    PageMenu.Visible = false

    if PickaxePopup then
        PickaxePopup.Visible = false
    end

    if FarmPickaxePopup then
        FarmPickaxePopup.Visible = false
    end

    if LevelPopup then
        LevelPopup.Visible = false
    end

    if EnchantPopup then
        EnchantPopup.Visible = false
    end
end

function switchPage(pageName)
    if pageName ~= "Auto Roll"
        and pageName ~= "Auto Farm"
        and pageName ~= "Misc"
    then
        return
    end

    ActivePage = pageName
    SavedActivePage = pageName
    closePopups()

    RollPage.Visible = pageName == "Auto Roll"
    FarmPage.Visible = pageName == "Auto Farm"
    MiscPage.Visible = pageName == "Misc"

    Title.Text = pageName

    local target = PAGE_SIZES[pageName]

    TweenService:Create(
        Main,
        TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        {
            Size = UDim2.fromOffset(target.X, target.Y)
        }
    ):Play()

    saveConfig()
end

PageButton.MouseButton1Click:Connect(function()
    PageMenu.Visible = not PageMenu.Visible
end)

RollPageButton.MouseButton1Click:Connect(function()
    switchPage("Auto Roll")
end)

FarmPageButton.MouseButton1Click:Connect(function()
    switchPage("Auto Farm")
end)

MiscPageButton.MouseButton1Click:Connect(function()
    switchPage("Misc")
end)

Close.MouseButton1Click:Connect(function()
    AutoRolling = false
    saveConfig()
    Screen:Destroy()
end)

-- Dragging from the header.
do
    local dragging = false
    local startMouse
    local startPosition

    Header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            startMouse = input.Position
            startPosition = Main.Position
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging
            and input.UserInputType == Enum.UserInputType.MouseMovement
        then
            local delta = input.Position - startMouse

            Main.Position =
                startPosition
                + UDim2.fromOffset(delta.X, delta.Y)
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            if dragging then
                SavedWindowPosition = Main.Position
                saveConfig()
            end

            dragging = false
        end
    end)
end

--==============================================================
-- SHARED DROPDOWN HELPERS
--==============================================================

function createSimpleDropdown(
    parent,
    position,
    size,
    defaultText,
    getOptions,
    onSelected,
    popupHeight
)
    local holder = Instance.new("Frame")
    holder.Size = size
    holder.Position = position
    holder.BackgroundTransparency = 1
    holder.ZIndex = 30
    holder.Parent = parent

    local button = Instance.new("TextButton")
    button.Size = UDim2.new(1, 0, 0, size.Y.Offset)
    button.BackgroundColor3 = Color3.fromRGB(36, 36, 43)
    button.TextColor3 = Color3.fromRGB(235, 235, 240)
    button.Text = defaultText .. "  ▼"
    button.TextSize = 11
    button.Font = Enum.Font.Gotham
    button.ZIndex = 31
    button.Parent = holder
    makeCorner(button, 6)

    local popup = Instance.new("ScrollingFrame")
    popup.Size = UDim2.new(1, 0, 0, popupHeight or 165)
    popup.Position = UDim2.fromOffset(0, size.Y.Offset + 4)
    popup.BackgroundColor3 = Color3.fromRGB(29, 29, 36)
    popup.BorderSizePixel = 0
    popup.ScrollBarThickness = 4
    popup.CanvasSize = UDim2.fromOffset(0, 0)
    popup.Visible = false
    popup.ZIndex = 150
    popup.Parent = holder
    makeCorner(popup, 6)

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 3)
    layout.Parent = popup

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 4)
    pad.PaddingLeft = UDim.new(0, 4)
    pad.PaddingRight = UDim.new(0, 4)
    pad.Parent = popup

    local function rebuild()
        for _, child in ipairs(popup:GetChildren()) do
            if child:IsA("TextButton") then
                child:Destroy()
            end
        end

        for _, option in ipairs(getOptions()) do
            local item = Instance.new("TextButton")
            item.Size = UDim2.new(1, -4, 0, 28)
            item.BackgroundColor3 = Color3.fromRGB(40, 40, 47)
            item.TextColor3 = Color3.fromRGB(235, 235, 240)
            item.Text = tostring(option)
            item.TextSize = 11
            item.Font = Enum.Font.Gotham
            item.ZIndex = 151
            item.Parent = popup
            makeCorner(item, 5)

            item.MouseButton1Click:Connect(function()
                button.Text = tostring(option) .. "  ▼"
                popup.Visible = false
                onSelected(option)
            end)
        end

        task.defer(function()
            popup.CanvasSize =
                UDim2.fromOffset(
                    0,
                    layout.AbsoluteContentSize.Y + 8
                )
        end)
    end

    button.MouseButton1Click:Connect(function()
        PageMenu.Visible = false
        rebuild()
        popup.Visible = not popup.Visible
    end)

    return {
        Button = button,
        Popup = popup,
        SetText = function(value)
            button.Text = tostring(value) .. "  ▼"
        end,
        Rebuild = rebuild,
    }
end

--==============================================================
-- AUTO ROLL PAGE
--==============================================================

PickaxeLabel = Instance.new("TextLabel")
PickaxeLabel.Size = UDim2.new(1, -28, 0, 18)
PickaxeLabel.Position = UDim2.fromOffset(14, 5)
PickaxeLabel.BackgroundTransparency = 1
PickaxeLabel.Text = "Enchant Pickaxe"
PickaxeLabel.TextColor3 = Color3.fromRGB(175, 175, 185)
PickaxeLabel.TextSize = 11
PickaxeLabel.Font = Enum.Font.Gotham
PickaxeLabel.TextXAlignment = Enum.TextXAlignment.Left
PickaxeLabel.Parent = RollPage

PickaxeButton = Instance.new("TextButton")
PickaxeButton.Size = UDim2.new(1, -28, 0, 62)
PickaxeButton.Position = UDim2.fromOffset(14, 25)
PickaxeButton.BackgroundColor3 = Color3.fromRGB(32, 32, 39)
PickaxeButton.Text = ""
PickaxeButton.AutoButtonColor = false
PickaxeButton.Parent = RollPage
makeCorner(PickaxeButton, 7)

SelectedNameLabel = Instance.new("TextLabel")
SelectedNameLabel.Size = UDim2.new(1, -42, 0, 21)
SelectedNameLabel.Position = UDim2.fromOffset(10, 6)
SelectedNameLabel.BackgroundTransparency = 1
SelectedNameLabel.Text = "Select a pickaxe"
SelectedNameLabel.TextColor3 = Color3.fromRGB(240, 240, 245)
SelectedNameLabel.TextSize = 14
SelectedNameLabel.Font = Enum.Font.GothamBold
SelectedNameLabel.TextXAlignment = Enum.TextXAlignment.Left
SelectedNameLabel.Parent = PickaxeButton

SelectedUUIDLabel = Instance.new("TextLabel")
SelectedUUIDLabel.Size = UDim2.new(1, -42, 0, 14)
SelectedUUIDLabel.Position = UDim2.fromOffset(10, 27)
SelectedUUIDLabel.BackgroundTransparency = 1
SelectedUUIDLabel.Text = "UUID: -"
SelectedUUIDLabel.TextColor3 = Color3.fromRGB(130, 130, 145)
SelectedUUIDLabel.TextSize = 9
SelectedUUIDLabel.Font = Enum.Font.Gotham
SelectedUUIDLabel.TextXAlignment = Enum.TextXAlignment.Left
SelectedUUIDLabel.Parent = PickaxeButton

SelectedEnchantLabel = Instance.new("TextLabel")
SelectedEnchantLabel.Size = UDim2.new(1, -42, 0, 16)
SelectedEnchantLabel.Position = UDim2.fromOffset(10, 42)
SelectedEnchantLabel.BackgroundTransparency = 1
SelectedEnchantLabel.Text = "Enchants: -"
SelectedEnchantLabel.TextColor3 = Color3.fromRGB(185, 185, 200)
SelectedEnchantLabel.TextSize = 10
SelectedEnchantLabel.Font = Enum.Font.Gotham
SelectedEnchantLabel.TextXAlignment = Enum.TextXAlignment.Left
SelectedEnchantLabel.TextTruncate = Enum.TextTruncate.AtEnd
SelectedEnchantLabel.Parent = PickaxeButton

PickaxeArrow = Instance.new("TextLabel")
PickaxeArrow.Size = UDim2.fromOffset(25, 62)
PickaxeArrow.Position = UDim2.new(1, -31, 0, 0)
PickaxeArrow.BackgroundTransparency = 1
PickaxeArrow.Text = "▼"
PickaxeArrow.TextColor3 = Color3.fromRGB(190, 190, 200)
PickaxeArrow.TextSize = 12
PickaxeArrow.Font = Enum.Font.GothamBold
PickaxeArrow.Parent = PickaxeButton

PickaxePopup = Instance.new("ScrollingFrame")
PickaxePopup.Size = UDim2.new(1, -28, 0, 205)
PickaxePopup.Position = UDim2.fromOffset(14, 134)
PickaxePopup.BackgroundColor3 = Color3.fromRGB(27, 27, 33)
PickaxePopup.BorderSizePixel = 0
PickaxePopup.ScrollBarThickness = 4
PickaxePopup.CanvasSize = UDim2.fromOffset(0, 0)
PickaxePopup.Visible = false
PickaxePopup.ZIndex = 500
PickaxePopup.Parent = Main
makeCorner(PickaxePopup, 7)

PickaxePopupStroke = Instance.new("UIStroke")
PickaxePopupStroke.Color = Color3.fromRGB(68, 68, 80)
PickaxePopupStroke.Thickness = 1
PickaxePopupStroke.Parent = PickaxePopup

PickaxeLayout = Instance.new("UIListLayout")
PickaxeLayout.Padding = UDim.new(0, 5)
PickaxeLayout.Parent = PickaxePopup

PickaxePadding = Instance.new("UIPadding")
PickaxePadding.PaddingTop = UDim.new(0, 5)
PickaxePadding.PaddingLeft = UDim.new(0, 5)
PickaxePadding.PaddingRight = UDim.new(0, 5)
PickaxePadding.Parent = PickaxePopup

function refreshSelectedPickaxeCard()
    local selected = getSelectedPickaxe()

    if not selected then
        SelectedNameLabel.Text = "Select a pickaxe"
        SelectedUUIDLabel.Text = "UUID: -"
        SelectedEnchantLabel.Text = "Enchants: -"
        return
    end

    SelectedNameLabel.Text = selected.Name
    SelectedUUIDLabel.Text = "UUID: " .. selected.UUID
    SelectedEnchantLabel.Text =
        "Enchants: "
        .. currentEnchantsText(selected.UUID)
end

function rebuildPickaxePopup()
    for _, child in ipairs(PickaxePopup:GetChildren()) do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end

    for _, info in ipairs(getAllPickaxes()) do
        local row = Instance.new("TextButton")
        row.Size = UDim2.new(1, -4, 0, 66)
        row.BackgroundColor3 =
            info.UUID == SelectedPickaxeUUID
            and Color3.fromRGB(46, 82, 60)
            or Color3.fromRGB(38, 38, 45)
        row.Text = ""
        row.AutoButtonColor = false
        row.ZIndex = 501
        row.Parent = PickaxePopup
        makeCorner(row, 6)

        local name = Instance.new("TextLabel")
        name.Size = UDim2.new(1, -12, 0, 21)
        name.Position = UDim2.fromOffset(8, 5)
        name.BackgroundTransparency = 1
        name.Text = info.Name
        name.TextColor3 = Color3.fromRGB(238, 238, 243)
        name.TextSize = 13
        name.Font = Enum.Font.GothamBold
        name.TextXAlignment = Enum.TextXAlignment.Left
        name.ZIndex = 502
        name.Parent = row

        local uuid = Instance.new("TextLabel")
        uuid.Size = UDim2.new(1, -12, 0, 14)
        uuid.Position = UDim2.fromOffset(8, 26)
        uuid.BackgroundTransparency = 1
        uuid.Text = info.UUID
        uuid.TextColor3 = Color3.fromRGB(130, 130, 145)
        uuid.TextSize = 9
        uuid.Font = Enum.Font.Gotham
        uuid.TextXAlignment = Enum.TextXAlignment.Left
        uuid.ZIndex = 502
        uuid.Parent = row

        local enchants = Instance.new("TextLabel")
        enchants.Size = UDim2.new(1, -12, 0, 18)
        enchants.Position = UDim2.fromOffset(8, 43)
        enchants.BackgroundTransparency = 1
        enchants.Text = "Enchants: " .. currentEnchantsText(info.UUID)
        enchants.TextColor3 = Color3.fromRGB(180, 180, 195)
        enchants.TextSize = 10
        enchants.Font = Enum.Font.Gotham
        enchants.TextXAlignment = Enum.TextXAlignment.Left
        enchants.TextTruncate = Enum.TextTruncate.AtEnd
        enchants.ZIndex = 502
        enchants.Parent = row

        row.MouseButton1Click:Connect(function()
            if AutoRolling then
                return
            end

            SelectedPickaxeUUID = info.UUID
            PickaxePopup.Visible = false
            RollCount = 0
            resetEnchantChangeCounter(SelectedPickaxeUUID)
            saveConfig()
            refreshSelectedPickaxeCard()
        end)
    end

    task.defer(function()
        PickaxePopup.CanvasSize =
            UDim2.fromOffset(
                0,
                PickaxeLayout.AbsoluteContentSize.Y + 10
            )
    end)
end

PickaxeButton.MouseButton1Click:Connect(function()
    PageMenu.Visible = false
    EnchantPopup.Visible = false
    LevelPopup.Visible = false
    FarmPickaxePopup.Visible = false

    rebuildPickaxePopup()
    PickaxePopup.Visible = not PickaxePopup.Visible
end)

if not getSelectedPickaxe() then
    local first = getAllPickaxes()[1]

    if first then
        SelectedPickaxeUUID = first.UUID
        saveConfig()
    end
end

resetEnchantChangeCounter(SelectedPickaxeUUID)
refreshSelectedPickaxeCard()

TargetTitle = Instance.new("TextLabel")
TargetTitle.Size = UDim2.new(1, -28, 0, 18)
TargetTitle.Position = UDim2.fromOffset(14, 98)
TargetTitle.BackgroundTransparency = 1
TargetTitle.Text = "Combo Builder — ALL enchants inside one combo must match"
TargetTitle.TextColor3 = Color3.fromRGB(175, 175, 185)
TargetTitle.TextSize = 10
TargetTitle.Font = Enum.Font.Gotham
TargetTitle.TextXAlignment = Enum.TextXAlignment.Left
TargetTitle.Parent = RollPage

EnchantHolder = Instance.new("Frame")
EnchantHolder.Size = UDim2.fromOffset(195, 32)
EnchantHolder.Position = UDim2.fromOffset(14, 119)
EnchantHolder.BackgroundTransparency = 1
EnchantHolder.Parent = RollPage

EnchantButton = Instance.new("TextButton")
EnchantButton.Size = UDim2.new(1, 0, 1, 0)
EnchantButton.BackgroundColor3 = Color3.fromRGB(36, 36, 43)
EnchantButton.TextColor3 = Color3.fromRGB(235, 235, 240)
EnchantButton.Text = SelectedEnchant .. "  ▼"
EnchantButton.TextSize = 11
EnchantButton.Font = Enum.Font.Gotham
EnchantButton.Parent = EnchantHolder
makeCorner(EnchantButton, 6)

EnchantPopup = Instance.new("ScrollingFrame")
EnchantPopup.Size = UDim2.fromOffset(195, 190)
EnchantPopup.Position = UDim2.fromOffset(14, 199)
EnchantPopup.BackgroundColor3 = Color3.fromRGB(29, 29, 36)
EnchantPopup.BorderSizePixel = 0
EnchantPopup.ScrollBarThickness = 4
EnchantPopup.CanvasSize = UDim2.fromOffset(0, 0)
EnchantPopup.Visible = false
EnchantPopup.ZIndex = 520
EnchantPopup.Parent = Main
makeCorner(EnchantPopup, 6)

EnchantPopupStroke = Instance.new("UIStroke")
EnchantPopupStroke.Color = Color3.fromRGB(68, 68, 80)
EnchantPopupStroke.Thickness = 1
EnchantPopupStroke.Parent = EnchantPopup

EnchantLayout = Instance.new("UIListLayout")
EnchantLayout.Padding = UDim.new(0, 3)
EnchantLayout.Parent = EnchantPopup

EnchantPad = Instance.new("UIPadding")
EnchantPad.PaddingTop = UDim.new(0, 4)
EnchantPad.PaddingLeft = UDim.new(0, 4)
EnchantPad.PaddingRight = UDim.new(0, 4)
EnchantPad.Parent = EnchantPopup

function rebuildEnchantPopup()
    for _, child in ipairs(EnchantPopup:GetChildren()) do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end

    for _, name in ipairs(EnchantOrder) do
        local item = Instance.new("TextButton")
        item.Size = UDim2.new(1, -4, 0, 28)
        item.BackgroundColor3 = Color3.fromRGB(40, 40, 47)
        item.TextColor3 = Color3.fromRGB(235, 235, 240)
        item.Text = name
        item.TextSize = 11
        item.Font = Enum.Font.Gotham
        item.ZIndex = 521
        item.Parent = EnchantPopup
        makeCorner(item, 5)

        item.MouseButton1Click:Connect(function()
            SelectedEnchant = name
            SelectedLevels = {}

            local maxTier = EnchantInfo[name].MaxTier
            SelectedLevels[maxTier] = true

            EnchantButton.Text = name .. "  ▼"
            EnchantPopup.Visible = false
            LevelPopup.Visible = false

            updateLevelText()
            saveConfig()
        end)
    end

    task.defer(function()
        EnchantPopup.CanvasSize =
            UDim2.fromOffset(0, EnchantLayout.AbsoluteContentSize.Y + 8)
    end)
end

EnchantButton.MouseButton1Click:Connect(function()
    PageMenu.Visible = false
    PickaxePopup.Visible = false
    LevelPopup.Visible = false
    FarmPickaxePopup.Visible = false

    rebuildEnchantPopup()
    EnchantPopup.Visible = not EnchantPopup.Visible
end)

LevelHolder = Instance.new("Frame")
LevelHolder.Size = UDim2.fromOffset(110, 32)
LevelHolder.Position = UDim2.fromOffset(217, 119)
LevelHolder.BackgroundTransparency = 1
LevelHolder.ZIndex = 32
LevelHolder.Parent = RollPage

LevelButton = Instance.new("TextButton")
LevelButton.Size = UDim2.new(1, 0, 1, 0)
LevelButton.BackgroundColor3 = Color3.fromRGB(36, 36, 43)
LevelButton.TextColor3 = Color3.fromRGB(235, 235, 240)
LevelButton.TextSize = 11
LevelButton.Font = Enum.Font.Gotham
LevelButton.ZIndex = 33
LevelButton.Parent = LevelHolder
makeCorner(LevelButton, 6)

LevelPopup = Instance.new("Frame")
LevelPopup.Size = UDim2.fromOffset(110, 165)
LevelPopup.Position = UDim2.fromOffset(217, 199)
LevelPopup.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
LevelPopup.BorderSizePixel = 0
LevelPopup.Visible = false
LevelPopup.ZIndex = 530
LevelPopup.Parent = Main
makeCorner(LevelPopup, 6)

LevelPopupStroke = Instance.new("UIStroke")
LevelPopupStroke.Color = Color3.fromRGB(68, 68, 80)
LevelPopupStroke.Thickness = 1
LevelPopupStroke.Parent = LevelPopup

LevelLayout = Instance.new("UIListLayout")
LevelLayout.Padding = UDim.new(0, 3)
LevelLayout.Parent = LevelPopup

LevelPad = Instance.new("UIPadding")
LevelPad.PaddingTop = UDim.new(0, 4)
LevelPad.PaddingLeft = UDim.new(0, 4)
LevelPad.PaddingRight = UDim.new(0, 4)
LevelPad.Parent = LevelPopup

function updateLevelText()
    local internal = EnchantInfo[SelectedEnchant].Internal
    LevelButton.Text = levelsToText(SelectedLevels, internal) .. "  ▼"
end

function rebuildLevelPopup()
    for _, child in ipairs(LevelPopup:GetChildren()) do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end

    local maxTier = EnchantInfo[SelectedEnchant].MaxTier

    for tier = 1, maxTier do
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -4, 0, 27)
        b.TextSize = 11
        b.Font = Enum.Font.Gotham
        b.ZIndex = 531
        b.Parent = LevelPopup
        makeCorner(b, 5)

        local function refresh()
            local on = SelectedLevels[tier] == true
            b.Text = (on and "✓  " or "   ") .. Roman[tier]
            b.BackgroundColor3 =
                on
                and Color3.fromRGB(48, 105, 70)
                or Color3.fromRGB(40, 40, 47)
            b.TextColor3 = Color3.fromRGB(235, 235, 240)
        end

        b.MouseButton1Click:Connect(function()
            if maxTier == 1 then
                SelectedLevels[1] = true
            else
                SelectedLevels[tier] = not SelectedLevels[tier]

                if selectedLevelCount() == 0 then
                    SelectedLevels[tier] = true
                end
            end

            refresh()
            updateLevelText()
            saveConfig()
        end)

        refresh()
    end

    LevelPopup.Size =
        UDim2.new(1, 0, 0, math.min(165, maxTier * 30 + 8))
end

LevelButton.MouseButton1Click:Connect(function()
    PageMenu.Visible = false
    PickaxePopup.Visible = false
    EnchantPopup.Visible = false
    FarmPickaxePopup.Visible = false

    rebuildLevelPopup()
    LevelPopup.Visible = not LevelPopup.Visible
end)

updateLevelText()

AddRequirement = Instance.new("TextButton")
AddRequirement.Size = UDim2.fromOffset(127, 32)
AddRequirement.Position = UDim2.fromOffset(335, 119)
AddRequirement.BackgroundColor3 = Color3.fromRGB(52, 105, 72)
AddRequirement.Text = "Add To Combo"
AddRequirement.TextColor3 = Color3.new(1, 1, 1)
AddRequirement.TextSize = 10
AddRequirement.Font = Enum.Font.GothamBold
AddRequirement.Parent = RollPage
makeCorner(AddRequirement, 6)

BuilderFrame = Instance.new("ScrollingFrame")
BuilderFrame.Size = UDim2.new(1, -28, 0, 88)
BuilderFrame.Position = UDim2.fromOffset(14, 162)
BuilderFrame.BackgroundColor3 = Color3.fromRGB(29, 29, 35)
BuilderFrame.BorderSizePixel = 0
BuilderFrame.ScrollBarThickness = 4
BuilderFrame.CanvasSize = UDim2.fromOffset(0, 0)
BuilderFrame.Parent = RollPage
makeCorner(BuilderFrame, 7)

BuilderLayout = Instance.new("UIListLayout")
BuilderLayout.Padding = UDim.new(0, 4)
BuilderLayout.Parent = BuilderFrame

BuilderPad = Instance.new("UIPadding")
BuilderPad.PaddingTop = UDim.new(0, 5)
BuilderPad.PaddingLeft = UDim.new(0, 5)
BuilderPad.PaddingRight = UDim.new(0, 5)
BuilderPad.Parent = BuilderFrame

SaveComboButton = Instance.new("TextButton")
SaveComboButton.Size = UDim2.new(0.5, -18, 0, 32)
SaveComboButton.Position = UDim2.fromOffset(14, 258)
SaveComboButton.BackgroundColor3 = Color3.fromRGB(50, 94, 155)
SaveComboButton.Text = "Save Combo"
SaveComboButton.TextColor3 = Color3.new(1, 1, 1)
SaveComboButton.TextSize = 11
SaveComboButton.Font = Enum.Font.GothamBold
SaveComboButton.Parent = RollPage
makeCorner(SaveComboButton, 6)

ClearBuilderButton = Instance.new("TextButton")
ClearBuilderButton.Size = UDim2.new(0.5, -18, 0, 32)
ClearBuilderButton.Position = UDim2.new(0.5, 4, 0, 258)
ClearBuilderButton.BackgroundColor3 = Color3.fromRGB(80, 60, 60)
ClearBuilderButton.Text = "Clear Builder"
ClearBuilderButton.TextColor3 = Color3.new(1, 1, 1)
ClearBuilderButton.TextSize = 11
ClearBuilderButton.Font = Enum.Font.GothamBold
ClearBuilderButton.Parent = RollPage
makeCorner(ClearBuilderButton, 6)

CombosTitle = Instance.new("TextLabel")
CombosTitle.Size = UDim2.new(1, -28, 0, 18)
CombosTitle.Position = UDim2.fromOffset(14, 300)
CombosTitle.BackgroundTransparency = 1
CombosTitle.Text = "Saved Combos — Auto Roll stops when ANY one combo matches"
CombosTitle.TextColor3 = Color3.fromRGB(175, 175, 185)
CombosTitle.TextSize = 10
CombosTitle.Font = Enum.Font.Gotham
CombosTitle.TextXAlignment = Enum.TextXAlignment.Left
CombosTitle.Parent = RollPage

ComboFrame = Instance.new("ScrollingFrame")
ComboFrame.Size = UDim2.new(1, -28, 0, 120)
ComboFrame.Position = UDim2.fromOffset(14, 322)
ComboFrame.BackgroundColor3 = Color3.fromRGB(29, 29, 35)
ComboFrame.BorderSizePixel = 0
ComboFrame.ScrollBarThickness = 4
ComboFrame.CanvasSize = UDim2.fromOffset(0, 0)
ComboFrame.Parent = RollPage
makeCorner(ComboFrame, 7)

ComboLayout = Instance.new("UIListLayout")
ComboLayout.Padding = UDim.new(0, 4)
ComboLayout.Parent = ComboFrame

ComboPad = Instance.new("UIPadding")
ComboPad.PaddingTop = UDim.new(0, 5)
ComboPad.PaddingLeft = UDim.new(0, 5)
ComboPad.PaddingRight = UDim.new(0, 5)
ComboPad.Parent = ComboFrame

function rebuildComboBuilder()
    for _, child in ipairs(BuilderFrame:GetChildren()) do
        if child:IsA("Frame") then
            child:Destroy()
        end
    end

    local ordered = {}

    for id, levels in pairs(ComboBuilder) do
        ordered[#ordered + 1] = {Id=id, Levels=levels}
    end

    table.sort(ordered, function(a,b)
        return displayEnchantName(a.Id) < displayEnchantName(b.Id)
    end)

    for _, entry in ipairs(ordered) do
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, -3, 0, 29)
        row.BackgroundColor3 = Color3.fromRGB(38, 38, 45)
        row.Parent = BuilderFrame
        makeCorner(row, 5)

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, -40, 1, 0)
        label.Position = UDim2.fromOffset(9, 0)
        label.BackgroundTransparency = 1
        label.Text =
            displayEnchantName(entry.Id)
            .. "  ["
            .. levelsToText(entry.Levels, entry.Id)
            .. "]"
        label.TextColor3 = Color3.fromRGB(235, 235, 240)
        label.TextSize = 10
        label.Font = Enum.Font.Gotham
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = row

        local remove = Instance.new("TextButton")
        remove.Size = UDim2.fromOffset(25, 22)
        remove.Position = UDim2.new(1, -29, 0.5, -11)
        remove.BackgroundColor3 = Color3.fromRGB(110, 48, 48)
        remove.Text = "×"
        remove.TextColor3 = Color3.new(1, 1, 1)
        remove.TextSize = 14
        remove.Font = Enum.Font.GothamBold
        remove.Parent = row
        makeCorner(remove, 5)

        remove.MouseButton1Click:Connect(function()
            ComboBuilder[entry.Id] = nil
            saveConfig()
            rebuildComboBuilder()
        end)
    end

    task.defer(function()
        BuilderFrame.CanvasSize =
            UDim2.fromOffset(0, BuilderLayout.AbsoluteContentSize.Y + 10)
    end)
end

function rebuildCombos()
    for _, child in ipairs(ComboFrame:GetChildren()) do
        if child:IsA("Frame") then
            child:Destroy()
        end
    end

    for index, combo in ipairs(Combos) do
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, -3, 0, 42)
        row.BackgroundColor3 = Color3.fromRGB(38, 38, 45)
        row.Parent = ComboFrame
        makeCorner(row, 5)

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, -43, 1, 0)
        label.Position = UDim2.fromOffset(9, 0)
        label.BackgroundTransparency = 1
        label.Text = "Combo " .. index .. ": " .. comboToText(combo)
        label.TextColor3 = Color3.fromRGB(235, 235, 240)
        label.TextSize = 9
        label.Font = Enum.Font.Gotham
        label.TextWrapped = true
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = row

        local remove = Instance.new("TextButton")
        remove.Size = UDim2.fromOffset(25, 22)
        remove.Position = UDim2.new(1, -29, 0.5, -11)
        remove.BackgroundColor3 = Color3.fromRGB(110, 48, 48)
        remove.Text = "×"
        remove.TextColor3 = Color3.new(1, 1, 1)
        remove.TextSize = 14
        remove.Font = Enum.Font.GothamBold
        remove.Parent = row
        makeCorner(remove, 5)

        remove.MouseButton1Click:Connect(function()
            table.remove(Combos, index)
            saveConfig()
            rebuildCombos()
        end)
    end

    task.defer(function()
        ComboFrame.CanvasSize =
            UDim2.fromOffset(0, ComboLayout.AbsoluteContentSize.Y + 10)
    end)
end

AddRequirement.MouseButton1Click:Connect(function()
    EnchantPopup.Visible = false
    LevelPopup.Visible = false

    local info = EnchantInfo[SelectedEnchant]

    if not info or selectedLevelCount() == 0 then
        return
    end

    local cleaned = {}

    for tier = 1, info.MaxTier do
        if SelectedLevels[tier] then
            cleaned[tier] = true
        end
    end

    if not next(cleaned) then
        cleaned[info.MaxTier] = true
    end

    ComboBuilder[info.Internal] = cloneLevelSet(cleaned)
    saveConfig()
    rebuildComboBuilder()
end)

SaveComboButton.MouseButton1Click:Connect(function()
    if comboRequirementCount(ComboBuilder) == 0 then
        return
    end

    Combos[#Combos + 1] = cloneCombo(ComboBuilder)
    ComboBuilder = {}
    saveConfig()
    rebuildComboBuilder()
    rebuildCombos()
end)

ClearBuilderButton.MouseButton1Click:Connect(function()
    ComboBuilder = {}
    saveConfig()
    rebuildComboBuilder()
end)

CurrentLabel = Instance.new("TextLabel")
CurrentLabel.Size = UDim2.new(1, -28, 0, 42)
CurrentLabel.Position = UDim2.fromOffset(14, 452)
CurrentLabel.BackgroundColor3 = Color3.fromRGB(29, 29, 35)
CurrentLabel.Text = "Current enchants: -"
CurrentLabel.TextColor3 = Color3.fromRGB(195, 195, 205)
CurrentLabel.TextSize = 10
CurrentLabel.Font = Enum.Font.Gotham
CurrentLabel.TextWrapped = true
CurrentLabel.Parent = RollPage
makeCorner(CurrentLabel, 7)

Status = Instance.new("TextLabel")
Status.Size = UDim2.new(1, -28, 0, 60)
Status.Position = UDim2.fromOffset(14, 504)
Status.BackgroundColor3 = Color3.fromRGB(29, 29, 35)
Status.Text = "Ready"
Status.TextColor3 = Color3.fromRGB(190, 190, 200)
Status.TextSize = 10
Status.Font = Enum.Font.Gotham
Status.TextWrapped = true
Status.Parent = RollPage
makeCorner(Status, 7)

Toggle = Instance.new("TextButton")
Toggle.Size = UDim2.new(1, -28, 0, 46)
Toggle.Position = UDim2.fromOffset(14, 574)
Toggle.BackgroundColor3 = Color3.fromRGB(125, 48, 48)
Toggle.Text = "AUTO ROLL: OFF"
Toggle.TextColor3 = Color3.new(1, 1, 1)
Toggle.TextSize = 14
Toggle.Font = Enum.Font.GothamBold
Toggle.Parent = RollPage
makeCorner(Toggle, 7)

function updateToggle()
    if AutoRolling then
        Toggle.Text = "AUTO ROLL: ON"
        Toggle.BackgroundColor3 = Color3.fromRGB(45, 125, 70)
    else
        Toggle.Text = "AUTO ROLL: OFF"
        Toggle.BackgroundColor3 = Color3.fromRGB(125, 48, 48)
    end
end

--==============================================================
-- AUTO FARM PAGE
--==============================================================

HeliumTitle = Instance.new("TextLabel")
HeliumTitle.Size = UDim2.new(1, -160, 0, 27)
HeliumTitle.Position = UDim2.fromOffset(14, 8)
HeliumTitle.BackgroundTransparency = 1
HeliumTitle.Text = "Helium-3 Gem: ..."
HeliumTitle.TextColor3 = Color3.fromRGB(235, 235, 240)
HeliumTitle.TextSize = 14
HeliumTitle.Font = Enum.Font.GothamBold
HeliumTitle.TextXAlignment = Enum.TextXAlignment.Left
HeliumTitle.Parent = FarmPage

FarmToggle = Instance.new("TextButton")
FarmToggle.Size = UDim2.fromOffset(125, 28)
FarmToggle.Position = UDim2.new(1, -139, 0, 7)
FarmToggle.TextSize = 10
FarmToggle.Font = Enum.Font.GothamBold
FarmToggle.TextColor3 = Color3.new(1, 1, 1)
FarmToggle.Parent = FarmPage
makeCorner(FarmToggle, 5)

function updateFarmToggle()
    if AutoFarmEnabled then
        FarmToggle.Text = "AUTO FARM: ON"
        FarmToggle.BackgroundColor3 = Color3.fromRGB(45, 120, 70)
    else
        FarmToggle.Text = "AUTO FARM: OFF"
        FarmToggle.BackgroundColor3 = Color3.fromRGB(110, 50, 50)
    end
end

FarmPickaxeLabel = Instance.new("TextLabel")
FarmPickaxeLabel.Size = UDim2.new(1, -28, 0, 16)
FarmPickaxeLabel.Position = UDim2.fromOffset(14, 43)
FarmPickaxeLabel.BackgroundTransparency = 1
FarmPickaxeLabel.Text = "Farm Pickaxe"
FarmPickaxeLabel.TextColor3 = Color3.fromRGB(175, 175, 190)
FarmPickaxeLabel.TextSize = 10
FarmPickaxeLabel.Font = Enum.Font.Gotham
FarmPickaxeLabel.TextXAlignment = Enum.TextXAlignment.Left
FarmPickaxeLabel.Parent = FarmPage

FarmPickaxeButton = Instance.new("TextButton")
FarmPickaxeButton.Size = UDim2.new(1, -28, 0, 58)
FarmPickaxeButton.Position = UDim2.fromOffset(14, 61)
FarmPickaxeButton.BackgroundColor3 = Color3.fromRGB(37, 37, 44)
FarmPickaxeButton.Text = ""
FarmPickaxeButton.AutoButtonColor = false
FarmPickaxeButton.Parent = FarmPage
makeCorner(FarmPickaxeButton, 6)

FarmPickaxeName = Instance.new("TextLabel")
FarmPickaxeName.Size = UDim2.new(1, -32, 0, 20)
FarmPickaxeName.Position = UDim2.fromOffset(9, 5)
FarmPickaxeName.BackgroundTransparency = 1
FarmPickaxeName.Text = "Select farm pickaxe"
FarmPickaxeName.TextColor3 = Color3.fromRGB(235, 235, 240)
FarmPickaxeName.TextSize = 12
FarmPickaxeName.Font = Enum.Font.GothamBold
FarmPickaxeName.TextXAlignment = Enum.TextXAlignment.Left
FarmPickaxeName.Parent = FarmPickaxeButton

FarmPickaxeUUIDLabel = Instance.new("TextLabel")
FarmPickaxeUUIDLabel.Size = UDim2.new(1, -32, 0, 13)
FarmPickaxeUUIDLabel.Position = UDim2.fromOffset(9, 25)
FarmPickaxeUUIDLabel.BackgroundTransparency = 1
FarmPickaxeUUIDLabel.Text = "UUID: -"
FarmPickaxeUUIDLabel.TextColor3 = Color3.fromRGB(130, 130, 145)
FarmPickaxeUUIDLabel.TextSize = 8
FarmPickaxeUUIDLabel.Font = Enum.Font.Gotham
FarmPickaxeUUIDLabel.TextXAlignment = Enum.TextXAlignment.Left
FarmPickaxeUUIDLabel.Parent = FarmPickaxeButton

FarmPickaxeEnchantLabel = Instance.new("TextLabel")
FarmPickaxeEnchantLabel.Size = UDim2.new(1, -32, 0, 16)
FarmPickaxeEnchantLabel.Position = UDim2.fromOffset(9, 39)
FarmPickaxeEnchantLabel.BackgroundTransparency = 1
FarmPickaxeEnchantLabel.Text = "Enchants: -"
FarmPickaxeEnchantLabel.TextColor3 = Color3.fromRGB(180, 180, 195)
FarmPickaxeEnchantLabel.TextSize = 9
FarmPickaxeEnchantLabel.Font = Enum.Font.Gotham
FarmPickaxeEnchantLabel.TextXAlignment = Enum.TextXAlignment.Left
FarmPickaxeEnchantLabel.TextTruncate = Enum.TextTruncate.AtEnd
FarmPickaxeEnchantLabel.Parent = FarmPickaxeButton

FarmPickaxeArrow = Instance.new("TextLabel")
FarmPickaxeArrow.Size = UDim2.fromOffset(22, 58)
FarmPickaxeArrow.Position = UDim2.new(1, -25, 0, 0)
FarmPickaxeArrow.BackgroundTransparency = 1
FarmPickaxeArrow.Text = "▼"
FarmPickaxeArrow.TextColor3 = Color3.fromRGB(185, 185, 195)
FarmPickaxeArrow.TextSize = 10
FarmPickaxeArrow.Font = Enum.Font.GothamBold
FarmPickaxeArrow.Parent = FarmPickaxeButton

FarmPickaxePopup = Instance.new("ScrollingFrame")
FarmPickaxePopup.Size = UDim2.new(1, -28, 0, 210)
FarmPickaxePopup.Position = UDim2.fromOffset(14, 166)
FarmPickaxePopup.BackgroundColor3 = Color3.fromRGB(27, 27, 33)
FarmPickaxePopup.BorderSizePixel = 0
FarmPickaxePopup.ScrollBarThickness = 4
FarmPickaxePopup.CanvasSize = UDim2.fromOffset(0, 0)
FarmPickaxePopup.Visible = false
FarmPickaxePopup.ZIndex = 540
FarmPickaxePopup.Parent = Main
makeCorner(FarmPickaxePopup, 7)

FarmPickaxePopupStroke = Instance.new("UIStroke")
FarmPickaxePopupStroke.Color = Color3.fromRGB(68, 68, 80)
FarmPickaxePopupStroke.Thickness = 1
FarmPickaxePopupStroke.Parent = FarmPickaxePopup

FarmPickaxeLayout = Instance.new("UIListLayout")
FarmPickaxeLayout.Padding = UDim.new(0, 5)
FarmPickaxeLayout.Parent = FarmPickaxePopup

FarmPickaxePadding = Instance.new("UIPadding")
FarmPickaxePadding.PaddingTop = UDim.new(0, 5)
FarmPickaxePadding.PaddingLeft = UDim.new(0, 5)
FarmPickaxePadding.PaddingRight = UDim.new(0, 5)
FarmPickaxePadding.Parent = FarmPickaxePopup

function refreshFarmPickaxeCard()
    local selected = getFarmPickaxe()

    if not selected then
        FarmPickaxeName.Text = "Select farm pickaxe"
        FarmPickaxeUUIDLabel.Text = "UUID: -"
        FarmPickaxeEnchantLabel.Text = "Enchants: -"
        return
    end

    FarmPickaxeName.Text = selected.Name
    FarmPickaxeUUIDLabel.Text = "UUID: " .. selected.UUID
    FarmPickaxeEnchantLabel.Text =
        "Enchants: "
        .. currentEnchantsText(selected.UUID)
end

function rebuildFarmPickaxePopup()
    for _, child in ipairs(FarmPickaxePopup:GetChildren()) do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end

    for _, info in ipairs(getAllPickaxes()) do
        local row = Instance.new("TextButton")
        row.Size = UDim2.new(1, -4, 0, 62)
        row.BackgroundColor3 =
            info.UUID == FarmPickaxeUUID
            and Color3.fromRGB(46, 82, 60)
            or Color3.fromRGB(38, 38, 45)
        row.Text = ""
        row.AutoButtonColor = false
        row.ZIndex = 541
        row.Parent = FarmPickaxePopup
        makeCorner(row, 6)

        local name = Instance.new("TextLabel")
        name.Size = UDim2.new(1, -12, 0, 19)
        name.Position = UDim2.fromOffset(8, 5)
        name.BackgroundTransparency = 1
        name.Text = info.Name
        name.TextColor3 = Color3.fromRGB(238, 238, 243)
        name.TextSize = 12
        name.Font = Enum.Font.GothamBold
        name.TextXAlignment = Enum.TextXAlignment.Left
        name.ZIndex = 542
        name.Parent = row

        local uuid = Instance.new("TextLabel")
        uuid.Size = UDim2.new(1, -12, 0, 13)
        uuid.Position = UDim2.fromOffset(8, 24)
        uuid.BackgroundTransparency = 1
        uuid.Text = info.UUID
        uuid.TextColor3 = Color3.fromRGB(130, 130, 145)
        uuid.TextSize = 8
        uuid.Font = Enum.Font.Gotham
        uuid.TextXAlignment = Enum.TextXAlignment.Left
        uuid.ZIndex = 542
        uuid.Parent = row

        local enchants = Instance.new("TextLabel")
        enchants.Size = UDim2.new(1, -12, 0, 17)
        enchants.Position = UDim2.fromOffset(8, 40)
        enchants.BackgroundTransparency = 1
        enchants.Text = "Enchants: " .. currentEnchantsText(info.UUID)
        enchants.TextColor3 = Color3.fromRGB(180, 180, 195)
        enchants.TextSize = 9
        enchants.Font = Enum.Font.Gotham
        enchants.TextXAlignment = Enum.TextXAlignment.Left
        enchants.TextTruncate = Enum.TextTruncate.AtEnd
        enchants.ZIndex = 542
        enchants.Parent = row

        row.MouseButton1Click:Connect(function()
            if FarmingForHelium then
                return
            end

            FarmPickaxeUUID = info.UUID
            FarmPickaxePopup.Visible = false

            saveConfig()
            refreshFarmPickaxeCard()
        end)
    end

    task.defer(function()
        FarmPickaxePopup.CanvasSize =
            UDim2.fromOffset(
                0,
                FarmPickaxeLayout.AbsoluteContentSize.Y + 10
            )
    end)
end

FarmPickaxeButton.MouseButton1Click:Connect(function()
    PageMenu.Visible = false
    PickaxePopup.Visible = false
    EnchantPopup.Visible = false
    LevelPopup.Visible = false

    rebuildFarmPickaxePopup()
    FarmPickaxePopup.Visible = not FarmPickaxePopup.Visible
end)

if not getFarmPickaxe() then
    if getSelectedPickaxe() then
        FarmPickaxeUUID = SelectedPickaxeUUID
    else
        local firstFarm = getAllPickaxes()[1]

        if firstFarm then
            FarmPickaxeUUID = firstFarm.UUID
        end
    end

    saveConfig()
end

refreshFarmPickaxeCard()

StartLabel = Instance.new("TextLabel")
StartLabel.Size = UDim2.fromOffset(155, 23)
StartLabel.Position = UDim2.fromOffset(14, 133)
StartLabel.BackgroundTransparency = 1
StartLabel.Text = "Start mine if under:"
StartLabel.TextColor3 = Color3.fromRGB(180, 180, 195)
StartLabel.TextSize = 10
StartLabel.Font = Enum.Font.Gotham
StartLabel.TextXAlignment = Enum.TextXAlignment.Left
StartLabel.Parent = FarmPage

StartBox = Instance.new("TextBox")
StartBox.Size = UDim2.fromOffset(105, 25)
StartBox.Position = UDim2.fromOffset(175, 132)
StartBox.BackgroundColor3 = Color3.fromRGB(39, 39, 46)
StartBox.Text = tostring(FarmStartBelow)
StartBox.PlaceholderText = "100"
StartBox.ClearTextOnFocus = false
StartBox.TextColor3 = Color3.fromRGB(235, 235, 240)
StartBox.TextSize = 11
StartBox.Font = Enum.Font.Gotham
StartBox.Parent = FarmPage
makeCorner(StartBox, 5)

StopLabel = Instance.new("TextLabel")
StopLabel.Size = UDim2.fromOffset(155, 23)
StopLabel.Position = UDim2.fromOffset(14, 165)
StopLabel.BackgroundTransparency = 1
StopLabel.Text = "Stop mine when at:"
StopLabel.TextColor3 = Color3.fromRGB(180, 180, 195)
StopLabel.TextSize = 10
StopLabel.Font = Enum.Font.Gotham
StopLabel.TextXAlignment = Enum.TextXAlignment.Left
StopLabel.Parent = FarmPage

StopBox = Instance.new("TextBox")
StopBox.Size = UDim2.fromOffset(105, 25)
StopBox.Position = UDim2.fromOffset(175, 164)
StopBox.BackgroundColor3 = Color3.fromRGB(39, 39, 46)
StopBox.Text = tostring(FarmStopAt)
StopBox.PlaceholderText = "500"
StopBox.ClearTextOnFocus = false
StopBox.TextColor3 = Color3.fromRGB(235, 235, 240)
StopBox.TextSize = 11
StopBox.Font = Enum.Font.Gotham
StopBox.Parent = FarmPage
makeCorner(StopBox, 5)

FarmStateLabel = Instance.new("TextLabel")
FarmStateLabel.Size = UDim2.new(1, -28, 0, 50)
FarmStateLabel.Position = UDim2.fromOffset(14, 203)
FarmStateLabel.BackgroundColor3 = Color3.fromRGB(29, 29, 35)
FarmStateLabel.Text = "Farm: idle"
FarmStateLabel.TextColor3 = Color3.fromRGB(170, 170, 185)
FarmStateLabel.TextSize = 10
FarmStateLabel.TextWrapped = true
FarmStateLabel.Font = Enum.Font.Gotham
FarmStateLabel.Parent = FarmPage
makeCorner(FarmStateLabel, 7)

TestMineButton = Instance.new("TextButton")
TestMineButton.Size = UDim2.new(0.5, -20, 0, 34)
TestMineButton.Position = UDim2.fromOffset(14, 264)
TestMineButton.BackgroundColor3 = Color3.fromRGB(42, 42, 48)
TestMineButton.Text = "Test Auto Mine"
TestMineButton.TextColor3 = Color3.fromRGB(235, 235, 240)
TestMineButton.TextSize = 10
TestMineButton.Font = Enum.Font.GothamBold
TestMineButton.Parent = FarmPage
makeCorner(TestMineButton, 6)

ForceMineOffButton = Instance.new("TextButton")
ForceMineOffButton.Size = UDim2.new(0.5, -20, 0, 34)
ForceMineOffButton.Position = UDim2.new(0.5, 6, 0, 264)
ForceMineOffButton.BackgroundColor3 = Color3.fromRGB(88, 48, 48)
ForceMineOffButton.Text = "Force Auto Mine OFF"
ForceMineOffButton.TextColor3 = Color3.fromRGB(235, 235, 240)
ForceMineOffButton.TextSize = 10
ForceMineOffButton.Font = Enum.Font.GothamBold
ForceMineOffButton.Parent = FarmPage
makeCorner(ForceMineOffButton, 6)

function commitFarmThresholds()
    local startValue = tonumber(StartBox.Text)
    local stopValue = tonumber(StopBox.Text)

    if startValue then
        FarmStartBelow = math.max(0, math.floor(startValue))
    end

    if stopValue then
        FarmStopAt = math.max(0, math.floor(stopValue))
    end

    if FarmStopAt < FarmStartBelow then
        FarmStopAt = FarmStartBelow
    end

    StartBox.Text = tostring(FarmStartBelow)
    StopBox.Text = tostring(FarmStopAt)

    saveConfig()
end

StartBox.FocusLost:Connect(commitFarmThresholds)
StopBox.FocusLost:Connect(commitFarmThresholds)

FarmToggle.MouseButton1Click:Connect(function()
    AutoFarmEnabled = not AutoFarmEnabled

    if not AutoFarmEnabled and FarmingForHelium then
        local ok, reason = setAutoMine(false)

        FarmingForHelium = false

        if ok then
            FarmStateLabel.Text = "Farm disabled; Auto Mine OFF"
        else
            FarmStateLabel.Text = "Farm disabled; " .. tostring(reason)
        end
    end

    updateFarmToggle()
    saveConfig()
end)

TestMineButton.MouseButton1Click:Connect(function()
    local ok, reason = setAutoMine(true)

    if ok then
        FarmStateLabel.Text = "Auto Mine test: ON request sent"
    else
        FarmStateLabel.Text = "Auto Mine test failed: " .. tostring(reason)
    end
end)

ForceMineOffButton.MouseButton1Click:Connect(function()
    local ok, reason = setAutoMine(false)
    FarmingForHelium = false

    if ok then
        FarmStateLabel.Text = "Auto Mine forced OFF"
    else
        FarmStateLabel.Text = "Force OFF failed: " .. tostring(reason)
    end
end)

updateFarmToggle()
--==============================================================
-- MISC PAGE
-- Kept inside a builder function to avoid Luau's 200-local limit.
--==============================================================

local MiscUI = {}

local function buildMiscPage()
    local m = MiscUI

    m.Title = Instance.new("TextLabel")
    m.Title.Size = UDim2.new(1, -28, 0, 28)
    m.Title.Position = UDim2.fromOffset(14, 8)
    m.Title.BackgroundTransparency = 1
    m.Title.Text = "Webhook"
    m.Title.TextColor3 = Color3.fromRGB(235, 235, 240)
    m.Title.TextSize = 15
    m.Title.Font = Enum.Font.GothamBold
    m.Title.TextXAlignment = Enum.TextXAlignment.Left
    m.Title.Parent = MiscPage

    m.WebhookToggle = Instance.new("TextButton")
    m.WebhookToggle.Size = UDim2.fromOffset(125, 28)
    m.WebhookToggle.Position = UDim2.new(1, -139, 0, 7)
    m.WebhookToggle.TextSize = 10
    m.WebhookToggle.Font = Enum.Font.GothamBold
    m.WebhookToggle.TextColor3 = Color3.new(1, 1, 1)
    m.WebhookToggle.Parent = MiscPage
    makeCorner(m.WebhookToggle, 5)

    m.UrlLabel = Instance.new("TextLabel")
    m.UrlLabel.Size = UDim2.new(1, -28, 0, 16)
    m.UrlLabel.Position = UDim2.fromOffset(14, 49)
    m.UrlLabel.BackgroundTransparency = 1
    m.UrlLabel.Text = "Webhook URL"
    m.UrlLabel.TextColor3 = Color3.fromRGB(175, 175, 190)
    m.UrlLabel.TextSize = 10
    m.UrlLabel.Font = Enum.Font.Gotham
    m.UrlLabel.TextXAlignment = Enum.TextXAlignment.Left
    m.UrlLabel.Parent = MiscPage

    m.UrlBox = Instance.new("TextBox")
    m.UrlBox.Size = UDim2.new(1, -28, 0, 34)
    m.UrlBox.Position = UDim2.fromOffset(14, 68)
    m.UrlBox.BackgroundColor3 = Color3.fromRGB(39, 39, 46)
    m.UrlBox.Text = WebhookUrl
    m.UrlBox.PlaceholderText = "https://discord.com/api/webhooks/..."
    m.UrlBox.ClearTextOnFocus = false
    m.UrlBox.TextColor3 = Color3.fromRGB(235, 235, 240)
    m.UrlBox.TextSize = 10
    m.UrlBox.Font = Enum.Font.Gotham
    m.UrlBox.TextXAlignment = Enum.TextXAlignment.Left
    m.UrlBox.Parent = MiscPage
    makeCorner(m.UrlBox, 5)

    m.UserLabel = Instance.new("TextLabel")
    m.UserLabel.Size = UDim2.new(1, -180, 0, 16)
    m.UserLabel.Position = UDim2.fromOffset(14, 116)
    m.UserLabel.BackgroundTransparency = 1
    m.UserLabel.Text = "Discord User ID for @ mention"
    m.UserLabel.TextColor3 = Color3.fromRGB(175, 175, 190)
    m.UserLabel.TextSize = 10
    m.UserLabel.Font = Enum.Font.Gotham
    m.UserLabel.TextXAlignment = Enum.TextXAlignment.Left
    m.UserLabel.Parent = MiscPage

    m.MentionToggle = Instance.new("TextButton")
    m.MentionToggle.Size = UDim2.fromOffset(125, 27)
    m.MentionToggle.Position = UDim2.new(1, -139, 0, 110)
    m.MentionToggle.TextSize = 10
    m.MentionToggle.Font = Enum.Font.GothamBold
    m.MentionToggle.TextColor3 = Color3.new(1, 1, 1)
    m.MentionToggle.Parent = MiscPage
    makeCorner(m.MentionToggle, 5)

    m.UserBox = Instance.new("TextBox")
    m.UserBox.Size = UDim2.new(1, -28, 0, 34)
    m.UserBox.Position = UDim2.fromOffset(14, 143)
    m.UserBox.BackgroundColor3 = Color3.fromRGB(39, 39, 46)
    m.UserBox.Text = WebhookUserId
    m.UserBox.PlaceholderText = "Discord user ID"
    m.UserBox.ClearTextOnFocus = false
    m.UserBox.TextColor3 = Color3.fromRGB(235, 235, 240)
    m.UserBox.TextSize = 10
    m.UserBox.Font = Enum.Font.Gotham
    m.UserBox.TextXAlignment = Enum.TextXAlignment.Left
    m.UserBox.Parent = MiscPage
    makeCorner(m.UserBox, 5)

    m.Preview = Instance.new("TextLabel")
    m.Preview.Size = UDim2.new(1, -28, 0, 58)
    m.Preview.Position = UDim2.fromOffset(14, 191)
    m.Preview.BackgroundColor3 = Color3.fromRGB(29, 29, 35)
    m.Preview.Text =
        "Message includes: Account ||"
        .. Player.Name
        .. "||, pickaxe name, current enchants, matched combo"
    m.Preview.TextColor3 = Color3.fromRGB(175, 175, 190)
    m.Preview.TextSize = 10
    m.Preview.Font = Enum.Font.Gotham
    m.Preview.TextWrapped = true
    m.Preview.Parent = MiscPage
    makeCorner(m.Preview, 7)

    m.TestWebhook = Instance.new("TextButton")
    m.TestWebhook.Size = UDim2.new(1, -28, 0, 34)
    m.TestWebhook.Position = UDim2.fromOffset(14, 262)
    m.TestWebhook.BackgroundColor3 = Color3.fromRGB(50, 94, 155)
    m.TestWebhook.Text = "Test Webhook"
    m.TestWebhook.TextColor3 = Color3.new(1, 1, 1)
    m.TestWebhook.TextSize = 11
    m.TestWebhook.Font = Enum.Font.GothamBold
    m.TestWebhook.Parent = MiscPage
    makeCorner(m.TestWebhook, 6)

    m.WebhookStatus = Instance.new("TextLabel")
    m.WebhookStatus.Size = UDim2.new(1, -28, 0, 50)
    m.WebhookStatus.Position = UDim2.fromOffset(14, 309)
    m.WebhookStatus.BackgroundColor3 = Color3.fromRGB(29, 29, 35)
    m.WebhookStatus.Text = "Webhook: idle"
    m.WebhookStatus.TextColor3 = Color3.fromRGB(175, 175, 190)
    m.WebhookStatus.TextSize = 10
    m.WebhookStatus.Font = Enum.Font.Gotham
    m.WebhookStatus.TextWrapped = true
    m.WebhookStatus.Parent = MiscPage
    makeCorner(m.WebhookStatus, 7)

    m.ConfigTitle = Instance.new("TextLabel")
    m.ConfigTitle.Size = UDim2.new(1, -28, 0, 20)
    m.ConfigTitle.Position = UDim2.fromOffset(14, 375)
    m.ConfigTitle.BackgroundTransparency = 1
    m.ConfigTitle.Text = "Config Export / Import"
    m.ConfigTitle.TextColor3 = Color3.fromRGB(235, 235, 240)
    m.ConfigTitle.TextSize = 13
    m.ConfigTitle.Font = Enum.Font.GothamBold
    m.ConfigTitle.TextXAlignment = Enum.TextXAlignment.Left
    m.ConfigTitle.Parent = MiscPage

    m.Export = Instance.new("TextButton")
    m.Export.Size = UDim2.new(0.5, -18, 0, 34)
    m.Export.Position = UDim2.fromOffset(14, 402)
    m.Export.BackgroundColor3 = Color3.fromRGB(50, 94, 155)
    m.Export.Text = "Export Config"
    m.Export.TextColor3 = Color3.new(1, 1, 1)
    m.Export.TextSize = 11
    m.Export.Font = Enum.Font.GothamBold
    m.Export.Parent = MiscPage
    makeCorner(m.Export, 6)

    m.Import = Instance.new("TextButton")
    m.Import.Size = UDim2.new(0.5, -18, 0, 34)
    m.Import.Position = UDim2.new(0.5, 4, 0, 402)
    m.Import.BackgroundColor3 = Color3.fromRGB(52, 105, 72)
    m.Import.Text = "Import Config"
    m.Import.TextColor3 = Color3.new(1, 1, 1)
    m.Import.TextSize = 11
    m.Import.Font = Enum.Font.GothamBold
    m.Import.Parent = MiscPage
    makeCorner(m.Import, 6)

    m.ImportBox = Instance.new("TextBox")
    m.ImportBox.Size = UDim2.new(1, -28, 0, 100)
    m.ImportBox.Position = UDim2.fromOffset(14, 447)
    m.ImportBox.BackgroundColor3 = Color3.fromRGB(29, 29, 35)
    m.ImportBox.Text = ""
    m.ImportBox.PlaceholderText = "Paste exported JSON here..."
    m.ImportBox.ClearTextOnFocus = false
    m.ImportBox.MultiLine = true
    m.ImportBox.TextWrapped = true
    m.ImportBox.TextXAlignment = Enum.TextXAlignment.Left
    m.ImportBox.TextYAlignment = Enum.TextYAlignment.Top
    m.ImportBox.TextColor3 = Color3.fromRGB(225, 225, 235)
    m.ImportBox.TextSize = 9
    m.ImportBox.Font = Enum.Font.Code
    m.ImportBox.Parent = MiscPage
    makeCorner(m.ImportBox, 6)

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 7)
    padding.PaddingBottom = UDim.new(0, 7)
    padding.PaddingLeft = UDim.new(0, 7)
    padding.PaddingRight = UDim.new(0, 7)
    padding.Parent = m.ImportBox

    m.ConfigStatus = Instance.new("TextLabel")
    m.ConfigStatus.Size = UDim2.new(1, -28, 0, 48)
    m.ConfigStatus.Position = UDim2.fromOffset(14, 558)
    m.ConfigStatus.BackgroundColor3 = Color3.fromRGB(29, 29, 35)
    m.ConfigStatus.Text =
        "Export copies JSON to clipboard. Paste JSON here on another account to import."
    m.ConfigStatus.TextColor3 = Color3.fromRGB(175, 175, 190)
    m.ConfigStatus.TextSize = 9
    m.ConfigStatus.Font = Enum.Font.Gotham
    m.ConfigStatus.TextWrapped = true
    m.ConfigStatus.Parent = MiscPage
    makeCorner(m.ConfigStatus, 7)

    local function updateWebhookToggle()
        if WebhookEnabled then
            m.WebhookToggle.Text = "WEBHOOK: ON"
            m.WebhookToggle.BackgroundColor3 = Color3.fromRGB(45, 120, 70)
        else
            m.WebhookToggle.Text = "WEBHOOK: OFF"
            m.WebhookToggle.BackgroundColor3 = Color3.fromRGB(110, 50, 50)
        end
    end

    local function updateMentionToggle()
        if WebhookMentionEnabled then
            m.MentionToggle.Text = "@ USER: ON"
            m.MentionToggle.BackgroundColor3 = Color3.fromRGB(45, 120, 70)
        else
            m.MentionToggle.Text = "@ USER: OFF"
            m.MentionToggle.BackgroundColor3 = Color3.fromRGB(110, 50, 50)
        end
    end

    local function refreshImportedUI()
        EnchantButton.Text = SelectedEnchant .. "  ▼"
        updateLevelText()

        StartBox.Text = tostring(FarmStartBelow)
        StopBox.Text = tostring(FarmStopAt)

        m.UrlBox.Text = WebhookUrl
        m.UserBox.Text = WebhookUserId

        updateFarmToggle()
        updateWebhookToggle()
        updateMentionToggle()

        rebuildComboBuilder()
        rebuildCombos()

        refreshSelectedPickaxeCard()
        refreshFarmPickaxeCard()
        updateCurrentDisplay()
    end

    m.WebhookToggle.MouseButton1Click:Connect(function()
        WebhookEnabled = not WebhookEnabled
        updateWebhookToggle()
        saveConfig()
    end)

    m.MentionToggle.MouseButton1Click:Connect(function()
        WebhookMentionEnabled = not WebhookMentionEnabled
        updateMentionToggle()
        saveConfig()
    end)

    m.UrlBox.FocusLost:Connect(function()
        WebhookUrl = m.UrlBox.Text
        saveConfig()
    end)

    m.UserBox.FocusLost:Connect(function()
        WebhookUserId = m.UserBox.Text:gsub("%D", "")
        m.UserBox.Text = WebhookUserId
        saveConfig()
    end)

    m.TestWebhook.MouseButton1Click:Connect(function()
        WebhookUrl = m.UrlBox.Text
        WebhookUserId = m.UserBox.Text:gsub("%D", "")
        m.UserBox.Text = WebhookUserId
        saveConfig()

        task.spawn(function()
            local ok, reason =
                sendWebhook(
                    "Webhook Test",
                    nil,
                    nil,
                    true
                )

            if ok then
                m.WebhookStatus.Text = "Webhook test sent"
            else
                m.WebhookStatus.Text =
                    "Webhook failed: "
                    .. tostring(reason)
            end
        end)
    end)

    m.Export.MouseButton1Click:Connect(function()
        WebhookUrl = m.UrlBox.Text
        WebhookUserId = m.UserBox.Text:gsub("%D", "")
        m.UserBox.Text = WebhookUserId
        saveConfig()

        local copied, value = exportPortableConfig()

        if copied then
            m.ConfigStatus.Text = "Config copied to clipboard."
        else
            m.ImportBox.Text = tostring(value or "")
            m.ConfigStatus.Text =
                "Clipboard API unavailable. JSON placed in the box below."
        end
    end)

    m.Import.MouseButton1Click:Connect(function()
        local raw = m.ImportBox.Text

        if raw:gsub("%s+", "") == "" and getclipboard then
            local ok, clip = pcall(getclipboard)

            if ok and typeof(clip) == "string" then
                raw = clip
            end
        end

        local ok, reason = importPortableConfig(raw)

        if ok then
            refreshImportedUI()
            m.ConfigStatus.Text =
                "Config imported and saved for "
                .. Player.Name
                .. "."
        else
            m.ConfigStatus.Text =
                "Import failed: "
                .. tostring(reason)
        end
    end)

    updateWebhookToggle()
    updateMentionToggle()
end

buildMiscPage()

--==============================================================
-- SHARED DISPLAY UPDATE
--==============================================================

local function updateCurrentDisplay()
    refreshSelectedPickaxeCard()
    refreshFarmPickaxeCard()

    if SelectedPickaxeUUID then
        CurrentLabel.Text =
            "Current enchants: "
            .. currentEnchantsText(SelectedPickaxeUUID)
    else
        CurrentLabel.Text = "Current enchants: -"
    end
end

rebuildComboBuilder()
rebuildCombos()
updateCurrentDisplay()
switchPage(SavedActivePage)

--==============================================================
-- FARM STATE MACHINE
--==============================================================

local function updateFarmState()
    local helium = getHeliumAmount()
    LastHeliumAmount = helium

    HeliumTitle.Text =
        HELIUM_ITEM_NAME
        .. ": "
        .. formatNumber(helium)

    if not AutoFarmEnabled then
        if not FarmingForHelium then
            FarmStateLabel.Text = "Farm: disabled"
        end

        return false
    end

    -- Enter farming mode when currency is low.
    if not FarmingForHelium and helium <= FarmStartBelow then
        local equipped, equipReason = equipFarmPickaxe()

        if not equipped then
            FarmingForHelium = false
            FarmStateLabel.Text =
                "Farm pickaxe equip failed: "
                .. tostring(equipReason)

            return false
        end

        local ok, reason = setAutoMine(true)

        if ok then
            FarmingForHelium = true

            local farmPickaxe = getFarmPickaxe()

            FarmStateLabel.Text =
                "Mining with "
                .. (farmPickaxe and farmPickaxe.Name or "farm pickaxe")
                .. " until "
                .. formatNumber(FarmStopAt)
        else
            FarmingForHelium = false
            FarmStateLabel.Text =
                "Auto Mine failed: "
                .. tostring(reason)
        end
    end

    -- Leave farming mode when enough currency is collected.
    if FarmingForHelium and helium >= FarmStopAt then
        local mineOff, mineReason = setAutoMine(false)

        -- Do not let a failed UI click prevent the return teleport.
        FarmingForHelium = false

        local teleported, teleportReason =
            teleportToEnchantMachine()

        if teleported then
            if mineOff then
                FarmStateLabel.Text =
                    "Farm complete; Auto Mine OFF; returned to enchant machine"
            else
                FarmStateLabel.Text =
                    "Farm complete; returned to machine; Auto Mine OFF failed: "
                    .. tostring(mineReason)
            end
        else
            FarmStateLabel.Text =
                "Farm complete; teleport failed: "
                .. tostring(teleportReason)
        end
    end

    return FarmingForHelium
end

--==============================================================
-- AUTO ROLL
--==============================================================

local function rollOnce(uuid)
    local oldFingerprint = enchantFingerprint(uuid)

    local success, result = pcall(function()
        return RollRemote:InvokeServer(
            createRollData(),
            {
                [uuid] = 1
            }
        )
    end)

    if not success then
        Status.Text = "Remote error: " .. tostring(result)
        return false
    end

    local changed = waitForEnchantUpdate(uuid, oldFingerprint)

    if changed then
        recordEnchantChange(uuid)
    end

    updateCurrentDisplay()

    local shouldStop, comboIndex, matched, total, matchedNames =
        checkCombos(uuid)

    if comboIndex > 0 then
        Status.Text =
            "Roll "
            .. tostring(RollCount)
            .. " | Best Combo #"
            .. tostring(comboIndex)
            .. " "
            .. tostring(matched)
            .. "/"
            .. tostring(total)
            .. " | Helium "
            .. formatNumber(LastHeliumAmount)
    else
        Status.Text =
            "Roll "
            .. tostring(RollCount)
            .. " | No combo match | Helium "
            .. formatNumber(LastHeliumAmount)
    end

    if shouldStop then
        AutoRolling = false

        Status.Text =
            "FOUND Combo #"
            .. tostring(comboIndex)
            .. ": "
            .. table.concat(matchedNames, " + ")

        updateToggle()
        saveConfig()

        task.spawn(function()
            sendWebhook(
                "Auto Enchant Found",
                comboIndex,
                matchedNames
            )
        end)

        return true
    end

    return false
end

local function startAuto()
    if comboCount() == 0 then
        Status.Text = "Add at least one saved combo first."
        return
    end

    local selected = getSelectedPickaxe()

    if not selected then
        Status.Text = "Select a valid pickaxe first."
        return
    end

    if not findInventoryStore() then
        Status.Text = "Could not find inventory data store."
        return
    end

    -- Auto Roll always owns the character/tool state first.
    Status.Text = "Disabling Auto Mine..."

    local mineOff, mineReason = setAutoMine(false)
    FarmingForHelium = false

    if not mineOff then
        Status.Text =
            "Could not disable Auto Mine: "
            .. tostring(mineReason)
        return
    end

    Status.Text = "Moving to enchant machine..."

    local teleported, teleportReason = teleportToEnchantMachine()

    if not teleported then
        Status.Text =
            "Could not reach enchant machine after 10 attempts: "
            .. tostring(teleportReason)
        return
    end

    local alreadyDone, comboIndex, matched, total, matchedNames =
        checkCombos(selected.UUID)

    updateCurrentDisplay()

    if alreadyDone then
        Status.Text =
            "Already matches Combo #"
            .. tostring(comboIndex)
            .. ": "
            .. table.concat(matchedNames, " + ")
        return
    end

    AutoRolling = true
    RollCount = 0
    resetEnchantChangeCounter(selected.UUID)
    updateToggle()
    saveConfig()

    task.spawn(function()
        while AutoRolling and Screen.Parent do
            local farming = updateFarmState()

            if farming then
                Status.Text =
                    "Paused rolling: farming "
                    .. HELIUM_ITEM_NAME
                    .. " ("
                    .. formatNumber(LastHeliumAmount)
                    .. "/"
                    .. formatNumber(FarmStopAt)
                    .. ")"

                task.wait(INVENTORY_REFRESH_DELAY)
                continue
            end

            if AutoFarmEnabled
                and LastHeliumAmount <= FarmStartBelow
                and not FarmingForHelium
            then
                Status.Text =
                    "Low Helium. Auto Mine is not ON; rolling paused. "
                    .. tostring(FarmStateLabel.Text)

                task.wait(INVENTORY_REFRESH_DELAY)
                continue
            end

            if rollOnce(selected.UUID) then
                break
            end

            task.wait(ROLL_DELAY)
        end
    end)
end

Toggle.MouseButton1Click:Connect(function()
    if AutoRolling then
        AutoRolling = false
        Status.Text = "Stopped manually."
        updateToggle()
        saveConfig()
    else
        startAuto()
        saveConfig()
    end
end)


--==============================================================
-- LIVE REFRESH
--==============================================================

rebuildComboBuilder()
rebuildCombos()
updateFarmToggle()
updateCurrentDisplay()

if ResumeAutoRoll then
    task.defer(function()
        if Screen.Parent and not AutoRolling then
            startAuto()
        end
    end)
end

task.spawn(function()
    while Screen.Parent do
        updateFarmState()

        if SelectedPickaxeUUID then
            local changed =
                recordEnchantChange(
                    SelectedPickaxeUUID
                )

            if changed and not AutoRolling then
                Status.Text =
                    "Enchant changed | Roll "
                    .. tostring(RollCount)
            end
        end

        if not AutoRolling then
            updateCurrentDisplay()
        end

        task.wait(INVENTORY_REFRESH_DELAY)
    end
end)


