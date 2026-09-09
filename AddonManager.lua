--[[
    Addon:       AddonManager (folder/internal name - GetAddOnInfo, ADDON_LOADED,
                 and SavedVariables all key off this, so it stays as-is even though
                 the addon displays as "Gimmetbarbie Addon Manager" everywhere else)
    Description: In-game addon list for WoW 1.12 clients that have no built-in one.
                 - Enable/disable any installed addon (takes effect after /reloadui,
                   same as the character-select AddOns screen - the client only reads
                   that state at login, there's no way around that).
                 - A minimap icon that collects other addons' minimap buttons into a
                   flyout drawer to unclutter the minimap ring.
                 - Quick-launch commands are auto-discovered: addons register slash
                   commands as plain globals (SLASH_X1="/x", SlashCmdList["X"]=...),
                   and globals are visible to every addon via _G. We watch each
                   addon's ADDON_LOADED event and diff _G for new SLASH_* entries
                   that appeared during its load, attributing them automatically -
                   so a newly installed addon needs no manual update here. A small
                   hand-picked override table takes priority for a few addons where
                   the auto-picked command isn't the best one to show.

    Slash Commands:
        /am              toggle the addon list window
        /am reload       reloads the UI (applies pending enable/disable changes)
        /am rescan       force a minimap-button collection pass
        /am probe        dumps GetAddOnInfo(1)'s raw return values to chat, for
                          verifying this client's exact field order (see NOTE below)
        /am commands     lists how many slash commands were auto-discovered per addon
--]]

-- ---------------------------------------------------------------------------------------------
-- NOTE on GetAddOnInfo: different client builds have returned slightly different field
-- orders for this call over the years, so AM.ParseAddOnInfo() (below) detects the
-- "loadable" boolean and "reason" string by their TYPE rather than trusting a fixed
-- position - that holds regardless of which slot each is actually returned in. An
-- addon is treated as unchecked when reason == "DISABLED". "/am probe" still dumps
-- the raw values if something still looks wrong.
-- ---------------------------------------------------------------------------------------------

AM = {}
AM.ADDON_NAME = "AddonManager"
AM.PAGE_SIZE  = 14
AM.ROW_HEIGHT = 20
AM.activeTab  = "enabled"

-- ===================== Error log =====================
-- seterrorhandler() lets an addon see every Lua error thrown by ANY addon, not
-- just its own - that's the mechanism tools like BugSack use. We wrap whatever
-- handler is already installed (rather than replacing it) so we don't break
-- anything else relying on the default error display/behavior.
AM.errorLog = {}
AM.ERROR_LOG_MAX = 200

local AM_previousErrorHandler = geterrorhandler()
seterrorhandler(function(msg)
    table.insert(AM.errorLog, { time = date("%H:%M:%S"), msg = tostring(msg) })
    while table.getn(AM.errorLog) > AM.ERROR_LOG_MAX do
        table.remove(AM.errorLog, 1)
    end
    AM_ErrorLog = AM.errorLog
    if AM.errorBox and AM.activeTab == "errors" then
        AM.RefreshErrorsPanel()
    end
    if AM_previousErrorHandler then
        AM_previousErrorHandler(msg)
    end
end)

-- ===================== Command overrides =====================
-- Hand-picked for addons where the auto-discovered command isn't the best one to
-- show (see the auto-discovery engine further down). Takes priority over whatever
-- gets auto-discovered for the same addon; everything not listed here is filled in
-- automatically at login with zero maintenance required.
-- {label, cmdText, SlashCmdList key} - the key lets us call the handler directly
-- instead of going through the chat editbox (see AM.RunCommand). BigWigs isn't
-- listed here because it registers through AceConsole's abstraction rather than a
-- plain SLASH_X global, so its real key isn't safely guessable by hand - it's left
-- to auto-discovery, which finds the real key correctly regardless of how a command
-- was registered.
AM.COMMAND_OVERRIDES = {
    ["Aegis_RallyPower"]  = { {"Open", "/rpc", "AEGISRP"} },
    ["AtlasLoot"]         = { {"Open", "/atlasloot", "ATLASLOOT"} },
    ["aux-addon"]         = { {"Open", "/aux", "AUX"} },
    ["Decursive"]         = { {"Open", "/decursive", "DECURSIVE"} },
    ["DoiteAuras"]        = { {"Open", "/da", "DOITEAURAS"} },
    ["GNS"]               = { {"Open", "/gns", "GNS"} },
    ["ItemRack"]          = { {"Open", "/itemrack", "ItemRackCOMMAND"} },
    ["LevelRange-Turtle"] = { {"Open", "/lr", "LEVELRANGE"} },
    ["ModernMapMarkers"]  = { {"Open", "/mmm", "MMM"} },
    ["ModernSpellBook"]   = { {"Open", "/msb", "MODERNSPELLBOOK"} },
    ["perfboostsettings"] = { {"Enable", "/pbenable", "PBENABLE"} },
    ["pfExtend"]          = { {"Open", "/pfex", "pfExtendCmd"} },
    ["pfQuest"]           = { {"Open", "/pfquest", "PFDB"} },
    ["Quiver"]            = { {"Open", "/quiver", "QUIVER"} },
    ["Rested"]            = { {"Status", "/rested", "RESTED"}, {"Help", "/rested help", "RESTED"} },
    ["ShaguDPS"]          = { {"Open", "/shagudps", "SHAGUMETER"} },
    ["ShaguPlates"]       = { {"Open", "/shaguplates", "SHAGUPLATES"} },
    ["ShaguTweaks"]       = { {"Open", "/stweaks", "STWEAKS"} },
    ["T-RestedXP"]        = { {"Open", "/trestedxp", "TRESTEDXP"} },
    ["TurtleMail"]        = { {"Open", "/turtlemail", "TURTLEMAIL"} },
    ["TWThreat"]          = { {"Open", "/twt", "TWT"} },
    ["UnitXP_SP3_Addon"]  = { {"Open", "/unitxp", "UNITXP"} },
    ["_LazyPig"]          = { {"Open", "/lp", "LAZYPIG"} },
}

AM.REASON_TEXT = {
    DISABLED           = "disabled",
    MISSING            = "files missing",
    INTERFACE_VERSION  = "wrong client version",
    DEP_DISABLED       = "dependency disabled",
    DEP_MISSING        = "dependency missing",
    DEP_BROKEN         = "dependency broken",
    TOO_MANY_BANKS     = "too many bank slots",
    ASCII_NAME         = "bad addon name",
    UNASCII_NAME       = "bad addon name",
}

-- ===================== Auto-discovered slash commands =====================
-- Watches _G for new SLASH_* globals appearing during each addon's ADDON_LOADED
-- event and attributes them to that addon. Only the *1 (primary) alias of each
-- command family is kept, and only families that actually have a handler
-- registered in SlashCmdList. Capped at 2 per addon to match the row UI.
AM.DiscoveredCommands = {}
AM.seenSlashKeys = {}

function AM.ScanNewSlashCommands(ownerAddon)
    local firstSeenThisPass = {}
    for k, v in pairs(_G) do
        if type(k) == "string" and type(v) == "string" and not AM.seenSlashKeys[k] then
            local s, e, base, idx = string.find(k, "^SLASH_(.+)(%d+)$")
            if base and idx == "1" and SlashCmdList[base] and not firstSeenThisPass[base] then
                firstSeenThisPass[base] = v
            end
            AM.seenSlashKeys[k] = true
        end
    end

    if not ownerAddon then return end
    for base, cmd in pairs(firstSeenThisPass) do
        local list = AM.DiscoveredCommands[ownerAddon]
        if not list then
            list = {}
            AM.DiscoveredCommands[ownerAddon] = list
        end
        if table.getn(list) < 2 then
            table.insert(list, { cmd, cmd, base })
        end
    end
end

function AM.DumpDiscoveredCommands()
    AM.Say("auto-discovered commands by addon:")
    for addonName, list in pairs(AM.DiscoveredCommands) do
        local cmds = ""
        for _, entry in ipairs(list) do
            cmds = cmds .. entry[2] .. " "
        end
        DEFAULT_CHAT_FRAME:AddMessage("  " .. addonName .. ": " .. cmds)
    end
end

-- One-time baseline: whichever addon's ADDON_LOADED fires first (alphabetically,
-- that's usually us) would otherwise have EVERY pre-existing SLASH_* global -
-- Blizzard's own built-ins (/gmotd etc.) and libraries loaded earlier (AceConsole's
-- /print etc.) - all show up as "new" in the same pairs(_G) pass and get credited
-- to it, since pairs() has no defined order and could easily fill both of that
-- addon's 2 slots before its own real command is even seen. Marking everything
-- that already exists as "seen" up front, with no owner, fixes that: only commands
-- that appear AFTER this point (i.e. registered by an addon's own file) get
-- attributed to anyone.
AM.ScanNewSlashCommands(nil)

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------
function AM.Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cFF008fecGimmetbarbie Addon Manager|r: " .. msg)
end

-- Runs a slash command. Prefers calling its SlashCmdList handler directly (reliable -
-- we know exactly which function that is), falling back to feeding it through the
-- chat editbox only when we don't have a key for it.
function AM.RunCommand(cmdText, key)
    if key and SlashCmdList[key] then
        local s, e, slashPart, args = string.find(cmdText, "^(/%S+)%s*(.-)$")
        local ok = pcall(SlashCmdList[key], args or "")
        if ok then return end
    end

    local ok2 = pcall(function()
        ChatFrame1EditBox:SetText(cmdText)
        ChatEdit_SendText(ChatFrame1EditBox, 1)
    end)
    if not ok2 then
        AM.Say("couldn't run " .. cmdText .. " - try typing it manually.")
    end
end

function AM.Probe()
    local a, b, c, d, e, f = GetAddOnInfo(1)
    AM.Say("GetAddOnInfo(1) raw values:")
    DEFAULT_CHAT_FRAME:AddMessage("  1: " .. tostring(a))
    DEFAULT_CHAT_FRAME:AddMessage("  2: " .. tostring(b))
    DEFAULT_CHAT_FRAME:AddMessage("  3: " .. tostring(c))
    DEFAULT_CHAT_FRAME:AddMessage("  4: " .. tostring(d))
    DEFAULT_CHAT_FRAME:AddMessage("  5: " .. tostring(e))
    DEFAULT_CHAT_FRAME:AddMessage("  6: " .. tostring(f))
end

-- ---------------------------------------------------------------------------------------------
-- Addon list data
-- ---------------------------------------------------------------------------------------------
AM.addons = {}
AM.filtered = {}
AM.page = 0
AM.filterText = ""
AM.settingsPage = 0

-- GetAddOnInfo's exact field order for slots 4+ isn't reliably known across client
-- builds (that guess was wrong here, which is why the list showed everything as
-- enabled). Instead of guessing a position, find "loadable" and "reason" by TYPE -
-- loadable is always a boolean, reason is always a string-or-nil - which holds
-- regardless of which slot each one is actually returned in.
function AM.ParseAddOnInfo(index)
    local name, title, notes, a4, a5, a6 = GetAddOnInfo(index)
    local loadable, reason

    -- checked individually (not via a loop over {a4,a5,a6}) so a nil in an earlier
    -- slot can't short-circuit checking the later ones
    if type(a4) == "boolean" then loadable = a4
    elseif type(a5) == "boolean" then loadable = a5
    elseif type(a6) == "boolean" then loadable = a6 end

    if type(a4) == "string" then reason = a4
    elseif type(a5) == "string" then reason = a5
    elseif type(a6) == "string" then reason = a6 end

    if loadable == nil then loadable = true end
    return name, title, notes, loadable, reason
end

function AM.BuildAddonList()
    AM.addons = {}
    local n = GetNumAddOns()
    for i = 1, n do
        local name, title, notes, loadable, reason = AM.ParseAddOnInfo(i)
        local isEnabled = (reason ~= "DISABLED")
        table.insert(AM.addons, {
            index          = i,
            name           = name,
            title          = title or name,
            notes          = notes,
            loadable       = loadable,
            reason         = reason,
            enabled        = isEnabled,
            originalEnabled = isEnabled, -- fixed at list-build time, for the "needs reload" marker
        })
    end

    table.sort(AM.addons, function(a, b)
        return string.lower(a.title) < string.lower(b.title)
    end)

    AM.ApplyFilter()
end

function AM.ApplyFilter()
    AM.filtered = {}
    local needle = string.lower(AM.filterText or "")
    -- Filtered by originalEnabled (state as of last list build/reload), not the
    -- live-toggled "enabled" - otherwise clicking to disable something in the
    -- Enabled tab would make it vanish immediately instead of staying put with a
    -- "*reload needed*" marker until the reload actually happens.
    local wantEnabled = (AM.activeTab == "enabled")
    for _, row in ipairs(AM.addons) do
        if row.originalEnabled == wantEnabled
            and (needle == "" or string.find(string.lower(row.title), needle, 1, true)
                or string.find(string.lower(row.name), needle, 1, true)) then
            table.insert(AM.filtered, row)
        end
    end
    local maxPage = math.floor((table.getn(AM.filtered) - 1) / AM.PAGE_SIZE)
    if maxPage < 0 then maxPage = 0 end
    if AM.page > maxPage then AM.page = maxPage end
end

function AM.ToggleAddonRow(row)
    -- No character argument: passing one "defensively" turned out to make the call
    -- silently no-op instead of being harmlessly ignored, which is why disabling
    -- something didn't survive a reload.
    if row.enabled then
        DisableAddOn(row.index)
        row.enabled = false
    else
        EnableAddOn(row.index)
        row.enabled = true
    end
    AM.pendingReload = true
    AM.RefreshWindow()
end

-- ---------------------------------------------------------------------------------------------
-- Main window
-- ---------------------------------------------------------------------------------------------
function AM.CreateMainFrame()
    local f = CreateFrame("Frame", "AM_MainFrame", UIParent)
    f:SetWidth(460); f:SetHeight(420)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local point, _, relPoint, x, y = f:GetPoint()
        AM_FramePos = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -12)
    title:SetText("Gimmetbarbie Addon Manager")

    local close = CreateFrame("Button", "AM_CloseBtn", f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() f:Hide() end)

    -- Tabs
    local tabEnabled = CreateFrame("Button", "AM_TabEnabled", f, "UIPanelButtonTemplate")
    tabEnabled:SetWidth(64); tabEnabled:SetHeight(20)
    tabEnabled:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -30)
    tabEnabled:SetText("Enabled")
    tabEnabled:SetScript("OnClick", function() AM.SetTab("enabled") end)
    f.tabEnabled = tabEnabled

    local tabDisabled = CreateFrame("Button", "AM_TabDisabled", f, "UIPanelButtonTemplate")
    tabDisabled:SetWidth(64); tabDisabled:SetHeight(20)
    tabDisabled:SetPoint("LEFT", tabEnabled, "RIGHT", 4, 0)
    tabDisabled:SetText("Disabled")
    tabDisabled:SetScript("OnClick", function() AM.SetTab("disabled") end)
    f.tabDisabled = tabDisabled

    local tabErrors = CreateFrame("Button", "AM_TabErrors", f, "UIPanelButtonTemplate")
    tabErrors:SetWidth(64); tabErrors:SetHeight(20)
    tabErrors:SetPoint("LEFT", tabDisabled, "RIGHT", 4, 0)
    tabErrors:SetText("Errors")
    tabErrors:SetScript("OnClick", function() AM.SetTab("errors") end)
    f.tabErrors = tabErrors

    local tabSettings = CreateFrame("Button", "AM_TabSettings", f, "UIPanelButtonTemplate")
    tabSettings:SetWidth(70); tabSettings:SetHeight(20)
    tabSettings:SetPoint("LEFT", tabErrors, "RIGHT", 4, 0)
    tabSettings:SetText("Settings")
    tabSettings:SetScript("OnClick", function() AM.SetTab("settings") end)
    f.tabSettings = tabSettings

    -- Reload banner/button
    local reloadBtn = CreateFrame("Button", "AM_ReloadBtn", f, "UIPanelButtonTemplate")
    reloadBtn:SetWidth(100); reloadBtn:SetHeight(22)
    reloadBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -52)
    reloadBtn:SetText("Reload UI")
    reloadBtn:SetScript("OnClick", function() ReloadUI() end)
    f.reloadBtn = reloadBtn

    local banner = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    banner:SetPoint("RIGHT", reloadBtn, "LEFT", -8, 0)
    banner:SetTextColor(1, 0.5, 0.2)
    banner:SetText("")
    f.banner = banner

    -- Filter box (Addons tab only)
    local filterLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    filterLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -54)
    filterLabel:SetText("Filter:")
    f.filterLabel = filterLabel

    local filterBox = CreateFrame("EditBox", "AM_FilterBox", f, "InputBoxTemplate")
    filterBox:SetWidth(140); filterBox:SetHeight(18)
    filterBox:SetPoint("LEFT", filterLabel, "RIGHT", 8, 0)
    filterBox:SetAutoFocus(false)
    filterBox:SetScript("OnTextChanged", function()
        AM.filterText = this:GetText()
        AM.page = 0
        AM.ApplyFilter()
        AM.RefreshWindow()
    end)
    filterBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    f.filterBox = filterBox

    -- List area
    local listTop = -78
    f.rows = {}
    for i = 1, AM.PAGE_SIZE do
        local row = CreateFrame("Frame", "AM_Row" .. i, f)
        row:SetWidth(432); row:SetHeight(AM.ROW_HEIGHT)
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 14, listTop - (i - 1) * (AM.ROW_HEIGHT + 2))

        local toggle = CreateFrame("Button", "AM_Row" .. i .. "Toggle", row, "UIPanelButtonTemplate")
        toggle:SetWidth(60); toggle:SetHeight(18)
        toggle:SetPoint("LEFT", row, "LEFT", 0, 0)
        toggle:SetScript("OnClick", function()
            local r = this:GetParent()
            if r.data then AM.ToggleAddonRow(r.data) end
        end)
        row.toggle = toggle

        local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", toggle, "RIGHT", 6, 0)
        label:SetWidth(182); label:SetJustifyH("LEFT")
        row.label = label

        row.cmdButtons = {}
        for c = 1, 2 do
            local btn = CreateFrame("Button", "AM_Row" .. i .. "Cmd" .. c, row, "UIPanelButtonTemplate")
            btn:SetWidth(58); btn:SetHeight(18)
            btn:Hide()
            row.cmdButtons[c] = btn
        end

        f.rows[i] = row
    end

    -- Pagination controls
    local pageLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageLabel:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
    pageLabel:SetText("")
    f.pageLabel = pageLabel

    local prevBtn = CreateFrame("Button", "AM_PrevBtn", f, "UIPanelButtonTemplate")
    prevBtn:SetWidth(70); prevBtn:SetHeight(20)
    prevBtn:SetPoint("RIGHT", pageLabel, "LEFT", -10, 0)
    prevBtn:SetText("< Prev")
    prevBtn:SetScript("OnClick", function()
        if AM.activeTab == "settings" then
            if AM.settingsPage > 0 then
                AM.settingsPage = AM.settingsPage - 1
                AM.RefreshSettingsPanel()
            end
        else
            if AM.page > 0 then
                AM.page = AM.page - 1
                AM.RefreshWindow()
            end
        end
    end)

    local nextBtn = CreateFrame("Button", "AM_NextBtn", f, "UIPanelButtonTemplate")
    nextBtn:SetWidth(70); nextBtn:SetHeight(20)
    nextBtn:SetPoint("LEFT", pageLabel, "RIGHT", 10, 0)
    nextBtn:SetText("Next >")
    nextBtn:SetScript("OnClick", function()
        if AM.activeTab == "settings" then
            local totalItems = table.getn(AM.collectedList) + table.getn(AM.releasedList)
            local maxPage = math.floor((totalItems - 1) / table.getn(AM.mainFrame.settingsRows))
            if maxPage < 0 then maxPage = 0 end
            if AM.settingsPage < maxPage then
                AM.settingsPage = AM.settingsPage + 1
                AM.RefreshSettingsPanel()
            end
        else
            local maxPage = math.floor((table.getn(AM.filtered) - 1) / AM.PAGE_SIZE)
            if maxPage < 0 then maxPage = 0 end
            if AM.page < maxPage then
                AM.page = AM.page + 1
                AM.RefreshWindow()
            end
        end
    end)
    f.prevBtn = prevBtn
    f.nextBtn = nextBtn

    -- ---------------- Errors tab ----------------
    local clearLogBtn = CreateFrame("Button", "AM_ClearLogBtn", f, "UIPanelButtonTemplate")
    clearLogBtn:SetWidth(90); clearLogBtn:SetHeight(20)
    clearLogBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -54)
    clearLogBtn:SetText("Clear Log")
    clearLogBtn:SetScript("OnClick", function()
        AM.errorLog = {}
        AM_ErrorLog = AM.errorLog
        AM.RefreshErrorsPanel()
    end)
    clearLogBtn:Hide()
    f.clearLogBtn = clearLogBtn

    local errorCountLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    errorCountLabel:SetPoint("LEFT", clearLogBtn, "RIGHT", 10, 0)
    errorCountLabel:SetText("")
    errorCountLabel:Hide()
    f.errorCountLabel = errorCountLabel

    local copyHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    copyHint:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -70)
    copyHint:SetText("Click in the box below, Ctrl+A then Ctrl+C to copy")
    copyHint:Hide()
    f.copyHint = copyHint

    local errorScroll = CreateFrame("ScrollFrame", "AM_ErrorScroll", f, "UIPanelScrollFrameTemplate")
    errorScroll:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -84)
    errorScroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -34, -16)
    errorScroll:Hide()
    f.errorScroll = errorScroll

    local errorBox = CreateFrame("EditBox", "AM_ErrorBox", errorScroll)
    errorBox:SetMultiLine(true)
    errorBox:SetFontObject(ChatFontNormal)
    errorBox:SetWidth(388)
    errorBox:SetHeight(3000) -- generously tall so the scrollbar always has room to work
    errorBox:SetAutoFocus(false)
    errorBox:EnableMouse(true)
    errorBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    errorScroll:SetScrollChild(errorBox)
    AM.errorBox = errorBox

    -- ---------------- Settings tab (minimap icons stored in the drawer) ----------------
    local rescanBtn = CreateFrame("Button", "AM_RescanBtn", f, "UIPanelButtonTemplate")
    rescanBtn:SetWidth(90); rescanBtn:SetHeight(20)
    rescanBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -54)
    rescanBtn:SetText("Rescan Now")
    rescanBtn:SetScript("OnClick", function()
        AM.ScanMinimapButtons()
        AM.RefreshSettingsPanel()
    end)
    rescanBtn:Hide()
    f.rescanBtn = rescanBtn

    local settingsCountLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    settingsCountLabel:SetPoint("LEFT", rescanBtn, "RIGHT", 10, 0)
    settingsCountLabel:SetText("")
    settingsCountLabel:Hide()
    f.settingsCountLabel = settingsCountLabel

    local settingsHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    settingsHint:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -70)
    settingsHint:SetText("Minimap icons currently tucked into the drawer:")
    settingsHint:Hide()
    f.settingsHint = settingsHint

    f.settingsRows = {}
    local SETTINGS_ROW_MAX = 14 -- fits inside the 420px-tall window at 22px/row from y=-84
    for i = 1, SETTINGS_ROW_MAX do
        local srow = CreateFrame("Frame", "AM_SettingsRow" .. i, f)
        srow:SetWidth(410); srow:SetHeight(20)
        srow:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -84 - (i - 1) * 22)
        srow:Hide()

        local sicon = srow:CreateTexture(nil, "ARTWORK")
        sicon:SetWidth(16); sicon:SetHeight(16)
        sicon:SetPoint("LEFT", srow, "LEFT", 0, 0)
        srow.icon = sicon

        local sname = srow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        sname:SetPoint("LEFT", sicon, "RIGHT", 6, 0)
        sname:SetWidth(300); sname:SetJustifyH("LEFT")
        srow.nameText = sname

        local releaseBtn = CreateFrame("Button", "AM_SettingsRow" .. i .. "Release", srow, "UIPanelButtonTemplate")
        releaseBtn:SetWidth(70); releaseBtn:SetHeight(18)
        releaseBtn:SetPoint("RIGHT", srow, "RIGHT", 0, 0)
        releaseBtn:SetText("Release")
        releaseBtn:SetScript("OnClick", function()
            local r = this:GetParent()
            if not r.frameRef then return end
            if r.isReleased then
                AM.RecollectMinimapButton(r.frameRef)
            else
                AM.ReleaseMinimapButton(r.frameRef)
            end
        end)
        srow.releaseBtn = releaseBtn

        f.settingsRows[i] = srow
    end

    AM.mainFrame = f

    if AM_FramePos then
        f:ClearAllPoints()
        f:SetPoint(AM_FramePos.point or "CENTER", UIParent, AM_FramePos.relPoint or "CENTER",
            AM_FramePos.x or 0, AM_FramePos.y or 40)
    end

    AM.SetTab("enabled")
