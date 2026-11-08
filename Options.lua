-- BRAT settings panel: Esc > Options > AddOns > BRAT (or /brat).
-- Every setting has a short explanation under it. Built from plain widgets
-- so it doesn't depend on Settings API helpers that change between patches.
local _, BRAT = ...
local Options = {}
BRAT.Options = Options

local panel, content, category
local widgets = {}
local WIDTH = 580
local y -- layout cursor (negative, grows downward)

---------------------------------------------------------------------------
-- Layout helpers: each adds something at the cursor and moves it down.
---------------------------------------------------------------------------
local function gap(px) y = y - px end

local function heading(text)
    gap(14)
    local fs = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetText(text)
    gap(fs:GetStringHeight() + 4)
    local line = content:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.3)
    line:SetSize(WIDTH, 1)
    line:SetPoint("TOPLEFT", 16, y)
    gap(8)
end

-- Grey explanatory text, wrapped. indent lines it up under a control's label.
local function help(text, indent)
    local fs = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 16 + (indent or 0), y)
    fs:SetWidth(WIDTH - (indent or 0))
    fs:SetJustifyH("LEFT")
    fs:SetSpacing(2)
    fs:SetTextColor(0.75, 0.75, 0.75)
    fs:SetText(text)
    -- The wrapped height isn't always known before the page is first shown, so
    -- also estimate it from the text's one-line width (+ its line breaks).
    local w = WIDTH - (indent or 0)
    local _, breaks = text:gsub("\n", "")
    local width = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
    local lines = math.ceil(width / w) + breaks
    gap(math.max(fs:GetStringHeight(), lines * 14) + 8)
    return fs
end

local function status()
    local fs = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 40, y)
    fs:SetWidth(WIDTH - 24)
    fs:SetJustifyH("LEFT")
    fs:SetSpacing(2)
    gap(16)
    return fs
end

local function controlLabel(b, text)
    local fs = b.text or b.Text
    if not fs then fs = b:CreateFontString(nil, "ARTWORK", "GameFontHighlight") end
    fs:ClearAllPoints()
    fs:SetPoint("LEFT", b, "RIGHT", 4, 0)
    fs:SetFontObject("GameFontHighlight")
    fs:SetText(text)
    b.text = fs
end

local function radio(text, onClick)
    local b = CreateFrame("CheckButton", nil, content, "UIRadioButtonTemplate")
    b:SetPoint("TOPLEFT", 20, y)
    controlLabel(b, text)
    b:SetScript("OnClick", function() onClick(); Options:Refresh() end)
    gap(22)
    return b
end

local function check(text, onClick)
    local b = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    b:SetPoint("TOPLEFT", 16, y + 4)
    controlLabel(b, text)
    b:SetScript("OnClick", function(self) onClick(self:GetChecked()); Options:Refresh() end)
    gap(26)
    return b
end

local function button(text, w, x, yOff, onClick)
    local b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    b:SetSize(w, 22)
    b:SetPoint("TOPLEFT", x, yOff)
    b:SetText(text)
    b:SetScript("OnClick", function() onClick(); Options:Refresh() end)
    return b
end

local function inlineText(x, yOff)
    local fs = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", x, yOff)
    return fs
end

