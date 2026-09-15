--[[
    test_release_persistence.lua - releasing a minimap button sticks across a
    reload, whether it was released from the settings menu or by dragging it out
    of the drawer.

    Usage (from the repo root):
        lua tools/test_release_persistence.lua [path/to/addon.lua]

    Two of these are safety properties rather than features, and both are
    asserted explicitly:

      * The drag must never call StartMoving/StopMovingOrSizing/SetUserPlaced on
        somebody else's button. Those make the CLIENT persist that frame's
        position to layout-cache.txt forever - outside this addon's control, and
        surviving its uninstall.
      * A released button must get its own drag scripts back, or the owning
        addon's icon would quietly stop being draggable once released.
--]]

local Stub = dofile("tools/wow_stub.lua")
local ADDON_PATH = arg[1] or "GimmetbarbieAddonManager.lua"

local failures, checks = 0, 0
local function check(label, got, want)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print("  FAIL " .. label .. ": got " .. tostring(got) .. ", wanted " .. tostring(want))
    end
end

-- Records any use of the APIs that mark a frame "user placed".
local forbidden

local function makeMinimapButton(name)
    local b = Stub.CreateFrame("Button", name, Minimap)
    b._w, b._h = 24, 24
    b:SetPoint("CENTER", Minimap, "CENTER", 0, 0)
    b.GetNormalTexture = function() return { GetTexture = function() return "icon" end } end
    b.StartMoving = function() forbidden["StartMoving:" .. name] = true end
    b.StopMovingOrSizing = function() forbidden["StopMovingOrSizing:" .. name] = true end
    b.SetUserPlaced = function() forbidden["SetUserPlaced:" .. name] = true end
    -- Pretend the owning addon made it draggable, the way real ones do.
    b.ownDragStart = function() end
    b.ownDragStop = function() end
    b:SetScript("OnDragStart", b.ownDragStart)
    b:SetScript("OnDragStop", b.ownDragStop)
    return b
end

-- Loads the addon fresh, as a reload would, carrying saved variables across.
local function boot(savedReleases, buttonNames)
    Stub.Reset()
    forbidden = {}
    Stub.SetRoster({ player = "Salahaja" })

    GetRealmName = function() return "N'Zoth" end
    time = os.time
    date = function() return "12:00:00" end
    GameTooltip = Stub.CreateFrame("Frame", "GameTooltip")
    Minimap = Stub.CreateFrame("Frame", "Minimap")
    Minimap._w, Minimap._h = 140, 140
    Minimap:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 1000, 900)
    ReloadUI = function() end
    geterrorhandler = function() return function() end end
    seterrorhandler = function() end
    GetNumAddOns = function() return 0 end
    GetAddOnInfo = function() return nil end
    IsAddOnLoaded = function() return nil end
    DisableAddOn = function() end
    EnableAddOn = function() end
    UIParent._w, UIParent._h = 1920, 1080

    AM_ReleasedButtons = savedReleases
    AM_MinimapPos, AM_FramePos, AM_ErrorLog = nil, nil, nil
    AM = nil
    dofile(ADDON_PATH)

    -- Buttons exist before the addon's first scan, as they would in game.
    local buttons = {}
    for _, name in ipairs(buttonNames) do buttons[name] = makeMinimapButton(name) end

    -- What ADDON_LOADED does for real.
    AM.releasedNames = AM_ReleasedButtons or {}
    AM.CreateDrawer()
    AM.drawer:Show()
    AM.drawer:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 100, 500)
    AM.ScanMinimapButtons()
    return buttons
end

local function collectedNames()
    local names = {}
    for _, b in ipairs(AM.collectedList) do table.insert(names, b:GetName()) end
    table.sort(names)
    return table.concat(names, ",")
end

local function releasedNamesList()
    local names = {}
    for _, b in ipairs(AM.releasedList) do table.insert(names, b:GetName()) end
    table.sort(names)
    return table.concat(names, ",")
end

-- ---------------------------------------------------------------------------
print("a fresh install collects everything eligible")
do
    boot(nil, { "AlphaButton", "BetaButton", "GammaButton" })
    check("all three collected", collectedNames(), "AlphaButton,BetaButton,GammaButton")
    check("none released", releasedNamesList(), "")
end

-- ---------------------------------------------------------------------------
print("releasing from the settings menu is written to saved variables")
do
    local buttons = boot(nil, { "AlphaButton", "BetaButton" })
    AM.ReleaseMinimapButton(buttons["BetaButton"])

    check("only Alpha left in the drawer", collectedNames(), "AlphaButton")
    check("Beta listed as released", releasedNamesList(), "BetaButton")
    check("Beta recorded by NAME for next session", AM_ReleasedButtons["BetaButton"], true)
    check("Alpha was not recorded", AM_ReleasedButtons["AlphaButton"], nil)
    check("Beta re-parented back to the minimap", buttons["BetaButton"]:GetParent(), Minimap)
end

-- ---------------------------------------------------------------------------
print("the release survives a reload (the actual request)")
do
    local buttons = boot(nil, { "AlphaButton", "BetaButton" })
    AM.ReleaseMinimapButton(buttons["BetaButton"])
    local saved = AM_ReleasedButtons

    -- Reload: same saved variables, everything else built from scratch.
    boot(saved, { "AlphaButton", "BetaButton" })
    check("Beta is NOT collected again", collectedNames(), "AlphaButton")
    check("Beta is still known as released", releasedNamesList(), "BetaButton")
    check("  so settings can still offer Recollect", AM.released[BetaButton], true)
end

