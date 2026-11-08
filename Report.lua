-- BRAT analysis: run on demand (/brat analyze, or the button in /brat) over
-- every fight History.lua logged for your current spec. Shows the results in a
-- window you can copy from, and saves a summary of each run for the trend.
--   * NEXT vs Blizzard: did NEXT match what Blizzard picked after you cast NOW?
--   * vs Warcraft Logs (top ~100 players): are BRAT's NEXT, Blizzard's picks and
--     your casts something top players do after that spell? (success = a common
--     follow-up, #1 = their single most common one)
--   * NEXT misses, cooldown-estimate misses, procs, how often you pressed NOW.
--   * Blizzard's priority per enemy count.
-- tools\Analyze-History.ps1 does the same on your PC and writes .log files.
local _, BRAT = ...
local Report = {}
BRAT.Report = Report

local MAX_RUNS = 200
local MIN_FIGHT = 20     -- seconds; shorter pulls are skipped
local READY = 1.5        -- a spell counts as ready with this little cooldown left
local LINES_PER_FRAME = 1500

local function say(msg) print("|cff66ccffBRAT|r: " .. msg) end
local function name(id) return BRAT.db.spellNames[id] or BRAT.Safe(C_Spell.GetSpellName, id) or tostring(id) end
local function pct(a, b) return (b or 0) > 0 and ("%.1f%%"):format(100 * a / b) or "-" end

local function split(s)
    local f = {}
    for v in (s .. ";"):gmatch("([^;]*);") do f[#f + 1] = v end
    return f
end

local function parseCds(s)
    local cds = {}
    if s and s ~= "" then
        for id, est, left in s:gmatch("(%d+):(~?)([%d%.]+)") do
            cds[tonumber(id)] = { left = tonumber(left), est = est == "~" }
        end
    end
    return cds
end

local function parseGlow(s)
    local g = {}
    if s and s ~= "" then for id in s:gmatch("%d+") do g[#g + 1] = tonumber(id) end end
    return g
end

-- Top players' rotation for this fight, chosen exactly as in game (Sources /
-- RotationBuilder): the dungeon (whole run), else generic dungeon; the raid
-- boss, else generic single target; elsewhere whichever kind BRAT used.
local function bossData(spec, fight)
    local kind, key
    if fight.instType == "party" then
        kind, key = "dungeon", BRAT.Context.Lower(fight.inst)
    elseif fight.enc then
        kind, key = "boss", fight.enc
    elseif fight.instType == "raid" then
        kind = "raid"
    else
        kind = (fight.ctxKind == "mplus") and "mplus" or "raid"
    end
    return (BRAT.Sources.logs:Data(kind, key, spec))
end

-- "After `from`, cast `to`" vs top players. Returns nil (no data for `from`),
-- else top (their #1 choice), known (one of their common choices).
-- `d` = the Warcraft Logs rotation for this fight (bossData).
local function wclEvalWith(spec, tg, from, to, d)
    if not d then return nil end
    local info = BRAT.WCLInfo(spec)
    local cap = (info and info.cap) or BRAT.MAX_TARGETS
    tg = math.max(1, math.min(tg, cap))
    local tos
    for r = 0, BRAT.MAX_TARGETS do
        tos = (d[tg - r] and d[tg - r][from]) or (d[tg + r] and d[tg + r][from])
        if tos then break end
    end
    if not tos then return nil end
    local best, bestN = nil, -1
    for id, n in pairs(tos) do if n > bestN then best, bestN = id, n end end
    return to == best, tos[to] ~= nil
end

local function newTotals()
    return { fights = 0, bossFights = 0, dur = 0, pred = 0, hit = 0,
        nextN = 0, nextTop = 0, nextOk = 0, blizN = 0, blizTop = 0, blizOk = 0, youN = 0, youTop = 0, youOk = 0,
        casts = 0, followed = 0, kinds = {}, misses = {}, late = {}, glow = {}, byBoss = {} }
end

local function bump(t, k, i, v)
    t[k] = t[k] or { 0, 0 }
    t[k][i] = t[k][i] + (v or 1)
end

-- Adds one fight's events to totals `s` and (if given) priority table `prio`.
local function analyzeFight(fight, s, prio)
    s.fights = s.fights + 1
    s.dur = s.dur + fight.length
    local spec, ev = fight.spec, fight.events
    local bd = bossData(spec, fight)
    if bd then s.bossFights = s.bossFights + 1 end
    local function wclEval(sp, tg, from, to) return wclEvalWith(sp, tg, from, to, bd) end
    local function tally(prefix, top, ok)
        if top == nil then return end
        s[prefix .. "N"] = s[prefix .. "N"] + 1
        if top then s[prefix .. "Top"] = s[prefix .. "Top"] + 1 end
        if ok then s[prefix .. "Ok"] = s[prefix .. "Ok"] + 1 end
    end

    local lastP, prevC
    for i, e in ipairs(ev) do
        if e.type == "P" and e.pick and e.pick ~= 0 then
            lastP = e
        end
        if prio and e.type == "P" and e.pick and e.pick ~= 0 then
            -- Priority: the pick beat every other known spell that was ready.
            prio[e.used] = prio[e.used] or {}
            local pt = prio[e.used]
            pt[e.pick] = pt[e.pick] or { w = 0, g = 0 }
            for other, o in pairs(pt) do
                if other ~= e.pick then
                    local c = e.cds[other]
                    if not (c and c.left > READY) then
                        pt[e.pick].w = pt[e.pick].w + 1
                        pt[e.pick].g = pt[e.pick].g + 1
                        o.g = o.g + 1
                    end
                end
            end
            for _, g in ipairs(e.glow) do
                bump(s.glow, g, 1)
                if g == e.pick then bump(s.glow, g, 2) end
            end
            local c = e.cds[e.pick]
            if c and c.est and c.left > READY then
                bump(s.late, e.pick, 1)
                bump(s.late, e.pick, 2, c.left)
            end
        elseif e.type == "C" then
            s.casts = s.casts + 1
            local tg = lastP and lastP.used or 1
            -- Pairs are consecutive casts inside this fight (combat start to end).
            if prevC then tally("you", wclEval(spec, tg, prevC.spell, e.spell)) end
            prevC = e
            if e.spell == e.now then
                s.followed = s.followed + 1
                if e.nxt and e.nxt ~= 0 then
                    -- Blizzard's answer: the last pick before your next cast;
                    -- no new pick means it repeated the same spell.
                    local actual = e.spell
                    for j = i + 1, #ev do
                        if ev[j].type == "C" then break end
                        if ev[j].type == "P" and ev[j].pick ~= 0 then actual = ev[j].pick end
                    end
                    local kind = (lastP and lastP.kind ~= "" and lastP.kind) or "?"
                    bump(s.kinds, kind, 1)
                    s.pred = s.pred + 1
                    if actual == e.nxt then
                        s.hit = s.hit + 1
                        bump(s.kinds, kind, 2)
                    else
                        local key = e.spell .. "|" .. e.nxt .. "|" .. actual
                        s.misses[key] = (s.misses[key] or 0) + 1
                    end
                    tally("next", wclEval(spec, tg, e.spell, e.nxt))
                    tally("bliz", wclEval(spec, tg, e.spell, actual))
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Results window (text can be selected and copied with Ctrl+C)
---------------------------------------------------------------------------
local window
local function showText(text)
    if not window then
        local f = CreateFrame("Frame", "BRATAnalysis", UIParent, "BasicFrameTemplateWithInset")
        f:SetSize(640, 460)
        f:SetPoint("CENTER")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetFrameStrata("DIALOG")
        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        f.title:SetPoint("TOP", 0, -5)
        f.title:SetText("BRAT analysis  (click the text, Ctrl+A then Ctrl+C to copy)")
        local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -30)
        scroll:SetPoint("BOTTOMRIGHT", -32, 12)
        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(580)
        edit:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(edit)
        f.edit = edit
        tinsert(UISpecialFrames, "BRATAnalysis") -- Esc closes it
        window = f
    end
    window.edit:SetText(text)
    window.edit:SetCursorPosition(0)
    window:Show()
end

---------------------------------------------------------------------------
-- Report text
---------------------------------------------------------------------------
local function buildText(s, spec, prio, lastN)
    local out = {}
    local function add(fmt, ...) out[#out + 1] = select("#", ...) > 0 and fmt:format(...) or fmt end
    local _, specName = GetSpecializationInfoByID(spec)
    local info = BRAT.WCLInfo(spec)

    add("BRAT analysis, %s, %s", specName or ("spec " .. spec), date("%Y-%m-%d %H:%M"))
    add("%d fights%s, %.1f minutes in combat", s.fights, lastN and (" (last " .. lastN .. ")") or "", s.dur / 60)
    add("")
    add("NEXT vs Blizzard (did NEXT match Blizzard's pick after you cast NOW?)")
    add("  overall %s  (%d predictions)", pct(s.hit, s.pred), s.pred)
    for k, v in pairs(s.kinds) do add("  %-8s %s  (%d)", k, pct(v[2], v[1]), v[1]) end
    add("")
    if info then
        add("Compared with Warcraft Logs (top %d players, data from %s)", info.players or 0, info.date or "?")
        add("  success = something top players do after that spell; #1 = their most common choice")
        add("  %d of %d fights compared with the matching rotation (that boss / dungeon, else the generic one); the rest had no Warcraft Logs rotation",
            s.bossFights, s.fights)
        add("  BRAT's NEXT       success %-7s  #1 %-7s  (%d steps)", pct(s.nextOk, s.nextN), pct(s.nextTop, s.nextN), s.nextN)
        add("  Blizzard's picks  success %-7s  #1 %-7s  (%d steps)", pct(s.blizOk, s.blizN), pct(s.blizTop, s.blizN), s.blizN)
        add("  Your casts        success %-7s  #1 %-7s  (%d steps)", pct(s.youOk, s.youN), pct(s.youTop, s.youN), s.youN)
    else
        add("Compared with Warcraft Logs: no logs data for this spec yet")
    end
    add("")
    add("You pressed the NOW spell %s of the time (%d casts)", pct(s.followed, s.casts), s.casts)
    add("")

    for _, section in ipairs({ "Raid (per boss)", "Mythic+ / dungeons (whole dungeon)", "Other" }) do
        local labels = {}
        for label, b in pairs(s.byBoss) do if b.section == section then labels[#labels + 1] = label end end
        if #labels > 0 then
            table.sort(labels, function(a, b) return s.byBoss[a].fights > s.byBoss[b].fights end)
            add(section)
            add("  %-40s %6s %10s %10s %9s", "", "fights", "NEXT=Bliz", "NEXT=WCL", "You=WCL")
            for _, label in ipairs(labels) do
                local b = s.byBoss[label]
                add("  %-40s %6d %10s %10s %9s", label:sub(1, 40), b.fights, pct(b.hit, b.pred), pct(b.nextOk, b.nextN), pct(b.youOk, b.youN))
            end
            add("")
        end
    end

    local misses = {}
    for k, n in pairs(s.misses) do misses[#misses + 1] = { k = k, n = n } end
    table.sort(misses, function(a, b) return a.n > b.n end)
    add("Most common NEXT misses (after X: NEXT said / Blizzard picked)")
    if #misses == 0 then add("  none") end
    for i = 1, math.min(10, #misses) do
        local a, b, c = misses[i].k:match("(%d+)|(%d+)|(%d+)")
        add("  %4dx  after %s: %s / %s", misses[i].n, name(tonumber(a)), name(tonumber(b)), name(tonumber(c)))
    end
    add("")

    add("Cooldown estimates that blocked a spell Blizzard wanted")
    local any = false
    for id, v in pairs(s.late) do
        any = true
        add("  %s: %d times, estimate was %.1fs too slow on average", name(id), v[1], v[2] / v[1])
    end
    if not any then add("  none") end
    add("")

    add("Procs: how often Blizzard picked a glowing spell straight away")
    any = false
    for id, v in pairs(s.glow) do any = true; add("  %s: %s (%d picks while glowing)", name(id), pct(v[2], v[1]), v[1]) end
    if not any then add("  none seen (no procs, or the game hides glows from addons)") end
    add("")

    add("Blizzard's priority (left = chosen first when ready)")
    local cap = BRAT.GetCap()
    for tg = 1, BRAT.MAX_TARGETS do
        local rows = {}
        for id, v in pairs(prio[tg] or {}) do
            if v.g >= 5 then rows[#rows + 1] = { id = id, score = v.w / v.g } end
        end
        table.sort(rows, function(a, b) return a.score > b.score end)
        if #rows > 0 then
            local parts = {}
            for i, r in ipairs(rows) do parts[i] = ("%s (%.0f%%)"):format(name(r.id), r.score * 100) end
            add("  %s: %s", tg >= cap and (tg .. "+ targets") or (tg .. " target(s)"), table.concat(parts, " > "))
        end
    end
    add("")

    add("Trend (previous runs for this spec, oldest first)")
    add("  %-17s %8s %10s %10s %9s", "run", "fights", "NEXT=Bliz", "NEXT=WCL", "You=WCL")
    local runs = {}
    for _, r in ipairs(BRAT.db.runs) do if r.spec == spec then runs[#runs + 1] = r end end
    for i = math.max(1, #runs - 9), #runs do
        local r = runs[i]
        add("  %-17s %8d %10s %10s %9s", date("%Y-%m-%d %H:%M", r.t), r.fights,
            pct(r.hit, r.pred), pct(r.nextOk, r.nextN), pct(r.youOk, r.youN))
    end
    add("  %-17s %8d %10s %10s %9s", "this run", s.fights, pct(s.hit, s.pred), pct(s.nextOk, s.nextN), pct(s.youOk, s.youN))
    return table.concat(out, "\n")
end

---------------------------------------------------------------------------
-- Run: parses the history a chunk per frame so the game doesn't freeze.
---------------------------------------------------------------------------
-- lastN: only the most recent N fights (nil = all).
function Report:Run(lastN)
    if self.running then say("analysis already running.") return end
    local spec = BRAT.GetSpecID()
    local h = BRAT.db.history
    local n = #h
    if n == 0 then
        say("no fights logged yet. Fight something for 20+ seconds (a target dummy works), then analyze.")
        return
    end
    self.running = true
    say(("analyzing %d logged events..."):format(n))

    local co = coroutine.create(function()
        -- Pass 1: find this spec's fights (start index of each).
        local starts = {}
        for i = 1, n do
            local l = h[i]
            if l:find("^H1;F;") then
                local f = split(l)
                if tonumber(f[4]) == spec then starts[#starts + 1] = i end
            end
            if i % LINES_PER_FRAME == 0 then coroutine.yield() end
        end
        local from = 1
        if lastN and lastN > 0 and #starts > lastN then from = #starts - lastN + 1 end

        -- Pass 2: parse and analyze each fight.
        local s, prio, done = newTotals(), {}, 0
        for k = from, #starts do
            local first = starts[k]
            local hf = split(h[first])
            -- Label: the boss if there was one, else the instance, else open world.
            local inst = hf[6] ~= "" and hf[6] or nil
            local instType = hf[7] or "none"
            local fight = { spec = spec, events = {}, length = 0, instType = instType,
                inst = (inst and instType ~= "none") and inst or nil,
                where = (inst and instType ~= "none") and inst or "Open world / target dummy" }
            local lastT = 0
            for i = first + 1, n do
                local l = h[i]
                if l:find("^H1;F;") then break end
                local p = split(l)
                local kind = p[2]
                if kind == "P" then
                    lastT = tonumber(p[3]) or lastT
                    fight.events[#fight.events + 1] = { type = "P", t = lastT, pick = tonumber(p[4]),
                        now = tonumber(p[5]), nxt = tonumber(p[6]), kind = p[7], used = tonumber(p[9]) or 1,
                        glow = parseGlow(p[10]), cds = parseCds(p[11]) }
                elseif kind == "C" then
                    lastT = tonumber(p[3]) or lastT
                    fight.events[#fight.events + 1] = { type = "C", t = lastT, spell = tonumber(p[4]),
                        now = tonumber(p[5]), nxt = tonumber(p[6]) }
                elseif kind == "X" then
                    fight.ctxKind = fight.ctxKind or p[4]
                elseif kind == "N" then
                    fight.enc = tonumber(p[4])
                    local diffName = GetDifficultyInfo and GetDifficultyInfo(tonumber(p[5]) or 0)
                    fight.boss = (p[6] ~= "" and p[6] or ("boss " .. p[4])) .. (diffName and (" (" .. diffName .. ")") or "")
                elseif kind == "E" then
                    fight.length = tonumber(p[3]) or 0
                end
                done = done + 1
                if done % LINES_PER_FRAME == 0 then coroutine.yield() end
            end
            if fight.length == 0 then fight.length = lastT end -- logged out mid-fight
            if fight.length >= MIN_FIGHT then
                analyzeFight(fight, s, prio)
                -- Dungeons count as one place (the whole run, trash and bosses);
                -- raids are split per boss, with trash on its own line.
                local label, section
                if fight.instType == "party" then
                    label, section = fight.where, "Mythic+ / dungeons (whole dungeon)"
                elseif fight.instType == "raid" then
                    label, section = fight.boss or (fight.where .. " (trash)"), "Raid (per boss)"
                else
                    label, section = fight.boss or fight.where, "Other"
                end
                s.byBoss[label] = s.byBoss[label] or newTotals()
                s.byBoss[label].section = section
                analyzeFight(fight, s.byBoss[label], nil)
            end
        end
        return s, prio
    end)

    local ticker
    ticker = C_Timer.NewTicker(0, function()
        local ok, s, prio = coroutine.resume(co)
        if not ok then
            ticker:Cancel(); self.running = false
            say("analysis failed: " .. tostring(s) .. " (paste this to Claude)")
            return
        end
        if coroutine.status(co) ~= "dead" then return end
        ticker:Cancel(); self.running = false
        if s.fights == 0 then
            say("no fights of 20+ seconds logged for this spec yet.")
            return
        end
        local text = buildText(s, spec, prio, lastN)
        BRAT.db.priority[spec] = prio
        local runs = BRAT.db.runs
        runs[#runs + 1] = { t = GetServerTime(), spec = spec, fights = s.fights, pred = s.pred, hit = s.hit,
            nextN = s.nextN, nextOk = s.nextOk, nextTop = s.nextTop, blizN = s.blizN, blizOk = s.blizOk,
            youN = s.youN, youOk = s.youOk }
        while #runs > MAX_RUNS do table.remove(runs, 1) end
        showText(text)
        say(("analysis done: NEXT matched Blizzard %s, top-player success %s."):format(
            pct(s.hit, s.pred), pct(s.nextOk, s.nextN)))
    end)
end
