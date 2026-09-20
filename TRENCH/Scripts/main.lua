-- Bodycam "Battlefield": bot autofill and artillery for a match you host.
-- Everything goes through UE4SS reflection; no offsets or guessed Bodycam calls.
-- Hotkeys and settings live at the bottom of this file; artillery is in features.lua.
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local scripts = assert(source:match("^(.*)/[^/]+$"), "Cannot locate mod directory")
local root = scripts .. "/.."
local Config = dofile(scripts .. "/config.lua")
-- Named after the folder the mod sits in, so renaming the folder renames the log with it and
-- there is nothing to keep in step by hand.
local modName = scripts:match("([^/]+)/[^/]+$") or "TRENCH"
local logPath = root .. "/" .. modName .. ".log"
-- The log is appended to for the whole session. At load, roll it over past 2 MB so it
-- cannot grow without bound; the previous one is kept as .1.
do
    local f = io.open(logPath, "rb")
    if f then
        local size = f:seek("end")
        f:close()
        if size and size > 2 * 1024 * 1024 then
            os.remove(logPath .. ".1")
            os.rename(logPath, logPath .. ".1")
        end
    end
end
local function log(s)
    local line = "[" .. modName .. "] " .. tostring(s)
    print(line .. "\n")
    local f = io.open(logPath, "a")
    if f then f:write(os.date("!%Y-%m-%dT%H:%M:%SZ "), line, "\n"); f:close() end
