-- BRAT display: two icons. Big = press now, small = press next.
local _, BRAT = ...
local Display = {}
BRAT.Display = Display

local GCD_SPELL = 61304
local UPDATE_RATE = 0.05
local SIZE_NOW, SIZE_NEXT, SIZE_THEN, SIZE_SOON = 56, 42, 34, 30
local SOON_MAX = 3 -- most SOON icons shown at once

---------------------------------------------------------------------------
-- Keybind lookup
---------------------------------------------------------------------------
local BAR_BINDINGS = {
    { 1, 12, "ACTIONBUTTON" },
    { 25, 36, "MULTIACTIONBAR3BUTTON" },
    { 37, 48, "MULTIACTIONBAR4BUTTON" },
    { 49, 60, "MULTIACTIONBAR2BUTTON" },
    { 61, 72, "MULTIACTIONBAR1BUTTON" },
    { 145, 156, "MULTIACTIONBAR5BUTTON" },
    { 157, 168, "MULTIACTIONBAR6BUTTON" },
    { 169, 180, "MULTIACTIONBAR7BUTTON" },
}

local keyCache = {}
function Display:ClearKeyCache() wipe(keyCache) end

local function shortKey(key)
    return key:gsub("SHIFT%-", "S"):gsub("CTRL%-", "C"):gsub("ALT%-", "A")
        :gsub("MOUSEBUTTON", "M"):gsub("NUMPAD", "N"):gsub("MOUSEWHEELUP", "WU")
        :gsub("MOUSEWHEELDOWN", "WD")
end

local function bindingForSlot(slot)
    for _, r in ipairs(BAR_BINDINGS) do
        if slot >= r[1] and slot <= r[2] then
            return GetBindingKey(r[3] .. (slot - r[1] + 1))
        end
    end
end

-- Does action slot `slot` cast `spellID`? Handles overrides (the button holds
-- the base spell, Blizzard shows the upgraded one) and macros.
local function slotCasts(slot, spellID, base)
    local ok, kind, id = pcall(GetActionInfo, slot)
    if not ok or BRAT.IsSecret(kind) or BRAT.IsSecret(id) then return false end
    if kind == "macro" then
        id = BRAT.Safe(GetMacroSpell, id)
    elseif kind ~= "spell" then
        return false
    end
    if not id then return false end
    if id == spellID or id == base then return true end
    return BRAT.Safe(C_Spell.GetOverrideSpell, id) == spellID
end

local function getKey(spellID)
    if keyCache[spellID] ~= nil then return keyCache[spellID] end
    local key = ""
    local slots = BRAT.Safe(C_ActionBar.FindSpellActionButtons, spellID)
    if type(slots) == "table" then
        for _, slot in ipairs(slots) do
            local k = bindingForSlot(slot)
            if k then key = shortKey(k) break end
        end
    end
    if key == "" then
        -- Slower full scan of every bound slot (only runs until cached).
        local base = BRAT.Safe(C_Spell.GetBaseSpell, spellID)
        for _, r in ipairs(BAR_BINDINGS) do
            for slot = r[1], r[2] do
                if slotCasts(slot, spellID, base) then
                    local k = bindingForSlot(slot)
                    if k then key = shortKey(k) break end
                end
            end
            if key ~= "" then break end
        end
    end
    keyCache[spellID] = key
    return key
end

function Display:GetKey(spellID) return getKey(spellID) end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------
local function makeIcon(parent, size, label)
    local b = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    b:SetSize(size, size)
    b:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 2 })
    b:SetBackdropBorderColor(0, 0, 0, 1)

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 2, -2)
    b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cd:SetAllPoints(b.icon)
    b.cd:SetHideCountdownNumbers(true)
    b.cd:SetDrawEdge(false)

    b.key = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.key:SetPoint("TOPRIGHT", -3, -3)

    -- Empower level to release at (Evoker: "R2" = let go at rank 2).
    b.rank = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.rank:SetPoint("BOTTOMLEFT", 3, 3)
    b.rank:SetTextColor(1, 0.82, 0)

    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.label:SetPoint("TOP", b, "BOTTOM", 0, -2)
    b.label:SetText(label)
    return b
end