end

-- Switches which content is visible: enabled addons, disabled addons, the error
-- log, or the minimap-icon settings.
function AM.SetTab(tab)
    AM.activeTab = tab
    local f = AM.mainFrame
    if not f then return end

    local isAddons = (tab == "enabled" or tab == "disabled")
    local isSettings = (tab == "settings")

    f.filterLabel:SetShown(isAddons)
    f.filterBox:SetShown(isAddons)
    f.pageLabel:SetShown(isAddons or isSettings)
    f.prevBtn:SetShown(isAddons or isSettings)
    f.nextBtn:SetShown(isAddons or isSettings)
    if isAddons then
        AM.page = 0
        AM.ApplyFilter()
    else
        for i = 1, AM.PAGE_SIZE do
            f.rows[i]:Hide()
        end
    end

    local isErrors = (tab == "errors")
    f.clearLogBtn:SetShown(isErrors)
    f.errorCountLabel:SetShown(isErrors)
    f.copyHint:SetShown(isErrors)
    f.errorScroll:SetShown(isErrors)

    f.rescanBtn:SetShown(isSettings)
    f.settingsCountLabel:SetShown(isSettings)
    f.settingsHint:SetShown(isSettings)
    if isSettings then
        AM.settingsPage = 0
    else
        for i = 1, table.getn(f.settingsRows) do
            f.settingsRows[i]:Hide()
        end
    end

    if f.tabEnabled then
        if tab == "enabled" then f.tabEnabled:Disable() else f.tabEnabled:Enable() end
    end
    if f.tabDisabled then
        if tab == "disabled" then f.tabDisabled:Disable() else f.tabDisabled:Enable() end
    end
    if f.tabErrors then
        if isErrors then f.tabErrors:Disable() else f.tabErrors:Enable() end
    end
    if f.tabSettings then
        if isSettings then f.tabSettings:Disable() else f.tabSettings:Enable() end
    end

    if isAddons then
        AM.RefreshWindow()
    elseif isErrors then
        AM.RefreshErrorsPanel()
    elseif isSettings then
        AM.RefreshSettingsPanel()
    end
