-- r2scripts -- (c) 2026 spekT -- licensed under rESL v1.0
--
-- BCS.luau -- BestCaseScenario
--
-- A universal exploit-side toolkit for Roblox games protected by client-side
-- anti-cheats of the "swish-hub/rivals-ac" family, bundled with a complete
-- cosmetic unlocker for Rivals. Designed to be cross-executor (Synapse X,
-- Krnl, Script-Ware, Fluxus, Wave, Electron) by abstracting the host API
-- behind a small shim layer.
--
-- Public API (mounted on _G.BCS after load):
--   BCS.start()                                  -- (auto-runs unless CONFIG.AUTOSTART = false)
--   BCS.stop()                                   -- best-effort teardown of injected hooks
--   BCS.status()                                 -- prints diagnostics
--   BCS.equip(weapon, cosmeticType, name, opts)  -- equip a cosmetic
--   BCS.unequip(weapon, cosmeticType)            -- clear a cosmetic slot
--   BCS.favorite(weapon, name, value)            -- toggle favourite
--   BCS.equipAll(weapon, table)                  -- bulk-equip multiple slots
--   BCS.randomize(weapon)                        -- random Skin/Wrap/Charm/Finisher
--   BCS.listEquipped()                           -- snapshot of current loadouts
--   BCS.exportConfig()                           -- JSON string of saved state
--   BCS.importConfig(jsonString)                 -- replace state from JSON
--   BCS.config                                   -- live config table (mutate freely)
--
-- Loadstring usage:
--   loadstring(game:HttpGet("https://raw.githubusercontent.com/Spektronazam/r2scripts/main/BCS.luau"))()
--

if _G.BCS and _G.BCS._loaded then
  warn("[BCS] already loaded -- ignoring duplicate execution")
  return _G.BCS
end

--------------------------------------------------------------------------------
-- 0. CONFIG
--------------------------------------------------------------------------------

local CONFIG = {
  AUTOSTART         = true,
  VERBOSE           = true,
  PERSIST_PATH      = "BCS/config.json",
  AC_BYPASS         = true,
  UNLOCK_ALL        = true,
  WATCH_NEW_SCRIPTS = true,    -- re-neuter scripts added to ReplicatedFirst at runtime
  BLOCK_AC_GUI      = true,    -- destroy AC alert GUIs on creation
  KILL_TELEMETRY    = true,    -- nuke AnalyticsService / LogService listeners
  KICK_PATTERNS     = {
    "kick", "ban", "shutdown", "takethel",
    "anticheat", "detected", "cheating", "exploit", "suspicious",
  },
  AC_SCRIPT_HINTS   = {
    "loadingscreen", "localscript3", "anticheat", "watchdog", "guard",
  },
}

--------------------------------------------------------------------------------
-- 1. SERVICES
--------------------------------------------------------------------------------

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst   = game:GetService("ReplicatedFirst")
local HttpService       = game:GetService("HttpService")
local CoreGui           = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- 2. LOGGER
--------------------------------------------------------------------------------

local Logger = {}
do
  local function fmt(level, ...)
    return string.format("[BCS][%s]", level), ...
  end
  function Logger.info(...)  if CONFIG.VERBOSE then print(fmt("INFO", ...)) end end
  function Logger.warn(...)  warn(fmt("WARN", ...)) end
  function Logger.error(...) warn(fmt("ERR ", ...)) end
  function Logger.debug(...) if CONFIG.VERBOSE then print(fmt("DBG ", ...)) end end
end

--------------------------------------------------------------------------------
-- 3. UTIL
--------------------------------------------------------------------------------