function Display:Init()
    local root = CreateFrame("Frame", "BRATFrame", UIParent)
    root:SetMovable(true)
    root:SetClampedToScreen(true)
    root:RegisterForDrag("LeftButton")
    root:SetScript("OnDragStart", function(s) if not BRAT.db.locked then s:StartMoving() end end)
    root:SetScript("OnDragStop", function(s)
        s:StopMovingOrSizing()
        local p, _, rp, x, y = s:GetPoint()
        BRAT.db.point = { p, "UIParent", rp, x, y }
    end)

    root.bg = root:CreateTexture(nil, "BACKGROUND")
    root.bg:SetAllPoints()
    root.bg:SetColorTexture(0.2, 0.6, 1, 0.25)

    self.now = makeIcon(root, SIZE_NOW, "NOW")
    self.now:SetPoint("LEFT")
    self.next = makeIcon(root, SIZE_NEXT, "NEXT")
    self.next:SetPoint("LEFT", self.now, "RIGHT", 8, 0)
    self.next2 = makeIcon(root, SIZE_THEN, "THEN")
    self.next2:SetPoint("LEFT", self.next, "RIGHT", 6, 0)

    -- SOON: heads-up for cooldowns coming back, each with a countdown.
    self.soons = {}
    for i = 1, SOON_MAX do
        local s = makeIcon(root, SIZE_SOON, i == 1 and "SOON" or "")
        s:SetBackdropBorderColor(1, 0.82, 0, 1)
        s.timer = s:CreateFontString(nil, "OVERLAY", "NumberFontNormalLarge")
        s.timer:SetPoint("CENTER")
        s:Hide()
        self.soons[i] = s
    end

    -- Enemy count used for the prediction, e.g. "3T" or "8+T".
    self.targets = root:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.targets:SetPoint("BOTTOMLEFT", root, "TOPLEFT", 0, 2)

    self.root = root
    self:ApplySettings()

    local elapsed = 0
    root:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < UPDATE_RATE then return end
        elapsed = 0
        Display:Update()
    end)
end

function Display:ApplySettings()
    local db, root = BRAT.db, self.root
    if not root then return end
    root:SetScale(db.scale)
    root:ClearAllPoints()
    local p = db.point
    root:SetPoint(p[1], UIParent, p[3], p[4], p[5])
    root:EnableMouse(not db.locked)
    root.bg:SetShown(not db.locked)

    -- Width follows how many upcoming spells are shown (0, 1 or 2).
    local n = db.nextCount or 1
    local w = SIZE_NOW + (n >= 1 and (8 + SIZE_NEXT) or 0) + (n >= 2 and (6 + SIZE_THEN) or 0)
    root:SetSize(w, SIZE_NOW)

    -- Keybind text size (independent of icon size). NEXT is a bit smaller.
    local font = (NumberFontNormal and NumberFontNormal:GetFont()) or "Fonts\\ARIALN.TTF"
    local size = db.keySize or 14
    self.now.key:SetFont(font, size, "OUTLINE")
    self.now.rank:SetFont(font, size, "OUTLINE")
    self.next.rank:SetFont(font, math.max(6, math.floor(size * SIZE_NEXT / SIZE_NOW + 0.5)), "OUTLINE")
    self.next2.rank:SetFont(font, math.max(6, math.floor(size * SIZE_THEN / SIZE_NOW + 0.5)), "OUTLINE")
    self.next.key:SetFont(font, math.max(6, math.floor(size * SIZE_NEXT / SIZE_NOW + 0.5)), "OUTLINE")
    self.next2.key:SetFont(font, math.max(6, math.floor(size * SIZE_THEN / SIZE_NOW + 0.5)), "OUTLINE")
    for _, s in ipairs(self.soons) do
        s.key:SetFont(font, math.max(6, math.floor(size * SIZE_SOON / SIZE_NOW + 0.5)), "OUTLINE")
    end
end

-- Empower level for an empowered spell at the current enemy count (spec rules:
-- empower), e.g. "R2"; "" for everything else.
local function rankText(spellID)
    local fn = BRAT.Rules().empower
    fn = fn and fn[BRAT.Cooldowns:Key(spellID)]
    local r = fn and fn(BRAT.Predict.realTargets or 1)
    return r and ("R" .. r) or ""
end

local function setIcon(b, spellID)
    if not spellID then b:Hide() return end
    b.icon:SetTexture(C_Spell.GetSpellTexture(spellID))
    b.key:SetText(getKey(spellID))
    b.rank:SetText(rankText(spellID))

    -- Red tint when out of range (skipped if range is secret/unknown).
    local inRange = BRAT.Safe(C_Spell.IsSpellInRange, spellID, "target")
    if inRange == false then b.icon:SetVertexColor(1, 0.3, 0.3)
    else b.icon:SetVertexColor(1, 1, 1) end
    b:Show()