end

-- Buttons store their icon in all sorts of ways (NormalTexture, a named child
-- texture, etc.) - try the common spots and fall back to a placeholder rather
-- than guessing wrong and erroring.
function AM.GetButtonIconTexture(frame)
    if frame.GetNormalTexture then
        local ok, nt = pcall(frame.GetNormalTexture, frame)
        if ok and nt and nt.GetTexture then
            local tex = nt:GetTexture()
            if tex then return tex end
        end
    end
    local ok, regions = pcall(function() return { frame:GetRegions() } end)
    if ok then
        for _, r in ipairs(regions) do
            if r.GetObjectType and r:GetObjectType() == "Texture" then
                local tex = r:GetTexture()
                if tex then return tex end
            end
        end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

function AM.RefreshSettingsPanel()
    local f = AM.mainFrame
    if not f then return end

    local combined = {}
    for _, btn in ipairs(AM.collectedList) do
        table.insert(combined, { frame = btn, released = false })
    end
    for _, btn in ipairs(AM.releasedList) do
        table.insert(combined, { frame = btn, released = true })
    end

    f.settingsCountLabel:SetText(table.getn(AM.collectedList) .. " stored, " .. table.getn(AM.releasedList) .. " released")

    local rowMax = table.getn(f.settingsRows)
    local total = table.getn(combined)
    local maxPage = math.floor((total - 1) / rowMax)
    if maxPage < 0 then maxPage = 0 end
    if AM.settingsPage > maxPage then AM.settingsPage = maxPage end
    f.pageLabel:SetText("Page " .. (AM.settingsPage + 1) .. " / " .. (maxPage + 1) .. "  (" .. total .. " icons)")

    local startIndex = AM.settingsPage * rowMax

    for i = 1, rowMax do
        local srow = f.settingsRows[i]
        local entry = combined[startIndex + i]
        if entry and entry.frame:GetName() then
            local name = entry.frame:GetName()
            srow.frameRef = entry.frame
            srow.isReleased = entry.released
            if entry.released then
                srow.nameText:SetText("|cFF888888" .. name .. " (released)|r")
                srow.releaseBtn:SetText("Recollect")
            else
                srow.nameText:SetText(name)
                srow.releaseBtn:SetText("Release")
            end
            srow.icon:SetTexture(AM.GetButtonIconTexture(entry.frame))
            srow.icon:SetVertexColor(entry.released and 0.5 or 1, entry.released and 0.5 or 1, entry.released and 0.5 or 1)
            srow:Show()
        else
            srow.frameRef = nil
            srow:Hide()
        end
    end
