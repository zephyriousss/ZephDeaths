--------------------------------------------------------------------------------
-- ZephDeaths v0.20
-- Per-player death tracking for Mythic+ dungeons
-- Author: Zephyrious
--
-- Uses polling (C_Timer) instead of events to avoid RegisterEvent taint.
-- Zero event frames, zero RegisterEvent calls.
--------------------------------------------------------------------------------

local addonName, ns = ...

--------------------------------------------------------------------------------
-- Defaults & State
--------------------------------------------------------------------------------

local defaults = {
    position = { point = "CENTER", relativePoint = "CENTER", xOfs = 0, yOfs = -200 },
    iconSize = 32,
    locked = false,
    fontSize = 14,
    countColor = "YELLOW",  -- YELLOW, WHITE, RED
    textSide = "RIGHT",     -- RIGHT or LEFT
    hideBlizzardDeaths = false,
    deathFlash = true,
    welcomed = false,
}

local deathCounts = {}
local partyUnits = {}       -- unit token -> { guid, name, class, wasDead }
local keystoneActive = false
local manualTracking = false
local addonLoaded = false
local deathPollTicker = nil
local statePollTicker = nil

local FEIGN_DEATH_SPELL_ID = 5384

--------------------------------------------------------------------------------
-- Utility
--------------------------------------------------------------------------------

local function EnsureDefaults(db, defs)
    for k, v in pairs(defs) do
        if db[k] == nil then
            if type(v) == "table" then
                db[k] = {}
                EnsureDefaults(db[k], v)
            else
                db[k] = v
            end
        end
    end
end

local function IsTracking()
    return keystoneActive or manualTracking
end