end

local function shouldShow()
    if not BRAT.db.locked then return true end
    if UnitAffectingCombat("player") then return true end
    if BRAT.db.showOutOfCombat then
        return BRAT.Safe(UnitCanAttack, "player", "target") == true
    end
    return false
end

-- Border colour by where the guess came from: blue = decided live from
-- Blizzard's learned priority and what's ready, yellow = proc, orange = Warcraft
-- Logs habit, green = learned from Blizzard, grey = fallback guess.
local function setSourceBorder(b, source)
    if source == "priority" then
        b:SetBackdropBorderColor(0.3, 0.75, 1, 1); b:SetAlpha(1)
    elseif source == "proc" then
        b:SetBackdropBorderColor(1, 0.9, 0.2, 1); b:SetAlpha(1)
    elseif source == "logs" then
        b:SetBackdropBorderColor(1, 0.55, 0.1, 1); b:SetAlpha(1)
    elseif source == "learned" then
        b:SetBackdropBorderColor(0.2, 0.9, 0.3, 1); b:SetAlpha(1)
    else
        b:SetBackdropBorderColor(0.4, 0.4, 0.4, 1); b:SetAlpha(0.75)
    end
end

function Display:Update()
    if not shouldShow() then
        self.now:Hide(); self.next:Hide(); self.next2:Hide(); self.targets:Hide()
        for _, s in ipairs(self.soons) do s:Hide() end
        return
    end

    local nextCount = BRAT.db.nextCount or 1
    local first, second, source, third, source3 = BRAT.Predict:GetQueue()
    if nextCount < 1 then second = nil end
    if nextCount < 2 then third = nil end
    if UnitAffectingCombat("player") and BRAT.Stats then BRAT.Stats:Sample(BRAT.Predict.realTargets) end
    local cap = BRAT.Predict.cap or BRAT.MAX_TARGETS
    local real, used = BRAT.Predict.realTargets or 1, BRAT.Predict.targets or 1
    local function fmt(n) return (n >= cap and n .. "+" or tostring(n)) .. "T" end
    -- e.g. "Raid  1T", "Ara-Kara  4+T", "Nek'zali  2T > 1T rotation"
    local ctx = (BRAT.ActiveSource() == "logs") and BRAT.Context:Label() or nil
    if ctx and #ctx > 24 then ctx = ctx:sub(1, 23) .. "…" end
    self.targets:SetText((ctx and (ctx .. "  ") or "") .. fmt(real)
        .. (used ~= real and (" > " .. fmt(used) .. " rotation") or "")
        .. (BRAT.db.targets ~= "auto" and " (fixed)" or ""))
    self.targets:Show()
    if not first and not BRAT.db.locked then
        -- Placeholder while moving the frame.
        self.now.icon:SetTexture(134400); self.now:Show()
        self.next.icon:SetTexture(134400); self.next:SetShown(nextCount >= 1)
        self.next2.icon:SetTexture(134400); self.next2:SetShown(nextCount >= 2)
        return
    end

    setIcon(self.now, first)
    setIcon(self.next, second)
    setIcon(self.next2, third)
    if third then setSourceBorder(self.next2, source3) end

    -- SOON: cooldowns coming back shortly, soonest first, with seconds to go.
    local soon = BRAT.Predict:ComingUp({ first, second, third }, BRAT.db.soonSeconds or 0, SOON_MAX)
    local anchor = (third and self.next2) or (second and self.next) or self.now
    for i, s in ipairs(self.soons) do
        local e = soon[i]
        if e then
            s:ClearAllPoints()
            s:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
            setIcon(s, e.id)
            s:SetBackdropBorderColor(1, 0.82, 0, 1)
            s.icon:SetDesaturated(true)
            s.timer:SetText(("%.1f"):format(e.left))
            anchor = s
        else
            s:Hide()
        end
    end

    -- GCD swipe on the NOW icon. Values may be secret; widgets accept them.
    local cd = BRAT.Safe(C_Spell.GetSpellCooldown, GCD_SPELL)
    if cd then pcall(self.now.cd.SetCooldown, self.now.cd, cd.startTime, cd.duration) end

    if second then setSourceBorder(self.next, source) end
end