-- ---------------------------------------------------------------------------
print("recollecting clears the saved release")
do
    boot({ BetaButton = true }, { "AlphaButton", "BetaButton" })
    check("starts released", collectedNames(), "AlphaButton")

    AM.RecollectMinimapButton(BetaButton)
    check("back in the drawer", collectedNames(), "AlphaButton,BetaButton")
    check("and cleared from saved variables", AM_ReleasedButtons["BetaButton"], nil)

    boot(AM_ReleasedButtons, { "AlphaButton", "BetaButton" })
    check("still collected after a reload", collectedNames(), "AlphaButton,BetaButton")
end

-- ---------------------------------------------------------------------------
print("dragging an icon OUT of the drawer releases it")
do
    local buttons = boot(nil, { "AlphaButton", "BetaButton" })
    local beta = buttons["BetaButton"]

    local inX, inY = AM.drawer:GetLeft() + 5, AM.drawer:GetTop() - 5
    Stub.cursor.x, Stub.cursor.y = inX, inY -- over the drawer
    check("  (sanity) that really is inside the drawer", AM.CursorOverDrawer(), true)
    Stub.FireScript(beta, "OnDragStart")
    Stub.cursor.x, Stub.cursor.y = 1500, 200 -- far outside it
    Stub.FireScript(beta, "OnDragStop")

    check("released", collectedNames(), "AlphaButton")
    check("  and recorded for next session", AM_ReleasedButtons["BetaButton"], true)

    boot(AM_ReleasedButtons, { "AlphaButton", "BetaButton" })
    check("still out after a reload", collectedNames(), "AlphaButton")
end

-- ---------------------------------------------------------------------------
print("dropping an icon back INSIDE the drawer keeps it")
do
    local buttons = boot(nil, { "AlphaButton", "BetaButton" })
    local beta = buttons["BetaButton"]

    local inX, inY = AM.drawer:GetLeft() + 5, AM.drawer:GetTop() - 5
    Stub.cursor.x, Stub.cursor.y = inX, inY
    Stub.FireScript(beta, "OnDragStart")
    Stub.cursor.x, Stub.cursor.y = inX + 3, inY - 3 -- still over the drawer
    Stub.FireScript(beta, "OnDragStop")

    check("still collected", collectedNames(), "AlphaButton,BetaButton")
    check("nothing recorded as released",
        AM_ReleasedButtons and AM_ReleasedButtons["BetaButton"], nil)
end

-- ---------------------------------------------------------------------------
print("dragging never marks somebody else's button 'user placed'")
do
    local buttons = boot(nil, { "AlphaButton", "BetaButton" })
    local beta = buttons["BetaButton"]

    Stub.cursor.x, Stub.cursor.y = AM.drawer:GetLeft() + 5, AM.drawer:GetTop() - 5
    Stub.FireScript(beta, "OnDragStart")
    Stub.cursor.x, Stub.cursor.y = 400, 400
    AM.dragDriver:GetScript("OnUpdate")()
    Stub.cursor.x, Stub.cursor.y = 1500, 200
    Stub.FireScript(beta, "OnDragStop")

    check("StartMoving never called", forbidden["StartMoving:BetaButton"], nil)
    check("StopMovingOrSizing never called", forbidden["StopMovingOrSizing:BetaButton"], nil)
    check("SetUserPlaced never called", forbidden["SetUserPlaced:BetaButton"], nil)
end

-- ---------------------------------------------------------------------------
print("a released button gets its own drag behaviour back")
do
    local buttons = boot(nil, { "AlphaButton" })
    local alpha = buttons["AlphaButton"]

    check("ours while collected", alpha:GetScript("OnDragStart") ~= alpha.ownDragStart, true)
    AM.ReleaseMinimapButton(alpha)
    check("theirs again once released", alpha:GetScript("OnDragStart"), alpha.ownDragStart)
    check("  and the stop handler too", alpha:GetScript("OnDragStop"), alpha.ownDragStop)
end

-- ---------------------------------------------------------------------------
print("a recollected button can be dragged straight back out again")
do
    -- The full round trip: released in a past session, recollected from the
    -- settings menu, then dragged out again. The drag hooks have to be
    -- reinstalled by the recollect, or the second drag would do nothing and the
    -- icon would be stuck in the drawer.
    boot({ BetaButton = true }, { "AlphaButton", "BetaButton" })
    check("starts out released", collectedNames(), "AlphaButton")

    AM.RecollectMinimapButton(BetaButton)
    check("recollected into the drawer", collectedNames(), "AlphaButton,BetaButton")
    check("  and no longer saved as released", AM_ReleasedButtons["BetaButton"], nil)

    local inX, inY = AM.drawer:GetLeft() + 5, AM.drawer:GetTop() - 5
    Stub.cursor.x, Stub.cursor.y = inX, inY
    Stub.FireScript(BetaButton, "OnDragStart")
    Stub.cursor.x, Stub.cursor.y = 1500, 200
    Stub.FireScript(BetaButton, "OnDragStop")

    check("dragging it out again releases it", collectedNames(), "AlphaButton")
    check("  and records it again", AM_ReleasedButtons["BetaButton"], true)

    boot(AM_ReleasedButtons, { "AlphaButton", "BetaButton" })
    check("  which survives the next reload", collectedNames(), "AlphaButton")
end

-- ---------------------------------------------------------------------------
print("")
if failures == 0 then
    print("all " .. checks .. " checks passed")
    os.exit(0)
else
    print(failures .. " of " .. checks .. " checks FAILED")
    os.exit(1)
end