end
local function try(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil, tostring(value)
end
local function valid(o) return o ~= nil and try(function() return o:IsValid() end) == true end
local function name(o) return try(function() return o:GetFullName() end) or "NOT FOUND" end
local function short(o) return try(function() return o:GetFName():ToString() end) or "?" end
local function read(o, p) return try(function() return o[p] end) end
-- Looked up once and kept. This used to be resolved by name on every context() call, which in
-- a match is ten times a second: each lookup hands a fresh string across to the engine, and
-- that boundary is exactly where the allocator crashes come from.
local kismet
-- The head count walks a replicated array, so it is only taken where it is actually printed
-- (the 5 s poll), not on every context() the fast loops make.
local function playerCount(c)
    if not valid(c.gs) then return nil end
    return try(function() return #c.gs.PlayerArray end)
end
-- A menu can have an authoritative GameMode. Require a networked server too.
local function contextForWorld(world)
    local c = {host = false, reason = "No active local controller/world"}
    c.world = world
    if not valid(c.world) then return c end
    c.gm = read(c.world, "AuthorityGameMode")
    c.gs = read(c.world, "GameState")
    c.gi = read(c.world, "OwningGameInstance")
    if not valid(kismet) then kismet = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    local k = kismet
    c.server = valid(k) and try(function() return k:IsServer(c.world) end)
    c.standalone = valid(k) and try(function() return k:IsStandalone(c.world) end)
    c.host = valid(c.gm) and c.server == true and c.standalone == false
    c.reason = c.host and "Networked authoritative host detected; private/public status not inferred"
        or "Not a confirmed networked host (client/menu/standalone/unknown); writes refused"
    return c
end
-- The current world and local player come straight from the engine. Scanning every UObject
-- (FindAllOf) while the async loader creates objects for a new map coincided with load
-- crashes/hangs, so scans now happen only once at startup (the engine) or inside a match.
local engine, statics, worldVia
local function currentWorld()
    if not valid(engine) then
        engine = nil
        for _, e in ipairs(FindAllOf("GameEngine") or {}) do
            if valid(e) and not name(e):find("Default__", 1, true) then engine = e; break end
        end
    end
    local vp = engine and read(engine, "GameViewport")
    local w = valid(vp) and read(vp, "World")
    local via = "GameViewport.World"
    if not valid(w) and engine then
        local gi = read(engine, "GameInstance")
        w = valid(gi) and try(function() return gi:GetWorld() end)
        via = "GameInstance:GetWorld()"
    end
    if not valid(w) then return nil end
    if not worldVia then worldVia = via; log("World lookup via " .. via) end
    return w
end
local function localController(world)
    world = world or currentWorld()
    if not world then return nil end
    if not valid(statics) then statics = StaticFindObject("/Script/Engine.Default__GameplayStatics") end
    local pc = try(function() return statics:GetPlayerController(world, 0) end)
    return valid(pc) and pc or nil
end
local function context()
    return contextForWorld(currentWorld())
end

local function header(c, count)
    log(c.reason)
    log("World: " .. name(c.world))
    log("GameMode: " .. (valid(c.gm) and name(c.gm:GetClass()) or "NOT FOUND"))
    log("GameState: " .. (valid(c.gs) and name(c.gs:GetClass()) or "NOT FOUND"))
    log("Current PlayerArray entries: " .. tostring(count or "UNKNOWN") .. " (may include bots/spectators; not verified human connections)")
    log("Online/EOS session interface: UNKNOWN (native interfaces are not necessarily UObjects)")
    log("Current advertised backend capacity: UNKNOWN; a local property is not backend readback")
end

-- Team Deathmatch capacity is grown two slots at a time by autofill as bots are added, never
-- before a map loads: a 24-slot initial bot fill hung map loading. Each map starts from stock.
local stock -- original {total, team} of the TDM config asset
-- Set by the 5 s poll: true only while hosting a loaded Team Deathmatch map. The fast loops
-- stay idle otherwise, so nothing of ours runs while a map is loading.
local inMatch = false
local tdmAsset
local function tdmData()
    if not valid(tdmAsset) then
        tdmAsset = nil
        if not inMatch then return nil end
        for _, asset in ipairs(FindAllOf("GameModeConfigDataAsset") or {}) do
            if valid(asset) and name(asset):find("/DA_GameModeTeamDeathmatch.", 1, true) then tdmAsset = asset; break end
        end
    end
    local data = tdmAsset and read(tdmAsset, "TeamConfig")
    if not valid(data) then return nil end
    if not stock then
        local total, team = read(data, "MaxPlayers"), read(data, "TeamMaxSize")
        if type(total) == "number" and type(team) == "number" then stock = {total = total, team = team} end
    end
    return data
end
-- Match length lives in the same asset, one struct over: PhaseConfig.PhaseDuration, in seconds
-- (600 as shipped). Written the same way capacity is, and put back the same way afterwards.
local stockPhase
local function applyMatchLength(minutes)
    if not tdmData() then return end            -- resolves tdmAsset while in a match
    local p = read(tdmAsset, "PhaseConfig")
    if not valid(p) then return end
    local cur = read(p, "PhaseDuration")
    if type(cur) ~= "number" then return end
    if not stockPhase then stockPhase = cur end
    local want = math.floor(tonumber(minutes) or 0) * 60
    if want <= 0 or math.abs(cur - want) < 0.5 then return end
    pcall(function() p.PhaseDuration = want end)
    log("Match length: " .. math.floor(cur / 60 + 0.5) .. " -> " .. (want / 60) .. " min")
end
-- Put capacity back to stock when leaving a match (uses the cached asset, no scanning).
local function restoreStock()
    if not valid(tdmAsset) or not stock then return end
    local data = read(tdmAsset, "TeamConfig")
    if not valid(data) then return end
    local total, team = read(data, "MaxPlayers"), read(data, "TeamMaxSize")
    if type(total) ~= "number" or type(team) ~= "number" then return end
    if total ~= stock.total or team ~= stock.team then
        pcall(function() data.MaxPlayers = stock.total end)
        pcall(function() data.TeamMaxSize = stock.team end)
        log("TDM capacity restored to stock " .. stock.total .. "/" .. stock.team .. " after the match")
    end
    local p = read(tdmAsset, "PhaseConfig")
    if stockPhase and valid(p) and read(p, "PhaseDuration") ~= stockPhase then
        pcall(function() p.PhaseDuration = stockPhase end)
        log("Match length restored to stock " .. math.floor(stockPhase / 60 + 0.5) .. " min")
    end
end
local function growCapacity(total, ceiling)
    local data = tdmData()
    if not data then return nil end
    local current = read(data, "MaxPlayers")
    if type(current) ~= "number" then return nil end
    if total < current then return current end
    local nextTotal = math.min(ceiling, total + 2)
    if nextTotal <= current then return current end
    pcall(function() data.MaxPlayers = nextTotal end)
    pcall(function() data.TeamMaxSize = math.ceil(nextTotal / 2) end)
    log("TDM capacity grown " .. current .. " -> " .. tostring(read(data, "MaxPlayers")))
    return read(data, "MaxPlayers")
end
-- One-shot dump of what the Team Deathmatch config asset and the game state actually carry.
-- The match timer has to be found by its real name before anything can set it; guessing at
-- property names is how setups break silently.
local configDumped = false
local function dumpMatchConfig(c, data)
    if configDumped then return "already dumped, see the log" end
    configDumped = true
    local total = 0
    -- Each object gets its own budget. One shared cap meant the game state, which has well over a
    -- hundred properties, spent all of it before the game mode was reached.
    local function dump(label, o, cap)
        cap = cap or 60
        if not valid(o) then log("Config dump [" .. label .. "]: NOT FOUND"); return end
        log("Config dump [" .. label .. "]: " .. name(o))
        local n, seen = 0, {}
        local function each(holder)
            if not valid(holder) then return end
            pcall(function()
                holder:ForEachProperty(function(p)
                    if n >= cap then return end
                    local pn = short(p)
                    if seen[pn] then return end
                    seen[pn] = true
                    n = n + 1; total = total + 1
                    local v = read(o, pn)
                    local t = type(v)
                    log("   " .. pn .. " = " .. ((t == "number" or t == "boolean" or t == "string")
                        and tostring(v) or ("<" .. (tostring(name(p)):match("^(%S+)") or "?") .. ">")))
                end)
            end)
        end
        -- A struct value lists its own fields; an object lists them through its class chain.
        -- TeamConfig came back empty last time because only the class route was tried.
        each(o)
        local cls = try(function() return o:GetClass() end)
        for _ = 1, 8 do
            if not valid(cls) or n >= cap then break end
            each(cls)
            cls = try(function() return cls:GetSuperStruct() end)
        end
        if n == 0 then log("   (no readable properties)") end
    end
    -- The asset and its config structs first: that is where a configured match length would live.
    dump("TDM asset", tdmAsset)
    for _, field in ipairs({"PhaseConfig", "ScoringConfig", "TeamConfig", "LoadoutConfig"}) do
        dump("TDM." .. field, read(tdmAsset, field) or (field == "TeamConfig" and data or nil))
    end
    dump("GameMode", c.gm, 90)
    -- The live phase, next to its configured counterpart: the round clock runs off these two.
    dump("GameState.CurrentPhase", valid(c.gs) and read(c.gs, "CurrentPhase") or nil)
    dump("GameState", c.gs, 60)
    return total .. " properties logged"
end
local lastSummary = nil

-- Every 5 s: log the host/world line when it changes and publish the match heartbeat.
local function poll()
    local c = context()
    local count = playerCount(c)
    local summary = name(c.world) .. "/" .. tostring(c.host) .. "/" .. tostring(count)
    if summary ~= lastSummary then lastSummary = summary; header(c, count) end
    -- Heartbeat for the menu window: "1" while hosting a Team Deathmatch map (starts the ambience).
    local was = inMatch
    inMatch = c.host and valid(c.gm) and name(c.gm:GetClass()):lower():find("gm_teamdeathmatch", 1, true) ~= nil
        and not name(c.world):find("/Game/Map/TransitionMap/", 1, true)
    if was and not inMatch then pcall(restoreStock) end
    local f = io.open(root .. "/match_state.txt", "wb")
    if f then f:write(inMatch and "1" or "0"); f:close() end
    -- (The original ShouldSpawnBots hook is no longer installed: team sizes are managed by autofill.)
end
-- Key presses arrive on UE4SS's input thread: only hand the work to the game thread and
-- touch no shared Lua state here. (Sharing tables across threads corrupted the Lua state
-- and crashed the game.) All periodic work runs via LoopInGameThreadWithDelay below.
local function dispatch(fn)
    pcall(ExecuteInGameThread, function()
        local worked, why = pcall(fn)
        if not worked then log("ERROR: " .. tostring(why)) end
    end)
end

log("=== " .. modName .. " revision 1.0 loaded; inspected build 25228199 ===")
log("Keys: F5/F6 your team +/-, F7/F8 enemy team +/-, F9 shelling on/off, Home bot-skill probe")
log("Config: " .. root .. "/config.json (player limit), settings.ini (teams, artillery, sound)")
log("Team sizes are held by autofill; TDM capacity grows on demand and is restored when the match ends")

-- Feedback in the game's chat/event feed (if Bodycam shows ClientMessage) and in the log.
local function notify(text)
    log(text)
    local pc = localController()
    if pc then pcall(function() pc:ClientMessage(text, FName("Event"), 5.0) end) end
end
local features = dofile(scripts .. "/features.lua")({log=log, try=try, valid=valid, name=name, short=short, root=root})

local destroyedCtrls = {}
local function isGone(ps)
    local owner = try(function() return ps:GetOwner() end)
    return not valid(owner) or destroyedCtrls[tostring(try(function() return owner:GetAddress() end))] == true
end
-- Team sizes (humans included) and bots per team key ("0", "1", "-1" = no team yet).
local function roster(c)
    local r = {sizes = {[0] = 0, [1] = 0}, bots = {}, total = 0}
    local players = try(function() return c.gs.PlayerArray end) or {}
    for i = 1, #players do
        local ps = players[i]
        if not isGone(ps) then
            r.total = r.total + 1
            local team = try(function() return ps.TeamID end)
            if team == 0 or team == 1 then r.sizes[team] = r.sizes[team] + 1 end
            if try(function() return ps.bIsABot end) == true then
                local key = tostring(team)
                r.bots[key] = r.bots[key] or {}
                table.insert(r.bots[key], ps)
            end
        end
    end
    return r
end
local function localPlayer()
    local pc = localController()
    if not pc then return nil end
    local ps = read(pc, "PlayerState")
    return read(pc, "Pawn"), valid(ps) and read(ps, "TeamID")
end
local function removeBot(ps)
    local ctrl = try(function() return ps:GetOwner() end)
    if not valid(ctrl) then return false end
    local pawn = read(ctrl, "Pawn")
    if valid(pawn) then pcall(function() pawn:K2_DestroyActor() end) end
    if not pcall(function() ctrl:K2_DestroyActor() end) then return false end
    destroyedCtrls[tostring(try(function() return ctrl:GetAddress() end))] = true
    return true
end
-- After the round starts Bodycam no longer assigns teams to new bots (they stayed TeamID -1
-- with no pawn). Put the bot on the wanted team, then respawn it. Every step is logged.
local signaturesLogged = false
-- Bots share the map's player starts. Asking for more bots than the map was built for puts
-- several of them on the same spot, capsules interpenetrating, and they cannot walk out of each
-- other - that is the clump of teammates shuffling forward and the pair of enemies standing
-- still. Step a freshly placed bot clear of whoever is already there. The move sweeps, so it
-- stops at walls instead of pushing through them.
local function spread(pawn)
    local here = try(function() return pawn:K2_GetActorLocation() end)
    local x = here and try(function() return here.X end)
    local y = here and try(function() return here.Y end)
    local z = here and try(function() return here.Z end)
    if type(x) ~= "number" or type(y) ~= "number" then return end
    local mine = try(function() return pawn:GetAddress() end)
    local crowded = false
    for _, ch in ipairs(FindAllOf("Character") or {}) do
        if valid(ch) and try(function() return ch:GetAddress() end) ~= mine then
            local o = try(function() return ch:K2_GetActorLocation() end)
            local ox = o and try(function() return o.X end)
            local oy = o and try(function() return o.Y end)
            if type(ox) == "number" and type(oy) == "number"
                and (ox - x) ^ 2 + (oy - y) ^ 2 < 120 * 120 then crowded = true; break end
        end
    end
    if not crowded then return end
    local angle, dist = math.random() * 2 * math.pi, 200 + math.random() * 300
    pcall(function()
        pawn:K2_SetActorLocation({X = x + math.cos(angle) * dist, Y = y + math.sin(angle) * dist, Z = z}, true, {}, true)
    end)
    return true
end
local function placeBot(c, bot, want)
    if not signaturesLogged then
        signaturesLogged = true
        for _, path in ipairs({"/Script/Bodycam.BodycamGameMode:SpawnBot", "/Script/Engine.GameModeBase:RestartPlayer"}) do
            local f = StaticFindObject(path)
            local params = {}
            if valid(f) then pcall(function() f:ForEachProperty(function(p) params[#params + 1] = name(p) end) end) end
            log("Signature " .. path .. ": " .. (valid(f) and (#params > 0 and table.concat(params, " | ") or "no params") or "NOT FOUND"))
        end
    end
    local ctrl = bot
    if not try(function() return bot:IsA("/Script/Engine.Controller") end) then ctrl = read(bot, "Controller") end
    if not valid(ctrl) then log("placeBot: SpawnBot returned " .. name(bot) .. " without a controller"); return nil end
    local ps = read(ctrl, "PlayerState")
    -- AssignTeamToPlayer is native-only (not callable from Lua); writing TeamID works.
    if valid(ps) then pcall(function() ps.TeamID = want end) end
    local team = valid(ps) and read(ps, "TeamID")
    -- Only respawn a bot that has no body. RestartPlayer on a bot that is already alive throws
    -- its pawn away and possesses a new one, and whatever the game starts as part of its own
    -- spawn does not necessarily start again on a bare re-possess: the bot comes back standing
    -- still. Setting TeamID is enough for one that is already on its feet.
    -- The AI controller ships with bStartAILogicOnPossess = false and bStopAILogicOnUnposses =
    -- true. RestartPlayer unpossesses first, which stops the behaviour tree, then possesses the
    -- new pawn without starting it again: the bot gets a body, keeps its BrainComponent, and
    -- stands there with nothing running. Turn the flag on before the restart so possession
    -- starts the logic itself.
    pcall(function() ctrl.bStartAILogicOnPossess = true end)
    local aiFlag = read(ctrl, "bStartAILogicOnPossess")
    local pawn = read(ctrl, "Pawn")
    local note
    if valid(pawn) then
        note = "already had a pawn, left alone"
    else
        local okRestart, errRestart = pcall(function() c.gm:RestartPlayer(ctrl) end)
        pawn = read(ctrl, "Pawn")
        note = "RestartPlayer " .. (okRestart and "ran" or ("FAILED " .. tostring(errRestart)))
    end
    local moved = valid(pawn) and spread(pawn)
    log("placeBot: team=" .. tostring(team) .. "; AI-on-possess=" .. tostring(aiFlag) .. "; " .. note
        .. "; pawn=" .. (valid(pawn) and "YES" or "NO")
        .. (moved and "; stepped out of a crowded spawn" or ""))
    return team
end
-- Hand an existing bot to another team instead of spawning a new one. r.bots holds PlayerStates;
-- placeBot wants the controller behind it.
local function moveBot(c, ps, want)
    local ctrl = try(function() return ps:GetOwner() end)
    if not valid(ctrl) then return false end
    return placeBot(c, ctrl, want) == want
end
-- The real head count, as autofill sees it. Logged only when it changes: without this there was
-- no way to tell a team that is short from a team the game keeps reassigning under us.
local lastRoster, crowdedWorld
local function logRoster(r, want)
    local line = string.format("%d/%d (want %d/%d), bots %d/%d, teamless %d, total %d",
        r.sizes[0], r.sizes[1], want[0] or 0, want[1] or 0,
        #(r.bots["0"] or {}), #(r.bots["1"] or {}), #(r.bots["-1"] or {}), r.total)
    if line == lastRoster then return end
    lastRoster = line
    log("Roster: " .. line)
end
local function spawnOne(c, r, limit, want)
    if not growCapacity(r.total, limit) then log("Autofill: Team Deathmatch config not found"); return false end
    local ok, bot = pcall(function() return c.gm:SpawnBot() end)
    if not ok or not valid(bot) then log("SpawnBot FAILED: " .. tostring(bot)); return false end
    if want == nil then return true end -- warm-up: Bodycam splits teams itself at round start
    local team = placeBot(c, bot, want)
    return team == want
end

-- Nothing may spawn or destroy while a map is still loading: SpawnBot during the first
-- seconds of a map crashed / hung the game. A map counts as settled 15 s after it is first
-- seen and once your own character exists; the transition map never counts.
local settleWorld, settleSince
local function settled(c)
    if not valid(c.world) then return false end
    local w = name(c.world)
    if w:find("/Game/Map/TransitionMap/", 1, true) then settleWorld = nil; return false end
    if settleWorld ~= w then
        settleWorld, settleSince = w, os.clock()
        -- Controller addresses from the previous map mean nothing here, and the engine reuses
        -- them: a stale entry would make a live bot look destroyed forever (autofill would then
        -- keep spawning). The table is dropped with the old world.
        destroyedCtrls = {}
        pcall(restoreStock)
    end
    if os.clock() - settleSince < 15 then return false end
    return valid((localPlayer()))
end

-- Keeps each team at the size set in settings.ini: one spawn or removal per second.
local fillBroken
local function autofill(c)
    if not c.host or not valid(c.gm) or not valid(c.gs) then return end
    if not name(c.gm:GetClass()):lower():find("gm_teamdeathmatch", 1, true) then return end
    if not settled(c) then return end
    local world = name(c.world)
    if fillBroken == world then return end
    local limit = Config.read(root .. "/config.json") or 64
    local s = features.settings()
    applyMatchLength(s.matchMinutes)
    local mine = math.max(1, math.floor(s.myTeam))
    local enemy = math.max(0, math.floor(s.enemyTeam))
    local r = roster(c)
    local _, myTeam = localPlayer()
    if myTeam ~= 0 and myTeam ~= 1 then
        -- Warm-up: no teams yet; keep the overall head count.
        local target = math.min(limit, mine + enemy)
        if r.total < target then spawnOne(c, r, limit, nil)
        elseif r.total > target then
            for _, bots in pairs(r.bots) do
                if #bots > 0 then removeBot(bots[#bots]); break end
            end
        end
        return
    end
    local other = 1 - myTeam
    local want = {[myTeam] = mine, [other] = enemy}
    local ceiling = math.min(limit, mine + enemy)
    -- Said once per map. Bots share the map's player starts, so past the size the level was
    -- built for they arrive on top of each other and shuffle instead of fighting. This is the
    -- one explanation for dull bots that every probe so far has failed to rule out.
    if stock and mine + enemy > stock.total and crowdedWorld ~= world then
        crowdedWorld = world
        log("Heads-up: this map ships with room for " .. stock.total .. " players, " .. stock.team
            .. " a side. You are asking for " .. (mine + enemy) .. ".")
    end
    logRoster(r, want)
    -- Trim before filling. The other way round, a team that never reached its number kept the
    -- spawn branch returning early, so removal and the teamless sweep below were unreachable and
    -- the head count climbed on its own - fifty players against a target of seventeen.
    local stray = r.bots["-1"] or {}
    if #stray > 0 then
        -- A teamless bot is a bot we already have: give it to whoever is short before killing it.
        for _, t in ipairs({myTeam, other}) do
            if r.sizes[t] < want[t] then moveBot(c, stray[#stray], t); return end
        end
        removeBot(stray[#stray])
        return
    end
    for _, t in ipairs({myTeam, other}) do
        local bots = r.bots[tostring(t)] or {}
        local over = r.sizes[t] - want[t]
        if over > 0 and #bots > 0 then
            local o = 1 - t
            -- A handful per pass, not one. Trimming is far cheaper than spawning, and at one a
            -- second clearing a full map took the better part of a minute - long enough that it
            -- reads as "nothing happens". Still capped so a big cut cannot stall the frame.
            local n = math.min(over, #bots, 5)
            log("Trimming team " .. t .. ": " .. r.sizes[t] .. " over a target of " .. want[t]
                .. "; taking " .. n .. " this pass")
            local sizes = {[0] = r.sizes[0], [1] = r.sizes[1]}
            for i = 0, n - 1 do
                local ps = bots[#bots - i]
                -- Move rather than destroy when the other side is short: same bot, right team,
                -- and no new spawn to push the total up.
                if sizes[o] < want[o] then
                    if moveBot(c, ps, o) then sizes[o] = sizes[o] + 1; sizes[t] = sizes[t] - 1 end
                elseif removeBot(ps) then
                    sizes[t] = sizes[t] - 1
                end
            end
            return
        end
    end
    -- Only now fill, and never past the two numbers added together.
    for _, t in ipairs({myTeam, other}) do
        if r.sizes[t] < want[t] and r.total < ceiling then
            if not spawnOne(c, r, limit, t) then
                fillBroken = world
                notify("Autofill stopped on this map: a new bot did not join team " .. t .. " (see log)")
            end
            return
        end
    end
end

-- Hotkeys change the targets; autofill does the rest.
local function adjust(key, delta)
    local s = features.settings()
    local limit = Config.read(root .. "/config.json") or 64
    local copy = {}
    for k, v in pairs(s) do copy[k] = v end
    -- Cutting counts down from what is actually on the field, not from a target the fill has
    -- not reached yet. Loading a preset of 32 a side and then pressing F6 over a dozen bots
    -- used to do nothing visible for twenty presses, which reads exactly like a dead key.
    if delta < 0 then
        local c = context()
        local _, myTeam = localPlayer()
        if c.host and valid(c.gs) and (myTeam == 0 or myTeam == 1) then
            local r = roster(c)
            local live = key == "myTeam" and r.sizes[myTeam] or r.sizes[1 - myTeam]
            if type(live) == "number" then
                if key == "myTeam" then copy.myTeam = math.min(copy.myTeam, live)
                else copy.enemyTeam = math.min(copy.enemyTeam, live) end
            end
        end
    end
    if key == "myTeam" then copy.myTeam = math.max(1, math.min(limit - copy.enemyTeam, copy.myTeam + delta))
    else copy.enemyTeam = math.max(0, math.min(limit - copy.myTeam, copy.enemyTeam + delta)) end
    features.save(copy)
    notify("Teams: you " .. copy.myTeam .. " vs enemy " .. copy.enemyTeam)
end
-- Four keys in a row for the two team sizes: F5/F6 yours, F7/F8 theirs.
RegisterKeyBind(Key.F5, function() dispatch(function() adjust("myTeam", 1) end) end)
RegisterKeyBind(Key.F6, function() dispatch(function() adjust("myTeam", -1) end) end)
RegisterKeyBind(Key.F7, function() dispatch(function() adjust("enemyTeam", 1) end) end)
RegisterKeyBind(Key.F8, function() dispatch(function() adjust("enemyTeam", -1) end) end)
-- Home arms the bot-skill probe: hooks every GetBotsAccuracy and logs what the game passes it.
-- Press it inside a match, then let bots shoot for a few seconds and read the log.
RegisterKeyBind(Key.HOME, function() dispatch(function()
    notify("Bot skill probe: " .. tostring(features.botProbe()))
    log("Match config: " .. tostring(dumpMatchConfig(context(), tdmData())))
end) end)
RegisterKeyBind(Key.F9, function() dispatch(function()
    local copy = {}
    for k, v in pairs(features.settings()) do copy[k] = v end
    copy.artillery = copy.artillery == 1 and 0 or 1
    features.save(copy)
    notify("Artillery: " .. (copy.artillery == 1 and "ON" or "OFF"))
end) end)

-- (No InitGameState/BeginPlay hooks: capacity is restored from the cached asset when a match ends.)
-- Periodic work, all on the game thread.
-- A loop that keeps failing is logged once, then once every 600 failures, so a broken
-- loop is visible in the log without flooding it ten times a second.
local function every(ms, label, fn)
    local failures = 0
    LoopInGameThreadWithDelay(ms, function()
        local ok, err = pcall(fn)
        if ok then return end
        failures = failures + 1
        if failures == 1 or failures % 600 == 0 then
            log(label .. " FAILED (" .. failures .. "x): " .. tostring(err))
        end
    end)
end
every(5000, "Automatic host check", poll)
every(1000, "Autofill", function()
    if not inMatch then return end
    local c = context()
    if c.host then autofill(c) end
end)
-- Artillery needs 0.1 s precision so the in-game blast lines up with the sound.
every(100, "Artillery", function()
    if not inMatch then return end
    local c = context()
    if not c.host or not valid(c.gm) then return end
    -- No second check that this is Team Deathmatch: inMatch already says so, and asking the
    -- class for its full name ten times a second was thirty needless strings across the
    -- Lua/engine boundary every second.
    if not settled(c) then return end
    local pawn = localPlayer()
    features.artilleryTick(c, pawn)
    features.writePose(pawn)
end)