local function specName()
    local idx = GetSpecialization and GetSpecialization()
    if not idx then return "your spec" end
    local _, name = GetSpecializationInfo(idx)
    local class = UnitClass("player") -- "Priest" (not the "PRIEST" token)
    return (name or "?") .. " " .. (class or "")
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------
function Options:Build()
    local db = BRAT.db
    panel = CreateFrame("Frame")
    panel.name = "BRAT"

    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", -28, 4)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(WIDTH + 32, 10)
    scroll:SetScrollChild(content)
    y = -12

    local title = content:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 16, y)
    title:SetText("BRAT")
    gap(28)
    help("Brad's Rotation Assistant Technology shows two icons:\n"
        .. "|cffffffffNOW|r (big): the spell to press right now.\n"
        .. "|cffffffffNEXT|r (small): the spell to press after that, so you're ready the moment the global cooldown ends.\n"
        .. "Both come from the rotation of the source you pick below.\n"
        .. "The keybind is shown in the corner of each icon, and icons turn red when your target is out of range.")
    help("NEXT border colours:  |cff4dbfffblue|r = decided live: the highest-priority spell that will be ready "
        .. "(BRAT learns Blizzard's priority as you play),  |cffffe633yellow|r = a proc is up (glowing spell),|cffff8c1aorange|r = from Warcraft Logs,  |cff33e64dgreen|r = learned from Blizzard,  "
        .. "|cff999999grey|r = a best guess (not enough data yet).")

    -- NEXT source -------------------------------------------------------------
    heading("Where NOW and NEXT come from")
    widgets.srcStatus = status()
    gap(16) -- room for a second line
    widgets.srcLogs = radio("Warcraft Logs", function() BRAT.SetSource("logs") end)
    help("NOW and NEXT come from the |cffffffffWarcraft Logs rotation|r: what top players of your spec cast, for "
        .. "where you are (this raid boss, else the generic single-target rotation; this dungeon, else the generic "
        .. "dungeon rotation), plus your spec's fixed rules from current guides. Casting what NEXT shows moves it "
        .. "into NOW. Out of combat, NOW is Blizzard's pick. Only spells you have talented are suggested. "
        .. "The data is pulled and built on your PC (see the Spec data page).", 24)
    widgets.srcBlizz = radio("Learn from Blizzard", function() BRAT.SetSource("blizzard") end)
    help("NOW and NEXT come from the |cffffffffBlizzard rotation|r BRAT builds from your own fights: every fight "
        .. "records what Blizzard's assistant picked (raw cache); you rebuild the averages and then the rotation "
        .. "(Spec data page, or |cffffffff/brat averages|r then |cffffffff/brat rotation|r). Same layout: per raid "
        .. "boss + generic single target, per dungeon + generic dungeon. Until a rotation is built, NOW is "
        .. "Blizzard's own pick.", 24)
    help("You can switch at any time and nothing is lost: BRAT records Blizzard's picks into the raw cache in either "
        .. "mode. Slash: |cffffffff/brat source logs|r or |cffffffff/brat source blizzard|r.")

    -- Targets -----------------------------------------------------------------
    heading("Enemy count")
    help("The best next spell depends on how many enemies you're fighting, so all of BRAT's data is split by target "
        .. "count (1, 2, 3 ... up to your spec's rotation cap). The label above the icons shows the count in use, "
        .. "e.g. |cffffffff3T|r, or |cffffffff4+T|r at the cap. To choose which rotation each enemy count uses, "
        .. "open the |cffffffffRotations|r page under BRAT in the list on the left.")
    widgets.tgAuto = radio("Auto", function() db.targets = "auto" end)
    help("Counts enemy nameplates that are in range and fighting you (your target, or anything you've hit); enemies "
        .. "only fighting other players nearby don't count. The Dungeoneer's Training Dummy always counts as 1 "
        .. "target. |cffffd100Enemy nameplates must be turned on|r "
        .. "(default key: V). If BRAT can't read nameplates during combat, it assumes 1 target and tells you once in chat.", 24)
    widgets.tgForced = radio("Fixed:", function() if db.targets == "auto" then db.targets = "1" end end)
    local rowY = y + 22
    widgets.tgMinus = button("-", 24, 100, rowY + 2, function()
        db.targets = tostring(math.max(1, (tonumber(db.targets) or 2) - 1))
    end)
    widgets.tgValue = inlineText(132, rowY - 2)
    widgets.tgPlus = button("+", 24, 156, rowY + 2, function()
        db.targets = tostring(math.min(BRAT.MAX_TARGETS, (tonumber(db.targets) or 0) + 1))
    end)
    help("Always use this many targets, e.g. set 1 for a single-target boss, or if Auto miscounts. "
        .. "Slash command: |cffffffff/brat targets 3|r, back to auto with |cffffffff/brat targets auto|r.", 24)
    widgets.tgStatus = status()

    -- Display -----------------------------------------------------------------
    heading("Display")
    widgets.locked = check("Lock position", function(v)
        db.locked = v and true or false; BRAT.Display:ApplySettings()
    end)
    help("Untick to move the icons: a blue box appears, drag it where you want, then tick this again. "
        .. "While unlocked the icons are always visible. Slash: |cffffffff/brat unlock|r, |cffffffff/brat lock|r.", 28)
    widgets.ooc = check("Show out of combat when targeting an enemy", function(v)
        db.showOutOfCombat = v and true or false
    end)
    help("When ticked, the icons appear as soon as you target something you can attack, so you can plan your opener. "
        .. "When unticked, they only appear in combat.", 28)
    local sY = y
    inlineText(20, sY - 4):SetText("Scale:")
    button("-", 24, 70, sY, function() db.scale = math.max(0.5, db.scale - 0.1); BRAT.Display:ApplySettings() end)
    widgets.scaleValue = inlineText(102, sY - 4)
    button("+", 24, 136, sY, function() db.scale = math.min(3, db.scale + 0.1); BRAT.Display:ApplySettings() end)
    button("Reset position", 120, 176, sY, function() SlashCmdList.BRAT("reset") end)
    gap(28)
    help("Makes the icons bigger or smaller (0.5 to 3). |cffffffffReset position|r puts them back near the middle of the "
        .. "screen at normal size, useful if they end up off screen. Slash: |cffffffff/brat scale 1.5|r, |cffffffff/brat reset|r.", 4)

    -- Keybind text size slider (plain Slider, no template, so patches can't break it).
    local kY = y
    inlineText(20, kY - 4):SetText("Keybind text size:")
    local slider = CreateFrame("Slider", nil, content, "BackdropTemplate")
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(200, 16)
    slider:SetPoint("TOPLEFT", 150, kY - 2)
    slider:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    slider:SetMinMaxValues(8, 32)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    slider:EnableMouseWheel(true)
    slider:SetScript("OnMouseWheel", function(s, d) s:SetValue(s:GetValue() + d) end)
    slider:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v + 0.5)
        widgets.keySizeValue:SetText(tostring(v))
        if db.keySize ~= v then db.keySize = v; BRAT.Display:ApplySettings() end
    end)
    widgets.keySize = slider
    widgets.keySizeValue = inlineText(362, kY - 4)
    gap(28)
    help("Makes the keybind letters in the corner of each icon bigger or smaller (8 to 32) without changing the icon "
        .. "size. The NEXT icon's text scales down to match its smaller icon. Drag the slider or use the mouse wheel. "
        .. "Slash: |cffffffff/brat keysize 18|r.", 4)

    local nY = y
    inlineText(20, nY - 4):SetText("Upcoming spells:")
    button("-", 24, 150, nY, function()
        db.nextCount = math.max(0, (db.nextCount or 1) - 1); BRAT.Display:ApplySettings()
    end)
    widgets.nextCountValue = inlineText(182, nY - 4)
    button("+", 24, 200, nY, function()
        db.nextCount = math.min(2, (db.nextCount or 1) + 1); BRAT.Display:ApplySettings()
    end)
    gap(28)
    help("How many spells to show after NOW: |cffffffff0|r = NOW only, |cffffffff1|r = NOW and NEXT, "
        .. "|cffffffff2|r = NOW, NEXT and THEN (a smaller third icon: the spell after NEXT). THEN is a further "
        .. "guess, so it changes more often. Slash: |cffffffff/brat next 2|r.", 4)

    local sY = y
    inlineText(20, sY - 4):SetText("SOON warning:")
    button("-", 24, 150, sY, function()
        db.soonSeconds = math.max(0, (db.soonSeconds or 3) - 0.5)
    end)
    widgets.soonValue = inlineText(182, sY - 4)
    button("+", 24, 230, sY, function()
        db.soonSeconds = math.min(10, (db.soonSeconds or 3) + 0.5)
    end)
    gap(28)
    help("Small grey |cffffd100SOON|r icons with a countdown, right of the upcoming spells, for every spell with a "
        .. "cooldown that comes back within this many seconds (soonest first, up to 3): Holy Word: Chastise, Holy "
        .. "Fire, Apotheosis, Halo, defensives... Spells already in NOW/NEXT/THEN aren't repeated. Outside your "
        .. "rotation, a cooldown shows once you've cast it this session (the game hides cooldowns in combat). "
        .. "0 = off. Slash: |cffffffff/brat soon 3|r.", 4)

    -- Data --------------------------------------------------------------------
    heading("Data")
    widgets.dataStatus = help("")
    gap(30) -- room for the two status lines filled in by Refresh()
    button("Clear learned data from Blizzard", 230, 16, y, function() StaticPopup_Show("BRAT_CONFIRM_FORGET") end)
    gap(30)
    help("Clears the Blizzard cache and rotation for your current spec (asks first). Warcraft Logs data is not "
        .. "affected. For each part on its own (cache / rotation, Blizzard / Warcraft Logs) and rebuilding, see the "
        .. "|cffffffffSpec data|r page. Slash: |cffffffff/brat forget|r, |cffffffff/brat rebuild|r. "
        .. "|cffffffff/brat stats|r prints a summary of all data in chat.", 4)

    -- Fight log + analysis ------------------------------------------------------
    heading("Fight log and analysis")
    widgets.history = check("Log every fight", function(v) db.recordHistory = v and true or false end)
    help("Records every fight: each Blizzard pick, what NOW and NEXT showed, what you cast, cooldowns, procs and "
        .. "enemy count. Keeps several hours of fights; the oldest drop off first. Slash: "
        .. "|cffffffff/brat history|r (how much is logged), |cffffffff/brat history clear|r.", 28)
    widgets.historyStatus = status()
    button("Analyze my fights", 160, 16, y, function() BRAT.Report:Run() end)
    button("Last 10 fights only", 160, 184, y, function() BRAT.Report:Run(10) end)
    gap(30)
    help("Studies every logged fight for your current spec and opens a results window: how often NEXT matched "
        .. "Blizzard, how BRAT's NEXT, Blizzard's picks and your own casts compare with the top Warcraft Logs "
        .. "players (success %), the most common NEXT mistakes, cooldown estimates that were off, procs, and "
        .. "Blizzard's priority list per enemy count. Each run is saved so the window shows the trend. "
        .. "Slash: |cffffffff/brat analyze|r, or |cffffffff/brat analyze 10|r for the last 10 fights.", 4)

    content:SetHeight(-y + 20)
    panel:SetScript("OnShow", function() Options:Refresh() end)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        category = Settings.RegisterCanvasLayoutCategory(panel, "BRAT")
        Settings.RegisterAddOnCategory(category)
    end
    self:BuildRotations()
    self:BuildContexts()
    self:BuildSpecData()
    self:BuildCompare()