local function SortedDeathList()
    local list = {}
    for _, data in pairs(deathCounts) do
        list[#list + 1] = data
    end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    return list
end

local function GetTotalDeaths()
    local total = 0
    for _, data in pairs(deathCounts) do
        total = total + data.count
    end
    return total
end

--------------------------------------------------------------------------------
-- Feign Death Check (buff-based, no combat log needed)
--------------------------------------------------------------------------------

local function HasFeignDeath(unit)
    -- C_UnitAuras.GetAuraDataBySpellID works for any unit, any locale (10.0+)
    if C_UnitAuras and C_UnitAuras.GetAuraDataBySpellID then
        local aura = C_UnitAuras.GetAuraDataBySpellID(unit, FEIGN_DEATH_SPELL_ID)
        if aura then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- Party State Management
--------------------------------------------------------------------------------

local function RefreshPartyState()
    wipe(partyUnits)
    wipe(deathCounts)

    local units = { "player" }
    for i = 1, 4 do
        units[#units + 1] = "party" .. i
    end

    for _, unit in ipairs(units) do
        if UnitExists(unit) then
            local guid = UnitGUID(unit)
            if guid then
                local _, class = UnitClass(unit)
                local name = UnitName(unit)
                local isDead = UnitIsDeadOrGhost(unit) and not HasFeignDeath(unit)

                partyUnits[unit] = {
                    guid = guid,
                    name = name,
                    class = class,
                    wasDead = isDead,
                }

                if not deathCounts[guid] then
                    deathCounts[guid] = {
                        name = name,
                        class = class,
                        count = 0,
                    }
                end
            end
        end
    end
end

local function UpdatePartyState()
    local units = { "player" }
    for i = 1, 4 do
        units[#units + 1] = "party" .. i
    end

    for _, unit in ipairs(units) do
        if UnitExists(unit) then
            local guid = UnitGUID(unit)
            if guid and not partyUnits[unit] then
                local _, class = UnitClass(unit)
                local name = UnitName(unit)
                local isDead = UnitIsDeadOrGhost(unit) and not HasFeignDeath(unit)

                partyUnits[unit] = {
                    guid = guid,
                    name = name,
                    class = class,
                    wasDead = isDead,
                }

                if not deathCounts[guid] then
                    deathCounts[guid] = {
                        name = name,
                        class = class,
                        count = 0,
                    }
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Display (forward declarations, built in Init)
--------------------------------------------------------------------------------

local anchor, countText, skullBg, skullIcon, skullBorder, skullHighlight, skullPulse, pulseAnim

local COLOR_PRESETS = {
    YELLOW = { r = 1, g = 0.82, b = 0, label = "Yellow" },
    WHITE  = { r = 1, g = 1,    b = 1, label = "White" },
    RED    = { r = 1, g = 0.3,  b = 0.3, label = "Red" },
}

local function ApplySettings()
    if not anchor or not ZephDeathsDB then return end

    local size = ZephDeathsDB.iconSize or 32

    -- Resize skull elements proportionally
    if skullBg then skullBg:SetSize(size * 0.875, size * 0.875) end
    if skullIcon then skullIcon:SetSize(size * 0.8125, size * 0.8125) end
    if skullBorder then skullBorder:SetSize(size * 1.6875, size * 1.6875) end
    if skullHighlight then skullHighlight:SetSize(size * 0.875, size * 0.875) end
    if skullPulse then skullPulse:SetSize(size * 0.875, size * 0.875) end

    -- Font size
    if countText then
        local fontFile = countText:GetFont()
        countText:SetFont(fontFile, ZephDeathsDB.fontSize or 14, "OUTLINE")
    end

    -- Text side (LEFT or RIGHT)
    local side = ZephDeathsDB.textSide or "RIGHT"
    if countText and skullBg then
        countText:ClearAllPoints()
        if side == "LEFT" then
            countText:SetPoint("RIGHT", skullBg, "LEFT", -2, 0)
        else
            countText:SetPoint("LEFT", skullBg, "RIGHT", 2, 0)
        end
    end

    -- Reposition skull within anchor based on text side
    if skullBg then
        skullBg:ClearAllPoints()
        if side == "LEFT" then
            skullBg:SetPoint("RIGHT", anchor, "RIGHT", -2, 0)
        else
            skullBg:SetPoint("LEFT", anchor, "LEFT", 2, 0)
        end
    end

    -- Border offset
    if skullBorder and skullBg then
        skullBorder:ClearAllPoints()
        skullBorder:SetPoint("CENTER", skullBg, "CENTER", size * 0.3125, size * -0.3125)
    end

    -- Resize anchor frame to fit
    anchor:SetSize(size + 40, size)
end

local function GetCountColor()
    local key = ZephDeathsDB and ZephDeathsDB.countColor or "YELLOW"
    return COLOR_PRESETS[key] or COLOR_PRESETS.YELLOW
end

local function UpdateDisplay()
    if not countText then return end
    local total = GetTotalDeaths()
    local c = GetCountColor()
    local side = ZephDeathsDB and ZephDeathsDB.textSide or "RIGHT"

    if total > 0 then
        if side == "LEFT" then
            countText:SetText(total .. " -")
        else
            countText:SetText("- " .. total)
        end
        countText:SetTextColor(c.r, c.g, c.b)
    else
        if side == "LEFT" then
            countText:SetText("0 -")
        else
            countText:SetText("- 0")
        end
        countText:SetTextColor(0.6, 0.6, 0.6)
    end

    -- Live-update tooltip if hovering
    if anchor and anchor:IsMouseOver() then
        anchor:GetScript("OnEnter")(anchor)
    end
end

local function FlashSkull()
    if pulseAnim and ZephDeathsDB and ZephDeathsDB.deathFlash ~= false then
        pulseAnim:Stop()
        pulseAnim:Play()
    end
end

local UpdateBlizzardDeathCount  -- forward declaration

local function ShowAnchor()
    if anchor and not anchor:IsShown() then
        anchor:Show()
    end
end

local function HideAnchor()
    if anchor and anchor:IsShown() then
        anchor:Hide()
    end
end

--------------------------------------------------------------------------------
-- Death Detection (polling - checks every 0.25s)
--------------------------------------------------------------------------------

local function SaveSession()
    if not ZephDeathsDB then return end
    -- Deep copy deathCounts into SavedVariables
    ZephDeathsDB.sessionDeaths = {}
    for guid, data in pairs(deathCounts) do
        ZephDeathsDB.sessionDeaths[guid] = {
            name = data.name,
            class = data.class,
            count = data.count,
        }
    end
end

local function PollDeaths()
    if not IsTracking() then return end

    -- Handle Blizzard death count visibility (moved from 2s ticker for smoother hiding)
    UpdateBlizzardDeathCount()

    for unit, data in pairs(partyUnits) do
        if UnitExists(unit) then
            -- Check GUID hasn't changed (party member swap)
            local currentGUID = UnitGUID(unit)
            if currentGUID ~= data.guid then
                -- GUID changed: update this slot inline (don't bail out)
                local _, class = UnitClass(unit)
                local name = UnitName(unit)
                local isDead = UnitIsDeadOrGhost(unit) and not HasFeignDeath(unit)

                partyUnits[unit] = {
                    guid = currentGUID,
                    name = name,
                    class = class,
                    wasDead = isDead,  -- treat current state as baseline
                }

                if not deathCounts[currentGUID] then
                    deathCounts[currentGUID] = {
                        name = name,
                        class = class,
                        count = 0,
                    }
                end
            else
                local isDead = UnitIsDeadOrGhost(unit) and not HasFeignDeath(unit)

                if isDead and not data.wasDead then
                    -- Transition: alive -> dead = real death
                    local guid = data.guid
                    if deathCounts[guid] then
                        deathCounts[guid].count = deathCounts[guid].count + 1
                        FlashSkull()
                        UpdateDisplay()
                        SaveSession()
                    end
                end

                data.wasDead = isDead
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Blizzard Death Count Hiding
--------------------------------------------------------------------------------

local cachedDeathCountFrame = nil

local function FindDeathCountFrame()
    -- Return cached reference if still valid
    if cachedDeathCountFrame and cachedDeathCountFrame.GetAlpha then
        return cachedDeathCountFrame
    end

    -- The DeathCount frame is nested under ScenarioObjectiveTracker
    -- with dynamically-generated hash keys. Search for it.
    local tracker = ScenarioObjectiveTracker
    if not tracker then return nil end
    local contents = tracker.ContentsFrame
    if not contents then return nil end

    -- Iterate children to find the block with DeathCount
    for _, child in pairs({ contents:GetChildren() }) do
        if child.DeathCount then
            cachedDeathCountFrame = child.DeathCount
            return cachedDeathCountFrame
        end
    end
    return nil
end

UpdateBlizzardDeathCount = function()
    if not ZephDeathsDB then return end
    local shouldHide = ZephDeathsDB.hideBlizzardDeaths

    local deathCountFrame = FindDeathCountFrame()
    if deathCountFrame then
        if shouldHide then
            deathCountFrame:SetAlpha(0)
        else
            deathCountFrame:SetAlpha(1)
        end
    end
end

--------------------------------------------------------------------------------
-- Keystone State (polling - checks every 2s)
--------------------------------------------------------------------------------

local function PollKeystoneState()
    if not C_ChallengeMode then return end

    local isActive = C_ChallengeMode.IsChallengeModeActive()

    if isActive and not keystoneActive then
        keystoneActive = true
        manualTracking = false
        cachedDeathCountFrame = nil  -- Blizzard tracker rebuilds on new key

        -- Check server death count to distinguish fresh key vs re-entry
        local serverDeaths = C_ChallengeMode.GetDeathCount() or 0

        if serverDeaths > 0 and ZephDeathsDB and ZephDeathsDB.sessionDeaths then
            -- Re-entering an in-progress key: restore saved counts
            wipe(deathCounts)
            for guid, data in pairs(ZephDeathsDB.sessionDeaths) do
                deathCounts[guid] = {
                    name = data.name,
                    class = data.class,
                    count = data.count,
                }
            end
            -- Rebuild party state without wiping death counts
            wipe(partyUnits)
            local units = { "player" }
            for i = 1, 4 do units[#units + 1] = "party" .. i end
            for _, unit in ipairs(units) do
                if UnitExists(unit) then
                    local guid = UnitGUID(unit)
                    if guid then
                        local _, class = UnitClass(unit)
                        local name = UnitName(unit)
                        local isDead = UnitIsDeadOrGhost(unit)
                        partyUnits[unit] = {
                            guid = guid, name = name, class = class, wasDead = isDead,
                        }
                        if not deathCounts[guid] then
                            deathCounts[guid] = { name = name, class = class, count = 0 }
                        end
                    end
                end
            end
        else
            -- Fresh key: wipe everything
            if ZephDeathsDB then ZephDeathsDB.sessionDeaths = nil end
            RefreshPartyState()
        end

        UpdateDisplay()
        ShowAnchor()
    elseif not isActive and keystoneActive then
        -- Left instance (may be temporary) - stop tracking but keep data
        keystoneActive = false
        UpdateDisplay()
    end

    -- Hide when not tracking and no longer in a group
    if not IsTracking() and anchor and anchor:IsShown() then
        if not IsInGroup() then
            HideAnchor()
        end
    end

    if IsTracking() then
        UpdatePartyState()
    end
end

--------------------------------------------------------------------------------
-- Polling Start/Stop
--------------------------------------------------------------------------------

local function StartPolling()
    if not deathPollTicker then
        deathPollTicker = C_Timer.NewTicker(0.25, PollDeaths)
    end
    if not statePollTicker then
        statePollTicker = C_Timer.NewTicker(2.0, PollKeystoneState)
    end
end

--------------------------------------------------------------------------------
-- Build UI (called once from init)
--------------------------------------------------------------------------------

local function BuildUI()
    anchor = CreateFrame("Frame", nil, UIParent)
    anchor:SetSize(70, 32)
    anchor:SetClampedToScreen(true)
    anchor:SetMovable(true)
    anchor:RegisterForDrag("LeftButton")
    anchor:EnableMouse(true)
    anchor:SetFrameStrata("MEDIUM")
    anchor:SetFrameLevel(50)
    anchor:Hide()

    -- Skull icon group
    skullBg = anchor:CreateTexture(nil, "BACKGROUND")
    skullBg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    skullBg:SetSize(28, 28)
    skullBg:SetPoint("LEFT", anchor, "LEFT", 2, 0)
    skullBg:SetVertexColor(0, 0, 0, 0.6)

    skullIcon = anchor:CreateTexture(nil, "ARTWORK")
    skullIcon:SetTexture("Interface\\TARGETINGFRAME\\UI-TargetingFrame-Skull")
    skullIcon:SetSize(26, 26)
    skullIcon:SetPoint("CENTER", skullBg, "CENTER", 0, 0)

    skullBorder = anchor:CreateTexture(nil, "OVERLAY")
    skullBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    skullBorder:SetSize(54, 54)
    skullBorder:SetPoint("CENTER", skullBg, "CENTER", 10, -10)

    -- Count text
    countText = anchor:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    countText:SetPoint("LEFT", skullBg, "RIGHT", 2, 0)
    countText:SetText("- 0")

    local c = GetCountColor()
    countText:SetTextColor(c.r, c.g, c.b)

    skullHighlight = anchor:CreateTexture(nil, "HIGHLIGHT")
    skullHighlight:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    skullHighlight:SetSize(28, 28)
    skullHighlight:SetPoint("CENTER", skullBg, "CENTER", 0, 0)
    skullHighlight:SetAlpha(0.3)

    -- Death pulse overlay (red glow on death)
    skullPulse = anchor:CreateTexture(nil, "OVERLAY", nil, -1)
    skullPulse:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMaskSmall")
    skullPulse:SetPoint("CENTER", skullBg, "CENTER", 0, 0)
    skullPulse:SetSize(28, 28)
    skullPulse:SetVertexColor(0.8, 0.05, 0.05)
    skullPulse:SetAlpha(0)

    local pulseGroup = skullPulse:CreateAnimationGroup()
    pulseGroup:SetScript("OnPlay", function()
        skullPulse:SetAlpha(0.7)
    end)
    pulseGroup:SetScript("OnFinished", function()
        skullPulse:SetAlpha(0)
    end)
    local fadeOut = pulseGroup:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(0.5)
    fadeOut:SetSmoothing("OUT")
    pulseAnim = pulseGroup

    -- Apply saved icon size, font, text side
    ApplySettings()

    -- Drag
    anchor:SetScript("OnDragStart", function(self)
        if ZephDeathsDB and ZephDeathsDB.locked then return end
        self:StartMoving()
    end)

    anchor:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
        if ZephDeathsDB then
            ZephDeathsDB.position.point = point
            ZephDeathsDB.position.relativePoint = relativePoint
            ZephDeathsDB.position.xOfs = xOfs
            ZephDeathsDB.position.yOfs = yOfs
        end
    end)

    -- Tooltip
    anchor:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()

        local total = GetTotalDeaths()
        GameTooltip:AddLine("Deaths: " .. total, 1, 1, 1)

        -- Show official time penalty during keystones
        if keystoneActive and C_ChallengeMode then
            local _, timeLost = C_ChallengeMode.GetDeathCount()
            if timeLost and timeLost > 0 then
                local mins = math.floor(timeLost / 60)
                local secs = timeLost % 60
                local timeStr = string.format("-%d:%02d", mins, secs)
                GameTooltip:AddLine("Time lost: " .. timeStr, 1, 0.3, 0.3)
            end
        end

        GameTooltip:AddLine(" ")

        local list = SortedDeathList()
        for _, data in ipairs(list) do
            local color = RAID_CLASS_COLORS[data.class]
            local r, g, b = 0.8, 0.8, 0.8
            if color then
                r, g, b = color.r, color.g, color.b
            end

            local deathStr
            if data.count == 0 then
                deathStr = "|cFF888888-|r"
            else
                deathStr = "|cFFFF4444" .. data.count .. "|r"
            end

            GameTooltip:AddDoubleLine(data.name, deathStr, r, g, b, 1, 1, 1)
        end

        if manualTracking then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Manual tracking active", 1, 0.8, 0)
        elseif not keystoneActive then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("No active keystone", 0.6, 0.6, 0.6)
        end

        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Drag to move", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)

    anchor:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
end

--------------------------------------------------------------------------------
-- Options Panel
--------------------------------------------------------------------------------

local optionsCategoryID

local function CreateOptionsPanel()
    local panel = CreateFrame("Frame", "ZephDeathsOptions", UIParent)
    panel.name = "ZephDeaths"
    panel:Hide()

    -- Title
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("ZephDeaths")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subtitle:SetText("Per-player death tracking for Mythic+ dungeons")

    local yOffset = -70

    ---------- Lock Checkbox ----------
    local lockCB = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    lockCB:SetPoint("TOPLEFT", 16, yOffset)
    lockCB.text = lockCB:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    lockCB.text:SetPoint("LEFT", lockCB, "RIGHT", 4, 0)
    lockCB.text:SetText("Lock position")
    lockCB:SetChecked(ZephDeathsDB.locked)
    lockCB:SetScript("OnClick", function(self)
        ZephDeathsDB.locked = self:GetChecked()
    end)

    yOffset = yOffset - 35

    ---------- Hide Blizzard Deaths Checkbox ----------
    local hideCB = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    hideCB:SetPoint("TOPLEFT", 16, yOffset)
    hideCB.text = hideCB:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    hideCB.text:SetPoint("LEFT", hideCB, "RIGHT", 4, 0)
    hideCB.text:SetText("Hide default death count on M+ timer")
    hideCB:SetChecked(ZephDeathsDB.hideBlizzardDeaths)
    hideCB:SetScript("OnClick", function(self)
        ZephDeathsDB.hideBlizzardDeaths = self:GetChecked()
        UpdateBlizzardDeathCount()
    end)

    yOffset = yOffset - 35

    ---------- Death Flash Checkbox ----------
    local flashCB = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    flashCB:SetPoint("TOPLEFT", 16, yOffset)
    flashCB.text = flashCB:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    flashCB.text:SetPoint("LEFT", flashCB, "RIGHT", 4, 0)
    flashCB.text:SetText("Flash skull on death")
    flashCB:SetChecked(ZephDeathsDB.deathFlash)
    flashCB:SetScript("OnClick", function(self)
        ZephDeathsDB.deathFlash = self:GetChecked()
    end)

    yOffset = yOffset - 35

    ---------- Text Side Toggle ----------
    local sideLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    sideLabel:SetPoint("TOPLEFT", 16, yOffset)
    sideLabel:SetText("Number position")

    yOffset = yOffset - 25

    local sideButtons = {}
    local sideOptions = {
        { key = "LEFT", label = "Left of skull" },
        { key = "RIGHT", label = "Right of skull" },
    }
    local sideXPos = 20

    for _, opt in ipairs(sideOptions) do
        local btn = CreateFrame("Button", nil, panel)
        btn:SetSize(110, 22)
        btn:SetPoint("TOPLEFT", sideXPos, yOffset)

        local btnBg = btn:CreateTexture(nil, "BACKGROUND")
        btnBg:SetAllPoints()
        btnBg:SetColorTexture(0.15, 0.15, 0.15, 0.8)

        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("CENTER")
        label:SetText(opt.label)

        local selected = btn:CreateTexture(nil, "OVERLAY")
        selected:SetAllPoints()
        selected:SetColorTexture(1, 1, 1, 0.15)
        btn.selected = selected

        btn:SetScript("OnClick", function()
            ZephDeathsDB.textSide = opt.key
            for _, b in pairs(sideButtons) do b.selected:Hide() end
            btn.selected:Show()
            ApplySettings()
            UpdateDisplay()
        end)

        btn:SetScript("OnEnter", function() btnBg:SetColorTexture(0.25, 0.25, 0.25, 0.8) end)
        btn:SetScript("OnLeave", function() btnBg:SetColorTexture(0.15, 0.15, 0.15, 0.8) end)

        if ZephDeathsDB.textSide == opt.key then
            selected:Show()
        else
            selected:Hide()
        end

        sideButtons[opt.key] = btn
        sideXPos = sideXPos + 118
    end

    yOffset = yOffset - 40

    ---------- Icon Size Slider ----------
    local iconLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    iconLabel:SetPoint("TOPLEFT", 16, yOffset)
    iconLabel:SetText("Icon size")

    yOffset = yOffset - 20

    local iconSlider = CreateFrame("Slider", "ZephDeathsIconSlider", panel, "OptionsSliderTemplate")
    iconSlider:SetPoint("TOPLEFT", 20, yOffset)
    iconSlider:SetWidth(200)
    iconSlider:SetMinMaxValues(20, 64)
    iconSlider:SetValueStep(2)
    iconSlider:SetObeyStepOnDrag(true)
    iconSlider:SetValue(ZephDeathsDB.iconSize)
    iconSlider.Low:SetText("20")
    iconSlider.High:SetText("64")
    iconSlider.Text:SetText(tostring(ZephDeathsDB.iconSize))

    iconSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value / 2 + 0.5) * 2  -- round to even
        ZephDeathsDB.iconSize = value
        self.Text:SetText(tostring(value))
        ApplySettings()
    end)

    yOffset = yOffset - 45

    ---------- Font Size Slider ----------
    local fontLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fontLabel:SetPoint("TOPLEFT", 16, yOffset)
    fontLabel:SetText("Font size")

    yOffset = yOffset - 20

    local fontSlider = CreateFrame("Slider", "ZephDeathsFontSlider", panel, "OptionsSliderTemplate")
    fontSlider:SetPoint("TOPLEFT", 20, yOffset)
    fontSlider:SetWidth(200)
    fontSlider:SetMinMaxValues(8, 24)
    fontSlider:SetValueStep(1)
    fontSlider:SetObeyStepOnDrag(true)
    fontSlider:SetValue(ZephDeathsDB.fontSize)
    fontSlider.Low:SetText("8")
    fontSlider.High:SetText("24")
    fontSlider.Text:SetText(tostring(ZephDeathsDB.fontSize))

    fontSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        ZephDeathsDB.fontSize = value
        self.Text:SetText(tostring(value))
        ApplySettings()
        UpdateDisplay()
    end)

    yOffset = yOffset - 50

    ---------- Font Color ----------
    local colorLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    colorLabel:SetPoint("TOPLEFT", 16, yOffset)
    colorLabel:SetText("Font color")

    yOffset = yOffset - 25

    local colorButtons = {}
    local colorOrder = { "YELLOW", "WHITE", "RED" }
    local xPos = 20

    for _, key in ipairs(colorOrder) do
        local preset = COLOR_PRESETS[key]

        local btn = CreateFrame("Button", nil, panel)
        btn:SetSize(60, 22)
        btn:SetPoint("TOPLEFT", xPos, yOffset)

        local btnBg = btn:CreateTexture(nil, "BACKGROUND")
        btnBg:SetAllPoints()
        btnBg:SetColorTexture(0.15, 0.15, 0.15, 0.8)

        local swatch = btn:CreateTexture(nil, "ARTWORK")
        swatch:SetSize(14, 14)
        swatch:SetPoint("LEFT", 4, 0)
        swatch:SetColorTexture(preset.r, preset.g, preset.b)

        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", swatch, "RIGHT", 4, 0)
        label:SetText(preset.label)

        local selected = btn:CreateTexture(nil, "OVERLAY")
        selected:SetAllPoints()
        selected:SetColorTexture(1, 1, 1, 0.15)
        btn.selected = selected

        btn:SetScript("OnClick", function()
            ZephDeathsDB.countColor = key
            for _, b in pairs(colorButtons) do b.selected:Hide() end
            btn.selected:Show()
            UpdateDisplay()
        end)

        btn:SetScript("OnEnter", function() btnBg:SetColorTexture(0.25, 0.25, 0.25, 0.8) end)
        btn:SetScript("OnLeave", function() btnBg:SetColorTexture(0.15, 0.15, 0.15, 0.8) end)

        if ZephDeathsDB.countColor == key then
            selected:Show()
        else
            selected:Hide()
        end

        colorButtons[key] = btn
        xPos = xPos + 68
    end

    -- Register with Settings API
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
        optionsCategoryID = category:GetID()
    end
end

--------------------------------------------------------------------------------
-- Init (deferred via C_Timer)
--------------------------------------------------------------------------------

C_Timer.After(0, function()
    ZephDeathsDB = ZephDeathsDB or {}
    EnsureDefaults(ZephDeathsDB, defaults)

    BuildUI()
    CreateOptionsPanel()

    local pos = ZephDeathsDB.position
    anchor:ClearAllPoints()
    anchor:SetPoint(pos.point, UIParent, pos.relativePoint, pos.xOfs, pos.yOfs)
    addonLoaded = true

    -- First-run welcome message (once per install)
    if not ZephDeathsDB.welcomed then
        ZephDeathsDB.welcomed = true
        C_Timer.After(3, function()
            print("|cFF00CCFFZephDeaths|r installed! Type |cFFFFFF00/zd|r for commands or |cFFFFFF00/zd options|r for settings.")
        end)
    end

    StartPolling()

    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive() then
        keystoneActive = true

        -- Restore saved death counts from before reload
        if ZephDeathsDB.sessionDeaths then
            for guid, data in pairs(ZephDeathsDB.sessionDeaths) do
                deathCounts[guid] = {
                    name = data.name,
                    class = data.class,
                    count = data.count,
                }
            end
        end

        -- Build party state without wiping restored death counts
        wipe(partyUnits)
        local units = { "player" }
        for i = 1, 4 do units[#units + 1] = "party" .. i end
        for _, unit in ipairs(units) do
            if UnitExists(unit) then
                local guid = UnitGUID(unit)
                if guid then
                    local _, class = UnitClass(unit)
                    local name = UnitName(unit)
                    local isDead = UnitIsDeadOrGhost(unit)
                    partyUnits[unit] = {
                        guid = guid,
                        name = name,
                        class = class,
                        wasDead = isDead,
                    }
                    if not deathCounts[guid] then
                        deathCounts[guid] = {
                            name = name,
                            class = class,
                            count = 0,
                        }
                    end
                end
            end
        end

        UpdateDisplay()
        ShowAnchor()
    else
        -- Not in a key, clear stale session data
        ZephDeathsDB.sessionDeaths = nil
    end
end)

--------------------------------------------------------------------------------
-- Addon Compartment (minimap dropdown)
--------------------------------------------------------------------------------

function ZephDeaths_OnCompartmentClick()
    if optionsCategoryID then
        Settings.OpenToCategory(optionsCategoryID)
    end
end

--------------------------------------------------------------------------------
-- Slash Commands
--------------------------------------------------------------------------------

SLASH_ZEPHDEATHS1 = "/zephdeaths"
SLASH_ZEPHDEATHS2 = "/zd"
SlashCmdList["ZEPHDEATHS"] = function(msg)
    msg = (msg or ""):lower():trim()

    if msg == "" or msg == "help" then
        print("|cFF00CCFFZephDeaths|r commands:")
        print("  /zd options - Open settings panel")
        print("  /zd show  - Force show the tracker")
        print("  /zd hide  - Hide the tracker")
        print("  /zd lock  - Lock position")
        print("  /zd unlock - Unlock position")
        print("  /zd reset - Reset position to center")
        print("  /zd track - Start tracking deaths anywhere")
        print("  /zd stop  - Stop manual tracking")
        print("  /zd test  - Load fake data for UI testing")
    elseif msg == "options" or msg == "config" or msg == "settings" then
        if optionsCategoryID then
            Settings.OpenToCategory(optionsCategoryID)
        else
            print("|cFF00CCFFZephDeaths|r: Options panel not available.")
        end
    elseif msg == "show" then
        ShowAnchor()
        print("|cFF00CCFFZephDeaths|r: Tracker shown.")
    elseif msg == "hide" then
        HideAnchor()
        print("|cFF00CCFFZephDeaths|r: Tracker hidden.")
    elseif msg == "lock" then
        if ZephDeathsDB then ZephDeathsDB.locked = true end
        print("|cFF00CCFFZephDeaths|r: Position locked.")
    elseif msg == "unlock" then
        if ZephDeathsDB then ZephDeathsDB.locked = false end
        print("|cFF00CCFFZephDeaths|r: Position unlocked.")
    elseif msg == "reset" then
        if ZephDeathsDB then
            ZephDeathsDB.position = {
                point = "CENTER",
                relativePoint = "CENTER",
                xOfs = 0,
                yOfs = -200,
            }
        end
        if anchor then
            anchor:ClearAllPoints()
            anchor:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
        end
        print("|cFF00CCFFZephDeaths|r: Position reset.")
    elseif msg == "track" then
        manualTracking = true
        RefreshPartyState()
        UpdateDisplay()
        ShowAnchor()
        print("|cFF00CCFFZephDeaths|r: Manual tracking started.")
    elseif msg == "stop" then
        manualTracking = false
        if not keystoneActive then
            HideAnchor()
        end
        print("|cFF00CCFFZephDeaths|r: Manual tracking stopped.")
    elseif msg == "test" then
        wipe(deathCounts)
        deathCounts["test-player"] = { name = UnitName("player"), class = select(2, UnitClass("player")), count = 2 }
        deathCounts["test-tank"] = { name = "Thrall", class = "SHAMAN", count = 0 }
        deathCounts["test-healer"] = { name = "Anduin Wrynn", class = "PRIEST", count = 1 }
        deathCounts["test-dps1"] = { name = "Jaina Proudmoore", class = "MAGE", count = 5 }
        deathCounts["test-dps2"] = { name = "Valeera Sanguinar", class = "ROGUE", count = 3 }
        manualTracking = true
        UpdateDisplay()
        ShowAnchor()
        print("|cFF00CCFFZephDeaths|r: Test data loaded. Use /zd stop to clear.")
    end
end
