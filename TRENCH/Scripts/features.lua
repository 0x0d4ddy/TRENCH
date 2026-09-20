-- Settings (settings.ini, hot-reloaded), presets (presets\*.ini) and artillery.
-- settings.ini is plain "key=value" so the desktop menu can write it too.
return function(api)
    local root = api.root
    local defaults = {
        matchMinutes = 10,      -- match length, minutes (PhaseConfig.PhaseDuration; 600 s as shipped)
        myTeam = 12,            -- players on your team, you included
        enemyTeam = 12,         -- players on the enemy team
        artillery = 0,
        artilleryMode = "random", -- random | player | bots | mixed
        artilleryClass = "/Game/BodycamWeapons/Core/Blueprint/Grenade/Grenade.Grenade_C",
        artilleryMinDelay = 6,    -- seconds between salvos
        artilleryMaxDelay = 15,
        artilleryShells = 6,      -- average shells per salvo; each salvo is this give or take two
        artilleryShellGap = 1.0,  -- seconds between shells in a salvo
        artilleryMinDist = 12,    -- metres from the target
        artilleryMaxDist = 40,
        artilleryFlight = 7,      -- seconds from the distant shot to impact (>= longest whistle)
        artilleryBattery = 900,   -- metres from the fight to the firing battery (for fire sounds)
        sound = 1,                -- custom whistle/impact/fire sounds (played by the menu window)
        soundVolume = 80,
        soundSync = 0,            -- seconds to shift the sound impact vs the in-game blast
        ambience = 1,             -- background war loop (played by the menu window during a match)
        artilleryFlash = 2,       -- 0 = blast only, no light; 1 = trench-zone flash; 2 = blinding flash
        artilleryKillRadius = 5,  -- metres; characters inside are killed (0 = no damage)
        artilleryHitsMe = 1,      -- 1 = the kill radius applies to you too
        soundImpact = 0,          -- extra impact layer from the menu on top of the game's own blast sound
    }
    local current, lastText, lastRead = {}, nil, 0

    local function parse(text)
        local out = {}
        for k, v in pairs(defaults) do out[k] = v end
        for line in text:gmatch("[^\r\n]+") do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k and defaults[k] ~= nil then
                if type(defaults[k]) == "number" then out[k] = tonumber(v) or defaults[k] else out[k] = v end
            end
        end
        return out
    end
    local function serialize(s)
        local keys = {}
        for k in pairs(defaults) do keys[#keys + 1] = k end
        table.sort(keys)
        local lines = {}
        for _, k in ipairs(keys) do lines[#lines + 1] = k .. "=" .. tostring(s[k]) end
        return table.concat(lines, "\n") .. "\n"
    end
    local function readFile(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local text = f:read("*a")
        f:close()
        return text
    end
    local function writeFile(path, text)
        local f = io.open(path, "wb")
        if not f then return false end
        f:write(text)
        f:close()
        return true
    end

    -- Re-read at most once a second; log when the menu changed something.
    local function settings()
        if os.clock() - lastRead < 1 and next(current) then return current end
        lastRead = os.clock()
        local text = readFile(root .. "/settings.ini")
        if not text then
            current = parse("")
            writeFile(root .. "/settings.ini", serialize(current))
            return current
        end
        if text ~= lastText then
            lastText = text
            current = parse(text)
            api.log("Settings loaded: my team " .. current.myTeam .. ", enemy " .. current.enemyTeam
                .. ", artillery " .. (current.artillery == 1 and current.artilleryMode or "off"))
        end
        return current
    end
    local function save(s)
        local text = serialize(s)
        writeFile(root .. "/settings.ini", text)
        lastText, current, lastRead = text, parse(text), os.clock()
    end

    -- F5: cycle presets listed (one name per line) in presets\index.txt by the desktop menu.
    local presetIndex = 0
    local function nextPreset()
        local list = readFile(root .. "/presets/index.txt")
        if not list then return nil, "no presets saved yet" end
        -- Lines are "preset_N|Name"; the ASCII file part is what io.open gets.
        local entries = {}
        for line in list:gmatch("[^\r\n]+") do
            local file, label = line:match("^([%w_]+)|(.*)$")
            if file then entries[#entries + 1] = {file = file, label = label} end
        end
        if #entries == 0 then return nil, "no presets saved yet" end
        presetIndex = presetIndex % #entries + 1
        local e = entries[presetIndex]
        local text = readFile(root .. "/presets/" .. e.file .. ".ini")
        if not text then return nil, "preset file missing: " .. e.file end
        writeFile(root .. "/settings.ini", text)
        lastRead = 0
        settings()
        return e.label
    end

    ---------------------------------------------------------------- artillery
    local nextSalvo = nil

    -- The shell is any loadable actor class (settings artilleryClass); grenade by default.
    -- Also used to load GameplayEffect classes by path.
    local function shellClass(path)
        local class = StaticFindObject(path)
        if api.valid(class) then return class end
        if type(LoadAsset) == "function" then
            pcall(function() LoadAsset((path:gsub("%.[^%.]+_C$", ""))) end)
            class = StaticFindObject(path)
            if api.valid(class) then return class end
        end
        return nil
    end
    -- (Removed: drone-class scan and the Grenade_C detonation probes. A spawned Grenade_C never
    -- exploded in-game, so an impact is now built from the game's own effects in fireShell.)

    -- Two Lua values can wrap one and the same actor, and then '==' between them is false.
    -- That is why "is this me?" kept coming out no: compare the addresses, which are the
    -- actor's real identity. (artilleryHitsMe leaned on '==' too, so it never held either.)
    local function sameActor(a, b)
        if a == b then return true end
        if not api.valid(a) or not api.valid(b) then return false end
        local x = api.try(function() return a:GetAddress() end)
        local y = api.try(function() return b:GetAddress() end)
        return x ~= nil and x == y
    end
    local function location(actor)
        local v = api.try(function() return actor:K2_GetActorLocation() end)
        if not v then return nil end
        local x, y, z = api.try(function() return v.X end), api.try(function() return v.Y end), api.try(function() return v.Z end)
        if type(x) ~= "number" then return nil end
        return {X = x, Y = y, Z = z}
    end

    local function pickTarget(c, s, localPawn)
        local mode = s.artilleryMode
        if mode == "mixed" then mode = ({"random", "random", "player", "bots"})[math.random(4)] end
        if mode == "player" and api.valid(localPawn) then return location(localPawn) end
        if mode == "random" then
            -- Random ground point inside the area the fighters currently cover (+30 m margin).
            local minX, minY, maxX, maxY
            local spots = {}
            for _, ch in ipairs(FindAllOf("Character") or {}) do
                if api.valid(ch) and api.valid(api.try(function() return ch.Controller end)) then
                    local l = location(ch)
                    if l then
                        spots[#spots + 1] = l
                        minX, maxX = math.min(minX or l.X, l.X), math.max(maxX or l.X, l.X)
                        minY, maxY = math.min(minY or l.Y, l.Y), math.max(maxY or l.Y, l.Y)
                    end
                end
            end
            if not minX then return nil end
            local x = minX - 3000 + math.random() * (maxX - minX + 6000)
            local y = minY - 3000 + math.random() * (maxY - minY + 6000)
            -- Ground height from the nearest fighter, so the shell lands on the local terrain.
            local best, bestD
            for _, l in ipairs(spots) do
                local d = (l.X - x) ^ 2 + (l.Y - y) ^ 2
                if not bestD or d < bestD then best, bestD = l, d end
            end
            return {X = x, Y = y, Z = best.Z, exact = true}
        end
        local pawns = {}
        local players = api.try(function() return c.gs.PlayerArray end) or {}
        for i = 1, #players do
            local ps = players[i]
            if api.try(function() return ps.bIsABot end) == true then
                local ctrl = api.try(function() return ps:GetOwner() end)
                local pawn = api.valid(ctrl) and api.try(function() return ctrl.Pawn end)
                if api.valid(pawn) then pawns[#pawns + 1] = pawn end
            end
        end
        if #pawns == 0 then return api.valid(localPawn) and location(localPawn) or nil end
        return location(pawns[math.random(#pawns)])
    end

    -- Generic deferred spawn of any actor class at a point.
    local function spawnClass(c, class, spot)
        local transform = {Rotation = {X = 0, Y = 0, Z = 0, W = 1}, Translation = spot, Scale3D = {X = 1, Y = 1, Z = 1}}
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local ok, actor = pcall(function()
            local a = gs:BeginDeferredActorSpawnFromClass(c.world, class, transform, 1, nil, 0)
            return gs:FinishSpawningActor(a, transform, 0)
        end)
        if not ok or not api.valid(actor) then return nil, tostring(actor):match("^[^\n]*") end
        return actor
    end
    -- An invisible marker actor that explosion functions can use as their "Target".
    local function marker(c, spot)
        local class = StaticFindObject("/Script/Engine.TargetPoint")
        if not api.valid(class) then return nil, "TargetPoint class missing" end
        local m, err = spawnClass(c, class, spot)
        if m then pcall(function() m:SetLifeSpan(15) end) end
        return m, err
    end
    local function explosionTrigger()
        for _, t in ipairs(FindAllOf("BP_ExplosionTrigger_C") or {}) do
            if api.valid(t) then return t end
        end
    end
    local grenadeGE = "/Game/BodycamCore/AbilitySystem/GameplayEffects/Grenades/GE_Grenade_Damage.GE_Grenade_Damage_C"
    local function asc(pawn)
        local a = api.try(function() return pawn:GetBodycamAbilitySystemComponent() end)
        if api.valid(a) then return a end
        return api.try(function() return pawn.AbilitySystemComponent end)
    end
    local function applyGE(pawn, path)
        local ge = shellClass(path)
        if not ge then return "effect not loaded: " .. path end
        local a = asc(pawn); if not api.valid(a) then return "no ability system component" end
        local ctx = a:MakeEffectContext()
        -- The handle that comes back is the only precise way to take this exact effect off
        -- again later; keep it. Older calls that ignored it still work, it is a second return.
        local handle = a:BP_ApplyGameplayEffectToSelf(ge, 1.0, ctx)
        return "applied " .. path:match("[^/]+$"), handle
    end
    local killGEPath = "/Game/BodycamCore/AbilitySystem/GameplayEffects/GE_InstantKill.GE_InstantKill_C"
    -- One artillery impact, built from the game's own effects (all three found by testing in-game):
    --   the blast itself - the RC-car/drone cue (sparks, shake, sound). Always played: it is the
    --     explosion, and on its own it is what artilleryFlash=0 gives you.
    --   the light - the trench zone's own explosion, in two strengths: "Multicast - PlayExplosionFX"
    --     (artilleryFlash=1) and the blinding "TriggerExplosionForTarget" (artilleryFlash=2).
    --     Laid over the blast, never instead of it.
    --   the damage - GE_InstantKill inside the kill radius, the game's explosion-nearby state
    --     out to three times that. Independent of the light: it works on maps with no trench zone.
    local loggedImpact = false
    local function fireShell(c, spot, localPawn)
        local s = settings()
        local ground = {X = spot.X, Y = spot.Y, Z = spot.Z - 150}
        local m, err = marker(c, ground)
        if not m then api.log("Artillery marker FAILED: " .. tostring(err)); return end
        local notes = {}
        local light = math.floor(tonumber(s.artilleryFlash) or 0)
        if light > 0 then
            local trigger = explosionTrigger()
            if trigger then
                local fn = light >= 2 and "TriggerExplosionForTarget" or "Multicast - PlayExplosionFX"
                local ok, e2 = pcall(function() trigger[fn](trigger, m) end)
                if not ok then notes[#notes + 1] = "flash FAILED " .. tostring(e2):match("^[^\n]*") end
            else
                notes[#notes + 1] = "no trench trigger on this map, so no flash here (the blast and the damage still work)"
            end
        end
        local cdo = StaticFindObject("/Game/BodycamCore/AbilitySystem/GameplayCues/Perk/RcCar/GCN_Explosion.Default__GCN_Explosion_C")
        if api.valid(cdo) then
            local ok, e3 = pcall(function() cdo:OnBurst(m, {}, {}) end)
            if not ok then notes[#notes + 1] = "burst FAILED " .. tostring(e3):match("^[^\n]*") end
        else
            notes[#notes + 1] = "blast cue not loaded"
        end
        -- Damage (verified in-game with the End-key probe): GE_InstantKill kills; everyone within
        -- three times the kill radius also gets the game's own "explosion nearby" state.
        local killed = 0
        local radius = (tonumber(s.artilleryKillRadius) or 0) * 100
        if radius > 0 then
            for _, ch in ipairs(FindAllOf("Character") or {}) do
                if api.valid(ch) and api.valid(api.try(function() return ch.Controller end))
                    and (s.artilleryHitsMe == 1 or not sameActor(ch, localPawn)) then
                    local l = location(ch)
                    local d2 = l and ((l.X - ground.X) ^ 2 + (l.Y - ground.Y) ^ 2 + (l.Z - ground.Z) ^ 2)
                    if d2 and d2 <= radius * radius then
                        if pcall(applyGE, ch, killGEPath) then killed = killed + 1 end
                    end
                end
            end
        end
        if not loggedImpact or #notes > 0 or killed > 0 then
            loggedImpact = true
            api.log("Artillery impact: killed " .. killed .. " within " .. (radius / 100) 
                .. (#notes > 0 and ("; " .. table.concat(notes, "; ")) or ""))
        end
    end
    -- Home key: one full shell (whistle + blast) 8 m in front of you, outside the default kill radius.
    local function testShell(c, localPawn)
        local l = api.valid(localPawn) and location(localPawn)
        if not l then return "no player pawn" end
        local ctrl = api.try(function() return localPawn.Controller end)
        local rot = api.valid(ctrl) and api.try(function() return ctrl:GetControlRotation() end)
        local yaw = math.rad(rot and api.try(function() return rot.Yaw end) or 0)
        return {X = l.X + math.cos(yaw) * 800, Y = l.Y + math.sin(yaw) * 800, Z = l.Z + 150}
    end
    ------------------------------------------------------------ damage probe (End key)
    -- The trench zone's TriggerExplosionForTarget did not hurt you, so try the ways damage
    -- normally flows in Bodycam (Gameplay Ability System) on yourself, one per press.
    local killGE
    local function findKillGE()
        if killGE ~= nil then return killGE end
        killGE = false
        local names = {}
        ForEachUObject(function(o)
            if #names >= 40 or not api.valid(o) then return end
            if api.try(function() return o:IsClass() end) ~= true then return end
            local n = api.short(o)
            local l = n:lower()
            if l:sub(1, 3) == "ge_" and (l:find("kill", 1, true) or l:find("death", 1, true) or l:find("dead", 1, true)
                or l:find("damage", 1, true) or l:find("lethal", 1, true) or l:find("explos", 1, true)) then
                names[#names + 1] = api.name(o)
                if not killGE and (l:find("kill", 1, true) or l:find("death", 1, true) or l:find("lethal", 1, true)) then
                    killGE = api.name(o):match("^%S+%s+(.+)$")
                end
            end
        end)
        api.log("Loaded damage-like effects: " .. (#names > 0 and table.concat(names, " | ") or "none"))
        return killGE
    end
    local damageMethods = {
        {"grenade damage effect", function(pawn) return applyGE(pawn, grenadeGE) end},
        {"engine ApplyDamage 1000", function(pawn)
            local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            return "returned " .. tostring(gs:ApplyDamage(pawn, 1000.0, nil, nil, nil))
        end},
        {"kill / death effect", function(pawn)
            local path = findKillGE()
            if not path then return "no kill/death effect loaded (see log for the damage list)" end
            return applyGE(pawn, path)
        end},
        {"BPI_Death", function(pawn)
            local fn = StaticFindObject("/Game/AdvancedLocomotionV4/Blueprints/CharacterLogic/ALS_Base_CharacterBP.ALS_Base_CharacterBP_C:BPI_Death")
            local params = {}
            if api.valid(fn) then pcall(function() fn:ForEachProperty(function(p) params[#params + 1] = api.name(p) end) end) end
            api.log("BPI_Death params: " .. (#params > 0 and table.concat(params, " | ") or "none"))
            if #params > 0 then return "needs parameters, not called" end
            pawn:BPI_Death(); return "called"
        end},
    }
    local damageIndex = 0
    local function damageTest(localPawn)
        if not api.valid(localPawn) then return "no player pawn" end
        damageIndex = damageIndex % #damageMethods + 1
        local label, fn = damageMethods[damageIndex][1], damageMethods[damageIndex][2]
        local ok, result = pcall(fn, localPawn)
        local text = ok and tostring(result) or ("FAILED " .. tostring(result):match("^[^\n]*"))
        api.log(string.format("Damage test #%d (%s): %s", damageIndex, label, text))
        return "#" .. damageIndex .. " " .. label .. ": " .. text
    end
    ------------------------------------------------------ bot skill probe (Home)
    -- Three classes carry a GetBotsAccuracy; only one of them is the one the game actually calls
    -- when a bot shoots. An earlier probe hooked a single guess, reported itself ACTIVE and then
    -- never produced a sample, which told us nothing. Hook all three and label every parameter
    -- with its real name, read off the UFunction itself.
    local accuracyPaths = {
        "/Game/AdvancedLocomotionV4/Blueprints/CharacterLogic/AI/ALS_AI_Controller.ALS_AI_Controller_C:GetBotsAccuracy",
        "/Game/GM/GT_Bodycam.GT_Bodycam_C:GetBotsAccuracy",
        "/Game/MenuSystemPro/Blueprints/Core/BodycamGI.BodycamGI_C:GetBotsAccuracy",
    }
    -- Where the difficulty actually lives. Hooking GetBotsAccuracy told us nothing because it is
    -- never called; its BotSkillThreshold parameter has to be fed from a property somewhere, and
    -- the controller and the bot's own pawn are where to look. Dumped once, with values, so the
    -- knob can be found by name instead of guessed at.
    local botDumped = false
    local function dumpBot()
        if botDumped then return end
        botDumped = true
        local ctrl
        for _, o in ipairs(FindAllOf("ALS_AI_Controller_C") or {}) do
            if api.valid(o) then ctrl = o; break end
        end
        if not ctrl then api.log("Bot dump: no AI controller in the world"); return end
        -- Object properties are not followed blindly - a pawn reaches the whole world in two
        -- hops. Only the handful that could hold a bot's settings are opened up.
        local expand = {BrainComponent = true, PerceptionComponent = true, Blackboard = true,
                        PlayerState = true, CharacterMovement = true, ActionsComp = true,
                        PathFollowingComponent = true, ["GT Bodycam"] = true,
                        AIPerception = true, AIPerceptionStimuliSource = true}
        local function fields(o, cap, indent, depth)
            local n, seen = 0, {}
            local function each(holder)
                if not api.valid(holder) then return end
                pcall(function()
                    holder:ForEachProperty(function(p)
                        if n >= cap then return end
                        local pn = api.short(p)
                        if seen[pn] then return end
                        seen[pn] = true
                        n = n + 1
                        local v = api.try(function() return o[pn] end)
                        local t = type(v)
                        local kind = tostring(api.name(p)):match("^(%S+)") or "?"
                        if t == "number" or t == "boolean" or t == "string" then
                            api.log(indent .. pn .. " = " .. tostring(v))
                        elseif depth > 0 and api.valid(v)
                            and (kind:find("Struct", 1, true) or expand[pn]) then
                            api.log(indent .. pn .. " <" .. kind .. "> " .. api.name(v))
                            fields(v, 60, indent .. "    ", depth - 1)
                        else
                            api.log(indent .. pn .. " = <" .. kind .. ">")
                        end
                    end)
                end)
            end
            each(o)                                   -- structs answer for themselves
            local cls = api.try(function() return o:GetClass() end)
            for _ = 1, 10 do
                if not api.valid(cls) or n >= cap then break end
                each(cls)
                cls = api.try(function() return cls:GetSuperStruct() end)
            end
            return n
        end
        -- Function names on one line each: a setter like SetBotDifficulty would never show up in
        -- a property list, and names are cheap enough to print them all.
        local function funcs(label, o)
            if not api.valid(o) then return end
            local names, cls = {}, api.try(function() return o:GetClass() end)
            for _ = 1, 10 do
                if not api.valid(cls) then break end
                pcall(function()
                    cls:ForEachFunction(function(f)
                        if #names < 300 then names[#names + 1] = api.short(f) end
                    end)
                end)
                cls = api.try(function() return cls:GetSuperStruct() end)
            end
            api.log("Bot dump [" .. label .. " functions: " .. #names .. "] " .. table.concat(names, ", "))
        end
        -- The bot's own pawn, not its controller, is what carries the accuracy machinery - which
        -- is why hooks on the controller never fired. These are the names worth a full signature,
        -- and the write-path ones get a live hook so we see the numbers the game feeds them.
        local hookSeen = {}
        local WANT = {UpdateBotAccuracy = "hook", BotsAim = "hook", ["Bots Method?"] = "hook",
                      GetBotsAccuracy = "hook", RefreshPerception = false, HandleSightSense = false,
                      RunBehaviorTree = false}
        local function signatures(label, o)
            if not api.valid(o) then return end
            local cls = api.try(function() return o:GetClass() end)
            for _ = 1, 10 do
                if not api.valid(cls) then break end
                pcall(function()
                    cls:ForEachFunction(function(f)
                        local fn = api.short(f)
                        if WANT[fn] == nil then return end
                        local full = api.name(f)
                        local ps = {}
                        pcall(function()
                            f:ForEachProperty(function(p)
                                ps[#ps + 1] = api.short(p) .. ":" .. (tostring(api.name(p)):match("^(%S+)") or "?")
                            end)
                        end)
                        api.log("Bot fn [" .. label .. "] " .. full
                            .. "  params: " .. (#ps > 0 and table.concat(ps, ", ") or "none"))
                        if WANT[fn] ~= "hook" then return end
                        local path = full:match("^%S+%s+(.+)$")
                        if not path or hookSeen[fn] then return end
                        hookSeen[fn] = 0
                        local ok, err = pcall(function()
                            RegisterHook(path, function() end, function(...)
                                if (hookSeen[fn] or 0) >= 6 then return end
                                hookSeen[fn] = (hookSeen[fn] or 0) + 1
                                local n, parts = select("#", ...), {}
                                for i = 2, n do
                                    local arg = select(i, ...)
                                    parts[#parts + 1] = (ps[i - 1] and ps[i - 1]:match("^[^:]+") or ("#" .. (i - 1)))
                                        .. "=" .. tostring(api.try(function() return arg:get() end))
                                end
                                api.log("Bot fn call [" .. fn .. "] " .. hookSeen[fn] .. "/6: "
                                    .. (#parts > 0 and table.concat(parts, "  ") or "no readable parameters"))
                            end)
                        end)
                        api.log("Bot fn hook [" .. fn .. "]: " .. (ok and "armed" or ("FAILED " .. tostring(err):match("^[^\n]*"))))
                    end)
                end)
                cls = api.try(function() return cls:GetSuperStruct() end)
            end
        end
        local function dump(label, o, cap)
            if not api.valid(o) then api.log("Bot dump [" .. label .. "]: NOT FOUND"); return end
            api.log("Bot dump [" .. label .. "]: " .. api.name(o))
            api.log("Bot dump [" .. label .. "]: " .. fields(o, cap, "   ", 1) .. " properties")
            funcs(label, o)
            signatures(label, o)
        end
        dump("AI controller", ctrl, 300)
        dump("bot pawn", api.try(function() return ctrl.Pawn end), 300)
        dump("bot player state", api.try(function() return ctrl.PlayerState end), 200)
    end

    -- A bot that stands still is usually a bot whose behaviour tree is not running. Sample a few
    -- AI controllers and say, for each, whether it has a body, a brain, perception, and whether
    -- it is actually moving. A row of brain=NONE names the problem outright.
    local function botState()
        local n, stuck = 0, 0
        for _, ctrl in ipairs(FindAllOf("ALS_AI_Controller_C") or {}) do
            if n >= 8 then break end
            if api.valid(ctrl) then
                n = n + 1
                local pawn = api.try(function() return ctrl.Pawn end)
                local brain = api.try(function() return ctrl.BrainComponent end)
                -- Read the component, do not call GetAIPerceptionComponent(): the call came back
                -- empty for every bot and had me believe they were blind, while the property
                -- dump showed PerceptionComponent sitting right there.
                local percep = api.try(function() return ctrl.PerceptionComponent end)
                local ai = api.try(function() return ctrl.bStartAILogicOnPossess end)
                -- The component existing proves nothing: a stopped behaviour tree keeps its
                -- BrainComponent. IsRunning is what separates a thinking bot from a statue.
                local running = api.valid(brain) and api.try(function() return brain:IsRunning() end)
                local v = api.valid(pawn) and api.try(function() return pawn:GetVelocity() end)
                local speed = v and api.try(function() return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end) or -1
                if speed >= 0 and speed < 1 then stuck = stuck + 1 end
                api.log(string.format("Bot %d: pawn=%s  brain=%s  running=%s  perception=%s  AI-on-possess=%s  speed=%.0f cm/s",
                    n, api.valid(pawn) and "yes" or "NO",
                    api.valid(brain) and api.short(brain) or "NONE", tostring(running),
                    api.valid(percep) and "yes" or "NO", tostring(ai), speed))
            end
        end
        if n == 0 then api.log("Bot state: no ALS_AI_Controller_C in the world") end
        return n .. " bots sampled, " .. stuck .. " standing still"
    end

    local probeArmed, seen = false, {}
    local function botProbe()
        -- The state sample runs on every press: it is a snapshot, and the interesting moment is
        -- whenever you happen to be looking at a bot that will not move.
        local state = botState()
        dumpBot()
        if probeArmed then return state .. "; hooks already armed" end
        probeArmed = true
        local notes = {}
        for _, path in ipairs(accuracyPaths) do
            local tag = path:match("([%w_]+)_C:") or path
            local fn = StaticFindObject(path)
            if not api.valid(fn) then
                notes[#notes + 1] = tag .. ": not loaded"
            else
                local names = {}
                pcall(function() fn:ForEachProperty(function(p) names[#names + 1] = api.short(p) end) end)
                seen[tag] = 0
                local ok, err = pcall(function()
                    RegisterHook(path, function() end, function(...)
                        if (seen[tag] or 0) >= 6 then return end
                        seen[tag] = (seen[tag] or 0) + 1
                        local n, parts = select("#", ...), {}
                        for i = 2, n do                       -- #1 is the calling object
                            local arg = select(i, ...)
                            local v = api.try(function() return arg:get() end)
                            parts[#parts + 1] = (names[i - 1] or ("#" .. (i - 1))) .. "=" .. tostring(v)
                        end
                        api.log("Bot accuracy [" .. tag .. "] " .. seen[tag] .. "/6: "
                            .. (#parts > 0 and table.concat(parts, "  ") or "no readable parameters"))
                    end)
                end)
                notes[#notes + 1] = tag .. ": " .. (ok and ("hooked, params " ..
                    (#names > 0 and table.concat(names, "/") or "none")) or ("FAILED " .. tostring(err):match("^[^\n]*")))
            end
        end
        api.log("Bot skill probe -- " .. table.concat(notes, " | "))
        return state .. "; hooks armed"
    end

    ------------------------------------------------------------ sound events
    -- The menu window tails this file and plays the clips with distance volume and
    -- stereo pan: seq|kind|delay|x|y|z|listenerX|listenerY|listenerZ|listenerYaw
    local eventsPath = root .. "/sound_events.txt"
    do local f = io.open(eventsPath, "wb"); if f then f:close() end end
    local seq = 0
    local function listener(localPawn)
        local l = api.valid(localPawn) and location(localPawn)
        if not l then return nil end
        local ctrl = api.try(function() return localPawn.Controller end)
        local rot = api.valid(ctrl) and api.try(function() return ctrl:GetControlRotation() end)
            or api.try(function() return localPawn:K2_GetActorRotation() end)
        l.Yaw = rot and api.try(function() return rot.Yaw end) or 0
        return l
    end
    local function emit(kind, delay, spot, localPawn)
        local s = settings()
        if s.sound ~= 1 then return end
        local l = listener(localPawn)
        if not l or not spot then return end
        seq = seq + 1
        local f = io.open(eventsPath, "ab")
        if not f then return end
        f:write(string.format("%d|%s|%.3f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.1f\n",
            seq, kind, delay, spot.X, spot.Y, spot.Z, l.X, l.Y, l.Z, l.Yaw))
        f:close()
    end

    ------------------------------------------------------------ salvo scheduler
    -- A salvo = N distant shots; each shell lands artilleryFlight seconds after its shot.
    -- The "incoming" sound event is written at shot time so the whistle can lead into the blast.
    local queue, battery, batteryWorld = {}, nil, nil
    local function now() return os.clock() end
    local function batterySpot(c, target)
        local w = api.name(c.world)
        if batteryWorld ~= w then batteryWorld, battery = w, math.random() * 2 * math.pi end
        local d = settings().artilleryBattery * 100
        return {X = target.X + math.cos(battery) * d, Y = target.Y + math.sin(battery) * d, Z = target.Z}
    end
    local function landingSpot(c, s, localPawn)
        local target = pickTarget(c, s, localPawn)
        if not target then return nil end
        if target.exact then return {X = target.X, Y = target.Y, Z = target.Z + 150} end
        local angle = math.random() * 2 * math.pi
        local dist = (s.artilleryMinDist + math.random() * math.max(0, s.artilleryMaxDist - s.artilleryMinDist)) * 100
        -- Spawned 1.5 m up so it drops onto the ground before going off.
        return {X = target.X + math.cos(angle) * dist, Y = target.Y + math.sin(angle) * dist, Z = target.Z + 150}
    end

    -- Called every 0.1 s on the game thread while hosting a Team Deathmatch match.
    local function artilleryTick(c, localPawn)
        local s = settings()
        local t = now()
        -- With shelling off no new salvos start, but shells already in the air still land.
        if s.artillery ~= 1 then nextSalvo = nil
        elseif not nextSalvo then nextSalvo = t + s.artilleryMinDelay end
        if s.artillery == 1 and #queue == 0 and t >= nextSalvo then
            -- The setting is an average, not a count: each salvo is that many shells give or
            -- take two, so no two barrages land the same. Never fewer than one.
            local shells = math.max(1, math.floor(s.artilleryShells) + math.random(-2, 2))
            for i = 1, shells do queue[#queue + 1] = {at = t + (i - 1) * s.artilleryShellGap, kind = "shot"} end
            local lo, hi = s.artilleryMinDelay, math.max(s.artilleryMinDelay, s.artilleryMaxDelay)
            nextSalvo = t + shells * s.artilleryShellGap + s.artilleryFlight + lo + math.random() * (hi - lo)
        end
        local i = 1
        while i <= #queue do
            local q = queue[i]
            if t >= q.at then
                table.remove(queue, i)
                if q.kind == "shot" then
                    local spot = landingSpot(c, s, localPawn)
                    if spot then
                        emit("incoming", s.artilleryFlight, spot, localPawn)
                        queue[#queue + 1] = {at = t + s.artilleryFlight, kind = "impact", spot = spot}
                    end
                else
                    fireShell(c, q.spot, localPawn)
                end
            else
                i = i + 1
            end
        end
    end
    -- Where you stand and look, for the app's 3D whistle panning (x|y|z|yaw, Unreal cm / degrees).
    local posePath = root .. "/pose.txt"
    local lastPose
    local function writePose(localPawn)
        local l = listener(localPawn)
        if not l then return end
        -- Called 10x a second: only touch the file when you actually moved or turned.
        local text = string.format("%.0f|%.0f|%.0f|%.1f", l.X, l.Y, l.Z, l.Yaw)
        if text == lastPose then return end
        lastPose = text
        local f = io.open(posePath, "wb")
        if f then f:write(text); f:close() end
    end
    local function testNow(c, localPawn)
        local spot = testShell(c, localPawn)
        if type(spot) ~= "table" then return spot end
        emit("incoming", settings().artilleryFlight, spot, localPawn)
        queue[#queue + 1] = {at = now() + settings().artilleryFlight, kind = "impact", spot = spot}
        return "incoming in " .. settings().artilleryFlight .. " s"
    end
    return {settings = settings, save = save, nextPreset = nextPreset, testShell = testNow, damageTest = damageTest, writePose = writePose,
        artilleryTick = artilleryTick, botProbe = botProbe}
end