end

---------------------------------------------------------------------------
-- "Rotations" page: which rotation to use for each enemy count.
---------------------------------------------------------------------------
local rotPanel
local rows = {}
local rw = {}

local function bucketLabel(b, cap)
    if b >= cap then return b .. "+ targets" end
    return b == 1 and "1 target" or (b .. " targets")
end

-- Most-cast spells in a rotation bucket, for the preview column.
local function topSpells(b)
    local d = BRAT.ActiveSourceObj():Data()
    local t = d and d[b]
    if not t then return "|cff888888no data yet|r" end
    local totals, list = {}, {}
    for _, tos in pairs(t) do for to, n in pairs(tos) do totals[to] = (totals[to] or 0) + n end end
    for id, n in pairs(totals) do list[#list + 1] = { id = id, n = n } end
    table.sort(list, function(a, c) return a.n > c.n end)
    local names = {}
    for i = 1, math.min(3, #list) do
        names[i] = (C_Spell.GetSpellName and C_Spell.GetSpellName(list[i].id)) or tostring(list[i].id)
    end
    return #names > 0 and table.concat(names, ", ") or "|cff888888no data yet|r"
end

-- Dropdown per row (modern menu API); falls back to a click-to-cycle button.
local function makePicker(parent, count)
    local ok, dd = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    if ok and dd and dd.SetupMenu then
        dd:SetWidth(160)
        dd:SetupMenu(function(_, root)
            local cap = BRAT.GetCap()
            for b = 1, cap do
                root:CreateRadio(bucketLabel(b, cap),
                    function() return BRAT.GetRemap(count) == b end,
                    function() BRAT.SetRemap(count, b); Options:Refresh() end)
            end
        end)
        dd.Update = function(self) if self.GenerateMenu then self:GenerateMenu() end end
        return dd
    end
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(160, 22)
    b:SetScript("OnClick", function()
        local cap = BRAT.GetCap()
        BRAT.SetRemap(count, BRAT.GetRemap(count) % cap + 1)
        Options:Refresh()
    end)
    b.Update = function(self) self:SetText(bucketLabel(BRAT.GetRemap(count), BRAT.GetCap())) end
    return b
end

function Options:BuildRotations()
    local db = BRAT.db
    rotPanel = CreateFrame("Frame")
    rotPanel.name = "Rotations"

    local function text(font, x, y, w)
        local fs = rotPanel:CreateFontString(nil, "ARTWORK", font)
        fs:SetPoint("TOPLEFT", x, y)
        fs:SetJustifyH("LEFT")
        if w then fs:SetWidth(w); fs:SetSpacing(2) end
        return fs
    end
    local function greyHelp(s, x, y)
        local fs = text("GameFontHighlightSmall", x, y, WIDTH - (x - 16))
        fs:SetTextColor(0.75, 0.75, 0.75)
        fs:SetText(s)
        return fs
    end

    text("GameFontNormalHuge", 16, -12):SetText("Rotations by enemy count")
    rw.spec = text("GameFontHighlight", 16, -42)
    greyHelp("Choose which rotation NEXT uses for each number of enemies. By default each count uses its own "
        .. "rotation. Change one to make BRAT play differently, e.g. set 2 enemies to use the 1-target rotation "
        .. "if you'd rather not cleave. Settings are saved per spec. BRAT still learns under the real enemy count, "
        .. "so remapping never mixes up its data. The label above the icons shows a remap like "
        .. "|cffffffff2T > 1T rotation|r.", 16, -62)

    -- Mode: auto vs fixed (same setting as the main page) --------------------
    text("GameFontNormal", 16, -140):SetText("How BRAT counts enemies")
    rw.auto = CreateFrame("CheckButton", nil, rotPanel, "UIRadioButtonTemplate")
    rw.auto:SetPoint("TOPLEFT", 20, -160)
    controlLabel(rw.auto, "Auto: count enemy nameplates (turn nameplates on)")
    rw.auto:SetScript("OnClick", function() db.targets = "auto"; Options:Refresh() end)
    rw.fixed = CreateFrame("CheckButton", nil, rotPanel, "UIRadioButtonTemplate")
    rw.fixed:SetPoint("TOPLEFT", 20, -182)
    controlLabel(rw.fixed, "Fixed: always")
    rw.fixed:SetScript("OnClick", function()
        if db.targets == "auto" then db.targets = "1" end; Options:Refresh()
    end)
    local function step(d)
        db.targets = tostring(math.max(1, math.min(BRAT.GetCap(), (tonumber(db.targets) or 1) + d)))
        Options:Refresh()
    end
    rw.minus = CreateFrame("Button", nil, rotPanel, "UIPanelButtonTemplate")
    rw.minus:SetSize(24, 22); rw.minus:SetPoint("TOPLEFT", 140, -180); rw.minus:SetText("-")
    rw.minus:SetScript("OnClick", function() step(-1) end)
    rw.value = text("GameFontHighlight", 172, -184)
    rw.plus = CreateFrame("Button", nil, rotPanel, "UIPanelButtonTemplate")
    rw.plus:SetSize(24, 22); rw.plus:SetPoint("TOPLEFT", 196, -180); rw.plus:SetText("+")
    rw.plus:SetScript("OnClick", function() step(1) end)
    greyHelp("Fixed is handy for a single-target boss or when Auto miscounts. "
        .. "Slash: |cffffffff/brat targets 3|r or |cffffffff/brat targets auto|r.", 44, -206)

    -- Table --------------------------------------------------------------------
    text("GameFontNormal", 16, -240):SetText("Enemies")
    text("GameFontNormal", 100, -240):SetText("Use rotation")
    text("GameFontNormal", 290, -240):SetText("Its most-cast spells")
    for k = 1, BRAT.MAX_TARGETS do
        local y = -262 - (k - 1) * 30
        local r = {}
        r.count = text("GameFontHighlightLarge", 30, y - 4)
        r.picker = makePicker(rotPanel, k)
        r.picker:SetPoint("TOPLEFT", 90, y + 2)
        r.preview = text("GameFontHighlightSmall", 290, y - 4, 300)
        r.preview:SetWordWrap(false)
        rows[k] = r
    end
    rw.reset = CreateFrame("Button", nil, rotPanel, "UIPanelButtonTemplate")
    rw.reset:SetSize(200, 22)
    rw.reset:SetText("Reset to defaults")
    rw.reset:SetScript("OnClick", function()
        db.remap[BRAT.GetSpecID()] = nil; Options:Refresh()
    end)
    rw.capHelp = greyHelp("", 16, 0)

    rotPanel:SetScript("OnShow", function() Options:Refresh() end)
    if category and Settings.RegisterCanvasLayoutSubcategory then
        Settings.RegisterCanvasLayoutSubcategory(category, rotPanel, "Rotations")
    end
end

function Options:RefreshRotations()
    if not rotPanel or not rotPanel:IsShown() then return end
    local db = BRAT.db
    local cap = BRAT.GetCap()
    local info = BRAT.WCLInfo()
    rw.spec:SetText("Spec: |cffffffff" .. specName() .. "|r   Rotation cap: |cffffffff" .. cap .. " targets|r"
        .. (info and "" or " (no Warcraft Logs data, using the default)"))

    local auto = db.targets == "auto"
    rw.auto:SetChecked(auto)
    rw.fixed:SetChecked(not auto)
    rw.value:SetText(auto and "-" or db.targets)
    rw.minus:SetEnabled(not auto)
    rw.plus:SetEnabled(not auto)

    local lastY
    for k = 1, BRAT.MAX_TARGETS do
        local r, shown = rows[k], k <= cap
        r.count:SetShown(shown); r.picker:SetShown(shown); r.preview:SetShown(shown)
        if shown then
            r.count:SetText(k == cap and (k .. "+") or tostring(k))
            local b = BRAT.GetRemap(k)
            local changed = b ~= k
            r.count:SetTextColor(changed and 1 or 1, changed and 0.82 or 1, changed and 0 or 1)
            r.picker:Update()
            r.preview:SetText(topSpells(b))
            lastY = -262 - (k - 1) * 30
        end
    end
    rw.reset:ClearAllPoints()
    rw.reset:SetPoint("TOPLEFT", 16, lastY - 36)
    rw.capHelp:ClearAllPoints()
    rw.capHelp:SetPoint("TOPLEFT", 16, lastY - 66)
    rw.capHelp:SetText("Counts in |cffffd100gold|r are remapped. The last row (" .. cap .. "+) covers every count from "
        .. cap .. " up: above the rotation cap, top players' rotation doesn't change. The preview shows "
        .. (db.source == "logs" and "Warcraft Logs data" or "what BRAT learned from Blizzard")
        .. ", matching your current NEXT source. Reset to defaults puts every count back on its own rotation.")
end

---------------------------------------------------------------------------
-- "Compare sources" page: how well BRAT knows each rotation, DPS per
-- source, A/B testing, your real parses, and the 90%+ readiness verdict.
---------------------------------------------------------------------------
local cmpPanel
local cw = {}

local function pct(x) return ("%.0f%%"):format((x or 0) * 100) end
local function short(n)
    if n >= 1e6 then return ("%.2fM"):format(n / 1e6) end
    if n >= 1e3 then return ("%.0fk"):format(n / 1e3) end
    return tostring(math.floor(n))
end
local function colored(ok, s) return (ok and "|cff33e64d" or "|cffff8800") .. s .. "|r" end

function Options:BuildCompare()
    local db = BRAT.db
    cmpPanel = CreateFrame("Frame")
    cmpPanel.name = "Compare sources"
    local scroll = CreateFrame("ScrollFrame", nil, cmpPanel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", -28, 4)
    local mainContent = content
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(WIDTH + 32, 10)
    scroll:SetScrollChild(content)
    y = -12

    local title = content:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 16, y)
    title:SetText("Compare sources")
    gap(28)
    cw.spec = help("")
    help("Data to help you choose where NEXT comes from, for your current spec. Everything here fills in as you "
        .. "play: BRAT scores its guesses every time you cast, and records your DPS after every fight of 20 seconds "
        .. "or more (from Blizzard's built-in damage meter).")

    heading("How well BRAT knows each rotation")
    cw.know = help("")
    gap(56)
    help("|cffffffffMatches Blizzard|r: after you cast the NOW spell, how often that source's NEXT guess was exactly "
        .. "what Blizzard's assistant recommended next (your last 300 casts). For Learn from Blizzard this is how "
        .. "well it has learned; for Warcraft Logs it shows how much top players differ from Blizzard, which is "
        .. "not a bad thing. |cffffffffHas a guess|r: how often the source had enough data to guess at all.")

    heading("Does BRAT know Blizzard's rotation?")
    cw.verdict = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    cw.verdict:SetPoint("TOPLEFT", 16, y)
    cw.verdict:SetWidth(WIDTH); cw.verdict:SetJustifyH("LEFT")
    gap(26)

    cw.reasons = help("")
    gap(56)
    
    help("This is about |cffffffffLearn from Blizzard|r: BRAT has learned Blizzard's rotation when NEXT matches "
        .. "Blizzard at least 90% of the time over 300+ casts, and at least 85% at every enemy count you've "
        .. "fought. A perfectly learned rotation makes you as good as Blizzard's assistant; how much DPS that "
        .. "is compared with Warcraft Logs is below.")

    heading("Which source does more DPS?")
    cw.dps = help("")

    heading("Your Warcraft Logs parses")
    cw.parses = help("")
    gap(76)

    cw.useBest = button("Use the recommended source", 220, 16, y, function()
        local w = BRAT.Stats:Winner(BRAT.GetSpecID())
        if w then BRAT.SetSource(w) end
    end)
    gap(30)

    help("Your DPS from Blizzard's damage meter after every fight of 20 seconds or more (raid, dungeons, target "
        .. "dummies), recorded for whichever source BRAT was using. Each fight is only compared with similar "
        .. "fights (same boss or dummy, similar enemy count), so a dummy and a raid boss don't mix. BRAT "
        .. "recommends a source once both have 5+ comparable fights and one is clearly ahead (more than the "
        .. "fight-to-fight noise).")
    cw.ab = check("A/B test: switch source automatically each pull", function(v)
        db.abTest = v and true or false
    end)
    help("Gets both sources fights on the same bosses and dummies. While ticked, BRAT uses whichever source has "
        .. "fewer fights there at every pull. The source you picked comes back between fights. Untick once the "
        .. "recommendation is clear.", 28)

    gap(8)
    button("Reset comparison data for this spec", 260, 16, y, function() StaticPopup_Show("BRAT_CONFIRM_RESET_CMP") end)
    gap(30)
    help("Starts the comparison fresh for this spec: clears fight DPS records and prediction scores. The rotation "
        .. "data itself is kept. Use after a big gear jump or a patch, when old results no longer apply.", 4)

    content:SetHeight(-y + 20)
    content = mainContent

    cmpPanel:SetScript("OnShow", function() Options:Refresh() end)
    if category and Settings.RegisterCanvasLayoutSubcategory then
        Settings.RegisterCanvasLayoutSubcategory(category, cmpPanel, "Compare sources")
    end
end

---------------------------------------------------------------------------
-- "Raid & Mythic+" page: the suggested rotation per boss and per dungeon,
-- the Raid and Mythic+ averages, and which one BRAT is using right now.
---------------------------------------------------------------------------
local ctxPanel, ctxText, ctxContent

-- "Smite > Holy Fire > Holy Word: Chastise": most-cast spells in one target bucket.
local function rotationSummary(rot, bucket)
    local t = rot and rot[bucket]
    if not t then return nil end
    local totals, list = {}, {}
    for _, tos in pairs(t) do for to, n in pairs(tos) do totals[to] = (totals[to] or 0) + n end end
    for id, n in pairs(totals) do list[#list + 1] = { id = id, n = n } end
    table.sort(list, function(a, b) return a.n > b.n end)
    local names = {}
    for i = 1, math.min(4, #list) do
        names[i] = (C_Spell.GetSpellName and C_Spell.GetSpellName(list[i].id)) or tostring(list[i].id)
    end
    return #names > 0 and table.concat(names, " > ") or nil
end

local function describe(rot, cap)
    local single = rotationSummary(rot, 1) or "|cff888888no data|r"
    local aoe = rotationSummary(rot, cap) or "|cff888888no data|r"
    return ("      |cffffffff1 target:|r %s\n      |cffffffff%d+ targets:|r %s"):format(single, cap, aoe)
end

---------------------------------------------------------------------------
-- "Spec data" page: pick a spec, clear its Warcraft Logs data (BRAT then
-- learns from Blizzard in real time, and the spec is flagged for a new pull by
-- BRAT Data Manager on your PC) or clear what it learned.
---------------------------------------------------------------------------
local sdPanel, sdText, sdSpec
local sdButtons = {}

local function specLabel(spec)
    local _, name, _, _, _, _, className = GetSpecializationInfoByID(spec)
    return name and ((name .. " " .. (className or "")):gsub("%s+$", "")) or ("spec " .. spec)
end

-- Specs BRAT has anything for, plus the one you're playing.
local function knownSpecs()
    local set, list = {}, {}
    local function add(s) if type(s) == "number" and s > 0 and not set[s] then set[s] = true; list[#list + 1] = s end end
    add(BRAT.GetSpecID())
    for s in pairs(BRAT.SpecRules or {}) do add(s) end
    for s in pairs(BRAT.WCLRaw or {}) do add(s) end
    for s in pairs(BRAT.db.bcache or {}) do add(s) end
    table.sort(list)
    return list
end

-- One confirm popup for every button here: data = { fn }.
StaticPopupDialogs["BRAT_SD_CONFIRM"] = {
    text = "%s",
    button1 = YES, button2 = CANCEL,
    OnAccept = function(_, data) if data and data.fn then data.fn() end; Options:Refresh() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
local function confirm(text, fn) StaticPopup_Show("BRAT_SD_CONFIRM", text, nil, { fn = fn }) end

local RED, GREY = "|cffff4040", "|cff999999"
local sections = {} -- [source key] = widgets of that section

function Options:BuildSpecData()
    sdPanel = CreateFrame("Frame")
    sdPanel.name = "Spec data"
    local scroll = CreateFrame("ScrollFrame", nil, sdPanel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", -28, 4)
    local c = CreateFrame("Frame", nil, scroll)
    c:SetSize(WIDTH + 32, 640)
    scroll:SetScrollChild(c)

    local function text(font, x, yy, w)
        local fs = c:CreateFontString(nil, "ARTWORK", font)
        fs:SetPoint("TOPLEFT", x, yy)
        if w then fs:SetWidth(w); fs:SetJustifyH("LEFT"); fs:SetSpacing(2) end
        return fs
    end
    local function btn(label, x, yy, w, fn)
        local b = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
        b:SetSize(w, 22); b:SetPoint("TOPLEFT", x, yy); b:SetText(label)
        b:SetScript("OnClick", function() fn(); Options:Refresh() end)
        return b
    end
    local function step(d)
        local list = knownSpecs()
        local idx = 1
        for i, s in ipairs(list) do if s == sdSpec then idx = i end end
        sdSpec = list[((idx - 1 + d) % #list) + 1]
    end

    text("GameFontNormalHuge", 16, -12):SetText("Spec data")
    btn("<", 16, -48, 26, function() step(-1) end)
    sdButtons.specName = text("GameFontNormalLarge", 50, -51)
    sdButtons.specName:SetWidth(260)
    btn(">", 314, -48, 26, function() step(1) end)
    local intro = text("GameFontHighlightSmall", 16, -78, WIDTH)
    intro:SetTextColor(0.75, 0.75, 0.75)
    intro:SetText("Each source has three layers: 1. the raw cache, 2. the averages built from it, 3. the rotation built "
        .. "from the averages, which is what BRAT serves (raid: per boss + generic single target; dungeons: per "
        .. "dungeon + generic dungeon). Each can be cleared or built on its own; BRAT tells you in chat when it's done.")

    -- One section per source, drawn by the same code.
    -- extra = optional { label, fn(spec) } second button on the raw-cache row.
    local function section(key, top, rawLabel, extra)
        local src = BRAT.Sources[key]
        local w = { src = src }
        sections[key] = w
        w.head = text("GameFontNormalLarge", 16, top)
        local rows = {
            { "1. Raw cache (" .. rawLabel .. ")", "clearraw", extra },
            { "2. Averages", "clearavg", { "Rebuild averages", function(spec) src:Run("averages", spec) end } },
            { "3. Rotation (served)", "clearrot", { "Build rotation", function(spec) src:Run("rotation", spec) end } },
        }
        for i, r in ipairs(rows) do
            local yy = top - 24 - (i - 1) * 44
            text("GameFontNormal", 16, yy):SetText(r[1])
            w["status" .. i] = text("GameFontHighlightSmall", 32, yy - 16, 300)
            w["clear" .. i] = btn("Clear", 340, yy - 4, 70, function()
                local spec = sdSpec
                confirm(("%s %s for %s?"):format(i == 1 and "Clear the" or "Clear the", src.name .. " " ..
                    ({ "raw cache", "averages", "rotation" })[i], specLabel(spec)), function() src:Run(r[2], spec) end)
            end)
            if r[3] then
                w["build" .. i] = btn(r[3][1], 416, yy - 4, 190, function() r[3][2](sdSpec) end)
            end
        end
        w.warn = text("GameFontHighlight", 16, top - 24 - 3 * 44, WIDTH)
        return w
    end

    section("logs", -126, "ships with the addon")
    section("blizzard", -340, "your fights; fills as you play", { "Fill from fight log", function(spec)
        confirm(("Refill the Blizzard raw cache for %s from the fight log (every logged fight, the data the "
            .. "analysis uses)? This replaces the current raw cache."):format(specLabel(spec)), function()
            print(("|cff66ccffBRAT|r: Blizzard raw cache filled from %d logged fights. Next: Rebuild averages.")
                :format(BRAT.Learn:ImportLog(spec)))
        end)
    end })

    local help = text("GameFontHighlightSmall", 16, -560, WIDTH)
    help:SetTextColor(0.75, 0.75, 0.75)
    help:SetText("Warcraft Logs' raw cache is top-player data that ships with BRAT and updates with new addon "
        .. "versions. Blizzard's raw cache gets a new entry after every fight; BRAT tells you when there's enough "
        .. "to rebuild. Slash: |cffffffff/brat averages|r and |cffffffff/brat rotation|r (your source), or add "
        .. "|cffffffffwcl|r / |cffffffffblizzard|r.")

    sdPanel:SetScript("OnShow", function() sdSpec = sdSpec or BRAT.GetSpecID(); Options:RefreshSpecData() end)
    if category and Settings.RegisterCanvasLayoutSubcategory then
        Settings.RegisterCanvasLayoutSubcategory(category, sdPanel, "Spec data")
    end
end

-- Status text and button states for one source's section.
local function refreshSection(w, spec, inUse)
    local src = w.src
    local st = src:Status(spec)
    w.head:SetText(src.name .. (inUse and "  |cff33e64d(your source)|r" or ""))
    local stamp = function(t) return t and date("%Y-%m-%d %H:%M", t) or "?" end
    w.status1:SetText(st.rawCount > 0 and st.rawInfo or (RED .. "empty|r"))
    w.status2:SetText(st.avgBuilt and ("built %s from %d; %d bosses, %d dungeons%s"):format(stamp(st.avgBuilt),
        st.avgFights or 0, st.avgBosses or 0, st.avgDungeons or 0, st.avgStale and (RED .. " (older than the raw cache)|r") or "")
        or (RED .. "none|r"))
    w.status3:SetText(st.rotBuilt and ("built %s; %d bosses, %d dungeons + generic%s"):format(stamp(st.rotBuilt),
        st.rotBosses or 0, st.rotDungeons or 0, st.rotStale and (RED .. " (older than the averages)|r") or "")
        or (RED .. "none|r" .. (inUse and GREY .. " (NOW shows Blizzard's own pick)|r" or "")))
    local warn = ""
    if st.rawCount == 0 and not st.avgBuilt then
        warn = RED .. "The raw cache and the averages are both empty.|r " .. src.emptyHint
            .. " Then Rebuild averages, then Build rotation."
    elseif not st.avgBuilt then
        warn = "No averages: Rebuild averages, then Build rotation."
    elseif not st.rotBuilt then
        warn = "No rotation in use: Build rotation."
    elseif st.avgStale then
        warn = "The raw cache has newer data: Rebuild averages, then Build rotation."
    elseif st.rotStale then
        warn = "The averages are newer than the rotation: Build rotation."
    end
    w.warn:SetText(warn)
    w.clear1:SetEnabled(st.canClearRaw and st.rawCount > 0)
    w.clear2:SetEnabled(st.avgBuilt ~= nil)
    w.clear3:SetEnabled(st.rotBuilt ~= nil)
    w.build2:SetEnabled(st.rawCount > 0)
    w.build3:SetEnabled(st.avgBuilt ~= nil)
end

function Options:RefreshSpecData()
    if not sdPanel or not sdPanel:IsShown() then return end
    sdSpec = sdSpec or BRAT.GetSpecID()
    sdButtons.specName:SetText(specLabel(sdSpec) .. (sdSpec == BRAT.GetSpecID() and "  |cff33e64d(playing)|r" or ""))
    local active = BRAT.ActiveSourceObj()
    for _, w in pairs(sections) do refreshSection(w, sdSpec, w.src == active) end
end

function Options:BuildContexts()
    ctxPanel = CreateFrame("Frame")
    ctxPanel.name = "Raid & Mythic+"
    local scroll = CreateFrame("ScrollFrame", nil, ctxPanel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", -28, 4)
    ctxContent = CreateFrame("Frame", nil, scroll)
    ctxContent:SetSize(WIDTH + 32, 10)
    scroll:SetScrollChild(ctxContent)

    local title = ctxContent:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 16, -12)
    title:SetText("Raid & Mythic+")
    ctxText = ctxContent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    ctxText:SetPoint("TOPLEFT", 16, -44)
    ctxText:SetWidth(WIDTH)
    ctxText:SetJustifyH("LEFT")
    ctxText:SetSpacing(3)

    ctxPanel:SetScript("OnShow", function() Options:RefreshContexts() end)
    if category and Settings.RegisterCanvasLayoutSubcategory then
        Settings.RegisterCanvasLayoutSubcategory(category, ctxPanel, "Raid & Mythic+")
    end
end

function Options:RefreshContexts()
    if not ctxPanel or not ctxPanel:IsShown() then return end
    local cap = BRAT.GetCap()
    local lines = {}
    local function add(s) lines[#lines + 1] = s end
    local function grey(s) return "|cffaaaaaa" .. s .. "|r" end
    local src = BRAT.ActiveSourceObj()
    local rot = src:Rot()

    add(grey("The rotation BRAT serves for your source (" .. src.name .. "), picked automatically at the start of "
        .. "every fight. Each line shows the most-cast spells for 1 target and for your spec's rotation cap; the "
        .. "enemy count above the icons picks the target bucket inside each rotation."))
    add("")
    local _, _, here = BRAT.Context:Where()
    local _, hereLabel = src:Data()
    add(("|cffffd100In use right now:|r %s (%s)"):format(hereLabel or "no rotation", here or "?"))
    add("")
    add(grey("How it picks: a raid boss with its own rotation uses it, else the generic single-target rotation (also "
        .. "raid trash, raid groups, solo and the Dungeoneer's Training Dummy). A dungeon uses its own rotation for "
        .. "the whole dungeon, else the generic dungeon rotation (also parties and the Cleave Training Dummy)."))
    add("")
    if not rot then
        add(grey("No " .. src.name .. " rotation built for this spec yet: BRAT settings > Spec data > Build rotation."))
    else
        local sectionsList = {
            { "RAID", "Generic single target", rot.raid.generic, rot.raid.bosses },
            { "DUNGEONS", "Generic dungeon", rot.dungeon.generic, rot.dungeon.dungeons },
        }
        for _, s in ipairs(sectionsList) do
            add("|cffffd100" .. s[1] .. "|r")
            add("  |cff66ccff" .. s[2] .. "|r")
            add(s[3] and describe(s[3], cap) or grey("      no data"))
            local keys = {}
            for k in pairs(s[4]) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(rot.labels[a] or a) < tostring(rot.labels[b] or b) end)
            for _, k in ipairs(keys) do
                add("  |cffffffff" .. tostring(rot.labels[k] or k) .. "|r")
                add(describe(s[4][k], cap))
            end
            add("")
        end
    end
    ctxText:SetText(table.concat(lines, "\n"))
    ctxContent:SetHeight(ctxText:GetStringHeight() + 70)
end

StaticPopupDialogs["BRAT_CONFIRM_RESET_CMP"] = {
    text = "Start this spec's comparison fresh? DPS records and prediction scores are cleared, and earlier parses stop counting.",
    button1 = YES, button2 = NO,
    OnAccept = function() BRAT.Stats:ResetComparison(); Options:Refresh() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

function Options:RefreshCompare()
    if not cmpPanel or not cmpPanel:IsShown() then return end
    local S = BRAT.Stats
    local spec = BRAT.GetSpecID()
    cw.spec:SetText("Spec: |cffffffff" .. specName() .. "|r.  NEXT source now: |cffffffff"
        .. S.LABEL[BRAT.db.source or "logs"] .. "|r" .. (BRAT.db.abTest and "  (A/B test on)" or ""))

    -- Knowledge
    local lines = {}
    for _, src in ipairs(S.SOURCES) do
        local a = S:Accuracy(src, spec)
        if a.n == 0 then
            lines[#lines + 1] = ("|cffffffff%s|r: no casts scored yet."):format(S.LABEL[src])
        else
            lines[#lines + 1] = ("|cffffffff%s|r: matches Blizzard %s, has a guess %s  (last %d casts)"):format(
                S.LABEL[src], pct(a.match), pct(a.coverage), a.n)
            local parts, cap = {}, BRAT.GetCap()
            for k = 1, cap do
                local bk = a.buckets[k]
                if bk and bk.seen >= 5 then
                    parts[#parts + 1] = ("%s: %s"):format(k >= cap and (k .. "+") or k, pct(bk.hit / bk.seen))
                end
            end
            if #parts > 0 then lines[#lines + 1] = "      by enemy count  " .. table.concat(parts, "   ") end
        end
    end
    cw.know:SetText(table.concat(lines, "\n"))

    -- Readiness
    local r = S:Readiness(spec)
    local avg = ("%.0f"):format(r.parse and r.parse.avg or 0)
    local verdicts = {
        ready = colored(true, "Yes: rotation learned and your parses average " .. avg),
        ["learned-below-90"] = colored(false, "Rotation learned, but your parses average " .. avg .. " (below 90)"),
        ["learned-no-parses"] = colored(true, "Rotation learned.") .. colored(false, " No parses yet to confirm 90%+."),
        learning = colored(false, "Not yet: still learning Blizzard's rotation"),
    }
    cw.verdict:SetText(verdicts[r.verdict])
    if #r.reasons > 0 then
        cw.reasons:SetText("Still needed:\n- " .. table.concat(r.reasons, "\n- "))
    elseif r.verdict == "learned-below-90" then
        cw.reasons:SetText("Blizzard's rotation is fully learned, so the gap is likely Blizzard's assistant itself, "
            .. "gear, or execution. Compare with Warcraft Logs below.")
    else
        cw.reasons:SetText("")
    end

    -- Parses (the recommendation)
    local winner, ps = S:Winner(spec)
    local p = {}

    for _, src in ipairs(S.SOURCES) do
        local e = ps.raw[src]

        if e.n > 0 then
            p[#p + 1] = ("|cffffffff%s|r: %d parses, average |cffffffff%.0f|r, best %.0f"):format(
                S.LABEL[src], e.n, e.avg, e.best)
        else
            p[#p + 1] = ("|cffffffff%s|r: no parses yet"):format(S.LABEL[src])
        end
    end

    if winner then
        local other = winner == "logs" and "blizzard" or "logs"

        p[#p + 1] = colored(true, ("Recommended: %s (average DPS %.0f vs %.0f)"):format(
            S.LABEL[winner],
            ps.raw[winner].avg,
            ps.raw[other].avg))
    else
        local need = {}
        for _, src in ipairs(S.SOURCES) do
            if ps.raw[src].n < S.MIN_PARSES then
                need[#need + 1] = ("%d more with %s"):format(
                    S.MIN_PARSES - ps.raw[src].n,
                    S.LABEL[src])
            end
        end

        p[#p + 1] = colored(false,
            #need > 0
            and ("No recommendation yet: needs " .. table.concat(need, " and ") .. ".")
            or "Both sources parse exactly the same.")
    end
    local info = BRAT.MyParsesInfo
    if info and info.date then p[#p + 1] = "Parses updated " .. info.date .. "." end
    cw.parses:SetText(table.concat(p, "\n"))
    cw.useBest:SetEnabled(winner ~= nil and winner ~= BRAT.db.source)
    cw.ab:SetChecked(BRAT.db.abTest)

    -- DPS (supporting info)
    local c = S:Compare(spec)
    local d = {}
    for _, src in ipairs(S.SOURCES) do
        local raw = c.raw[src]
        d[#d + 1] = ("|cffffffff%s|r: %d fights, average %s DPS"):format(
            S.LABEL[src], raw.n, raw.n > 0 and short(raw.avg) or "-")
    end
    if c.diff then
        d[#d + 1] = ("In comparable fights Warcraft Logs is %+.1f%% vs Blizzard%s."):format(c.diff * 100,
            c.winner and "" or (" (within normal variation of +/-%.1f%%)"):format(c.noise * 100))
    else
        d[#d + 1] = "Not enough comparable fights yet (5 per source)."
    end
    cw.dps:SetText(table.concat(d, "\n"))
end

StaticPopupDialogs["BRAT_CONFIRM_FORGET"] = {
    text = "Clear learned data from Blizzard for this spec (its Blizzard cache and rotation)?",
    button1 = YES, button2 = NO,
    OnAccept = function() SlashCmdList.BRAT("forget"); Options:Refresh() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

function Options:Refresh()
    if self.RefreshRotations then self:RefreshRotations() end
    if self.RefreshCompare then self:RefreshCompare() end
    if self.RefreshContexts then self:RefreshContexts() end
    if self.RefreshSpecData then self:RefreshSpecData() end
    if not panel or not panel:IsShown() then return end
    local db = BRAT.db
    local spec = BRAT.GetSpecID()

    widgets.srcLogs:SetChecked(db.source == "logs")
    widgets.srcBlizz:SetChecked(db.source ~= "logs")
    -- Which source is in use, and whether it has a rotation for this spec.
    if db.source == "logs" then
        local data, _, label = BRAT.Context:Get()
        if data and next(data) then
            widgets.srcStatus:SetText(("|cff33e64dIn use: Warcraft Logs|r for %s (rotation here: %s)."):format(
                specName(), label or "?"))
        else
            widgets.srcStatus:SetText(("|cffff8800In use: Warcraft Logs|r, but there's no Warcraft Logs rotation for %s: "
                .. "NOW shows Blizzard's pick until you build one (Spec data page)."):format(specName()))
        end
    elseif BRAT.Learn:HasRotation(spec) then
        local _, label = BRAT.Learn:Data()
        widgets.srcStatus:SetText(("|cff33e64dIn use: Learn from Blizzard|r for %s (rotation here: %s)."):format(
            specName(), label or "?"))
    else
        widgets.srcStatus:SetText(("|cffff8800In use: Learn from Blizzard|r, but no Blizzard rotation is built for %s "
            .. "yet: NOW shows Blizzard's own pick (Spec data page to build one)."):format(specName()))
    end

    local auto = db.targets == "auto"
    widgets.tgAuto:SetChecked(auto)
    widgets.tgForced:SetChecked(not auto)
    widgets.tgValue:SetText(auto and "-" or db.targets)
    widgets.tgMinus:SetEnabled(not auto)
    widgets.tgPlus:SetEnabled(not auto)
    widgets.tgStatus:SetText(info and info.cap
        and ("Rotation cap for " .. specName() .. ": |cffffffff" .. info.cap .. " targets|r. Above that, top players' "
            .. "rotation doesn't change, so " .. info.cap .. "+ all use the same data.")
        or "")

    widgets.locked:SetChecked(db.locked)
    widgets.ooc:SetChecked(db.showOutOfCombat)
    widgets.scaleValue:SetText(("%.1f"):format(db.scale))
    widgets.history:SetChecked(db.recordHistory)
    local fights, events = BRAT.History:Count()
    widgets.historyStatus:SetText(("|cffffd100Logged:|r %d fights, %d events%s"):format(
        fights, events, db.recordHistory and "" or " (logging is off)"))
    widgets.nextCountValue:SetText(tostring(db.nextCount or 1))
    widgets.soonValue:SetText((db.soonSeconds or 3) > 0 and ("%.1fs"):format(db.soonSeconds or 3) or "off")
    widgets.keySize:SetValue(db.keySize or 14)
    widgets.keySizeValue:SetText(tostring(db.keySize or 14))

    local lines = {}
    for _, key in ipairs({ "logs", "blizzard" }) do
        local src = BRAT.Sources[key]
        local st = src:Status(spec)
        lines[#lines + 1] = ("|cffffffff%s|r for %s: raw %s; rotation %s (BRAT settings > Spec data)."):format(
            src.name, specName(), st.rawInfo or "empty", st.rotBuilt and "built" or "not built")
    end
    widgets.dataStatus:SetText(table.concat(lines, "\n"))
end

function Options:IsRegistered() return category ~= nil end

-- The settings panel can't be opened in combat: the game blocks it (protected
-- OpenSettingsPanel, an ADDON_ACTION_BLOCKED, which pcall can't catch). Open it
-- as soon as combat ends instead.
local openAfterCombat = CreateFrame("Frame")
openAfterCombat:SetScript("OnEvent", function(f)
    f:UnregisterEvent("PLAYER_REGEN_ENABLED")
    Options:Open()
end)

function Options:Open()
    if InCombatLockdown() then
        print("|cff66ccffBRAT|r: settings open when combat ends.")
        openAfterCombat:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    if category and Settings.OpenToCategory then
        local ok = pcall(Settings.OpenToCategory, category:GetID())
        if ok then return end
    end
    print("|cff66ccffBRAT|r: open Esc > Options > AddOns > BRAT.")
end