end

-- Puts a collected button back on the minimap and stops re-collecting it this
-- session (original position isn't recorded, so it lands near the minimap center -
-- drag it wherever if the addon it belongs to doesn't reposition it itself).
function AM.ReleaseMinimapButton(btn)
    for i, v in ipairs(AM.collectedList) do
        if v == btn then
            table.remove(AM.collectedList, i)
            break
        end
    end
    AM.collected[btn] = nil
    AM.released[btn] = true
    table.insert(AM.releasedList, btn)

    btn:SetParent(Minimap)
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", 0, 0)
    btn:Show()

    AM.LayoutDrawer()
    AM.RefreshSettingsPanel()
end

-- Undoes a release: back into the drawer, and eligible for auto-collection again.
function AM.RecollectMinimapButton(btn)
    for i, v in ipairs(AM.releasedList) do
        if v == btn then
            table.remove(AM.releasedList, i)
            break
        end
    end
    AM.released[btn] = nil
    AM.collected[btn] = true
    table.insert(AM.collectedList, btn)

    btn:SetParent(AM.drawer)
    btn:SetFrameLevel(AM.drawer:GetFrameLevel() + 1)

    AM.LayoutDrawer()
    AM.RefreshSettingsPanel()
end

function AM.RefreshErrorsPanel()
    if not AM.errorBox then return end
    local lines = {}
    for i = 1, table.getn(AM.errorLog) do
        local e = AM.errorLog[i]
        table.insert(lines, "[" .. e.time .. "] " .. e.msg)
    end
    if table.getn(lines) == 0 then
        AM.errorBox:SetText("No errors logged yet.")
    else
        AM.errorBox:SetText(table.concat(lines, "\n"))
    end
    if AM.mainFrame and AM.mainFrame.errorCountLabel then
        AM.mainFrame.errorCountLabel:SetText(table.getn(AM.errorLog) .. " error(s) logged")
    end
end

function AM.RefreshWindow()
    local f = AM.mainFrame
    if not f then return end
    if AM.activeTab ~= "enabled" and AM.activeTab ~= "disabled" then return end

    if AM.pendingReload then
        f.banner:SetText("Changes need a reload to apply")
    else
        f.banner:SetText("")
    end

    local total = table.getn(AM.filtered)
    local maxPage = math.floor((total - 1) / AM.PAGE_SIZE)
    if maxPage < 0 then maxPage = 0 end
    f.pageLabel:SetText("Page " .. (AM.page + 1) .. " / " .. (maxPage + 1) .. "  (" .. total .. " addons)")

    local startIndex = AM.page * AM.PAGE_SIZE

    for i = 1, AM.PAGE_SIZE do
        local row = f.rows[i]
        local data = AM.filtered[startIndex + i]
        row.data = data

        if not data then
            row:Hide()
        else
            row:Show()

            if data.enabled then
                row.toggle:SetText("|cFFFFFF00Enabled|r")
            else
                row.toggle:SetText("|cFF888888Disabled|r")
            end

            local text = data.title
            local color = "|cFF00FF7F" -- green: enabled/loadable
            if not data.enabled then
                color = "|cFFFF5179" -- red: disabled
            elseif not data.loadable then
                color = "|cFFFFA500" -- orange: some other load problem
                local reasonText = AM.REASON_TEXT[data.reason] or data.reason
                if reasonText then text = text .. " (" .. reasonText .. ")" end
            end
            if data.name == AM.ADDON_NAME then
                text = text .. " |cFFAAAAAA(this addon)|r"
            end
            if data.enabled ~= data.originalEnabled then
                text = text .. " |cFFFF6600*reload needed*|r"
            end
            row.label:SetText(color .. text .. "|r")

            local cmds = AM.COMMAND_OVERRIDES[data.name] or AM.DiscoveredCommands[data.name]
            for c = 1, 2 do
                local btn = row.cmdButtons[c]
                local entry = cmds and cmds[c]
                if entry then
                    btn:ClearAllPoints()
                    if c == 1 and cmds[2] then
                        btn:SetPoint("RIGHT", row.cmdButtons[2], "LEFT", -4, 0)
                    else
                        btn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
                    end
                    btn:SetText(entry[1])
                    local cmdText = entry[2]
                    local cmdKey = entry[3]
                    btn:SetScript("OnClick", function() AM.RunCommand(cmdText, cmdKey) end)
                    btn:Show()
                else
                    btn:Hide()
                end
            end
        end
    end
end

function AM.ToggleMainFrame()
    if not AM.mainFrame then AM.CreateMainFrame() end
    if AM.mainFrame:IsShown() then
        AM.mainFrame:Hide()
    else
        AM.BuildAddonList()
        AM.RefreshWindow()
        AM.mainFrame:Show()
    end
end

-- ---------------------------------------------------------------------------------------------
-- Minimap button + collected-buttons drawer
-- ---------------------------------------------------------------------------------------------

-- Blizzard's own default minimap widgets - never collect these.
AM.MINIMAP_EXCLUDE = {
    MinimapBackdrop = true,
    MinimapCluster = true,
    MinimapZoomIn = true,
    MinimapZoomOut = true,
    MinimapToggleButton = true,
    MinimapNorthTag = true,
    GameTimeFrame = true,
    MiniMapMailFrame = true,
    MiniMapWorldMapButton = true,
    MiniMapTracking = true,
    MiniMapTrackingButton = true,
    MiniMapTrackingDropDown = true,
    MiniMapVoiceChatFrame = true,
    MiniMapBattlefieldFrame = true,
    MiniMapLFGFrame = true,
    MinimapZoneTextButton = true,
    TimeManagerClockButton = true,
    AM_MinimapButton = true,
}

AM.collected = {}     -- [frame] = true, so we don't re-collect the same one
AM.collectedList = {} -- ordered list for layout
AM.released = {}      -- [frame] = true, so a manually-released icon stays off the
                       -- minimap-drawer until explicitly recollected (session-only -
                       -- frame references can't be saved across reloads)
AM.releasedList = {}  -- ordered list, for the Settings tab

-- Same idea as AM.GetButtonIconTexture, but just checking presence - used to
-- require "actually looks like an icon" before collecting something.
function AM.HasVisibleTexture(frame)
    if frame.GetNormalTexture then
        local ok, nt = pcall(frame.GetNormalTexture, frame)
        if ok and nt and nt.GetTexture and nt:GetTexture() then return true end
    end
    local ok, regions = pcall(function() return { frame:GetRegions() } end)
    if ok then
        for _, r in ipairs(regions) do
            if r.GetObjectType and r:GetObjectType() == "Texture" and r.GetTexture and r:GetTexture() then
                return true
            end
        end
    end
    return false
end

-- Real minimap tracking icons are small, roughly square, visible, and have an
-- actual icon texture on them. The original version of this check (any Button
-- 10-60px wide) was too loose and swept up unrelated buttons that just happened
-- to be parented to Minimap for positioning convenience, not shown as icons.
function AM.IsCollectibleMinimapChild(child)
    if not child or not child.GetObjectType then return false end
    if child:GetObjectType() ~= "Button" then return false end
    local name = child.GetName and child:GetName()
    if not name then return false end
    if AM.MINIMAP_EXCLUDE[name] then return false end
    -- pfQuest names its quest-marker pins "pfMiniMapPinN" (one per active
    -- marker, numbered) - these are map data, not launcher icons, and pfQuest
    -- already has its own logic to dodge known collector addons (it checks for
    -- "MBB"/"ElvUI_MinimapButtons" by name and renames itself to avoid them),
    -- but doesn't know about us. Prefix match since N varies.
    if string.find(name, "^pfMiniMapPin") then return false end
    if AM.collected[child] then return false end
    if AM.released[child] then return false end
    if not child:IsVisible() then return false end

    local w, h = child:GetWidth(), child:GetHeight()
    if not w or not h or w < 18 or w > 40 or h < 18 or h > 40 then return false end
    local ratio = w / h
    if ratio < 0.7 or ratio > 1.4 then return false end

    if not AM.HasVisibleTexture(child) then return false end

    return true
end

-- Grid shape scales with how many icons there actually are, instead of always
-- being a fixed 6-wide box: 3 icons get a tight single row instead of sitting in a
-- mostly-empty 6-wide box, and 16 get a clean 8x2 block instead of a lopsided
-- 6-wide grid with a nearly-empty last row. Picks the fewest rows needed (capped at
-- MAX_COLS wide) then spreads the icons evenly across those rows.
function AM.LayoutDrawer()
    local pad, size = 4, 28
    local MAX_COLS = 8
    local count = table.getn(AM.collectedList)

    if count == 0 then
        AM.drawer.emptyLabel:Show()
        AM.drawer:SetWidth(140)
        AM.drawer:SetHeight(30)
        return
    end
    AM.drawer.emptyLabel:Hide()

    local rowsNeeded = math.ceil(count / MAX_COLS)
    if rowsNeeded < 1 then rowsNeeded = 1 end
    local cols = math.ceil(count / rowsNeeded)

    local i = 0
    for _, btn in ipairs(AM.collectedList) do
        local col = math.mod(i, cols)
        local row = math.floor(i / cols)
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", AM.drawer, "TOPLEFT", pad + col * (size + pad), -(pad + row * (size + pad)))
        i = i + 1
    end

    AM.drawer:SetWidth(pad + cols * (size + pad))
    AM.drawer:SetHeight(pad + rowsNeeded * (size + pad))
end

function AM.ScanMinimapButtons()
    local kids = { Minimap:GetChildren() }
    local found = false
    for _, child in ipairs(kids) do
        if AM.IsCollectibleMinimapChild(child) then
            AM.collected[child] = true
            child:SetParent(AM.drawer)
            child:SetFrameLevel(AM.drawer:GetFrameLevel() + 1)
            table.insert(AM.collectedList, child)
            found = true
        end
    end
    if found then AM.LayoutDrawer() end
end

function AM.CreateDrawer()
    local d = CreateFrame("Frame", "AM_Drawer", UIParent)
    d:SetWidth(140); d:SetHeight(30)
    d:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    d:SetBackdropColor(0, 0, 0, 0.8)
    d:SetFrameStrata("DIALOG")
    d:Hide()

    local empty = d:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    empty:SetPoint("CENTER", d, "CENTER", 0, 0)
    empty:SetText("No stray minimap buttons found yet")
    d.emptyLabel = empty

    AM.drawer = d
end

function AM.ToggleDrawer()
    if AM.drawer:IsShown() then
        AM.drawer:Hide()
    else
        AM.drawer:ClearAllPoints()
        AM.drawer:SetPoint("TOPRIGHT", AM.minimapButton, "BOTTOMLEFT", 0, -4)
        AM.drawer:Show()
    end
end

function AM.CreateMinimapButton()
    local btn = CreateFrame("Button", "AM_MinimapButton", Minimap)
    btn:SetWidth(31); btn:SetHeight(31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetWidth(20); icon:SetHeight(20)
    icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 7, -6)
    icon:SetTexture("Interface\\Icons\\Trade_Engineering")

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetWidth(53); border:SetHeight(53)
    border:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    btn:SetScript("OnMouseDown", function()
        if arg1 == "LeftButton" then this.dragging = true end
    end)
    btn:SetScript("OnMouseUp", function() this.dragging = false end)

    btn:SetScript("OnUpdate", function()
        if this.dragging then
            local mx, my = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            mx, my = mx / scale, my / scale
            local cx, cy = Minimap:GetCenter()
            AM_MinimapPos = math.deg(math.atan2(my - cy, mx - cx))
            AM.UpdateMinimapButtonPos()
        end
    end)

    btn:SetScript("OnClick", function()
        if arg1 == "LeftButton" then
            AM.ToggleMainFrame()
        elseif arg1 == "RightButton" then
            AM.ToggleDrawer()
        end
    end)

    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Gimmetbarbie Addon Manager")
        GameTooltip:AddLine("Left-click: addon list", 1, 1, 1)
        GameTooltip:AddLine("Right-click: minimap button drawer", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    AM.minimapButton = btn
    AM.UpdateMinimapButtonPos()
end

function AM.UpdateMinimapButtonPos()
    if not AM.minimapButton then return end
    local angle = math.rad(AM_MinimapPos or 200)
    local radius = (Minimap:GetWidth() / 2) + 10
    local x = math.cos(angle) * radius
    local y = math.sin(angle) * radius
    AM.minimapButton:ClearAllPoints()
    AM.minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- ---------------------------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")

ev.scanDelay = 3
ev.rescanTimer = 0
ev.initialScanDone = false

ev:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" then
        if arg1 == AM.ADDON_NAME then
            -- merge whatever was persisted from previous sessions (already in
            -- chronological order) with any (unlikely) entries logged between
            -- file-load and this event, keeping chronological order
            local merged = AM_ErrorLog or {}
            for i = 1, table.getn(AM.errorLog) do
                table.insert(merged, AM.errorLog[i])
            end
            AM.errorLog = merged
            while table.getn(AM.errorLog) > AM.ERROR_LOG_MAX do
                table.remove(AM.errorLog, 1)
            end
            AM.CreateDrawer()
            AM.CreateMinimapButton()
            AM.Say("/am opens list, right-click icon too")
        end
        -- Attribute any newly-visible SLASH_* globals to whichever addon just
        -- finished loading (covers commands registered at file-load time, which
        -- is the vast majority of them).
        AM.ScanNewSlashCommands(arg1)
    elseif event == "PLAYER_ENTERING_WORLD" then
        ev.scanDelay = 3
        -- One more pass in case anything registered its commands late (deferred
        -- to PLAYER_LOGIN/PLAYER_ENTERING_WORLD instead of file-load time). These
        -- can't be reliably attributed to a specific addon at this point, so they
        -- aren't - they just stop showing up as "new" in future scans.
        AM.ScanNewSlashCommands(nil)
    end
end)

ev:SetScript("OnUpdate", function()
    if not AM.drawer then return end

    if not ev.initialScanDone then
        ev.scanDelay = ev.scanDelay - arg1
        if ev.scanDelay <= 0 then
            AM.ScanMinimapButtons()
            ev.initialScanDone = true
        end
        return
    end

    -- keep periodically sweeping for late-created buttons (cheap, harmless if empty)
    ev.rescanTimer = ev.rescanTimer + arg1
    if ev.rescanTimer >= 5 then
        ev.rescanTimer = 0
        AM.ScanMinimapButtons()
    end
end)

-- ---------------------------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------------------------
SLASH_ADDONMANAGER1 = "/am"
SlashCmdList["ADDONMANAGER"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "reload" then
        ReloadUI()
    elseif msg == "rescan" then
        AM.ScanMinimapButtons()
        AM.Say("rescanned minimap buttons.")
    elseif msg == "probe" then
        AM.Probe()
    elseif msg == "commands" then
        AM.DumpDiscoveredCommands()
    else
        AM.ToggleMainFrame()
    end
end