local Util = {}
do
  function Util.safeCall(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then Logger.warn("safeCall failed:", tostring(result)) end
    return ok, result
  end

  function Util.shallowClone(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
  end

  function Util.matchesAny(haystack, patterns)
    if type(haystack) ~= "string" then return false end
    local lower = haystack:lower()
    for _, pat in ipairs(patterns) do
      if lower:find(pat, 1, true) then return true end
    end
    return false
  end

  -- Polls for value, returns it once non-nil or after timeout (defaults: 10s @ 0.1s).
  function Util.waitFor(fn, timeout, interval)
    timeout  = timeout  or 10
    interval = interval or 0.1
    local elapsed = 0
    while elapsed < timeout do
      local ok, value = pcall(fn)
      if ok and value then return value end
      task.wait(interval)
      elapsed = elapsed + interval
    end
    return nil
  end

  function Util.requireSafe(instance)
    if not instance then return nil end
    local ok, mod = pcall(require, instance)
    if not ok then
      Logger.warn("require failed for", tostring(instance), "->", tostring(mod))
      return nil
    end
    return mod
  end
end

--------------------------------------------------------------------------------
-- 4. EXECUTOR SHIM
--   Normalises the wildly inconsistent API surface of common Roblox executors.
--------------------------------------------------------------------------------

local Exec = {}
do
  Exec.name = identifyexecutor and (identifyexecutor()) or
              (syn and "Synapse X") or
              (KRNL_LOADED and "Krnl") or
              (fluxus and "Fluxus") or
              (getexecutorname and getexecutorname()) or
              "Unknown"

  -- HTTP
  Exec.httpRequest = (syn and syn.request) or
                     (http and http.request) or
                     (fluxus and fluxus.request) or
                     http_request or
                     request

  -- Filesystem
  Exec.writeFile  = writefile
  Exec.readFile   = readfile
  Exec.isFile     = isfile
  Exec.isFolder   = isfolder
  Exec.makeFolder = makefolder
  Exec.delFile    = delfile

  -- Hooking primitives
  Exec.hookFunction     = hookfunction or replaceclosure or detour
  Exec.hookMetamethod   = hookmetamethod
  Exec.getRawMetatable  = getrawmetatable or debug.getmetatable
  Exec.setReadOnly      = setreadonly or make_writeable or function() end
  Exec.newCClosure      = newcclosure or function(f) return f end
  Exec.getNamecallMethod = getnamecallmethod or function() return "" end
  Exec.getGc            = getgc or get_gc_objects
  Exec.getConstants     = debug.getconstants or getconstants
  Exec.getInfo          = debug.getinfo or getinfo

  -- Drawing / GUI helpers (not used directly, but exposed for downstream scripts)
  Exec.gethui = gethui or function() return CoreGui end

  function Exec.has(name)
    return type(Exec[name]) == "function"
  end

  function Exec.report()
    Logger.info("executor =", Exec.name)
    local feats = { "hookFunction", "hookMetamethod", "getRawMetatable", "getGc",
                    "writeFile", "readFile", "httpRequest" }
    for _, f in ipairs(feats) do
      Logger.info(string.format("  %-16s = %s", f, Exec.has(f) and "yes" or "MISSING"))
    end
  end
end

--------------------------------------------------------------------------------
-- 5. HOOK REGISTRY
--   Tracks every hook we install so BCS.stop() can roll most of them back.
--------------------------------------------------------------------------------

local Hooks = { entries = {} }
do
  function Hooks.track(label, restoreFn)
    table.insert(Hooks.entries, { label = label, restore = restoreFn })
  end

  function Hooks.restoreAll()
    for i = #Hooks.entries, 1, -1 do
      local entry = Hooks.entries[i]
      Util.safeCall(entry.restore)
      Hooks.entries[i] = nil
    end
  end

  -- Wrap hookmetamethod in a way that preserves the original closure.
  function Hooks.hookNamecall(target, label, handler)
    if not Exec.hookMetamethod then
      Logger.warn("hookmetamethod unavailable, skipping", label)
      return nil
    end
    local original
    original = Exec.hookMetamethod(target, "__namecall", function(self, ...)
      return handler(original, self, ...)
    end)
    Hooks.track(label, function()
      -- Best-effort: re-hook to call the captured original. There is no clean
      -- "unhook" primitive on most executors; this is the standard idiom.
      Exec.hookMetamethod(target, "__namecall", original)
    end)
    return original
  end

  -- Hook a Lua function in-place; works on most executors that expose hookfunction.
  function Hooks.hookFn(label, target, replacement)
    if not Exec.hookFunction then
      Logger.warn("hookfunction unavailable, skipping", label)
      return target
    end
    local original = Exec.hookFunction(target, replacement)
    Hooks.track(label, function() Exec.hookFunction(replacement, original) end)
    return original
  end
end

--------------------------------------------------------------------------------
-- 6. ANTI-CHEAT BYPASS
--------------------------------------------------------------------------------

local AntiCheat = {}
do
  local fakeAlert -- spoofed RemoteEvent, kept alive for the session

  function AntiCheat.spoofClientAlert()
    -- The Rivals AC client expects LocalPlayer:WaitForChild("ClientAlert"); we
    -- give it a do-nothing RemoteEvent so it never times out and never fires.
    fakeAlert = Instance.new("RemoteEvent")
    fakeAlert.Name = "ClientAlert"
    fakeAlert.Parent = LocalPlayer

    if not Exec.getRawMetatable then
      Logger.warn("getrawmetatable unavailable, ClientAlert spoof partial")
      return
    end

    local pmt = Exec.getRawMetatable(LocalPlayer)
    local oldNc = pmt.__namecall
    Exec.setReadOnly(pmt, false)
    pmt.__namecall = Exec.newCClosure(function(self, ...)
      if Exec.getNamecallMethod() == "WaitForChild" and select(1, ...) == "ClientAlert" then
        return fakeAlert
      end
      return oldNc(self, ...)
    end)
    Exec.setReadOnly(pmt, true)

    Hooks.track("clientAlertSpoof", function()
      Exec.setReadOnly(pmt, false)
      pmt.__namecall = oldNc
      Exec.setReadOnly(pmt, true)
      if fakeAlert then fakeAlert:Destroy() end
    end)
  end

  function AntiCheat.blockKickAndShutdown()
    -- Catches both the obvious :Kick path and the AC's preferred ClientAlert:FireServer.
    Hooks.hookNamecall(game, "kickBlocker", function(original, self, ...)
      local m = Exec.getNamecallMethod()
      if not m or m == "" then return original(self, ...) end

      -- Direct kick on our LocalPlayer.
      if self == LocalPlayer and (m == "Kick" or m == "kick") then
        Logger.info("blocked :Kick on LocalPlayer")
        return
      end

      -- Anything that smells like a kick/ban/shutdown call.
      if Util.matchesAny(m, CONFIG.KICK_PATTERNS) then
        Logger.info("blocked namecall:", m)
        return
      end

      -- AC pinging itself through the spoofed remote.
      if m == "FireServer" and self == fakeAlert then return end

      return original(self, ...)
    end)
  end

  -- Generic constant-scanner: nukes any GC function whose script context matches
  -- AC_SCRIPT_HINTS *or* whose constants match KICK_PATTERNS. This is the same
  -- trick the original used for LocalScript3, generalised.
  function AntiCheat.neuterGcFunctions()
    if not Exec.getGc then
      Logger.warn("getgc unavailable, skipping gc neuter")
      return 0
    end

    local count = 0
    for _, f in ipairs(Exec.getGc(false)) do
      if type(f) == "function" then
        local okEnv, env = pcall(getfenv, f)
        if okEnv and type(env) == "table" then
          local scr = rawget(env, "script")
          local scrName = scr and tostring(scr) or ""
          local hintMatch = Util.matchesAny(scrName, CONFIG.AC_SCRIPT_HINTS)

          if hintMatch and Exec.getConstants then
            local okC, consts = pcall(Exec.getConstants, f)
            if okC and consts then
              for _, k in ipairs(consts) do
                if type(k) == "string" and Util.matchesAny(k, CONFIG.KICK_PATTERNS) then
                  if Exec.hookFunction then
                    pcall(Exec.hookFunction, f, function() end)
                    count = count + 1
                  end
                  break
                end
              end
            end
          end
        end
      end
    end
    Logger.info("neutered", count, "AC-suspect closures")
    return count
  end

  -- Block in-game GUI alerts that the AC pops up *before* it fires :Kick.
  function AntiCheat.blockAlertGui()
    if not CONFIG.BLOCK_AC_GUI then return end
    local function inspect(gui)
      if not gui:IsA("ScreenGui") then return end
      local n = gui.Name:lower()
      if Util.matchesAny(n, CONFIG.KICK_PATTERNS) or n:find("alert") or n:find("ban") then
        Logger.info("destroyed AC gui:", gui.Name)
        pcall(function() gui:Destroy() end)
      end
    end
    local conn = CoreGui.ChildAdded:Connect(inspect)
    Hooks.track("alertGuiWatcher", function() conn:Disconnect() end)
    for _, c in ipairs(CoreGui:GetChildren()) do inspect(c) end
  end

  -- Re-run gc neuter when scripts arrive late (some ACs delay-load on join).
  function AntiCheat.watchReplicatedFirst()
    if not CONFIG.WATCH_NEW_SCRIPTS then return end
    local conn = ReplicatedFirst.ChildAdded:Connect(function(child)
      if child:IsA("LocalScript") or child:IsA("ModuleScript") then
        task.wait(0.5)  -- let the script load its closures into gc
        AntiCheat.neuterGcFunctions()
      end
    end)
    Hooks.track("replicatedFirstWatcher", function() conn:Disconnect() end)
  end

  -- Disable telemetry pipelines some ACs ride on.
  function AntiCheat.killTelemetry()
    if not CONFIG.KILL_TELEMETRY then return end
    Util.safeCall(function()
      local Analytics = game:GetService("AnalyticsService")
      if Analytics and Exec.hookMetamethod then
        Hooks.hookNamecall(Analytics, "analyticsKill", function(original, self, ...)
          local m = Exec.getNamecallMethod()
          if m and m:find("Fire") then return end
          return original(self, ...)
        end)
      end
    end)
  end

  function AntiCheat.start()
    Logger.info("starting AC bypass")
    AntiCheat.spoofClientAlert()
    AntiCheat.blockKickAndShutdown()
    AntiCheat.blockAlertGui()
    AntiCheat.killTelemetry()

    -- Wait briefly for LocalScript3 (or whatever the AC is named today) to land.
    local ls3 = ReplicatedFirst:FindFirstChild("LocalScript3") or
                Util.waitFor(function() return ReplicatedFirst:FindFirstChild("LocalScript3") end, 5)
    if ls3 then Logger.info("located AC source:", ls3:GetFullName()) end

    AntiCheat.neuterGcFunctions()
    AntiCheat.watchReplicatedFirst()
    Logger.info("AC bypass active")
  end
end

--------------------------------------------------------------------------------
-- 7. UNLOCK-ALL  (Rivals-specific; degrades gracefully if modules not present)
--------------------------------------------------------------------------------

local Unlock = {}
do
  local state = {
    equipped         = {},
    favorites        = {},
    constructingWpn  = nil,
    viewingProfile   = nil,
    lastUsedWeapon   = nil,
    started          = false,
  }
  Unlock.state = state

  -- Module handles, populated lazily.
  local Modules = {
    EnumLibrary       = nil,
    CosmeticLibrary   = nil,
    ItemLibrary       = nil,
    DataController    = nil,
    FighterController = nil,
    ClientItem        = nil,
    ClientViewModel   = nil,
    ClientEntity      = nil,
    ViewProfile       = nil,
    ReplicatedClass   = nil,
  }

  local function resolveModules()
    local repModules = ReplicatedStorage:WaitForChild("Modules", 10)
    if not repModules then
      Logger.warn("ReplicatedStorage.Modules not found -- unlock disabled")
      return false
    end

    Modules.EnumLibrary     = Util.requireSafe(repModules:WaitForChild("EnumLibrary", 10))
    Modules.CosmeticLibrary = Util.requireSafe(repModules:WaitForChild("CosmeticLibrary", 10))
    Modules.ItemLibrary     = Util.requireSafe(repModules:WaitForChild("ItemLibrary", 10))
    Modules.ReplicatedClass = Util.requireSafe(repModules:FindFirstChild("ReplicatedClass"))

    if Modules.EnumLibrary and Modules.EnumLibrary.WaitForEnumBuilder then
      pcall(function() Modules.EnumLibrary:WaitForEnumBuilder() end)
    end

    local playerScripts = LocalPlayer:WaitForChild("PlayerScripts", 10)
    if not playerScripts then return false end
    local controllers = playerScripts:WaitForChild("Controllers", 10)
    if not controllers then return false end

    Modules.DataController    = Util.requireSafe(controllers:WaitForChild("PlayerDataController", 10))
    Modules.FighterController = Util.requireSafe(controllers:FindFirstChild("FighterController"))

    local clientCls = playerScripts:FindFirstChild("Modules")
      and playerScripts.Modules:FindFirstChild("ClientReplicatedClasses")
    if clientCls then
      local clientFighter = clientCls:FindFirstChild("ClientFighter")
      if clientFighter then
        Modules.ClientItem = Util.requireSafe(clientFighter:FindFirstChild("ClientItem"))
        if clientFighter:FindFirstChild("ClientItem") then
          local vm = clientFighter.ClientItem:FindFirstChild("ClientViewModel")
          Modules.ClientViewModel = Util.requireSafe(vm)
        end
      end
      Modules.ClientEntity = Util.requireSafe(clientCls:FindFirstChild("ClientEntity"))
    end

    local pages = playerScripts:FindFirstChild("Modules")
      and playerScripts.Modules:FindFirstChild("Pages")
    if pages then
      Modules.ViewProfile = Util.requireSafe(pages:FindFirstChild("ViewProfile"))
    end

    return Modules.CosmeticLibrary ~= nil and Modules.DataController ~= nil
  end

  local function cloneCosmetic(name, cosmeticType, options)
    local lib = Modules.CosmeticLibrary
    if not lib then return nil end
    local base = lib.Cosmetics and lib.Cosmetics[name]
    if not base then return nil end

    local data = Util.shallowClone(base)
    data.Name = name
    data.Type = data.Type or cosmeticType
    data.Seed = data.Seed or math.random(1, 1000000)

    if Modules.EnumLibrary then
      local ok, enumId = pcall(Modules.EnumLibrary.ToEnum, Modules.EnumLibrary, name)
      if ok and enumId then
        data.Enum     = enumId
        data.ObjectID = data.ObjectID or enumId
      end
    end

    if options then
      if options.inverted ~= nil then data.Inverted = options.inverted end
      if options.favoritesOnly ~= nil then data.OnlyUseFavorites = options.favoritesOnly end
    end
    return data
  end
  Unlock.cloneCosmetic = cloneCosmetic

  ----------------------------------------------------------------------------
  -- Persistence
  ----------------------------------------------------------------------------

  local function ensureFolder()
    if not Exec.makeFolder then return end
    local folder = CONFIG.PERSIST_PATH:match("^(.+)/") or "BCS"
    pcall(Exec.makeFolder, folder)
  end

  function Unlock.saveConfig()
    if not Exec.writeFile then return end
    Util.safeCall(function()
      local snapshot = { equipped = {}, favorites = state.favorites }
      for weapon, cosmetics in pairs(state.equipped) do
        snapshot.equipped[weapon] = {}
        for cosmeticType, cosmetic in pairs(cosmetics) do
          if cosmetic and cosmetic.Name then
            snapshot.equipped[weapon][cosmeticType] = {
              name     = cosmetic.Name,
              seed     = cosmetic.Seed,
              inverted = cosmetic.Inverted,
            }
          end
        end
      end
      ensureFolder()
      Exec.writeFile(CONFIG.PERSIST_PATH, HttpService:JSONEncode(snapshot))
    end)
  end

  function Unlock.loadConfig()
    if not (Exec.readFile and Exec.isFile and Exec.isFile(CONFIG.PERSIST_PATH)) then return end
    Util.safeCall(function()
      local cfg = HttpService:JSONDecode(Exec.readFile(CONFIG.PERSIST_PATH))
      if cfg.equipped then
        for weapon, cosmetics in pairs(cfg.equipped) do
          state.equipped[weapon] = {}
          for cosmeticType, info in pairs(cosmetics) do
            local cloned = cloneCosmetic(info.name, cosmeticType, { inverted = info.inverted })
            if cloned then
              cloned.Seed = info.seed
              state.equipped[weapon][cosmeticType] = cloned
            end
          end
        end
      end
      state.favorites = cfg.favorites or {}
    end)
  end

  function Unlock.exportConfig()
    return HttpService:JSONEncode({ equipped = state.equipped, favorites = state.favorites })
  end

  function Unlock.importConfig(json)
    local ok, data = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok then return false, data end
    state.equipped, state.favorites = {}, data.favorites or {}
    if data.equipped then
      for weapon, cosmetics in pairs(data.equipped) do
        state.equipped[weapon] = {}
        for cosmeticType, info in pairs(cosmetics) do
          local cloned = cloneCosmetic(info.name or info.Name, cosmeticType, info)
          if cloned then state.equipped[weapon][cosmeticType] = cloned end
        end
      end
    end
    Unlock.saveConfig()
    return true
  end

  ----------------------------------------------------------------------------
  -- Public mutators
  ----------------------------------------------------------------------------

  function Unlock.equip(weapon, cosmeticType, name, opts)
    state.equipped[weapon] = state.equipped[weapon] or {}
    if not name or name == "" or name == "None" then
      state.equipped[weapon][cosmeticType] = nil
      if not next(state.equipped[weapon]) then state.equipped[weapon] = nil end
    else
      local cloned = cloneCosmetic(name, cosmeticType, opts)
      if not cloned then return false, "unknown cosmetic" end
      state.equipped[weapon][cosmeticType] = cloned
    end
    Util.safeCall(function() Modules.DataController.CurrentData:Replicate("WeaponInventory") end)
    Unlock.saveConfig()
    return true
  end

  function Unlock.unequip(weapon, cosmeticType)
    return Unlock.equip(weapon, cosmeticType, nil)
  end

  function Unlock.favorite(weapon, name, value)
    state.favorites[weapon] = state.favorites[weapon] or {}
    state.favorites[weapon][name] = value or nil
    Unlock.saveConfig()
    Util.safeCall(function() Modules.DataController.CurrentData:Replicate("FavoritedCosmetics") end)
  end

  function Unlock.equipAll(weapon, slots)
    if type(slots) ~= "table" then return false end
    for cosmeticType, value in pairs(slots) do
      if type(value) == "string" then
        Unlock.equip(weapon, cosmeticType, value)
      elseif type(value) == "table" then
        Unlock.equip(weapon, cosmeticType, value.name or value.Name, value.opts or value)
      end
    end
    return true
  end

  function Unlock.randomize(weapon)
    local lib = Modules.CosmeticLibrary
    if not (lib and lib.Cosmetics) then return false end
    local buckets = { Skin = {}, Wrap = {}, Charm = {}, Finisher = {} }
    for name, data in pairs(lib.Cosmetics) do
      if data and data.Type and buckets[data.Type] then
        table.insert(buckets[data.Type], name)
      end
    end
    for cosmeticType, names in pairs(buckets) do
      if #names > 0 then
        Unlock.equip(weapon, cosmeticType, names[math.random(1, #names)])
      end
    end
    return true
  end

  function Unlock.listEquipped()
    local out = {}
    for weapon, cosmetics in pairs(state.equipped) do
      out[weapon] = {}
      for cosmeticType, c in pairs(cosmetics) do out[weapon][cosmeticType] = c.Name end
    end
    return out
  end

  ----------------------------------------------------------------------------
  -- Hooks (the actual unlock magic)
  ----------------------------------------------------------------------------

  local function patchOwnership()
    local lib = Modules.CosmeticLibrary
    if not lib then return end
    lib.OwnsCosmeticNormally    = function() return true end
    lib.OwnsCosmeticUniversally = function() return true end
    lib.OwnsCosmeticForWeapon   = function() return true end
    local origOwns = lib.OwnsCosmetic
    lib.OwnsCosmetic = function(self, inventory, name, weapon)
      if type(name) == "string" and name:find("MISSING_") then
        return origOwns(self, inventory, name, weapon)
      end
      return true
    end
  end

  local function patchDataController()
    local dc = Modules.DataController
    if not dc then return end

    local originalGet = dc.Get
    dc.Get = function(self, key)
      local data = originalGet(self, key)
      if key == "CosmeticInventory" then
        local proxy = {}
        if data then for k, v in pairs(data) do proxy[k] = v end end
        return setmetatable(proxy, { __index = function() return true end })
      end
      if key == "FavoritedCosmetics" then
        local result = data and table.clone(data) or {}
        for weapon, favs in pairs(state.favorites) do
          result[weapon] = result[weapon] or {}
          for name, isFav in pairs(favs) do result[weapon][name] = isFav end
        end
        return result
      end
      return data
    end

    local originalGetWeapon = dc.GetWeaponData
    dc.GetWeaponData = function(self, weaponName)
      local data = originalGetWeapon(self, weaponName)
      if not data then return nil end
      local merged = Util.shallowClone(data)
      merged.Name = weaponName
      if state.equipped[weaponName] then
        for cosmeticType, cosmetic in pairs(state.equipped[weaponName]) do
          merged[cosmeticType] = cosmetic
        end
      end
      return merged
    end
  end

  local function patchEquipRemotes()
    if not Exec.hookMetamethod then
      Logger.warn("hookmetamethod missing -- equip persistence disabled")
      return
    end
    local remotes        = ReplicatedStorage:FindFirstChild("Remotes")
    local dataRemotes    = remotes and remotes:FindFirstChild("Data")
    local equipRemote    = dataRemotes and dataRemotes:FindFirstChild("EquipCosmetic")
    local favoriteRemote = dataRemotes and dataRemotes:FindFirstChild("FavoriteCosmetic")
    local repRemotes     = remotes and remotes:FindFirstChild("Replication")
    local fighterRemotes = repRemotes and repRemotes:FindFirstChild("Fighter")
    local useItemRemote  = fighterRemotes and fighterRemotes:FindFirstChild("UseItem")

    if not equipRemote then
      Logger.warn("EquipCosmetic remote not found -- skipping equip hook")
      return
    end

    Hooks.hookNamecall(game, "equipRemoteRouter", function(original, self, ...)
      if Exec.getNamecallMethod() ~= "FireServer" then return original(self, ...) end
      local args = { ... }

      -- Track which weapon fired UseItem so we know which finisher to apply.
      if useItemRemote and self == useItemRemote and Modules.FighterController then
        local objectId = args[1]
        Util.safeCall(function()
          local fighter = Modules.FighterController:GetFighter(LocalPlayer)
          if fighter and fighter.Items then
            for _, item in pairs(fighter.Items) do
              if item:Get("ObjectID") == objectId then
                state.lastUsedWeapon = item.Name
                break
              end
            end
          end
        end)
      end

      if self == equipRemote then
        local weaponName, cosmeticType, cosmeticName, options = args[1], args[2], args[3], args[4] or {}
        if cosmeticName and cosmeticName ~= "None" and cosmeticName ~= "" then
          local inv = Modules.DataController:Get("CosmeticInventory")
          if inv and rawget(inv, cosmeticName) then
            return original(self, ...)
          end
        end
        Unlock.equip(weaponName, cosmeticType, cosmeticName, {
          inverted      = options.IsInverted,
          favoritesOnly = options.OnlyUseFavorites,
        })
        return
      end

      if self == favoriteRemote then
        Unlock.favorite(args[1], args[2], args[3])
        return
      end

      return original(self, ...)
    end)
  end

  local function patchClientItem()
    local CI = Modules.ClientItem
    if not (CI and CI._CreateViewModel) then return end
    local origCreate = CI._CreateViewModel
    CI._CreateViewModel = function(self, viewmodelRef)
      local weaponName = self.Name
      local weaponPlayer = self.ClientFighter and self.ClientFighter.Player
      state.constructingWpn = (weaponPlayer == LocalPlayer) and weaponName or nil

      if weaponPlayer == LocalPlayer
         and state.equipped[weaponName]
         and state.equipped[weaponName].Skin
         and viewmodelRef then
        local dataKey = self:ToEnum("Data")
        local skinKey = self:ToEnum("Skin")
        local nameKey = self:ToEnum("Name")
        if viewmodelRef[dataKey] then
          viewmodelRef[dataKey][skinKey] = state.equipped[weaponName].Skin
          viewmodelRef[dataKey][nameKey] = state.equipped[weaponName].Skin.Name
        elseif viewmodelRef.Data then
          viewmodelRef.Data.Skin = state.equipped[weaponName].Skin
          viewmodelRef.Data.Name = state.equipped[weaponName].Skin.Name
        end
      end
      local result = origCreate(self, viewmodelRef)
      state.constructingWpn = nil
      return result
    end
  end

  local function patchClientViewModel()
    local VM = Modules.ClientViewModel
    if not VM then return end

    if VM.GetWrap then
      local origGet = VM.GetWrap
      VM.GetWrap = function(self)
        local item     = self.ClientItem
        local wpnName  = item and item.Name
        local wpnOwner = item and item.ClientFighter and item.ClientFighter.Player
        if wpnName and wpnOwner == LocalPlayer
           and state.equipped[wpnName] and state.equipped[wpnName].Wrap then
          return state.equipped[wpnName].Wrap
        end
        return origGet(self)
      end
    end

    if VM.new and Modules.ReplicatedClass then
      local RC = Modules.ReplicatedClass
      local origNew = VM.new
      VM.new = function(replicatedData, clientItem)
        local wpnOwner = clientItem.ClientFighter and clientItem.ClientFighter.Player
        local wpnName  = state.constructingWpn or clientItem.Name
        if wpnOwner == LocalPlayer and state.equipped[wpnName] then
          local dataKey = RC:ToEnum("Data")
          replicatedData[dataKey] = replicatedData[dataKey] or {}
          local cosmetics = state.equipped[wpnName]
          if cosmetics.Skin  then replicatedData[dataKey][RC:ToEnum("Skin")]  = cosmetics.Skin  end
          if cosmetics.Wrap  then replicatedData[dataKey][RC:ToEnum("Wrap")]  = cosmetics.Wrap  end
          if cosmetics.Charm then replicatedData[dataKey][RC:ToEnum("Charm")] = cosmetics.Charm end
        end
        local result = origNew(replicatedData, clientItem)
        if wpnOwner == LocalPlayer
           and state.equipped[wpnName]
           and state.equipped[wpnName].Wrap
           and result._UpdateWrap then
          result:_UpdateWrap()
          task.delay(0.1, function()
            if not result._destroyed then result:_UpdateWrap() end
          end)
        end
        return result
      end
    end
  end

  local function patchItemLibrary()
    local IL = Modules.ItemLibrary
    if not (IL and IL.GetViewModelImageFromWeaponData) then return end
    local orig = IL.GetViewModelImageFromWeaponData
    IL.GetViewModelImageFromWeaponData = function(self, weaponData, highRes)
      if not weaponData then return orig(self, weaponData, highRes) end
      local weaponName = weaponData.Name
      local equip = state.equipped[weaponName]
      local profileMatch = state.viewingProfile == LocalPlayer and equip and equip.Skin
      local matchesEquipped = weaponData.Skin and equip and weaponData.Skin == equip.Skin
      if (matchesEquipped or profileMatch) and equip and equip.Skin then
        local skinInfo = self.ViewModels[equip.Skin.Name]
        if skinInfo then
          return skinInfo[highRes and "ImageHighResolution" or "Image"] or skinInfo.Image
        end
      end
      return orig(self, weaponData, highRes)
    end
  end

  local function patchViewProfile()
    local VP = Modules.ViewProfile
    if not (VP and VP.Fetch) then return end
    local orig = VP.Fetch
    VP.Fetch = function(self, target)
      state.viewingProfile = target
      return orig(self, target)
    end
  end

  local function patchFinishers()
    local CE = Modules.ClientEntity
    if not (CE and CE.ReplicateFromServer) then return end
    local orig = CE.ReplicateFromServer
    CE.ReplicateFromServer = function(self, action, ...)
      if action == "FinisherEffect" then
        local args = { ... }
        local killerName = args[3]
        local decoded = killerName
        if type(killerName) == "userdata" and Modules.EnumLibrary and Modules.EnumLibrary.FromEnum then
          local ok, dec = pcall(Modules.EnumLibrary.FromEnum, Modules.EnumLibrary, killerName)
          if ok and dec then decoded = dec end
        end
        local ours = tostring(decoded):lower() == LocalPlayer.Name:lower()
        if ours and state.lastUsedWeapon
           and state.equipped[state.lastUsedWeapon]
           and state.equipped[state.lastUsedWeapon].Finisher then
          local fin = state.equipped[state.lastUsedWeapon].Finisher
          local enumId = fin.Enum
          if not enumId and Modules.EnumLibrary then
            local ok, e = pcall(Modules.EnumLibrary.ToEnum, Modules.EnumLibrary, fin.Name)
            if ok and e then enumId = e end
          end
          if enumId then
            args[1] = enumId
            return orig(self, action, table.unpack(args))
          end
        end
      end
      return orig(self, action, ...)
    end
  end

  function Unlock.start()
    if state.started then return end
    state.started = true
    Logger.info("starting unlock-all")
    if not resolveModules() then
      Logger.warn("required modules missing -- unlock disabled")
      return
    end
    patchOwnership()
    patchDataController()
    patchEquipRemotes()
    patchClientItem()
    patchClientViewModel()
    patchItemLibrary()
    patchViewProfile()
    patchFinishers()
    Unlock.loadConfig()
    Logger.info("unlock-all active")
  end
end

--------------------------------------------------------------------------------
-- 8. PUBLIC API + LIFECYCLE
--------------------------------------------------------------------------------

local BCS = {
  _loaded   = false,
  _version  = "1.0.0",
  config    = CONFIG,
  log       = Logger,
  exec      = Exec,
  hooks     = Hooks,
  antiCheat = AntiCheat,
  unlock    = Unlock,
}

function BCS.start()
  if BCS._loaded then return BCS end
  Logger.info(string.format("BCS v%s booting", BCS._version))
  Exec.report()
  if CONFIG.AC_BYPASS  then Util.safeCall(AntiCheat.start) end
  if CONFIG.UNLOCK_ALL then Util.safeCall(Unlock.start) end
  BCS._loaded = true
  Logger.info("BCS ready")
  return BCS
end

function BCS.stop()
  Logger.info("tearing down BCS")
  Hooks.restoreAll()
  BCS._loaded = false
end

function BCS.status()
  Logger.info("=== BCS status ===")
  Logger.info("version           ", BCS._version)
  Logger.info("executor          ", Exec.name)
  Logger.info("ac bypass enabled ", tostring(CONFIG.AC_BYPASS))
  Logger.info("unlock enabled    ", tostring(CONFIG.UNLOCK_ALL))
  Logger.info("hooks installed   ", #Hooks.entries)
  local equippedSnap = Unlock.listEquipped()
  local count = 0
  for _ in pairs(equippedSnap) do count = count + 1 end
  Logger.info("loadouts saved    ", count)
end

-- Pass-through helpers so callers don't need to drill into BCS.unlock.
BCS.equip         = function(...) return Unlock.equip(...) end
BCS.unequip       = function(...) return Unlock.unequip(...) end
BCS.favorite      = function(...) return Unlock.favorite(...) end
BCS.equipAll      = function(...) return Unlock.equipAll(...) end
BCS.randomize     = function(...) return Unlock.randomize(...) end
BCS.listEquipped  = function() return Unlock.listEquipped() end
BCS.exportConfig  = function() return Unlock.exportConfig() end
BCS.importConfig  = function(json) return Unlock.importConfig(json) end

_G.BCS = BCS

if CONFIG.AUTOSTART then
  BCS.start()
end

return BCS
