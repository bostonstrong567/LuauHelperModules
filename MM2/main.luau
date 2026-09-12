--!native
--!optimize 2
--!nocheck
--!nolint UnknownGlobal

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local StarterGui = game:GetService("StarterGui")

local MM2_GAME_ID = 66654135

if not game:IsLoaded() then game.Loaded:Wait() end

------------------------------------------------------------------------------------------- Bootstrap
-- Loads Ember and UniversalNav over HTTP, retrying before it reports a failure.
local function coreNotify(title, text)
	for _ = 1, 10 do
		local ok = pcall(StarterGui.SetCore, StarterGui, "SendNotification", { Title = title, Text = text, Duration = 8 })
		if ok then return end
		task.wait(0.5)
	end
end

if game.GameId ~= MM2_GAME_ID then
	warn(string.format("RBX.lol Hub: this game (%d) is not supported, only Murder Mystery 2 is", game.GameId))
	coreNotify("RBX.lol Hub", "This game is not supported. This script is for Murder Mystery 2.")
	return
end

local player = Players.LocalPlayer
if not player.Character then player.CharacterAdded:Wait() end

local function fetchLib(name, url, accept)
	local lastErr = "no response"
	for attempt = 1, 5 do
		local ok, body = pcall(game.HttpGet, game, url)
		if ok and type(body) == "string" and #body > 1000 then
			local chunk, err = loadstring(body, name)
			if chunk then
				local ran, lib = pcall(chunk)
				if ran and type(lib) == "table" and accept(lib) then return lib end
				lastErr = ran and "library returned " .. typeof(lib) or tostring(lib)
			else
				lastErr = tostring(err)
			end
		else
			lastErr = ok and ("short response, " .. tostring(type(body) == "string" and #body or 0) .. " bytes") or tostring(body)
		end
		task.wait(attempt * 0.5)
	end
	coreNotify("RBX.lol Hub", "Could not load " .. name .. " from rbx.lol: " .. lastErr)
	error("RBX.lol Hub: could not load " .. name .. ", " .. lastErr, 0)
end

local Ember = fetchLib("ember", "https://rbx.lol/ember.lua", function(lib) return type(lib.new) == "function" end)
local UniversalNav = fetchLib("nav", "https://raw.githubusercontent.com/bostonstrong567/LuauHelperModules/main/nav/UniversalNav.luau", function(lib) return type(lib.Navigator) == "table" end)

pcall(function()
	local live = rawget(getgenv(), "__EMBER_LIVE")
	if type(live) ~= "table" then return end
	for i = #live, 1, -1 do
		local w = live[i]
		local id = type(w) == "table" and w._identity
		if id == "mm2" or id == "rbxlolhub" then
			pcall(w.Destroy, w, true)
			table.remove(live, i)
		end
	end
end)

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Round = require(Modules:WaitForChild("CurrentRoundClient"))
local LevelModule = require(Modules:WaitForChild("LevelModule"))
local ProfileData = require(Modules:WaitForChild("ProfileData"))
local Gameplay = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Gameplay")

local ROLE_COLOURS = {
	Murderer = Color3.fromRGB(220, 60, 60),
	Sheriff = Color3.fromRGB(60, 120, 235),
	Hero = Color3.fromRGB(60, 120, 235),
	Innocent = Color3.fromRGB(70, 200, 90),
	Zombie = Color3.fromRGB(25, 172, 0),
	Survivor = Color3.fromRGB(43, 154, 238),
	Freezer = Color3.fromRGB(150, 220, 250),
	Runner = Color3.fromRGB(0, 200, 100),
}

local COIN_COLOUR = Color3.fromRGB(255, 200, 40)
local KNIFE_REACH = 12
local THROW_REACH = 70
local AIM_FOV_MAX = 800
local CLAIM_WINDOW = 2.5
local COIN_SWITCH_RATIO = 0.7
local COIN_RETHINK = 0.5
local danger = { near = 40, safe = 60, beenTo = {}, fleeing = false, brainOn = false, friends = {}, badGoals = {}, traps = {}, trapHits = {}, pathLen = math.huge, pathAt = 0, pathFor = nil, routing = false, touchWas = {}, touchOff = false, knifeSeen = {} }
function danger.path(radius, spacing)
	return PathfindingService:CreatePath({
		AgentRadius = radius,
		AgentHeight = 4.5,
		AgentCanJump = true,
		AgentCanClimb = true,
		AgentMaxSlope = 60,
		WaypointSpacing = spacing,
	})
end

function danger.keepBest(best, at, score)
	local worst = best[#best]
	if #best < 8 or score > worst.score then
		table.insert(best, { at = at, score = score })
		table.sort(best, function(a, b) return a.score > b.score end)
		if #best > 8 then table.remove(best) end
	end
end

function danger.rayIgnoring(list)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = list
	return rp
end

function danger.flat(a, b)
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z)
end

local STALL_SECONDS = 0.4
local TOTALS_KEY = "mm2_totals"

local state = {
	roleEsp = false,
	nameEsp = false,
	showDead = false,
	coinEsp = false,
	gunEsp = false,
	autoCoin = false,
	avoid = true,
	autoVote = false,
	favMaps = {},
	autoPickup = false,
	autoKillMurderer = false,
	autoKillAll = false,
	autoKillSheriff = false,
	killAura = false,
	noStab = false,
	silentAim = false,
	resetFor = { Murderer = true },
	spareFriends = false,
	coinsFirst = false,
	hvh = false,
	survive = false,
	legit = true,
	legitFor = { ["Shooting as sheriff"] = true, ["Stabbing as murderer"] = true, ["Running as innocent"] = true },
	antiFling = true,
	speed = 16,
	jump = 50,
	gravity = 196,
	fly = false,
	flySpeed = 60,
	noclip = false,
	antiIdle = true,
	notify = true,
	killDelay = 0.2,
	killRange = 12,
	coinSpeed = 22,
	coinPath = true,
	aimFov = 160,
	aimInfinite = false,
	showFov = true,
}

----------------------------------------------------------------------------------------------- State
-- Live settings and what is remembered between sessions.
local function flip(key, on)
	local was = state[key]
	state[key] = on
	return was ~= on
end

local function legitOn(what)
	return state.legit and state.legitFor[what] == true
end

function danger.sawKnife(who)
	if not who then return end
	local char = who.Character
	if char and char:FindFirstChild("Knife") then danger.knifeSeen[who] = true end
end

function danger.drawnKnife(who)
	if not legitOn("Wait until the knife is drawn") then return true end
	if not who then return false end
	return danger.knifeSeen[who] == true
end

local session = {
	coins = 0,
	killsAsMurderer = 0,
	killsAsSheriff = 0,
	deaths = 0,
	survived = 0,
	roundsAsMurderer = 0,
	roundsAsSheriff = 0,
	roundsAsInnocent = 0,
	gunsGrabbed = 0,
	rounds = 0,
	xpStart = nil,
	lastXp = nil,
	levelStart = nil,
	lastLevel = nil,
	startedAt = os.clock(),
}

local function blankTotals()
	return {
		coins = 0,
		killsAsMurderer = 0,
		killsAsSheriff = 0,
		rounds = 0,
		deaths = 0,
		survived = 0,
		roundsAsMurderer = 0,
		roundsAsSheriff = 0,
		roundsAsInnocent = 0,
		gunsGrabbed = 0,
		xp = 0,
		levels = 0,
		playtime = 0,
		sessions = 0,
	}
end

local prefs = Ember.Store.get("mm2_prefs")
if type(prefs) ~= "table" or type(prefs.keep) ~= "table" then
	prefs = { keep = {} }
end
prefs.defaults = { movement = false, esp = true, combat = true, coins = true, interface = true, antifling = true }
for key, default in pairs(prefs.defaults) do
	if type(prefs.keep[key]) ~= "boolean" then prefs.keep[key] = default end
end

function prefs.key(group, key)
	if prefs.keep[group] then return key end
	return nil
end

local totals = blankTotals()

do
	local saved = Ember.Store.get(TOTALS_KEY)
	if type(saved) == "table" then
		for k in pairs(totals) do
			if type(saved[k]) == "number" then totals[k] = saved[k] end
		end
	end
	totals.sessions += 1
end

local lastSave = 0

local function saveTotals(force)
	local now = os.clock()
	if not force and now - lastSave < 5 then return end
	lastSave = now
	Ember.Store.set(TOTALS_KEY, totals)
end

local function bump(field, amount)
	amount = amount or 1
	session[field] += amount
	totals[field] += amount
	saveTotals()
end

local function fmtDuration(sec)
	local m = math.floor(sec / 60)
	if m >= 60 then
		return string.format("%dh %dm", math.floor(m / 60), m % 60)
	end
	return string.format("%dm %ds", m, math.floor(sec % 60))
end

----------------------------------------------------------------------------------------------- Round
-- Roles, friends and the gun holder, read from the game's own module.
local function roleData()
	return Round.PlayerData
end

local function myRole()
	local data = roleData()
	local d = data[player.Name]
	if d and d.Role then
		session.roleSeen = d.Role
	elseif next(data) == nil then
		session.roleSeen = nil
	end
	return session.roleSeen
end

local function roleOf(who)
	local d = roleData()[who.Name]
	return d and d.Role
end

local function isDead(who)
	local d = roleData()[who.Name]
	return d ~= nil and (d.Dead or d.Killed) == true
end

function danger.friend(who)
	if not state.spareFriends then return false end
	local known = danger.friends[who.UserId]
	if known == nil then
		local ok, answer = pcall(player.IsFriendsWith, player, who.UserId)
		if not ok then
			danger.friends[who.UserId] = true
			task.delay(30, function() danger.friends[who.UserId] = nil end)
			return true
		end
		known = answer == true
		danger.friends[who.UserId] = known
	end
	return known
end

local function findByRole(role)
	for name, d in pairs(roleData()) do
		if d.Role == role then
			return Players:FindFirstChild(name), d
		end
	end
	return nil, nil
end

local function gunHolder()
	for _, role in { "Sheriff", "Hero" } do
		local who, data = findByRole(role)
		if who and not isDead(who) then return who, data end
	end
	return nil, nil
end

local function nameFor(role)
	for name, d in pairs(roleData()) do
		if d.Role == role then
			return name .. ((d.Dead or d.Killed) and " (dead)" or "")
		end
	end
	return nil
end

----------------------------------------------------------------------------------------------- World
-- Map bounds, lobby tests and whether a round can be acted in.
local function myChar()
	return player.Character
end

local function myRoot()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function myHumanoid()
	local c = player.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

local function getMap()
	for _, v in Workspace:GetChildren() do
		if v:GetAttribute("MapID") then return v end
	end
	return nil
end

local function roundTimer()
	local part = Workspace:FindFirstChild("RoundTimerPart")
	return part and part:GetAttribute("Time")
end

local function amDead()
	local d = getMap() and roleData()[player.Name]
	if d and (d.Dead or d.Killed) then return true end
	local hum = myHumanoid()
	return hum == nil or hum.Health <= 0
end

local function insideBox(pos, cf, size, pad)
	local rel = cf:PointToObjectSpace(pos)
	return math.abs(rel.X) <= size.X / 2 + pad
		and math.abs(rel.Y) <= size.Y / 2 + pad
		and math.abs(rel.Z) <= size.Z / 2 + pad
end

local boxCache = {}

local function boundsOf(model)
	local box = boxCache[model]
	if not box or os.clock() - box.at > 3 then
		local cf, size = model:GetBoundingBox()
		box = { cf = cf, size = size, at = os.clock() }
		boxCache[model] = box
	end
	return box
end

function danger.lobbyHas(pos)
	local lobby = Workspace:FindFirstChild("RegularLobby")
	if not lobby then return false end
	local box = boundsOf(lobby)
	return insideBox(pos, box.cf, box.size, 20)
end

local function inLobby()
	local root = myRoot()
	if not root then return true end
	return danger.lobbyHas(root.Position)
end

local function inMap()
	local map, root = getMap(), myRoot()
	if not map or not root then return false end
	local box = boundsOf(map)
	return insideBox(root.Position, box.cf, box.size, 150)
end

local function roundLive()
	if not getMap() then return false end
	return next(roleData()) ~= nil
end

local function canAct()
	if not roundLive() then return false, "no round running" end
	if amDead() then return false, "you are dead" end
	if inLobby() then return false, "you are in the lobby" end
	if not inMap() then return false, "not on the map" end
	return true
end

local function findTool(name)
	local c = myChar()
	local pack = player:FindFirstChildOfClass("Backpack")
	return (c and c:FindFirstChild(name)) or (pack and pack:FindFirstChild(name))
end

function danger.surviving()
	if not state.survive then return false end
	local role = myRole()
	return role == "Innocent" or role == "Hero" or role == "Sheriff"
end

function danger.wanting()
	if danger.surviving() then return true end
	local role = myRole()
	if role == "Murderer" then return state.autoKillAll or state.autoKillSheriff or state.autoKillMurderer end
	return (role == "Sheriff" or role == "Hero") and state.autoKillMurderer
end

local function equipTool(tool)
	if tool.Parent == myChar() then return end
	local hum = myHumanoid()
	if hum then hum:EquipTool(tool) end
end

local function hitPartOf(who)
	local c = who.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

function danger.foe()
	local who = findByRole("Murderer")
	return who and who ~= player and not isDead(who) and hitPartOf(who) or nil
end

function danger.offMap(who)
	local map, root = getMap(), hitPartOf(who)
	if not map or not root then return false end
	if danger.lobbyHas(root.Position) then return false end
	local box = boundsOf(map)
	local centre = box.cf.Position
	if (root.Position - centre).Magnitude > math.max(box.size.X, box.size.Z) + 150 then return false end
	if root.Position.Y < centre.Y - box.size.Y / 2 - 3 then return true end
	return not insideBox(root.Position, box.cf, box.size, 4)
end

function danger.onMap(who)
	local map, root = getMap(), hitPartOf(who)
	if not map or not root then return false end
	if danger.lobbyHas(root.Position) then return false end
	local box = boundsOf(map)
	return insideBox(root.Position, box.cf, box.size, 150)
end

function danger.knifeNear()
	if findTool("Knife") then return false end
	local who = findByRole("Murderer")
	if not who or who == player or isDead(who) then return false end
	local part, me = hitPartOf(who), myRoot()
	if not part or not me then return false end
	return (part.Position - me.Position).Magnitude < THROW_REACH
end

function danger.cheaters()
	local out = {}
	local data = roleData()
	for _, who in Players:GetPlayers() do
		if who ~= player and data[who.Name] and not isDead(who) and not danger.friend(who) and danger.offMap(who) then
			local c = who.Character
			local hum = c and c:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				table.insert(out, { player = who, role = roleOf(who) })
			end
		end
	end
	return out
end

local function aliveTargets()
	local out = {}
	local root = myRoot()
	if not root then return out end
	local data = roleData()
	for _, who in Players:GetPlayers() do
		if who ~= player and data[who.Name] and not isDead(who) and not danger.friend(who) and danger.onMap(who) then
			local c = who.Character
			local r = c and c:FindFirstChild("HumanoidRootPart")
			local hum = c and c:FindFirstChildOfClass("Humanoid")
			if r and hum and hum.Health > 0 then
				table.insert(out, {
					player = who,
					root = r,
					role = roleOf(who),
					dist = (r.Position - root.Position).Magnitude,
				})
			end
		end
	end
	table.sort(out, function(a, b) return a.dist < b.dist end)
	return out
end

---------------------------------------------------------------------------------------------- Status
-- Status bar text and notifications.
if type(getgenv().__MM2_HUBS) ~= "table" then getgenv().__MM2_HUBS = {} end
for i = #getgenv().__MM2_HUBS, 1, -1 do
	local old = getgenv().__MM2_HUBS[i]
	getgenv().__MM2_HUBS[i] = nil
	pcall(function() old:Destroy() end)
end
if getgenv().__MM2_HUB then
	pcall(function() getgenv().__MM2_HUB:Destroy() end)
	getgenv().__MM2_HUB = nil
end
task.wait(0.2)
for _, old in (gethui and gethui() or game:GetService("CoreGui")):GetChildren() do
	if old:IsA("ScreenGui") and (old.Name == "rbxlolhub" or old.Name == "MM2Fov") then old:Destroy() end
end

local win = Ember.new({
	Name = "rbxlolhub",
	Title = "RBX.lol Hub",
	Subtitle = "Murder Mystery 2",
	Icon = "swords",
	Size = Vector2.new(760, 520),
	Keybind = false,
	Search = true,
	SaveLayout = "rbxlolhub",
	Footer = "",
	StatusBar = {
		Text = "Ready",
		Icon = "circle-dot",
		Items = {
			{ Id = "role", Align = "left", Text = "Role: -", Icon = "user" },
			{ Id = "map", Align = "right", Text = "Map: -" },
		},
	},
})

getgenv().__MM2_HUB = win
table.insert(getgenv().__MM2_HUBS, win)

local holdUntil = 0
local shownStatus = nil
local gone = false

local function say(text, icon, colour, holdFor)
	if gone then return end
	if os.clock() - (state.booted or 0) < 3 then return end
	holdUntil = os.clock() + (holdFor or 3)
	shownStatus = nil
	win.StatusBar:Set(text, { Icon = icon or "circle-dot", Color = colour or "muted" })
end

local function report(ok, good, bad)
	if ok then
		say(good, "check", "accent")
	else
		say(tostring(bad), "triangle-alert", "danger")
	end
end

local function notify(title, text, icon, colour)
	if gone or not state.notify then return end
	win:Notify({ Title = title, Text = text, Icon = icon, IconColor = colour })
end

local function idleStatus()
	if not getMap() then return "Waiting in lobby", "clock" end
	if amDead() then return "Dead, waiting for next round", "skull" end
	if inLobby() then return "Waiting for the map", "clock" end
	local role = myRole()
	if not role then return "Loading round", "loader" end
	return "Playing as " .. role, "circle-dot"
end

local function refreshStatus()
	if gone or os.clock() < holdUntil then return end
	local text, icon = idleStatus()
	if text == shownStatus then return end
	shownStatus = text
	win.StatusBar:Set(text, { Icon = icon, Color = "muted" })
end

local myAttacks = {}

----------------------------------------------------------------------------------------------- Melee
-- Knife attacks and the trail that pulls the body back out of the floor.
local function claimAttack(name, weapon)
	myAttacks[name] = { at = os.clock(), weapon = weapon }
end

local function creditDeath(name)
	local mine = myAttacks[name]
	if not mine or name == player.Name then return end
	if os.clock() - mine.at > CLAIM_WINDOW then return end
	myAttacks[name] = nil
	bump(mine.weapon == "Gun" and "killsAsSheriff" or "killsAsMurderer")
end

local function knifeRemotes()
	local knife = findTool("Knife")
	if not knife then return nil, "no knife" end
	equipTool(knife)
	local events = knife:FindFirstChild("Events")
	local stabbed = events and events:FindFirstChild("KnifeStabbed")
	local touched = events and events:FindFirstChild("HandleTouched")
	if not stabbed or not touched then return nil, "knife remotes missing" end
	return stabbed, touched
end

local function sheathe()
	task.delay(0.1, function()
		local hum = myHumanoid()
		if hum then hum:UnequipTools() end
	end)
end

local function stabTarget(entry)
	local stabbed, touched = knifeRemotes()
	if not stabbed then return false, touched end
	local hit = hitPartOf(entry.player)
	if not hit then return false, "target has no body" end
	stabbed:FireServer()
	touched:FireServer(hit)
	claimAttack(entry.player.Name, "Knife")
	sheathe()
	return true
end

local function stabMany(list)
	local stabbed, touched = knifeRemotes()
	if not stabbed then return 0, touched end
	stabbed:FireServer()
	local sent = 0
	for _, e in list do
		local hit = hitPartOf(e.player)
		if hit then
			touched:FireServer(hit)
			claimAttack(e.player.Name, "Knife")
			sent += 1
		end
	end
	sheathe()
	return sent
end

function danger.fallGuard(now)
	local root, hum = myRoot(), myHumanoid()
	local map = getMap()
	if not root or not hum or not map or hum.Health <= 0 or amDead() then
		danger.safePos = nil
		return
	end
	local box = boundsOf(map)
	local floor = box.cf.Position.Y - box.size.Y / 2
	if root.Position.Y > floor and hum.FloorMaterial ~= Enum.Material.Air and insideBox(root.Position, box.cf, box.size, 4) then
		danger.safePos = root.Position
		local trail = danger.safeTrail or {}
		danger.safeTrail = trail
		if #trail == 0 or (trail[#trail] - root.Position).Magnitude >= 4 then
			table.insert(trail, root.Position)
			if #trail > 12 then table.remove(trail, 1) end
		end
		return
	end
	if state.legit or not danger.safePos or root.Position.Y > floor - 8 or now - (danger.rescuedAt or 0) < 1 then return end
	danger.rescuedAt = now
	root.CFrame = CFrame.new(danger.safePos + Vector3.new(0, 3, 0)) * root.CFrame.Rotation
	root.AssemblyLinearVelocity = Vector3.zero
	say("Pulled back onto the map", "life-buoy", "muted")
end

------------------------------------------------------------------------------------------------- Aim
-- Gun aiming. One cooldown owner, and points led by ping so the server's trace agrees.
local function excludeMe()
	return danger.rayIgnoring({ myChar() })
end

function danger.stepHeight()
	local hum, root = myHumanoid(), myRoot()
	if not hum or not root then return 2.5 end
	return hum.HipHeight + root.Size.Y / 2
end

function danger.canStepOver(root, dir)
	local hum = myHumanoid()
	if not hum then return false end
	local foot = root.Position.Y - danger.stepHeight()
	local reach = math.max(root.Size.Z, 2) + 1.5
	local rp = excludeMe()
	rp.RespectCanCollide = true
	local clear = hum.HipHeight
	-- something at shin height that the body clears by walking is not an obstacle
	local low = Workspace:Raycast(Vector3.new(root.Position.X, foot + 0.25, root.Position.Z), dir * reach, rp)
	if not low then return false end
	local above = Workspace:Raycast(Vector3.new(root.Position.X, foot + clear, root.Position.Z), dir * reach, rp)
	if above then return false end
	local top = Workspace:Raycast(
		Vector3.new(root.Position.X, foot + clear, root.Position.Z) + dir * reach,
		Vector3.new(0, -(clear + 0.5), 0), rp)
	if not top then return true end
	return (top.Position.Y - foot) <= clear
end

function danger.weaponIgnore()
	local map = getMap()
	local list = { myChar(), map and map:FindFirstChild("CoinContainer") }
	for _, v in CollectionService:GetTagged("WeaponPassthrough") do
		table.insert(list, v)
	end
	return list
end

function danger.weaponRay(from, to)
	local ignore = danger.weaponIgnore()
	local rp = danger.rayIgnoring(ignore)
	local dir = to - from
	local seen = {}
	for _ = 1, 24 do
		local hit = Workspace:Raycast(from, dir, rp)
		if not hit then return nil end
		local part = hit.Instance
		if not part or part.Transparency ~= 1 then return hit end
		if seen[part] then return hit end
		seen[part] = true
		table.insert(ignore, part)
		rp = danger.rayIgnoring(ignore)
	end
	return nil
end

local function shotIsClear(fromPos, targetPart)
	local body = targetPart.Parent
	if not body then return false end
	local centre = targetPart.Position
	local side = centre - fromPos
	side = Vector3.new(-side.Z, 0, side.X)
	if side.Magnitude < 0.01 then return false end
	side = side.Unit * 1.4
	local head = body:FindFirstChild("Head")
	local aims = { centre, head and head.Position or centre + Vector3.new(0, 2, 0), centre + side, centre - side }
	for _, aim in aims do
		local hit = danger.weaponRay(fromPos, aim)
		if not hit or not hit.Instance:IsDescendantOf(body) then return false end
	end
	return true
end

local hold = { cf = nil, conn = nil, since = 0, seen = setmetatable({}, { __mode = "k" }) }

local function releaseHold()
	if hold.conn then
		hold.conn:Disconnect()
		hold.conn = nil
	end
	hold.cf = nil
end

local function holdAt(cf)
	hold.cf = cf
	hold.since = os.clock()
	if hold.conn then return end
	hold.conn = RunService.Heartbeat:Connect(function()
		local r = hold.cf and myRoot()
		if not r then return end
		r.CFrame = hold.cf
		r.AssemblyLinearVelocity = Vector3.zero
		r.AssemblyAngularVelocity = Vector3.zero
	end)
end

local function settleAt(cf)
	if not myRoot() then return false end
	holdAt(cf)
	local steady = 0
	for _ = 1, 40 do
		RunService.Heartbeat:Wait()
		hold.since = os.clock()
		local r = myRoot()
		if not r then break end
		if (r.Position - cf.Position).Magnitude < 2 then
			steady += 1
			if steady >= 4 then
				for _ = 1, 18 do RunService.Heartbeat:Wait() end
				return true
			end
		else
			steady = 0
		end
	end
	releaseHold()
	return false
end

local function spotIsStandable(spot)
	local rp = excludeMe()
	if Workspace:Raycast(spot + Vector3.new(0, 2.5, 0), Vector3.new(0, -0.5, 0), rp) then return false end
	local op = OverlapParams.new()
	op.FilterType = Enum.RaycastFilterType.Exclude
	op.FilterDescendantsInstances = rp.FilterDescendantsInstances
	op.RespectCanCollide = true
	if #Workspace:GetPartBoundsInBox(CFrame.new(spot + Vector3.new(0, 1.5, 0)), Vector3.new(2.5, 4, 2.5), op) > 0 then return false end
	return Workspace:Raycast(spot, Vector3.new(0, -14, 0), rp) ~= nil
end

local function stepIntoView(targetPart)
	local root = myRoot()
	if not root then return false end
	local centre, here = targetPart.Position, root.Position
	if (here - centre).Magnitude >= KNIFE_REACH and shotIsClear(here, targetPart) then return true end

	local best, bestScore
	for _, radius in { 20, 32, 48, 70, 100, 140 } do
		for turn = 0, 23 do
			local a = math.rad(turn * 15)
			for _, lift in { 3, 9, 18 } do
				local spot = centre + Vector3.new(math.cos(a) * radius, lift, math.sin(a) * radius)
				if spotIsStandable(spot) and shotIsClear(spot, targetPart) then
					local score = (spot - here).Magnitude - math.min(radius, 90) * 1.5
					if not bestScore or score < bestScore then
						best, bestScore = spot, score
					end
				end
			end
		end
	end
	if not best then
		for _, radius in { 24, 32, 40 } do
			for turn = 0, 23 do
				local a = math.rad(turn * 15)
				for _, lift in { 3, 8 } do
					local spot = centre + Vector3.new(math.cos(a) * radius, lift, math.sin(a) * radius)
					if shotIsClear(spot, targetPart) and Workspace:Raycast(spot, Vector3.new(0, -45, 0), excludeMe()) then
						local score = (spot - here).Magnitude
						if not bestScore or score < bestScore then best, bestScore = spot, score end
					end
				end
			end
			if best then break end
		end
	end
	if not best then return false end
	if not settleAt(CFrame.lookAt(best, centre)) then return false end
	local now = myRoot()
	return now ~= nil and shotIsClear(now.Position, targetPart)
end

local function gunOrigin()
	local root = myRoot()
	local att = root and root:FindFirstChild("GunRaycastAttachment")
	return att
end

local lastShot = 0
local SHOT_GAP = 0.6

local function fireShot(shoot, originCF, point, name)
	local now = os.clock()
	if now - lastShot < SHOT_GAP then return false end
	lastShot = now
	shoot:FireServer(originCF, CFrame.new(point))
	if name then claimAttack(name, "Gun") end
	return true
end

local function clearAim(origin, entry)
	local char = entry.player.Character
	local root = entry.root
	local head = char and char:FindFirstChild("Head")
	if not char or not root then return nil end
	local now = os.clock()
	local seen = hold.seen[root]
	if not seen or now - seen.at > 0.04 then hold.seen[root] = { pos = root.Position, at = now } end
	local side = root.Position - origin
	side = Vector3.new(-side.Z, 0, side.X)
	side = side.Magnitude > 0.01 and side.Unit * 1.1 or Vector3.zero
	local points = { root.Position, root.Position + Vector3.new(0, 1.3, 0), root.Position + side, root.Position - side }
	if head then table.insert(points, 2, head.Position) end
	local blocker
	local function lands(from, ray)
		local hit = danger.weaponRay(from, from + ray)
		if not hit then return false end
		if hit.Instance:IsDescendantOf(char) then return true, hit.Position end
		blocker = blocker or hit.Instance
		return false
	end
	local mine = myChar()
	local eye = mine and mine:FindFirstChild("Head")
	for _, point in points do
		local ray = point - origin
		local across = Vector3.new(-ray.Z, 0, ray.X)
		across = across.Magnitude > 0.01 and across.Unit * 0.9 or Vector3.zero
		local ok, onBody = lands(origin, ray)
		if ok and lands(origin + across, ray) and lands(origin - across, ray) and (not eye or lands(eye.Position, point - eye.Position)) then return onBody end
	end
	return nil, blocker
end

local function readyGun(entry)
	local gun = findTool("Gun")
	if not gun then return nil, "no gun" end
	equipTool(gun)
	local shoot = gun:FindFirstChild("Shoot")
	if not shoot then return nil, "gun has no Shoot" end
	local aim = hitPartOf(entry.player)
	if not aim then return nil, "target has no body" end
	local origin = gunOrigin()
	if not origin then return nil, "no gun attachment" end
	if os.clock() - lastShot < SHOT_GAP then return nil, "reloading" end
	return shoot, aim, origin
end

local function fire(shoot, entry, origin, aim)
	local point = clearAim(origin.WorldCFrame.Position, { player = entry.player, root = aim })
	if not point then return false, "no clear shot" end
	if not fireShot(shoot, origin.WorldCFrame, point, entry.player.Name) then return false, "reloading" end
	return true
end

local function shootFromHere(entry)
	local shoot, aim, origin = readyGun(entry)
	if not shoot then return false, aim end
	local ok, why = fire(shoot, entry, origin, aim)
	sheathe()
	return ok, why
end

local function shootTarget(entry)
	local shoot, aim, origin = readyGun(entry)
	if not shoot then return false, aim end

	local from = origin.WorldCFrame.Position
	if (from - aim.Position).Magnitude < KNIFE_REACH or not shotIsClear(from, aim) then
		if not stepIntoView(aim) then
			releaseHold()
			return false, "no clear shot"
		end
		origin = gunOrigin()
		if not origin or not shotIsClear(origin.WorldCFrame.Position, aim) then
			releaseHold()
			return false, "line broke"
		end
	end

	local ok, why = fire(shoot, entry, origin, aim)
	if not ok then
		releaseHold()
		sheathe()
		return false, why
	end
	task.delay(0.15, releaseHold)
	sheathe()
	return true
end

local sniper = { busy = false, blockedSince = nil, close = 30, hold = 48, far = 80, reach = 45, label = nil, labelAt = 0, noPath = {} }

local function sniperTick(now)
	local target
	for _, e in aliveTargets() do
		if e.role == "Murderer" then
			target = e
			break
		end
	end
	if not target then
		sniper.blockedSince = nil
		return
	end
	local gun = findTool("Gun")
	local shoot = gun and gun:FindFirstChild("Shoot")
	if not shoot then return end
	equipTool(gun)
	local origin = gunOrigin()
	if not origin then return end
	if now - lastShot < SHOT_GAP then return end

	local point = clearAim(origin.WorldCFrame.Position, target)
	local range = (target.root.Position - origin.WorldCFrame.Position).Magnitude
	if point and (range > sniper.reach or range < KNIFE_REACH) then point = nil end
	if point then
		sniper.blockedSince = nil
		if legitOn("Shooting as sheriff") or hold.cf then
			fireShot(shoot, origin.WorldCFrame, point, target.player.Name)
			task.delay(0.15, releaseHold)
			sheathe()
		elseif not sniper.busy then
			sniper.busy = true
			task.spawn(function()
				pcall(function()
				local r = myRoot()
				if r and settleAt(r.CFrame) then
					local o = gunOrigin()
					local aim = o and clearAim(o.WorldCFrame.Position, target)
					if aim then fireShot(shoot, o.WorldCFrame, aim, target.player.Name) end
				end
				end)
				task.delay(0.15, releaseHold)
				sheathe()
				sniper.busy = false
			end)
		end
		return
	end

	sniper.blockedSince = sniper.blockedSince or now
	if (sniper.noPath[target.player] or 0) > now then return end
	if range > sniper.reach then return end
	if now - sniper.blockedSince > 0.15 and not sniper.busy then
		sniper.busy = true
		task.spawn(function()
			pcall(function()
			if legitOn("Shooting as sheriff") then
				pcall(sniper.duel, target.player, 20)
			else
				local homeRoot = myRoot()
				local home = homeRoot and inMap() and homeRoot.CFrame
				local okStep, found = pcall(stepIntoView, target.root)
				task.delay(0.5, releaseHold)
				if okStep and found then
					local t0 = os.clock()
					while os.clock() - t0 < 0.8 and lastShot < t0 do RunService.Heartbeat:Wait() end
					task.wait(0.35)
					local r, t = myRoot(), hitPartOf(target.player)
					if r and home and t and not isDead(target.player) and (t.Position - r.Position).Magnitude < 25 and (home.Position - r.Position).Magnitude < 160 then
						local floor = danger.floorAt(home.X, home.Y + 5, home.Z)
						if floor then
							releaseHold()
							r.CFrame = CFrame.new(floor + Vector3.new(0, 3, 0)) * home.Rotation
							r.AssemblyLinearVelocity = Vector3.zero
						end
					end
				else
					sniper.blockedSince = os.clock() + 3
				end
			end
			end)
			sniper.busy = false
		end)
	end
end

local function killEntry(entry)
	if findTool("Knife") then return stabTarget(entry) end
	if findTool("Gun") then return shootTarget(entry) end
	return false, "no weapon in hand"
end

local function legalTargets()
	local list = aliveTargets()
	if findTool("Knife") then return list end
	local out = {}
	for _, e in list do
		if e.role == "Murderer" and danger.drawnKnife(e.player) then table.insert(out, e) end
	end
	return out
end

local fovGui, fovRing = nil, nil

------------------------------------------------------------------------------------------ Silent aim
-- Namecall hook that bends a shot onto the nearest legal head inside the FOV ring.
local function fovWanted()
	return state.silentAim and state.showFov and not state.aimInfinite
end

local function clearCircle()
	if fovGui then
		fovGui:Destroy()
		fovGui, fovRing = nil, nil
	end
end

local function refreshCircle()
	if not fovWanted() then
		if fovGui then fovGui.Enabled = false end
		return
	end
	if not fovGui then
		fovGui = Instance.new("ScreenGui")
		fovGui.Name = "MM2Fov"
		fovGui.IgnoreGuiInset = true
		fovGui.ResetOnSpawn = false
		fovGui.DisplayOrder = 0
		fovRing = Instance.new("Frame")
		fovRing.AnchorPoint = Vector2.new(0.5, 0.5)
		fovRing.Position = UDim2.fromScale(0.5, 0.5)
		fovRing.BackgroundTransparency = 1
		fovRing.Parent = fovGui
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(1, 0)
		round.Parent = fovRing
		local edge = Instance.new("UIStroke")
		edge.Thickness = 2
		edge.Color = ROLE_COLOURS.Sheriff
		edge.Parent = fovRing
		fovGui.Parent = gethui()
	end
	fovRing.Size = UDim2.fromOffset(state.aimFov * 2, state.aimFov * 2)
	fovGui.Enabled = true
end

local function aimHead()
	local cam = Workspace.CurrentCamera
	local centre = cam.ViewportSize / 2
	local limit = state.aimInfinite and math.huge or state.aimFov
	local best, bestDist
	for _, e in legalTargets() do
		local head = e.player.Character:FindFirstChild("Head")
		if head then
			local screen, onScreen = cam:WorldToViewportPoint(head.Position)
			if onScreen or state.aimInfinite then
				local d = (Vector2.new(screen.X, screen.Y) - centre).Magnitude
				if d <= limit and (not bestDist or d < bestDist) then
					best, bestDist = head, d
				end
			end
		end
	end
	return best
end

local function hookSilentAim()
	getgenv().__MM2_SILENT = { state = state, aimHead = aimHead }
	if getgenv().__MM2_SILENT_HOOKED then return end
	getgenv().__MM2_SILENT_HOOKED = true
	local old
	old = hookmetamethod(game, "__namecall", function(self, ...)
		local live = rawget(getgenv(), "__MM2_SILENT")
		if live and live.state.silentAim and not checkcaller() and getnamecallmethod() == "FireServer" and typeof(self) == "Instance" and self.Name == "Shoot" then
			local args = { ... }
			if #args >= 2 then
				local head = live.aimHead()
				if head then
					args[2] = CFrame.new(head.Position)
					return old(self, table.unpack(args))
				end
			end
		end
		return old(self, ...)
	end)
end

--------------------------------------------------------------------------------------------- Pickups
-- Dropped guns on the ground.
local function droppedGuns()
	local out = {}
	for _, gun in CollectionService:GetTagged("GunDrop") do
		if gun:IsA("BasePart") and gun:IsDescendantOf(Workspace) then
			table.insert(out, gun)
		end
	end
	return out
end

function danger.armed(who)
	if not who or who == player then return false end
	local char = who.Character
	if char and char:FindFirstChild("Gun") then return true end
	local pack = who:FindFirstChildOfClass("Backpack")
	return pack ~= nil and pack:FindFirstChild("Gun") ~= nil
end

function danger.heldGuns()
	local out = {}
	for _, who in Players:GetPlayers() do
		local char = who ~= player and who.Character
		local tool = char and char:FindFirstChild("Gun")
		local handle = tool and tool:FindFirstChild("Handle")
		if handle and handle:IsA("BasePart") then table.insert(out, handle) end
	end
	return out
end

local function nearestGun(from)
	local best, bestDist
	for _, gun in droppedGuns() do
		local d = (gun.Position - from).Magnitude
		if not bestDist or d < bestDist then best, bestDist = gun, d end
	end
	return best, bestDist
end

local coin = { set = {}, skipped = {}, hooks = {}, bagFull = false }

local function coinValid(part)
	if not part.Parent or not part:IsA("BasePart") or not part:IsDescendantOf(Workspace) then return false end
	if part:GetAttribute("Collected") then return false end
	if not part:FindFirstChild("TouchInterest") then return false end
	local vis = part:FindFirstChild("CoinVisual")
	if not vis or vis:GetAttribute("Delete") or vis:GetAttribute("Collected") then return false end
	local mesh = vis:FindFirstChild("MainCoin")
	if not mesh or not mesh:IsA("BasePart") or mesh.Transparency >= 0.95 then return false end
	return true
end

local onCoinAdded

local function addCoin(part)
	if coin.set[part] or not part:IsA("BasePart") then return end
	coin.set[part] = true
	if part:FindFirstChild("TouchInterest") then
		if onCoinAdded then onCoinAdded(part) end
		return
	end
	local conn
	conn = part.ChildAdded:Connect(function(child)
		if child.Name ~= "TouchInterest" then return end
		conn:Disconnect()
		if coin.set[part] and onCoinAdded then onCoinAdded(part) end
	end)
end

local function coinParts()
	local out = {}
	for part in pairs(coin.set) do
		if coinValid(part) then
			table.insert(out, part)
		elseif not part.Parent or not part:IsDescendantOf(Workspace) then
			coin.set[part] = nil
		end
	end
	return out
end

---------------------------------------------------------------------------------------------- Threat
-- The murderer, how far away he really is, and which coins that makes worth taking.
function danger.root()
	if not (state.avoid or danger.surviving()) then
		danger.rootWhy = "off"
		return nil
	end
	local armed = findTool("Gun") ~= nil or findTool("Knife") ~= nil
	if armed and findTool("Knife") then
		danger.rootWhy = "armed"
		return nil
	end
	if armed then
		local part = danger.foe()
		local me = myRoot()
		if not (part and me and (part.Position - me.Position).Magnitude < KNIFE_REACH + 6) then
			danger.rootWhy = "armed"
			return nil
		end
	end
	local who = findByRole("Murderer")
	if who and who ~= player and not isDead(who) then
		local part = hitPartOf(who)
		local me = myRoot()
		if part and me and roundTimer() == -1 then
			if (part.Position - me.Position).Magnitude <= 30 then danger.closeUntil = os.clock() + 8 end
			if (danger.closeUntil or 0) < os.clock() then
				danger.rootWhy = "unarmed"
				return nil
			end
		end
		if part then
			danger.rootWhy = nil
			danger.lastThreat, danger.lastThreatAt = part, os.clock()
			return part
		end
		danger.rootWhy = "no body"
	else
		danger.rootWhy = who == nil and "no murderer" or (who == player and "me" or "dead")
	end
	if danger.lastThreat and os.clock() - danger.lastThreatAt < 1 and danger.lastThreat.Parent then return danger.lastThreat end
	return nil
end

function danger.shadow()
	local who = findByRole("Murderer")
	if not who or who == player or isDead(who) or danger.offMap(who) then return nil end
	return hitPartOf(who)
end

function danger.walkLength(from, to)
	local path = danger.path(2, 6)
	local ok = pcall(path.ComputeAsync, path, from, to)
	if not ok or path.Status ~= Enum.PathStatus.Success then return math.huge end
	local len = 0
	local pts = path:GetWaypoints()
	for i = 2, #pts do len += (pts[i].Position - pts[i - 1].Position).Magnitude end
	return len
end

function danger.gap(from, threat)
	local delta = threat.Position - from
	local flat = Vector3.new(delta.X, 0, delta.Z).Magnitude
	local dy = math.abs(delta.Y)
	local root = myRoot()
	if root and danger.pathFor == threat and os.clock() - danger.pathAt < 1.5 and (from - root.Position).Magnitude < 2 then
		if flat < 12 and dy < 6 then return flat end
		local gap = flat + dy * 3
		if danger.pathLen ~= math.huge then gap = math.max(danger.pathLen, flat) end
		if threat.Position.Y > from.Y - 2 and dy < 40 then
			gap = math.min(gap, flat + dy * 0.5)
		elseif flat < 60 and dy < 8 then
			local rp = danger.rayIgnoring({ myChar(), threat.Parent })
			if not Workspace:Raycast(threat.Position, from + Vector3.new(0, 1, 0) - threat.Position, rp) then
				gap = math.min(gap, flat)
			end
		end
		return gap
	end
	if dy < 6 then return flat end
	if threat.Position.Y > from.Y - 2 and dy < 40 then return flat + dy * 0.5 end
	local gap = flat + dy * 3
	local rp = danger.rayIgnoring({ myChar(), threat.Parent })
	if Workspace:Raycast(threat.Position, -delta, rp) then gap += 40 end
	return gap
end

function danger.sees(from, threat)
	if not threat or not threat.Parent then return false end
	local rp = danger.rayIgnoring({ myChar(), threat.Parent })
	rp.RespectCanCollide = true
	local eye = threat.Position + Vector3.new(0, 1.5, 0)
	for _, lift in { 1.5, 0, 3 } do
		if not Workspace:Raycast(eye, from + Vector3.new(0, lift, 0) - eye, rp) then return true end
	end
	return false
end

function danger.reach()
	local seen = danger.throwSeen
	if not seen or seen <= 0 then return THROW_REACH end
	return math.clamp(seen * 1.15, KNIFE_REACH + 6, 250)
end

function danger.sawThrow(at)
	local me = myRoot()
	if not me or not at then return end
	local span = (at - me.Position).Magnitude
	if span < KNIFE_REACH or span > 400 then return end
	local seen = danger.throwSeen
	danger.throwSeen = seen and math.max(seen * 0.7 + span * 0.3, span) or span
end

function danger.watchThrows()
	if danger.throwHooked then return end
	local ok, svc = pcall(function()
		return require(ReplicatedStorage:WaitForChild("ClientServices", 5):WaitForChild("WeaponService", 5))
	end)
	local signal = ok and svc and rawget(svc, "KnifeThrown")
	if not signal then return end
	local function heard()
		local foe = danger.foe()
		if foe then danger.sawThrow(foe.Position) end
	end
	local fine, conn = pcall(function()
		if typeof(signal) == "Instance" then return signal.Event:Connect(heard) end
		return signal:Connect(heard)
	end)
	if fine and conn then danger.throwHooked = true end
end

function danger.knifeHandles()
	local out = {}
	for _, who in Players:GetPlayers() do
		local char = who ~= player and who.Character
		local knife = char and char:FindFirstChild("Knife")
		local handle = knife and knife:FindFirstChild("Handle")
		if handle and handle:IsA("BasePart") then table.insert(out, handle) end
	end
	return out
end

function danger.untouchable(on)
	if on then
		for _, handle in danger.knifeHandles() do
			if danger.touchWas[handle] == nil then danger.touchWas[handle] = handle.CanTouch end
			handle.CanTouch = false
		end
		return
	end
	for handle, was in pairs(danger.touchWas) do
		if handle.Parent then handle.CanTouch = was end
	end
	table.clear(danger.touchWas)
end

function danger.guardTouch()
	if not state.noStab then
		if danger.touchOff or next(danger.touchWas) ~= nil then
			danger.untouchable(false)
			danger.touchOff = false
		end
		return
	end
	danger.touchOff = true
	danger.untouchable(true)
end

function danger.dangerous(threat)
	local me = myRoot()
	if not me or not threat then return false end
	local span = danger.gap(me.Position, threat)
	if span < KNIFE_REACH + 8 then return true end
	if not danger.sees(me.Position, threat) then return false end
	return span < danger.reach()
end

function danger.heading(threat)
	local v = threat.AssemblyLinearVelocity
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude > 4 then return flat.Unit, math.min(flat.Magnitude, 20) end
	local look = threat.CFrame.LookVector
	look = Vector3.new(look.X, 0, look.Z)
	return look.Magnitude > 0.1 and look.Unit or nil, 0
end

function danger.ahead(threat)
	local heading, speed = danger.heading(threat)
	return heading and threat.Position + heading * speed * 1.5 or threat.Position
end

function danger.routeSafe(legs, from, threat, first)
	local prev, run = from, 0
	for i = first or 1, #legs do
		local p = legs[i].Position
		run += (p - prev).Magnitude
		prev = p
		local his = danger.gap(p, threat)
		if his < 26 or his / 18 < run / math.max(state.coinSpeed or 22, 16) + 0.5 then return false end
	end
	return true
end

function danger.pathGap(from, to, threat)
	local a = Vector3.new(from.X, 0, from.Z)
	local b = Vector3.new(to.X, 0, to.Z)
	local t = Vector3.new(threat.Position.X, 0, threat.Position.Z)
	local ab = b - a
	local len = ab.Magnitude
	if len < 0.01 then return (t - a).Magnitude end
	local along = math.clamp((t - a):Dot(ab) / (len * len), 0, 1)
	local gap = (t - (a + ab * along)).Magnitude
	if math.abs(threat.Position.Y - from.Y) >= 6 then gap += 30 end
	return gap
end

function danger.closeBy(from, threat, within)
	local flat = danger.flat(threat.Position, from).Magnitude
	local dy = math.abs(threat.Position.Y - from.Y)
	local above = threat.Position.Y > from.Y - 2 and dy < 40
	return flat < within and (dy < 10 or above or (dy < 20 and flat < within * 0.5))
end

local function nearestCoin(from, now)
	local ranked = {}
	local threat = danger.root()
	local parts = coinParts()
	local minGap = danger.safe
	local ourGap = threat and danger.gap(from, threat) or math.huge
	local toThreat = threat and danger.flat(threat.Position, from) or Vector3.zero
	for _, part in parts do
		local until_ = coin.skipped[part]
		if not until_ or until_ < now then
			local d = (part.Position - from).Magnitude
			local nearby = 0
			for _, other in parts do
				if other ~= part and (other.Position - part.Position).Magnitude < 20 then nearby += 1 end
			end
			local score = d - math.min(nearby, 6) * 4
			if danger.lethal(part.Position, 12) then score = nil end
			if score and threat then
				local gap = danger.gap(part.Position, threat)
				local toCoin = danger.flat(part.Position, from)
				local towardThem = toCoin.Magnitude > 1 and toThreat.Magnitude > 0.01 and toCoin.Unit:Dot(toThreat.Unit) > 0.5 and gap < math.max(ourGap, 50)
				local ahead = danger.ahead(threat)
				local inHisWay = math.abs(threat.Position.Y - part.Position.Y) < 8 and danger.flat(ahead, part.Position).Magnitude < 40
				if gap < minGap or towardThem or inHisWay or danger.pathGap(from, part.Position, threat) < 26 then
					score = nil
				elseif gap < 60 then
					score += (60 - gap) * 2
				end
			end
			if score then table.insert(ranked, { part = part, dist = d, score = score }) end
		end
	end
	table.sort(ranked, function(a, b) return a.score < b.score end)
	for i = 1, math.min(#ranked, 8) do
		local pick = ranked[i]
		if danger.reachable(from, pick.part.Position) then
			return pick.part, pick.dist
		end
	end
	local fallback = ranked[1]
	if fallback then return fallback.part, fallback.dist end
	return nil, nil
end

function coin.first()
	if not (state.coinsFirst and state.autoCoin) or coin.bagFull then return false end
	local now = os.clock()
	if now - (coin.firstAt or 0) < 0.25 then return coin.firstWas end
	coin.firstAt = now
	local root = myRoot()
	if not root then
		coin.firstWas = false
		return false
	end
	local threat = danger.foe()
	local reach = findTool("Knife") and 15 or (findTool("Gun") and 40) or 0
	local prey = reach > 0 and legalTargets()[1]
	coin.firstWas = nearestCoin(root.Position, now) ~= nil and not (threat and danger.gap(root.Position, threat) < danger.near) and not (prey and prey.dist <= reach)
	return coin.firstWas
end

local function forgetCoinHooks()
	for _, c in coin.hooks do c:Disconnect() end
	table.clear(coin.hooks)
	table.clear(coin.set)
	table.clear(coin.skipped)
	coin.held, coin.tries = nil, 0
end

local function hookContainer(container)
	for _, child in container:GetChildren() do addCoin(child) end
	table.insert(coin.hooks, container.ChildAdded:Connect(addCoin))
	table.insert(coin.hooks, container.ChildRemoved:Connect(function(part) coin.set[part] = nil end))
end

local function watchMapCoins(map)
	forgetCoinHooks()
	local container = map:FindFirstChild("CoinContainer")
	if container then
		hookContainer(container)
		return
	end
	table.insert(coin.hooks, map.ChildAdded:Connect(function(child)
		if child.Name == "CoinContainer" then hookContainer(child) end
	end))
end

local coinRun = nil
local borrowed = nil

-------------------------------------------------------------------------------------------- Movement
-- Borrowing the humanoid, and the gate that stops every walker in one frame.
local function borrowMovement()
	local hum = myHumanoid()
	if not hum or borrowed then return hum end
	borrowed = {
		walk = hum.WalkSpeed,
		jump = hum.JumpPower,
		height = hum.JumpHeight,
		usePower = hum.UseJumpPower,
		states = {},
	}
	for _, st in { Enum.HumanoidStateType.Seated, Enum.HumanoidStateType.FallingDown, Enum.HumanoidStateType.Ragdoll, Enum.HumanoidStateType.PlatformStanding } do
		borrowed.states[st] = hum:GetStateEnabled(st)
		hum:SetStateEnabled(st, false)
	end
	if hum.SeatPart then hum.Sit = false end
	hum.PlatformStand = false
	return hum
end

local function restoreMovement(keepMoving)
	local hum = myHumanoid()
	if hum and borrowed then
		hum.WalkSpeed = state.speed ~= 16 and state.speed or borrowed.walk
		if not keepMoving then player:Move(Vector3.zero, false) end
		hum.UseJumpPower = borrowed.usePower
		hum.JumpPower = borrowed.jump
		hum.JumpHeight = borrowed.height
		for st, was in pairs(borrowed.states) do
			hum:SetStateEnabled(st, was)
		end
	end
	borrowed = nil
end

danger.moveGate = 0
function danger.canMove()
	return os.clock() >= danger.moveGate
end

local function halt()
	local root, hum = myRoot(), myHumanoid()
	player:Move(Vector3.zero, false)
	if hum then hum:Move(Vector3.zero, false) end
	if root and hum and hum.FloorMaterial ~= Enum.Material.Air then
		root.AssemblyLinearVelocity = Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
	end
end

local function stopCoinRun()
	if coinRun then coinRun.active = false end
end

local function cutRun()
	local run = coinRun
	if not run then
		halt()
		return
	end
	run.active = false
	run.moveDir = nil
	if run.stepConn then
		run.stepConn:Disconnect()
		run.stepConn = nil
	end
	halt()
end

function danger.stopPursuit()
	if coinRun and coinRun.kind == "pursuit" then
		danger.pursuing = false
		sniper.busy = false
		cutRun()
	end
end

local function finishRun(keepMoving)
	local run = coinRun
	coinRun = nil
	danger.run = nil
	if run and run.stepConn then run.stepConn:Disconnect() end
	if not keepMoving then halt() end
	restoreMovement(keepMoving)
end

local lastHop = 0

local function jumpNow(force)
	local now = os.clock()
	if now - lastHop < 0.6 then return end
	local hum = myHumanoid()
	if not hum then return end
	local st = hum:GetState()
	if st == Enum.HumanoidStateType.Freefall or st == Enum.HumanoidStateType.Jumping then return end
	if not force and danger.knifeNear() then return end
	lastHop = now
	hum:ChangeState(Enum.HumanoidStateType.Jumping)
end

local function routeTo(from, to)
	local path = danger.path(2.2, 4)
	local ok = pcall(path.ComputeAsync, path, from, to)
	if not ok or path.Status ~= Enum.PathStatus.Success then return nil end
	local pts = path:GetWaypoints()
	if #pts < 2 then return nil end
	return pts
end

local function drive(run, root, hum, target, speed)
	if not run.active or coinRun ~= run then return end
	local here = root.Position
	local dx, dz = target.X - here.X, target.Z - here.Z
	local length = math.sqrt(dx * dx + dz * dz)
	if length > 0.01 then dx, dz = dx / length, dz / length end
	hum.WalkSpeed = speed
	local want = Vector3.new(dx, 0, dz)
	local now = os.clock()
	local dt = math.min(now - (run.driveAt or now), 0.1)
	run.driveAt = now
	local have = run.moveDir
	if have and have.Magnitude > 0.5 then
		have = have.Unit
		local angle = math.acos(math.clamp(have:Dot(want), -1, 1))
		local most = math.rad(540) * dt * math.clamp(speed / 18, 1, 1.6)
		if angle > most then
			local sign = have:Cross(want).Y >= 0 and 1 or -1
			if math.abs(have:Cross(want).Y) < 0.01 then sign = 1 end
			want = CFrame.Angles(0, sign * most, 0) * have
		end
	end
	if not danger.roomAhead(here, want, 3) then
		run.bendMemo = run.bendMemo or {}
		local open = danger.bendAround(here, want, run.bendMemo)
		if open then
			want = open
		elseif run.moveDir and danger.roomAhead(here, run.moveDir, 3) then
			want = run.moveDir
		else
			jumpNow(danger.canStepOver(root, want))
		end
	end
	run.moveDir = want
	if run.weave and length > 6 and run.weaveNear then
		local sway = math.sin(os.clock() * 2.5) * 0.45
		run.moveDir = (run.moveDir + Vector3.new(-dz, 0, dx) * sway).Unit
		if os.clock() - lastHop >= 0.9 then jumpNow() end
	end
	if danger.canMove() then player:Move(run.moveDir, false) end
end

local function unstick(fix, hum)
	fix.level += 1
	if fix.level > 1 then return "replan" end
	jumpNow()
	return true
end

local function lineIsClear(from, to, ignore)
	local rp = excludeMe()
	if ignore then rp.FilterDescendantsInstances = { myChar(), ignore } end
	rp.RespectCanCollide = true
	local eye = from + Vector3.new(0, 1, 0)
	for _, lift in { 0, -2, 2 } do
		if Workspace:Raycast(eye, (to + Vector3.new(0, lift, 0)) - eye, rp) then return false end
	end
	return true
end

function danger.threatFrom(here, threat)
	if threat.Position.Y > here.Y - 2 then return threat.Position end
	if danger.pathFor == threat and danger.approach and not lineIsClear(here, threat.Position, threat.Parent) then return danger.approach end
	return threat.Position
end

function danger.log(text)
	danger.brainLog = danger.brainLog or {}
	table.insert(danger.brainLog, string.format("%.1f %s", os.clock() - (danger.brainStart or 0), text))
	if #danger.brainLog > 24 then table.remove(danger.brainLog, 1) end
end

---------------------------------------------------------------------------------------------- Walker
-- Walks one leg, steering around walls and giving up when it stops gaining ground.
local function travel(run, points, hum)
	local fix = { level = 0, stalled = 0, progress = 0 }
	local last = #points
	local legStart = os.clock()
	run.points, run.leg = points, 0

	local i = 0
	while i < last do
		i += 1
		local here0 = myRoot()
		while i < last and here0 and points[i].Action == Enum.PathWaypointAction.Walk and points[i + 1].Action == Enum.PathWaypointAction.Walk
			and (points[i + 1].Position - here0.Position).Magnitude < 12 and math.abs(points[i + 1].Position.Y - here0.Position.Y) < 3
			and danger.straight(here0.Position, points[i + 1].Position) do
			i += 1
		end
		local wp = points[i]
		run.leg = i
		if type(wp) == "table" and wp.Transition and wp.Transition.Kind == "Climb" then
			local outcome = UniversalNav.Roblox.ClimbExecutor.run(wp.Transition, {
				Root = myRoot,
				Humanoid = function() return hum end,
				Move = function(dir)
					run.moveDir = dir.Magnitude > 0.01 and dir or nil
					if danger.canMove() then player:Move(dir, false) end
				end,
				Jump = jumpNow,
				Active = function() return run.active end,
			})
			if not run.active then return "stopped" end
			if outcome.Status ~= "done" then
				danger.log(string.format("climb failed in %s after %.1f studs, held %.1f, %s, %.1f below crest, foot %s", tostring(outcome.Phase), outcome.Rise or 0, outcome.Held or 0, tostring(outcome.State), outcome.BelowCrest or 0, tostring(outcome.Foot)))
				danger.legFailed(run, wp, outcome, "in " .. tostring(outcome.Phase))
				return "replan"
			end
			danger.legDone(wp, outcome)
			local foot = wp.Transition.Data.Affordance.Face
			danger.traps[danger.goalKey(foot)] = nil
			continue
		end
		if type(wp) == "table" and wp.Transition and wp.Transition.Kind == "Jump" then
			local outcome = UniversalNav.Roblox.JumpExecutor.run(wp.Transition, {
				Root = myRoot,
				Humanoid = function() return hum end,
				Move = function(dir)
					run.moveDir = dir.Magnitude > 0.01 and dir or nil
					if danger.canMove() then player:Move(dir, false) end
				end,
				Jump = function()
					lastHop = os.clock()
					hum:ChangeState(Enum.HumanoidStateType.Jumping)
				end,
				Active = function() return run.active end,
				Lift = danger.lift,
			})
			if not run.active then return "stopped" end
			if outcome.Status ~= "done" then
				danger.log(string.format("jump failed in %s, %.1f off, %.1f below, held %.1f", tostring(outcome.Phase), outcome.Off or 0, outcome.Below or 0, outcome.Held or 0))
				danger.legFailed(run, wp, outcome, "in " .. tostring(outcome.Phase))
				return "replan"
			end
			danger.legDone(wp, outcome)
			continue
		end
		local target = wp.Position + Vector3.new(0, 1.5, 0)
		local final = i == last
		local climbLeg = wp.Action == Enum.PathWaypointAction.Jump or wp.Label == "Climb"
		if wp.Action == Enum.PathWaypointAction.Jump then
			local r = myRoot()
			if r then
				jumpNow(true)
			end
		end

		local lastPos, lastFlat = nil, nil
		local closing = nil
		local bestFlat, bestAt = math.huge, os.clock()
		while true do
			if not run.active then return "stopped" end
			if run.retarget and os.clock() - legStart > 0.4 then return "retarget" end
			if not run.valid(run.target) then return "arrived" end
			local root = myRoot()
			if not root then return "stopped" end

			if hum.SeatPart then hum.Sit = false end
			if root.Anchored then root.Anchored = false end
			if state.autoCoin and not coin.bagFull then coin.sweep(root) end
			local speed = math.clamp(run.speed or state.coinSpeed, 16, 25)
			local here = root.Position
			local flat = danger.flat(target, here).Magnitude
			local dy = target.Y - here.Y
			local dt = RunService.Heartbeat:Wait()
			local step = math.max(1, speed * dt * 1.5)
			local reach = final and step
				or (i < last and points[i + 1].Action == Enum.PathWaypointAction.Jump) and math.max(1.5, step)
				or math.max(3, speed * dt * 1.2)
			if flat < reach and dy < 1.5 and dy > -7 then break end
			if not final and flat < 1.5 and dy < -6 then break end
			if flat < 3 and dy >= 1.5 then
				fix.overhead = (fix.overhead or 0) + dt
				if fix.overhead > 0.35 then
					if not danger.legFailed(run, wp, nil, "overhead") then danger.wedged(here) end
					return "replan"
				end
			else
				fix.overhead = 0
			end

			local now = os.clock()
			if not final and not climbLeg and now - (fix.lookAt or 0) > 0.15 then
				fix.lookAt = now
				local j = i
				while j < last and j < i + 3 do
					local ahead = points[j + 1]
					if ahead.Action ~= Enum.PathWaypointAction.Walk or ahead.Label == "Climb" then break end
					if (ahead.Position - here).Magnitude > 12 or not danger.straight(here, ahead.Position) then break end
					j += 1
				end
				if j > i then
					i = j
					wp = points[i]
					run.leg = i
					target = wp.Position + Vector3.new(0, 1.5, 0)
					final = i == last
					flat = danger.flat(target, here).Magnitude
					dy = target.Y - here.Y
					bestFlat, bestAt = flat, now
				end
			end
			local goal = target
			if final and flat < math.max(3, step) and dy < 1.5 and dy > -7 then
				closing = closing or now
				if run.moveDir then
					goal = here + run.moveDir * 6
					if danger.flat(target, here):Dot(run.moveDir) < 0 then break end
				end
				if now - closing > 0.4 then break end
			end
			local climb = climbLeg and dy > 2
			if flat > 3 and not climb then
				local ahead = danger.flat(goal, here)
				if ahead.Magnitude > 0.01 then
					local bent, hop, wall = danger.steerClear(root, ahead.Unit, fix)
					if wall and not lineIsClear(here, target) and now - bestAt > 0.5 then
						fix.wallTime = (fix.wallTime or 0) + dt
						if fix.wallTime > 0.5 then
							local hit = fix.wallHit and fix.wallHit.Instance
							if not danger.legFailed(run, wp, nil, "wall " .. (hit and (hit.Parent and hit.Parent.Name .. "." or "") .. hit.Name or "?")) then danger.wedged(here) end
							run.replans = (run.replans or 0) + 1
							return run.replans >= 2 and "stuck" or "replan"
						end
					else
						fix.wallTime = 0
					end
					if hop and hum.FloorMaterial ~= Enum.Material.Air then
						jumpNow(true)
					elseif not bent then
						goal = nil
					elseif bent ~= ahead.Unit then
						goal = here + bent * 6
					end
				end
			end
			if goal then
				drive(run, root, hum, goal, speed)
			else
				local back = lastPos and (root.Position - lastPos) or Vector3.zero
				back = Vector3.new(back.X, 0, back.Z)
				local out = back.Magnitude > 0.05 and -back.Unit or (run.moveDir and -run.moveDir) or -root.CFrame.LookVector
				if not danger.roomAhead(here, out, 4) then
					local trail = run.trail
					for k = #trail, math.max(#trail - 4, 1), -1 do
						local away = trail[k] - here
						away = Vector3.new(away.X, 0, away.Z)
						if away.Magnitude > 3 and danger.roomAhead(here, away.Unit, 4) then
							out = away.Unit
							break
						end
					end
				end
				drive(run, root, hum, root.Position + out * 6, speed)
				fix.stalled += dt
			end

			local flatNow = danger.flat(target, root.Position).Magnitude
			local moved = lastFlat and (lastFlat - flatNow) or speed * dt
			if hum:GetState() == Enum.HumanoidStateType.Climbing then
				moved = (lastPos and root.Position.Y - lastPos.Y > 0.05) and speed * dt or 0
			end
			fix.pen = fix.pen or here
			if (here - fix.pen).Magnitude > 6 then
				fix.pen, fix.penned = here, 0
			else
				fix.penned = (fix.penned or 0) + dt
			end
			lastPos = root.Position
			lastFlat = flatNow
			if moved < speed * dt * 0.25 then
				fix.stalled += dt
				fix.progress = 0
			else
				fix.stalled = 0
				fix.progress += dt
				if fix.progress > 0.6 then fix.level = 0 end
				local trail = run.trail
				if hum.FloorMaterial ~= Enum.Material.Air and (#trail == 0 or (trail[#trail] - here).Magnitude >= 3) then
					table.insert(trail, here)
					if #trail > 30 then table.remove(trail, 1) end
				end
			end
			if (fix.penned or 0) > 1.5 then
				if not danger.legFailed(run, wp, nil, "penned") then danger.wedged(root.Position) end
				run.replans = (run.replans or 0) + 1
				return run.replans >= 2 and "stuck" or "replan"
			end
			if flatNow < bestFlat - 1.5 then
				bestFlat, bestAt = flatNow, now
				fix.noGain = 0
			else
				fix.noGain = (fix.noGain or 0) + dt
				if fix.noGain > 1.2 then
					if not danger.legFailed(run, wp, nil, "no gain") then danger.wedged(root.Position) end
					run.replans = (run.replans or 0) + 1
					return run.replans >= 2 and "stuck" or "replan"
				end
				if now - bestAt > 0.8 then
					fix.stalled = STALL_SECONDS
					bestAt = now - 0.4
				end
			end
			if fix.stalled >= STALL_SECONDS then
				fix.stalled = 0
				local fixed = unstick(fix, hum)
				if fixed == "replan" then
					if not danger.legFailed(run, wp, nil, "stall") then danger.wedged(root.Position) end
					run.replans = (run.replans or 0) + 1
					return run.replans >= 2 and "stuck" or "replan"
				end
			end
		end
	end
	return "arrived"
end

function danger.leg(run, legs, hum, watch)
	local ok, outcome = pcall(travel, run, legs, hum)
	if watch then watch:Disconnect() end
	if not ok then error(outcome, 0) end
	return outcome
end

local nav = { ready = false, count = 0, map = nil, calls = 0, used = 0, stats = {}, world = nil, navigator = nil, agent = nil }

function nav.budget(cheap)
	local seen = cheap and nav.costCheap or nav.costFull
	if not seen then return cheap and 600 or 3000 end
	return math.clamp(math.floor(seen * 4), cheap and 600 or 3000, 250000)
end

function nav.spent(cheap, expanded, why)
	local seen = cheap and nav.costCheap or nav.costFull
	local worst = math.max(expanded or 0, seen or 0)
	if why == "cap" then worst = math.max(worst, (seen or 0) * 2, expanded * 2) end
	local blend = seen and (seen * 0.8 + worst * 0.2) or worst
	if cheap then nav.costCheap = blend else nav.costFull = blend end
end

------------------------------------------------------------------------------------------ Navigation
-- The map as a UniversalNav lattice, and routes priced to keep off the murderer's ground.
function nav.reset()
	if nav.world then nav.world:Abort() end
	nav.world, nav.navigator, nav.map, nav.ready, nav.count = nil, nil, nil, false, 0
end

function nav.live()
	if not nav.ready or not nav.map then return false end
	if nav.map.Parent == nil then
		-- the map this lattice was built from is gone; the nodes describe dead geometry
		nav.ready = false
		return false
	end
	return nav.world ~= nil and nav.world.model == nav.map
end

function nav.ignore()
	local list = {}
	for _, who in Players:GetPlayers() do
		if who.Character then table.insert(list, who.Character) end
	end
	for _, child in Workspace:GetChildren() do
		if child:IsA("Model") and child:FindFirstChildOfClass("Humanoid") then table.insert(list, child) end
	end
	local map = getMap()
	if map then
		for _, child in map:GetChildren() do
			if child:IsA("Model") and child:FindFirstChildOfClass("Humanoid") then table.insert(list, child) end
		end
	end
	return list
end

function nav.speed()
	return math.clamp(coinRun and coinRun.speed or state.coinSpeed, 16, 25)
end

function nav.jumpV()
	local hum = myHumanoid()
	if not hum then return 50 end
	if hum.UseJumpPower then return hum.JumpPower end
	return math.sqrt(2 * Workspace.Gravity * hum.JumpHeight)
end

function nav.body()
	local char = myChar()
	if not char then return 2, 4.5 end
	local widest, lowest, highest = 0, nil, nil
	for _, part in char:GetChildren() do
		if part:IsA("BasePart") and part.Name ~= "Handle" then
			widest = math.max(widest, part.Size.X, part.Size.Z)
			local half = part.Size.Y / 2
			highest = highest and math.max(highest, part.Position.Y + half) or (part.Position.Y + half)
			lowest = lowest and math.min(lowest, part.Position.Y - half) or (part.Position.Y - half)
		end
	end
	if not lowest or widest <= 0 then return 2, 4.5 end
	return math.max(widest, 1), math.max(highest - lowest, 2)
end

function nav.build(map)
	nav.reset()
	nav.map = map
	local radius, height = nav.body()
	local agent = UniversalNav.Roblox.HumanoidAdapter.new({ Humanoid = myHumanoid, Speed = nav.speed, JumpVelocity = nav.jumpV, Radius = radius, Height = height })
	local envelope = agent:JumpEnvelope()
	local world = UniversalNav.World.SurfaceLattice.new({
		Model = map,
		Geometry = UniversalNav.Roblox.WorkspaceGeometry.new({ Ignore = nav.ignore }),
		Lift = agent:Lift(),
		Reach = envelope.MaxFlat,
		Rise = envelope.MaxUp,
		Step = agent:Step(),
	})
	nav.world = world
	nav.agent = agent
	nav.navigator = UniversalNav.Navigator.new({ World = world })
	local ok = world:Build()
	if nav.world ~= world then return end
	nav.count = world.Count
	nav.ready = ok
	if ok then
		task.spawn(nav.warm, world)
	else
		-- the model died mid-scan, or produced nothing: let the tick try again at once
		nav.map = nil
	end
end

function nav.warm(world)
	nav.warmed = 0
	while nav.world == world and nav.live() do
		local root = myRoot()
		local from = root and not inLobby() and root.Position
		if not from then
			local spawns = nav.map and nav.map:FindFirstChild("Spawns")
			local spawn = spawns and spawns:FindFirstChildWhichIsA("BasePart")
			from = spawn and spawn.Position
		end
		if from then
			nav.warmed += nav.navigator:Warm({ Agent = nav.agent, Position = from, Nodes = math.min(nav.budget(true), 2000), Budget = 0.002, Active = function() return nav.world == world end })
		end
		task.wait(0.5)
	end
end

function danger.legFailed(run, wp, outcome, why)
	if not (nav.live() and nav.navigator and type(wp) == "table" and wp.Transition) then return false end
	nav.navigator:Report(wp.Transition, outcome or false)
	local at = wp.Position
	run.learned = string.format("%s %s at (%.0f,%.0f,%.0f)", wp.Transition.Kind, why or "failed", at.X, at.Y, at.Z)
	return true
end

function danger.legDone(wp, outcome)
	if nav.live() and nav.navigator and type(wp) == "table" and wp.Transition then nav.navigator:Report(wp.Transition, outcome) end
end

function danger.lift()
	return nav.agent:Lift()
end

function danger.straight(here, floorPoint)
	if not nav.live() then return false end
	local lift = nav.agent:Lift()
	local ctx = { Agent = nav.agent, Geometry = nav.world.geometry, World = nav.world }
	return UniversalNav.Traversal.Ground.Between(here - Vector3.new(0, 3 - lift, 0), floorPoint + Vector3.new(0, lift, 0), ctx) ~= nil
end

function danger.roomAhead(from, dir, want)
	if not nav.live() then return true end
	local lift = nav.agent:Lift()
	local ctx = { Agent = nav.agent, Geometry = nav.world.geometry, World = nav.world }
	return UniversalNav.Steering.Room(from - Vector3.new(0, 3 - lift, 0), dir, ctx, want + 1) >= want
end

function danger.bendAround(from, dir, memo)
	if not nav.live() then return nil end
	local lift = nav.agent:Lift()
	local ctx = { Agent = nav.agent, Geometry = nav.world.geometry, World = nav.world }
	local bent = UniversalNav.Steering.Heading(from - Vector3.new(0, 3 - lift, 0), dir, ctx, memo)
	if not bent or bent == dir then return nil end
	return bent
end

function danger.push(run, root, dir)
	if not dir or not run or not run.active or coinRun ~= run or not danger.canMove() then return end
	dir = Vector3.new(dir.X, 0, dir.Z)
	if dir.Magnitude < 0.01 then return end
	dir = dir.Unit
	run.bendMemo = run.bendMemo or {}
	if not danger.roomAhead(root.Position, dir, 3) then
		dir = danger.bendAround(root.Position, dir, run.bendMemo) or dir
	end
	run.moveDir = dir
	local hum = myHumanoid()
	if hum then hum.WalkSpeed = run.speed or state.speed end
	player:Move(dir, false)
end

function danger.steerClear(root, dir, fix)
	if not nav.live() then return dir, false, false end
	local lift = nav.agent:Lift()
	local from = root.Position - Vector3.new(0, 3 - lift, 0)
	local ctx = { Agent = nav.agent, Geometry = nav.world.geometry, World = nav.world }
	fix.memo = fix.memo or {}
	local bent, _, blocker = UniversalNav.Steering.Heading(from, dir, ctx, fix.memo)
	if bent == dir then return dir, false, false end
	fix.wallHit = blocker
	if danger.canStepOver(root, dir) then return dir, true, false end
	if bent then return bent, false, true end
	return nil, false, true
end

function nav.blocked(s)
	return (danger.traps[danger.goalKey(s.Position)] or 0) > os.clock()
end

function danger.lethal(pos, within)
	return nav.navigator ~= nil and nav.navigator:Lethal(pos, within, 1)
end

function nav.costFor(him, me, careful)
	return {
		Of = function(t)
			local cost = t.Time + t.Risk * 3
			if careful and t.Kind == "Jump" then cost += 1.5 end
			if him then
				local p = t.To.Position
				if math.abs(p.Y - him.Y) < 10 then
					local his = danger.flat(p, him).Magnitude
					if his < 30 and his < danger.flat(p, me).Magnitude then cost += 4 end
				end
			end
			return cost
		end,
		Heuristic = UniversalNav.Cost.Fastest.Heuristic,
	}
end

function nav.openness(pos)
	if not nav.live() then return 0 end
	local count = 0
	for _, n in nav.world:Nearby(pos, 24) do
		if math.abs(n.Position.Y - pos.Y) <= 6 then count += 1 end
	end
	return count
end

function nav.route(from, goal, cheap)
	if not nav.live() then return nil end
	nav.calls += 1
	local foe = danger.foe()
	local gap = foe and danger.gap(from, foe) or math.huge
	local policies = UniversalNav.ProbePolicies
	local policy = cheap and policies.Never or policies.Conservative
	local search = { MaxExpansions = nav.budget(cheap), TimeSlice = gap < 60 and 0.008 or 0.005 }
	local him = (not cheap and foe and danger.root() ~= nil) and foe.Position or nil
	local result = nav.navigator:FindPath({ Agent = nav.agent, Start = from, Goal = goal, Blocked = nav.blocked, SearchPolicy = search, ProbePolicy = policy, Cost = nav.costFor(him, from, gap < 90) })
	local st = result.Stats
	nav.stats = { why = result.Why, expanded = st.Expanded, ms = st.Ms, legs = result.Path and #result.Path or 0, jumps = 0, req = st.Requests, hits = st.Hits, rays = st.Rays, casts = st.Casts, probing = result.Probing }
	nav.lastTime = result.Time
	nav.spent(cheap, st.Expanded, result.Why)
	if not result.Path then return nil end
	local legs = {}
	for _, t in result.Path do
		if t.Kind == "Jump" then nav.stats.jumps += 1 end
		local to = t.To
		table.insert(legs, { Position = to.Lattice and to.Floor or to.Position, Action = t.Kind == "Jump" and Enum.PathWaypointAction.Jump or Enum.PathWaypointAction.Walk, Label = t.Kind == "Climb" and "Climb" or "", Transition = t })
	end
	return legs
end

function danger.route(threat)
	local root = myRoot()
	if not root then return end
	danger.routing = true
	local path = danger.path(2, 6)
	local ok = pcall(path.ComputeAsync, path, threat.Position, root.Position)
	local len = math.huge
	danger.approach = nil
	if ok and path.Status == Enum.PathStatus.Success then
		len = 0
		local pts = path:GetWaypoints()
		for i = 2, #pts do len += (pts[i].Position - pts[i - 1].Position).Magnitude end
		if #pts >= 2 then danger.approach = pts[math.max(#pts - 2, 1)].Position end
	elseif (danger.routeDud or 0) < os.clock() then
		local legs = nav.route(threat.Position, root.Position, true)
		if legs then
			len = 0
			local last = threat.Position
			for _, wp in legs do
				len += (wp.Position - last).Magnitude
				last = wp.Position
			end
			if #legs >= 2 then danger.approach = legs[math.max(#legs - 2, 1)].Position end
		else
			danger.routeDud = os.clock() + 2
		end
	end
	danger.pathLen, danger.pathAt, danger.pathFor = len, os.clock(), threat
	danger.routing = false
end

local function legsTo(from, goal, ignore)
	local finalLeg = { Position = goal, Action = Enum.PathWaypointAction.Walk, Label = "" }
	local direct = nav.live() and nav.navigator:DirectTransition({ Agent = nav.agent, Start = from, Goal = goal })
	if direct then
		return { {
			Position = goal,
			Action = direct.Kind == "Jump" and Enum.PathWaypointAction.Jump or Enum.PathWaypointAction.Walk,
			Label = direct.Kind == "Climb" and "Climb" or "",
			Transition = direct,
		} }
	end
	if not nav.live() and lineIsClear(from, goal, ignore) then return { finalLeg } end
	local best, bestTime = nil, math.huge
	-- The lattice router measured 0.5ms; PathfindingService measured 101.9ms on
	-- the same query and returned NoPath. Ask the cheap one first and only pay
	-- for the expensive one when the lattice cannot answer.
	local quick = nav.route(from, goal)
	if quick then
		nav.used += 1
		return quick
	end
	if state.coinPath and (danger.traps[danger.goalKey(from)] or 0) < os.clock() then
		local rp = excludeMe()
		if ignore then rp.FilterDescendantsInstances = { myChar(), ignore } end
		local floor = Workspace:Raycast(goal, Vector3.new(0, -12, 0), rp)
		local legs = routeTo(from, floor and floor.Position or goal)
		if legs and not danger.throughTrap(legs) then
			local climbs, length, prev = 0, 0, from
			for _, wp in legs do
				if wp.Label == "Climb" or wp.Action == Enum.PathWaypointAction.Jump then climbs += 1 end
				length += (wp.Position - prev).Magnitude
				prev = wp.Position
			end
			table.insert(legs, finalLeg)
			best, bestTime = legs, length / nav.speed() + climbs * 1.5
		end
	end
	local legs = nav.route(from, goal)
	if legs and nav.lastTime < bestTime then
		nav.used += 1
		best = legs
	end
	return best
end

function danger.reachable(here, goal)
	if not nav.live() then return true end
	if danger.straight(here, goal) then return true end
	local from = nav.world:NodeAt(here, 8)
	local to = nav.world:NodeAt(goal, 8)
	if not from or not to then return false end
	local a, b = nav.world:Piece(from), nav.world:Piece(to)
	return a ~= nil and a == b
end

local function newRun(target, valid, kind)
	local run = { active = true, kind = kind, target = target, targetDist = math.huge, retarget = false, trail = {}, moveDir = nil, valid = valid }
	run.stepConn = RunService.RenderStepped:Connect(function()
		if run.active and coinRun == run and run.moveDir and danger.canMove() then player:Move(run.moveDir, false) end
	end)
	coinRun = run
	danger.run = run
	return run
end

function danger.handoff(target, valid, kind)
	stopCoinRun()
	while coinRun do RunService.Heartbeat:Wait() end
	return newRun(target, valid, kind)
end

------------------------------------------------------------------------------------------- Coin runs
-- The auto coin loop.
local function coinLoop(run)
	local hum = borrowMovement()
	if not hum then return "no character" end
	local lastCheck = 0

	while run.active do
		RunService.Heartbeat:Wait()
		local now = os.clock()
		if now - lastCheck > 0.25 then
			lastCheck = now
			local ok, why = canAct()
			if not ok then return why end
		end
		local root = myRoot()
		if not root then return "no character" end

		local target, dist = nearestCoin(root.Position, now)
		if not target then
			run.idle = true
			local waited = 0
			while run.active and waited < 3 and not nearestCoin(root.Position, os.clock()) do
				if not run.wanderDir or os.clock() > (run.wanderUntil or 0) or not danger.roomAhead(root.Position, run.wanderDir, 4) then
					run.wanderDir = danger.openDir(root, danger.root()) or run.moveDir or root.CFrame.LookVector
					run.wanderUntil = os.clock() + 2
				end
				danger.push(run, root, run.wanderDir)
				waited += RunService.Heartbeat:Wait()
			end
			run.idle = false
			run.moveDir = nil
			if not nearestCoin(root.Position, os.clock()) then return "no coins on the map" end
			continue
		end

		if run.target and coinValid(run.target) and (coin.skipped[run.target] or 0) < now then
			local heldDist = (run.target.Position - root.Position).Magnitude
			if heldDist <= (dist or math.huge) * 1.6 then target, dist = run.target, heldDist end
		end
		if target ~= run.target then run.replans = 0 end
		run.target, run.targetDist, run.retarget = target, dist, false
		local legs = legsTo(root.Position, target.Position)
		local threat = danger.root()
		if legs and threat and not danger.routeSafe(legs, root.Position, threat) then
			coin.skipped[target] = os.clock() + 6
			continue
		end
		if not legs then
			coin.skipped[target] = os.clock() + 15
			continue
		end
		local outcome = travel(run, legs, hum)

		if outcome == "stopped" then return nil end
		if outcome == "stuck" then
			coin.skipped[target] = os.clock() + 10
		elseif outcome == "arrived" and coinValid(target) then
			coin.skipped[target] = os.clock() + 3
		end
	end
	return nil
end

local function startCoinRun()
	if coinRun then return false, "already collecting" end
	local ok, why = canAct()
	if not ok then return false, why end
	if #coinParts() == 0 then return false, "no coins on the map" end

	local run = newRun(nil, coinValid, "coins")
	task.spawn(function()
		local okRun, result = pcall(coinLoop, run)
		finishRun()
		if not okRun then
			say("collect error: " .. tostring(result), "triangle-alert", "danger")
		elseif result and state.autoCoin then
			say(result, "circle-dollar-sign", "muted")
		end
	end)
	return true
end

local grab = { walking = false, nextTry = 0, failed = {} }

local function gunStillThere(gun)
	return gun.Parent ~= nil and gun:IsDescendantOf(Workspace)
end

local function touchGun(gun)
	local root = myRoot()
	if not root then return false end
	firetouchinterest(root, gun, 0)
	RunService.Heartbeat:Wait()
	firetouchinterest(root, gun, 1)
	task.wait(0.3)
	return findTool("Gun") ~= nil
end

local function grabDroppedGun()
	if findTool("Gun") then return false, "already have a gun" end
	if grab.walking then return false, "already walking to it" end
	if os.clock() < grab.nextTry then return false, "tried a moment ago" end
	local root = myRoot()
	if not root then return false, "no character" end
	local gun, dist = nearestGun(root.Position)
	if not gun then return false, "no gun on the ground" end
	local failed = grab.failed[gun]
	if failed and os.clock() < failed.until_ then return false, "that gun is out of reach" end
	local able, why = canAct()
	if not able then return false, why end
	if not legitOn("Walking to the dropped gun") then
		grab.nextTry = os.clock() + 0.5
		if touchGun(gun) then return true end
		if not gunStillThere(gun) then return false, "the gun is gone" end
	end
	if danger.fleeing then return false, "still getting away" end
	local threat = danger.root()
	if threat then
		if danger.gap(root.Position, threat) < math.max(danger.near, dist) or danger.gap(gun.Position, threat) < 45 or danger.pathGap(root.Position, gun.Position, threat) < 25 then
			return false, "the murderer is too close to the gun"
		end
		if (threat.Position - gun.Position).Magnitude < 30 or danger.walkLength(threat.Position, gun.Position) < 60 then
			return false, "the murderer is too close to the gun"
		end
	end

	grab.walking = true
	grab.cut = false
	grab.nextTry = os.clock() + 2
	task.spawn(function()
		local run
		local okRun, err = pcall(function()
			if not legitOn("Walking to the dropped gun") and touchGun(gun) then return end
			if not gunStillThere(gun) then return end
			run = danger.handoff(gun, gunStillThere, "gun")
			run.targetDist = dist
			local hum = borrowMovement()
			if not hum then return end
			local until_ = os.clock() + 45
			while run.active and gunStillThere(gun) and os.clock() < until_ do
				if not canAct() or not legitOn("Walking to the dropped gun") then break end
				local from = myRoot()
				if not from then break end
				local foe = danger.root()
				local legs = legsTo(from.Position, gun.Position)
				if legs and foe and not danger.routeSafe(legs, from.Position, foe) then legs = nil end
				if not legs then
					if foe and danger.gap(from.Position, foe) < danger.safe then
						danger.push(run, from, danger.openDir(from, foe) or run.moveDir)
					else
						run.moveDir = nil
						player:Move(Vector3.zero, false)
					end
					RunService.Heartbeat:Wait()
					task.wait(0.5)
					continue
				end
				run.retarget = false
				local watch = RunService.Heartbeat:Connect(function()
					local r, t = myRoot(), danger.root()
					if not r or not t then return end
					if danger.gap(r.Position, t) < 40 or danger.pathGap(r.Position, gun.Position, t) < 25 then run.retarget = true end
				end)
				local outcome = danger.leg(run, legs, hum, watch)
				run.moveDir = nil
				if outcome == "stopped" then
					grab.cut = true
					break
				end
				if outcome == "arrived" and gunStillThere(gun) then
					touchGun(gun)
					break
				end
				if outcome == "stuck" then break end
			end
		end)
		if run then finishRun() end
		grab.walking = false
		if not okRun then
			say("gun error: " .. tostring(err), "triangle-alert", "danger")
		elseif findTool("Gun") then
			grab.failed[gun] = nil
			bump("gunsGrabbed")
			say("Grabbed the gun", "package", "accent")
		elseif gunStillThere(gun) and not grab.cut then
			local f = grab.failed[gun] or { count = 0 }
			f.count += 1
			f.until_ = os.clock() + math.min(4 * f.count, 15)
			grab.failed[gun] = f
			if f.count == 1 then say("Could not reach the gun", "package", "danger") end
		end
	end)
	return true, string.format("%.0f studs away", dist)
end

function sniper.legsToward(root, who, target)
	local them = target.Position
	local goal = them
	local legs = legsTo(root.Position, goal, who.Character)
	for _, part in { 0.75, 0.5, 0.25 } do
		if legs then break end
		local mid = root.Position:Lerp(them, part)
		local floor = danger.floorAt(mid.X, math.max(mid.Y, root.Position.Y) + 6, mid.Z)
		if floor then
			goal = floor + Vector3.new(0, 2, 0)
			legs = legsTo(root.Position, goal, who.Character)
		end
	end
	return legs, goal
end

local function pursue(who, reach)
	local function alive()
		return hitPartOf(who) ~= nil and not isDead(who)
	end
	local root0, target0 = myRoot(), hitPartOf(who)
	if not root0 or not target0 then return false end
	if (target0.Position - root0.Position).Magnitude > reach and not sniper.legsToward(root0, who, target0) then
		sniper.noPath[who] = os.clock() + 1
		return false
	end
	danger.pursuing = true
	local run = danger.handoff(who, alive, "pursuit")
	run.weave = danger.armed(who)
	local hum = borrowMovement()
	if not hum then
		finishRun()
		return false
	end
	local reached = false
	local okLoop, errLoop = pcall(function()
	local until_ = os.clock() + 30
	while os.clock() < until_ do
		RunService.Heartbeat:Wait()
		if not run.active or not alive() then break end
		local root, target = myRoot(), hitPartOf(who)
		if not root or not target then break end
		if (target.Position - root.Position).Magnitude <= reach then
			reached = true
			break
		end
		local them = target.Position
		local legs, goal = sniper.legsToward(root, who, target)
		if not legs then
			sniper.noPath[who] = os.clock() + 1
			break
		end
		run.retarget = false
		local watch = RunService.Heartbeat:Connect(function()
			local t, r = hitPartOf(who), myRoot()
			if not t or not r then return end
			local gap = (t.Position - r.Position).Magnitude
			run.weaveNear = gap < 60
			if gap <= reach or (t.Position - them).Magnitude > math.max(gap * 0.35, 8) then
				run.retarget = true
			end
		end)
		local outcome = danger.leg(run, legs, hum, watch)
		if outcome == "stopped" or outcome == "stuck" then break end
	end
	end)
	finishRun(true)
	danger.pursuing = false
	if not okLoop then error(errLoop, 0) end
	return reached
end

------------------------------------------------------------------------------------------------ Flee
-- Escape goals he cannot cut us off from, and the dash used when he is on top of us.
function danger.openDir(root, threat)
	local here = root.Position
	local rp = excludeMe()
	if threat and threat.Parent then rp.FilterDescendantsInstances = { myChar(), threat.Parent } end
	rp.RespectCanCollide = true
	local toThem = threat and danger.flat(threat.Position, here)
	toThem = toThem and toThem.Magnitude > 0.01 and toThem.Unit or nil
	local best, bestFree
	for turn = 0, 330, 30 do
		local dir = CFrame.Angles(0, math.rad(turn), 0) * root.CFrame.LookVector
		dir = Vector3.new(dir.X, 0, dir.Z).Unit
		if not toThem or dir:Dot(toThem) < -0.3 or (threat and (threat.Position - here).Magnitude > 60 and dir:Dot(toThem) < 0.3) then
			local hit = Workspace:Raycast(here + Vector3.new(0, 1, 0), dir * 30, rp)
			local free = hit and (hit.Position - here).Magnitude or 30
			if free >= 8 and (not bestFree or free > bestFree) then best, bestFree = dir, free end
		end
	end
	return best
end

function danger.breakout(root, threat)
	local here = root.Position
	local from = danger.threatFrom(here, threat)
	local away = danger.flat(here, from)
	local dist = away.Magnitude
	away = dist > 0.01 and away / dist or root.CFrame.LookVector
	local rp = excludeMe()
	rp.FilterDescendantsInstances = { myChar(), threat.Parent }
	rp.RespectCanCollide = true
	local vel = root.AssemblyLinearVelocity
	local heading = Vector3.new(vel.X, 0, vel.Z)
	heading = heading.Magnitude > 4 and heading.Unit or nil
	local best, bestScore, bestFree, bestDot
	local rays = {}
	for turn = 0, 330, 30 do
		local dir = CFrame.Angles(0, math.rad(turn), 0) * away
		local hit = Workspace:Raycast(here + Vector3.new(0, 1, 0), dir * 60, rp)
		local free = hit and (hit.Position - here).Magnitude or 60
		local dot = dir:Dot(away)
		table.insert(rays, { dir = dir, free = free, dot = dot })
		if dot > 0.3 and free >= 12 then
			local score = math.min(free, 40) * (0.3 + 0.7 * dot)
			if heading and dir:Dot(heading) > 0.5 then score *= 1.3 end
			if not bestScore or score > bestScore then best, bestScore, bestFree, bestDot = dir, score, free, dot end
		end
	end
	if not best and dist < 16 then
		for _, r in rays do
			local lateral = math.abs(r.dir:Cross(away).Y) * dist
			if r.dot <= -0.2 and r.free > dist + 12 and lateral >= 10 then
				local score = r.free * (0.5 + lateral / 8)
				if not bestScore or score > bestScore then best, bestScore, bestFree, bestDot = r.dir, score, r.free, r.dot end
			end
		end
	end
	local function endGap(r)
		return (here + r.dir * math.min(r.free - 3, 40) - threat.Position).Magnitude
	end
	if not best then
		for _, r in rays do
			if r.dot > -0.2 and r.free >= 8 and endGap(r) >= dist - 2 and (not bestScore or r.free > bestScore) then best, bestScore, bestFree, bestDot = r.dir, r.free, r.free, r.dot end
		end
	end
	if not best then
		for _, r in rays do
			local gapAfter = endGap(r)
			if r.free >= 3 and (not bestScore or gapAfter > bestScore) then best, bestScore, bestFree, bestDot = r.dir, gapAfter, r.free, r.dot end
		end
		if not best then return nil end
		jumpNow()
	end
	local goal = here + best * math.min(bestFree - 3, 40)
	return { { Position = goal, Action = Enum.PathWaypointAction.Walk, Label = "" } }, goal
end

function danger.goalKey(goal)
	return string.format("%d,%d,%d", math.floor(goal.X / 8), math.floor(goal.Y / 8), math.floor(goal.Z / 8))
end

function danger.hazard(pos)
	if not nav.navigator then return end
	local part = danger.foe()
	if not part or (part.Position - pos).Magnitude < 60 then return end
	nav.navigator:ReportLethal(pos)
end

function danger.wedged(pos)
	local now = os.clock()
	local hits = danger.trapHits
	for i = #hits, 1, -1 do
		if now - hits[i].at > 20 then table.remove(hits, i) end
	end
	for i, hit in hits do
		if (hit.pos - pos).Magnitude < 10 then
			danger.traps[danger.goalKey(hit.pos)] = now + 30
			danger.traps[danger.goalKey(pos)] = now + 30
			table.remove(hits, i)
			return true
		end
	end
	table.insert(hits, { pos = pos, at = now })
	return false
end

function danger.throughTrap(legs)
	local now = os.clock()
	for _, wp in legs do
		if (danger.traps[danger.goalKey(wp.Position)] or 0) > now then return true end
	end
	return false
end

function danger.wayBack(root, trail)
	local now = os.clock()
	for i = #trail, 1, -1 do
		local point = trail[i]
		if (point - root.Position).Magnitude >= 12 and (danger.traps[danger.goalKey(point)] or 0) < now then
			local legs = legsTo(root.Position, point)
			if legs and not danger.throughTrap(legs) then return legs, point end
		end
	end
	return nil
end

function danger.fleeLegs(root, threat)
	local now = os.clock()
	local here = root.Position
	if danger.closeBy(here, threat, 18) and danger.gap(here, threat) < 18 then
		local legsOut, goalOut = danger.breakout(root, threat)
		if legsOut then return legsOut, goalOut end
	end
	local sticky = danger.fleeGoal and now - danger.fleeGoalAt < 6 and (danger.fleeGoal - here).Magnitude > 8 and danger.fleeGoal or nil
	if sticky then
		local keeps = danger.gap(sticky, threat) > danger.gap(here, threat)
			and danger.pathGap(here, sticky, threat) >= 26
		local legs = keeps and legsTo(here, sticky)
		if legs and danger.routeSafe(legs, here, threat) then return legs, sticky end
		if not keeps then danger.fleeGoal = nil end
	end
	local mine = (here - threat.Position).Magnitude
	local heading = danger.heading(threat)
	local best = {}
	nav.navigator:Reachable({
		Agent = nav.agent,
		Position = here,
		Reach = 200,
		Nodes = nav.budget(false),
		Blocked = nav.blocked,
		Score = function(state)
			local p = state.Position
			if (danger.badGoals[danger.goalKey(p)] or 0) > now then return nil end
			if danger.lethal(p, 12) then return nil end
			local run = (p - here).Magnitude
			if run < 10 then return nil end
			local his = danger.gap(p, threat)
			local score = math.min(his, 120) + math.min(run, 80) * 0.8
			-- getting out of sight is worth as much as getting far away
			if danger.exposed(p, threat) then score -= 70 end
			if his < math.max(mine, danger.safe) then score -= 60 end
			if his / 18 < run / math.max(state.coinSpeed or 22, 16) + 0.5 then score -= 80 end
			local hisWay = danger.flat(p, threat.Position)
			if heading and hisWay.Magnitude > 1 then score -= 40 * math.max(0, heading:Dot(hisWay.Unit)) end
			danger.keepBest(best, state.Lattice and state.Floor or p, score)
			return score
		end,
	})
	-- same cap as roaming: eight path computations in a row is a visible freeze
	local tried = 0
	for _, entry in best do
		tried += 1
		if tried > 2 then break end
		local at = entry.at + Vector3.new(0, 2, 0)
		local legs = legsTo(here, at)
		if legs and (entry.score < 0 or danger.routeSafe(legs, here, threat)) then
			if danger.fleeLast and (at - danger.fleeLast).Magnitude < 8 then
				danger.fleeBounce = (danger.fleeBounce or 0) + 1
				if danger.fleeBounce >= 2 then
					danger.badGoals[danger.goalKey(at)] = now + 10
					danger.fleeBounce = 0
					continue
				end
			else
				danger.fleeBounce = 0
			end
			danger.fleeLast = danger.fleeGoal
			danger.fleeGoal, danger.fleeGoalAt = at, now
			return legs, at
		end
		danger.badGoals[danger.goalKey(at)] = now + 2
	end
	return danger.breakout(root, threat)
end

function danger.flee(threat)
	danger.fleeing = true
	local run = danger.handoff(threat, function(t) return t.Parent ~= nil end, "flee")
	run.speed = 25
	local hum = borrowMovement()
	if hum then
		local until_ = os.clock() + 30
		while os.clock() < until_ do
			RunService.Heartbeat:Wait()
			local root = myRoot()
			if not run.active or not root or not threat.Parent then break end
			if danger.gap(root.Position, threat) > danger.safe then break end
			local legs = danger.fleeLegs(root, threat)
			if not legs then
				danger.fleeSkipUntil = os.clock() + 1
				break
			end
			run.retarget = false
			local legAt = os.clock()
			local watch = RunService.Heartbeat:Connect(function()
				local r = myRoot()
				if not r or not threat.Parent then return end
				local gap = danger.gap(r.Position, threat)
				if gap > danger.safe or os.clock() - legAt > 1.2 then run.retarget = true end
			end)
			local outcome = danger.leg(run, legs, hum, watch)
			if outcome == "stopped" or outcome == "stuck" then break end
		end
	end
	finishRun(true)
	danger.fleeing = false
end

function danger.floorAt(x, y, z)
	local ignore = {}
	for _, who in Players:GetPlayers() do
		if who.Character then table.insert(ignore, who.Character) end
	end
	for _ = 1, 4 do
		local rp = danger.rayIgnoring(ignore)
		local hit = Workspace:Raycast(Vector3.new(x, y, z), Vector3.new(0, -45, 0), rp)
		if not hit then return nil end
		if hit.Instance.Transparency < 0.99 and hit.Instance.CanCollide then return hit.Position end
		table.insert(ignore, hit.Instance)
	end
	return nil
end

function danger.coinPull(at)
	-- Wandering scored only distance, so the farthest corner always won and it
	-- walked the same circuit forever. Coins are the point of wandering.
	local near
	for _, part in coinParts() do
		local d = (part.Position - at).Magnitude
		if not near or d < near then near = d end
	end
	return near
end

function danger.exposed(at, threat)
	-- Standing where he can see you is its own cost, whatever the distance.
	if not threat or not threat.Parent then return false end
	local eye = threat.Position + Vector3.new(0, 1.5, 0)
	local rp = danger.rayIgnoring({ myChar(), threat.Parent })
	rp.RespectCanCollide = true
	return not Workspace:Raycast(eye, at + Vector3.new(0, 1, 0) - eye, rp)
end

function danger.roamLegs(root, threatRoot)
	local map = getMap()
	if not (map and nav.live()) then return nil end
	local here = root.Position
	local now = os.clock()
	local ahead = threatRoot and danger.ahead(threatRoot)
	local eyes = excludeMe()
	if threatRoot then eyes.FilterDescendantsInstances = { myChar(), threatRoot.Parent } end
	local mine = threatRoot and (here - threatRoot.Position).Magnitude or math.huge
	local function shortlist(avoid)
		local best = {}
		nav.navigator:Reachable({
			Agent = nav.agent,
			Position = here,
			Reach = 250,
			Nodes = nav.budget(false),
			Budget = 0.004,
			Blocked = nav.blocked,
			Score = function(state)
				local p = state.Position
				local run = danger.flat(p, here).Magnitude
				if run < 25 or run > 250 then return nil end
				if (danger.badGoals[danger.goalKey(p)] or 0) > now then return nil end
				if danger.lethal(p, 12) then return nil end
				-- Somewhere it just came from is worth less, but not worthless: a hard
				-- reject used to empty the shortlist and it would pick the same corner.
				local stale = 0
				for i, was in danger.beenTo do
					local gap = (p - was).Magnitude
					if gap < 30 then
						local recent = i > #danger.beenTo - 3 and 2 or 1
						stale += (30 - gap) * recent
					end
				end
				if avoid and stale > 45 then return nil end
				local score = math.min(run, 120) * 0.4 - stale
				-- walk toward coins, not just away from him
				local pull = danger.coinPull(p)
				if pull then score += math.max(0, 90 - pull) * 0.9 end
				if threatRoot then
					local his = (p - threatRoot.Position).Magnitude
					if his < math.min(math.max(mine - 10, danger.near), danger.safe) then return nil end
					if ahead and (p - ahead).Magnitude < 40 then return nil end
					score += math.min(his, 150) * 0.6
					-- do not stand in his eyeline while wandering
					if danger.exposed(p, threatRoot) then score -= 55 end
				end
				danger.keepBest(best, state.Lattice and state.Floor or p, score)
				return score
			end,
		})
		return best
	end
	local tries = shortlist(true)
	if #tries == 0 then tries = shortlist(false) end
	-- One legsTo can cost two path computations (~60ms). Eight of them in a row
	-- measured 800ms with the character standing still. Try the best couple and
	-- let the next tick carry on; roamDud already spaces the retries.
	local tried = 0
	for _, entry in tries do
		tried += 1
		if tried > 2 then break end
		local at = entry.at
		local seen = threatRoot and (at - threatRoot.Position).Magnitude < 90
			and not Workspace:Raycast(threatRoot.Position, at + Vector3.new(0, 1, 0) - threatRoot.Position, eyes)
		local legs = not seen and legsTo(here, at + Vector3.new(0, 2, 0))
		if legs and (not threatRoot or danger.routeSafe(legs, here, threatRoot)) then
			local been = danger.beenTo
			table.insert(been, at)
			if #been > 24 then table.remove(been, 1) end
			return legs, at + Vector3.new(0, 2, 0)
		end
		danger.badGoals[danger.goalKey(at)] = now + 1.5
	end
	return nil
end

function danger.farSpot(root, threat)
	local map = getMap()
	if not map or not nav.live() or not nav.world then return nil end
	local box = boundsOf(map)
	local centre = box.cf.Position
	local hx, hz = box.size.X * 0.42, box.size.Z * 0.42
	local here = root.Position
	local best, bestScore
	for ix = -2, 2 do
		for iz = -2, 2 do
			local x, z = centre.X + hx * ix / 2, centre.Z + hz * iz / 2
			local floor = danger.floorAt(x, here.Y + 8, z) or danger.floorAt(x, centre.Y + box.size.Y / 2 - 2, z)
			if floor then
				for _, n in nav.world:Nearby(floor + Vector3.new(0, nav.agent:Lift(), 0), 12) do
					local at = n.Floor or (n.Position - Vector3.new(0, nav.agent:Lift(), 0))
					local fromUs = (Vector3.new(at.X, 0, at.Z) - Vector3.new(here.X, 0, here.Z)).Magnitude
					local fromThem = (at - threat.Position).Magnitude
					if fromUs > 40 and danger.inBounds(at, box) and spotIsStandable(at + Vector3.new(0, 2, 0)) then
						local score = fromThem + math.min(fromUs, 60)
						if not bestScore or score > bestScore then best, bestScore = at, score end
					end
				end
			end
		end
	end
	return best
end

function danger.inBounds(at, box)
	local c, half = box.cf.Position, box.size / 2
	return math.abs(at.X - c.X) <= half.X - 4
		and math.abs(at.Z - c.Z) <= half.Z - 4
		and at.Y >= c.Y - half.Y and at.Y <= c.Y + half.Y
end

function danger.ledgeOut(root, threat)
	local here = root.Position
	local found = {}
	for turn = 0, 330, 30 do
		local dir = CFrame.Angles(0, math.rad(turn), 0) * Vector3.new(0, 0, -1)
		for _, dist in { 5, 9, 13 } do
			for up = 3, 6, 3 do
				local spot = here + dir * dist + Vector3.new(0, up, 0)
				local floor = danger.floorAt(spot.X, spot.Y + 1, spot.Z)
				if floor and spot.Y - floor.Y < 2.5 and floor.Y - here.Y > 2 and spotIsStandable(floor + Vector3.new(0, 2.5, 0)) then
					table.insert(found, { at = floor + Vector3.new(0, 2, 0), score = (floor.Y - here.Y) + dist * 0.5 })
					break
				end
			end
		end
	end
	table.sort(found, function(a, b) return a.score < b.score end)
	for i = 1, math.min(#found, 6) do
		local ledge = found[i].at
		if danger.roamLegs({ Position = ledge, CFrame = root.CFrame }, threat) then return ledge end
	end
	return nil
end

------------------------------------------------------------------------------------- Survive planner
-- One loop picking flee, coin or roam for each leg, never halting in between.
function danger.brain()
	danger.brainOn = true
	local map = getMap()
	if not map or not myRoot() then
		danger.brainOn = false
		return
	end
	local run = danger.handoff(nil, function() return true end, "survive")
	danger.goalNow, danger.modeNow = nil, nil
	local hum = borrowMovement()
	if not hum then
		finishRun()
		danger.brainOn = false
		return
	end
	local started, lastCheck, fled, stuckPos, stuckAt, lastGoal, goBack = os.clock(), 0, false, nil, 0, nil, false
	danger.brainExit = "running"
	danger.brainStart = started
	local note = danger.log
	note("start")
	while run.active do
		RunService.Heartbeat:Wait()
		local now = os.clock()
		if now - lastCheck > 0.25 then
			lastCheck = now
			local able, why = canAct()
			if not danger.wanting() or not able then
				danger.brainExit = "cannot act: " .. tostring(why or "not surviving")
				break
			end
		end
		local root = myRoot()
		if not root then
			danger.brainExit = "no root"
			break
		end
		if not stuckPos or (root.Position - stuckPos).Magnitude > 6 then
			stuckPos, stuckAt = root.Position, now
		elseif now - stuckAt > 1 then
			note("shake loose")
			danger.fleeGoal = nil
			if lastGoal then danger.badGoals[danger.goalKey(lastGoal)] = now + 12 end
			if run.target then coin.skipped[run.target] = now + 8 end
			local open = danger.breakout(root, danger.root() or root)
			local shake = open and (open[1].Position - root.Position).Unit or danger.openDir(root, danger.root())
			jumpNow()
			local until_ = os.clock() + 0.6
			repeat
				danger.push(run, root, shake)
				RunService.Heartbeat:Wait()
			until os.clock() >= until_ or not run.active
			stuckPos, stuckAt = nil, os.clock()
			continue
		end
		local threat = danger.root()
		local gap = threat and danger.gap(root.Position, threat) or math.huge
		if not threat or (gap >= 80 and not danger.closeBy(root.Position, threat, 45)) then fled = false end
		local legs, goal, mode
		if threat and (gap < danger.near or danger.closeBy(root.Position, threat, 18) or (fled and (gap < danger.safe or danger.closeBy(root.Position, threat, 40)))) then
			mode = "flee"
			fled = true
			if not legitOn("Running as innocent") and now - (danger.hopAt or 0) > 2 then
				local spot = danger.farSpot(root, threat)
				danger.hopAt = now
				if spot and legsTo(spot + Vector3.new(0, 2, 0), root.Position) then
					local was = root.CFrame
					root.CFrame = CFrame.new(spot + Vector3.new(0, 3, 0)) * root.CFrame.Rotation
					root.AssemblyLinearVelocity = Vector3.zero
					task.wait(0.15)
					local landed = danger.floorAt(root.Position.X, root.Position.Y + 2, root.Position.Z)
					local here2 = getMap()
					if not landed or root.Position.Y - landed.Y > 8 or (here2 and not danger.inBounds(root.Position, boundsOf(here2))) then
						root.CFrame = was
						root.AssemblyLinearVelocity = Vector3.zero
						note("teleport refused, no floor")
					else
						danger.pathAt, danger.pathLen = 0, math.huge
						fled = false
						note("teleport away " .. math.floor((spot - threat.Position).Magnitude))
						task.wait(0.3)
						continue
					end
				end
			end
			legs, goal = danger.fleeLegs(root, threat)
		end
		if not legs and goBack then
			goBack = false
			legs, goal = danger.wayBack(root, run.trail)
			if legs then mode = "back" end
		end
		if mode == "flee" and not legs then
			local away = danger.openDir(root, threat)
			note(away and "flee no legs, open way" or "flee no legs, cornered")
			if not away then
				jumpNow()
				local from = danger.threatFrom(root.Position, threat)
				local out = danger.flat(root.Position, from)
				away = out.Magnitude > 0.01 and out.Unit or root.CFrame.LookVector
			end
			danger.push(run, root, away)
			RunService.Heartbeat:Wait()
			continue
		end
		if not legs and not fled and state.autoCoin and not coin.bagFull then
			local target, dist = nearestCoin(root.Position, now)
			local held = coin.held
			if held and coinValid(held) and (coin.skipped[held] or 0) < now and (coin.tries or 0) < 4
				and now - (coin.heldAt or 0) < 8 then
				local heldDist = (held.Position - root.Position).Magnitude
				if target and heldDist <= (dist or math.huge) * 1.6 then target, dist = held, heldDist end
			end
			if target ~= held then coin.held, coin.tries, coin.heldAt = target, 0, now end
			if target then
				local found = legsTo(root.Position, target.Position)
				if not found then coin.skipped[target] = now + 15 end
				if found and danger.throughTrap(found) then
					coin.skipped[target] = now + 20
					found = nil
				end
				if found and threat and not danger.routeSafe(found, root.Position, threat) then
					coin.skipped[target] = now + 6
					found = nil
				end
				if found then
					mode, legs, goal = "coin", found, target.Position
					run.target, run.targetDist = target, dist
				end
			end
		end
		local hunter = not danger.surviving() or (state.autoKillMurderer and findTool("Gun") ~= nil)
		if not legs and hunter then
			local hunt = legalTargets()[1]
			if hunt and (sniper.noPath[hunt.player] or 0) < now then
				for _, part in { 1, 0.75, 0.5, 0.25 } do
					local mid = root.Position:Lerp(hunt.root.Position, part)
					local floor = danger.floorAt(mid.X, math.max(mid.Y, root.Position.Y) + 6, mid.Z)
					local found = floor and legsTo(root.Position, floor + Vector3.new(0, 2, 0), hunt.player.Character)
					if found and not danger.throughTrap(found) then
						mode, legs, goal = "hunt", found, floor + Vector3.new(0, 2, 0)
						break
					end
				end
				if not legs then
					sniper.noPath[hunt.player] = now + 1
					note("hunt no legs to " .. hunt.player.Name)
				end
			elseif not hunt then
				note("hunt none, targets " .. #aliveTargets())
			end
		end
		if not legs and (danger.roamDud or 0) < now then
			mode = "roam"
			legs, goal = danger.roamLegs(root, threat or danger.shadow())
			if not legs then danger.roamDud = now + 0.75 end
			if legs and danger.throughTrap(legs) then
				danger.badGoals[danger.goalKey(goal)] = now + 12
				legs = nil
			end
			if not legs and threat and gap < 60 then legs, goal = danger.breakout(root, threat) end
		end
		if not legs then
			local ledge = danger.ledgeOut(root, threat)
			if ledge then
				note(string.format("ledge up %.0f", ledge.Y - root.Position.Y))
				mode, goal = "ledge", ledge
				legs = { { Position = ledge, Action = Enum.PathWaypointAction.Jump, Label = "" } }
			end
		end
		if not legs and not threat then
			local centre = boundsOf(map).cf.Position
			legs, goal = danger.breakout(root, { Position = root.Position * 2 - centre, Parent = nil })
			if legs and (goal - root.Position).Magnitude < 12 then
				danger.badGoals[danger.goalKey(goal)] = now + 8
				legs, goal = nil, nil
			end
			if legs then mode = "open" end
		end
		if not legs then
			note("no legs gap=" .. tostring(math.floor(gap ~= math.huge and gap or -1)))
			danger.push(run, root, danger.openDir(root, threat) or run.moveDir or root.CFrame.LookVector)
			RunService.Heartbeat:Wait()
			continue
		end
		note(mode .. " legs=" .. #legs .. " gap=" .. tostring(math.floor(gap ~= math.huge and gap or -1)))
		run.kind = mode == "coin" and "coins" or "survive"
		run.speed = mode == "flee" and 25 or nil
		if mode == "coin" then
			run.valid = coinValid
		else
			run.target = nil
			run.valid = function() return true end
		end
		local key = danger.goalKey(goal)
		if (mode == "roam" or mode == "hunt") and key == run.goalBefore and key ~= run.goalKey then
			danger.badGoals[key] = now + 12
			if run.goalKey then danger.badGoals[run.goalKey] = now + 12 end
			run.goalBefore, run.goalKey = nil, nil
			note("ping-pong banned")
			RunService.Heartbeat:Wait()
			continue
		end
		if key ~= run.goalKey then run.goalBefore, run.goalKey, run.replans = run.goalKey, key, 0 end
		danger.goalNow, danger.modeNow = goal, mode
		lastGoal = goal
		local legFrom = root.Position
		run.retarget = false
		local legAt = now
		local watch = RunService.Heartbeat:Connect(function()
			local r = myRoot()
			if not r then return end
			local t = danger.root()
			local g = t and danger.gap(r.Position, t) or math.huge
			if mode == "flee" then
				if (g > danger.safe and not (t and danger.closeBy(r.Position, t, 40))) or os.clock() - legAt > 1.2 then run.retarget = true end
				if t and run.points and os.clock() - (run.checkAt or 0) > 0.15 then
					run.checkAt = os.clock()
					if not danger.routeSafe(run.points, r.Position, t, run.leg) then run.retarget = true end
				end
			else
				if g < danger.near then run.retarget = true end
				if mode == "roam" and os.clock() - legAt > 6 then run.retarget = true end
				if mode == "roam" and t and g < 120 and (goal - t.Position).Magnitude < (r.Position - t.Position).Magnitude - 5 then run.retarget = true end
				if mode == "hunt" and os.clock() - legAt > math.clamp((goal - r.Position).Magnitude / 25, 1.5, 5) then run.retarget = true end
				if mode == "coin" and run.target and not coinValid(run.target) then run.retarget = true end
				if mode == "coin" and t and run.points and os.clock() - (run.checkAt or 0) > 0.25 then
					run.checkAt = os.clock()
					if not danger.routeSafe(run.points, r.Position, t, run.leg) then run.retarget = true end
				end
			end
		end)
		local outcome = danger.leg(run, legs, hum, watch)
		local after = myRoot()
		local crawled = after ~= nil and (after.Position - legFrom).Magnitude < 4
		if run.learned then
			local why = run.learned
			run.learned = false
			local key = danger.goalKey(goal)
			run.learnedAt = run.learnedAt or {}
			local again = (run.learnedAt[key] or 0) > os.clock()
			run.learnedAt[key] = os.clock() + 20
			if mode == "coin" and run.target then coin.skipped[run.target] = os.clock() + (again and 10 or 4) end
			if again then danger.badGoals[key] = os.clock() + 12 end
			note((again and "leg unlearned twice, goal dropped: " or "leg unlearned: ") .. why)
		elseif outcome == "stuck" or outcome == "replan" or (outcome == "retarget" and crawled) then
			danger.badGoals[danger.goalKey(goal)] = os.clock() + 12
			danger.fleeGoal = nil
			if mode == "coin" and run.target then coin.skipped[run.target] = os.clock() + 8 end
			if after and outcome == "retarget" then danger.wedged(after.Position) end
			if after and (danger.traps[danger.goalKey(after.Position)] or 0) > os.clock() then
				goBack = true
				note("trap " .. danger.goalKey(after.Position))
			end
		elseif mode == "coin" and run.target and outcome == "arrived" and coinValid(run.target) then
			coin.tries = (coin.tries or 0) + 1
			coin.skipped[run.target] = os.clock() + (coin.tries >= 3 and 20 or 3)
		end
		danger.brainExit = mode .. " " .. tostring(outcome)
		note(mode .. " -> " .. tostring(outcome))
		if outcome == "stopped" then break end
	end
	finishRun(true)
	danger.brainOn = false
end

function sniper.hvh(now)
	if not state.hvh or sniper.busy or now - (sniper.hvhAt or 0) < 1 then return end
	local knife, gun = findTool("Knife"), findTool("Gun")
	if not knife and not gun then return end
	for _, e in danger.cheaters() do
		if knife or e.role == "Murderer" then
			sniper.hvhAt = now
			sniper.busy = true
			task.spawn(function()
				local ok, err = pcall(function()
					local root, target = myRoot(), hitPartOf(e.player)
					if not root or not target then return end
					local home = root.CFrame
					if knife then
						holdAt(CFrame.new(target.Position + target.CFrame.LookVector * -5, target.Position))
						for _ = 1, 8 do RunService.Heartbeat:Wait() end
						stabTarget(e)
						task.wait(0.2)
					else
						shootTarget(e)
						task.wait(0.3)
					end
					releaseHold()
					local r = myRoot()
					if r then
						r.CFrame = home
						r.AssemblyLinearVelocity = Vector3.zero
					end
				end)
				sniper.busy = false
				if not ok then
					say("cheater hunt error: " .. tostring(err), "triangle-alert", "danger")
				else
					say("Hit " .. e.player.Name .. " off the map", "crosshair", "accent")
				end
			end)
			return
		end
	end
end

local vote = { stale = true, known = { "Bank2", "Factory", "Hotel", "House2", "Mansion2", "MilBase", "PoliceStation", "ResearchFacility", "Workplace" }, walking = false, hooks = {}, pick = nil }

function danger.stopAll()
	danger.moveGate = os.clock() + 0.4
	cutRun()
	danger.brainOn = false
	danger.fleeing = false
	danger.pursuing = false
	danger.fleeGoal = nil
	danger.goalNow, danger.modeNow = nil, nil
	grab.walking = false
	sniper.busy = false
	halt()
end

---------------------------------------------------------------------------------------------- Voting
-- Reads the lobby vote pads and walks onto a favourite map.
function vote.same(a, b)
	local function fold(t)
		return (tostring(t):lower():gsub("[%s%d_%-]", ""))
	end
	local x, y = fold(a), fold(b)
	return x == y or (x ~= "" and y ~= "" and (x:find(y, 1, true) or y:find(x, 1, true)) ~= nil)
end

function vote.board()
	local lobby = Workspace:FindFirstChild("RegularLobby")
	local pads = lobby and lobby:FindFirstChild("VotePads")
	if not lobby or not pads then return {} end
	local open = roundTimer() == -1
	local out = {}
	for i = 1, 3 do
		local pad = lobby:FindFirstChild("VotePad" .. i)
		local det = pads:FindFirstChild("Detector" .. i)
		if pad and det then
			local label
			for _, d in pad:GetDescendants() do
				if d:IsA("TextLabel") and d.Name == "MapName" then label = d.Text end
			end
			if label and label ~= "" and label ~= "MAP NAME" then
				table.insert(out, { name = label, detector = det, open = open })
			end
		end
	end
	return out
end

function vote.learn(names)
	local changed = false
	for _, name in names do
		local dup = false
		for _, k in vote.known do
			if vote.same(k, name) then
				dup = true
				break
			end
		end
		if not dup then
			table.insert(vote.known, name)
			changed = true
		end
	end
	if changed then
		table.sort(vote.known)
		Ember.Store.set("mm2_maps", vote.known)
		if vote.pick then
			vote.pick:SetOptions(table.clone(vote.known))
		end
	end
end

function vote.walk(det)
	vote.walking = true
	local run = danger.handoff(det, function(d) return d.Parent ~= nil end, "vote")
	local hum = borrowMovement()
	local root = myRoot()
	if hum and root then
		local goal = Vector3.new(det.Position.X, root.Position.Y, det.Position.Z)
		local legs = legsTo(root.Position, goal)
		if legs then
			local watch = RunService.Heartbeat:Connect(function()
				if getMap() or not inLobby() then run.active = false end
			end)
			danger.leg(run, legs, hum, watch)
		end
		run.moveDir = nil
	end
	finishRun()
	vote.walking = false
end

function vote.stepOff(board)
	local root = myRoot()
	if not root then return end
	for _, entry in board do
		local det = entry.detector
		local flat = danger.flat(det.Position, root.Position)
		if flat.Magnitude < 4.5 then
			vote.walking = true
			local run = danger.handoff(det, function(d) return d.Parent ~= nil end, "vote")
			local hum = borrowMovement()
			if hum then
				local away = Vector3.new(0, 0, -9)
				local legs = legsTo(root.Position, Vector3.new(det.Position.X, root.Position.Y, det.Position.Z) + away)
				if legs then
					local watch = RunService.Heartbeat:Connect(function()
						if getMap() or not inLobby() then run.active = false end
					end)
					danger.leg(run, legs, hum, watch)
				end
			end
			finishRun()
			vote.walking = false
			return
		end
	end
end

function vote.check()
	local board = vote.board()
	local names = {}
	for _, entry in board do table.insert(names, entry.name) end
	vote.learn(names)
	if not state.autoVote or vote.walking or vote.stale then return end
	if getMap() or not inLobby() or not myRoot() then return end
	local best, bestRank
	for _, entry in board do
		if entry.open then
			for rank, fav in state.favMaps do
				if vote.same(entry.name, fav) and (not bestRank or rank < bestRank) then best, bestRank = entry, rank end
			end
		end
	end
	if not best then
		task.spawn(function()
			local ok, err = pcall(vote.stepOff, board)
			if not ok then
				vote.walking = false
				if coinRun and coinRun.kind == "vote" then finishRun() end
				say("vote error: " .. tostring(err), "triangle-alert", "danger")
			end
		end)
		return
	end
	do
		local entry = best
		if entry then
			task.spawn(function()
				local ok, err = pcall(vote.walk, entry.detector)
				if not ok then
					vote.walking = false
					if coinRun and coinRun.kind == "vote" then finishRun() end
					say("vote error: " .. tostring(err), "triangle-alert", "danger")
				end
			end)
			say("Voting for " .. entry.name, "vote", "accent")
		end
	end
end

function vote.hook()
	for _, c in vote.hooks do c:Disconnect() end
	table.clear(vote.hooks)
	local lobby = Workspace:FindFirstChild("RegularLobby")
	if not lobby then return end
	for i = 1, 3 do
		local pad = lobby:FindFirstChild("VotePad" .. i)
		if pad then
			for _, d in pad:GetDescendants() do
				if d:IsA("TextLabel") and d.Name == "MapName" then
					table.insert(vote.hooks, d:GetPropertyChangedSignal("Text"):Connect(function()
						vote.stale = false
						task.defer(vote.check)
					end))
				end
			end
		end
	end
	local timerPart = Workspace:FindFirstChild("RoundTimerPart")
	if timerPart then
		table.insert(vote.hooks, timerPart:GetAttributeChangedSignal("Time"):Connect(function()
			if roundTimer() == -1 then task.defer(vote.check) end
		end))
	end
end

---------------------------------------------------------------------------------------------- Combat
-- Legit attacks and the gunfight loop: strafe for a line, back off inside knife range.
local function legitStab(entry)
	local root, target = myRoot(), hitPartOf(entry.player)
	if not root or not target then return false, "target has no body" end
	if (target.Position - root.Position).Magnitude > 7 and not pursue(entry.player, 6) then
		return false, "could not reach " .. entry.player.Name
	end
	return stabTarget(entry)
end

local function legitShoot(entry)
	local ok, why = shootFromHere(entry)
	if ok then return true end
	if why == "reloading" then return false, why end
	if sniper.duel(entry.player, 15) then return true end
	return false, "no clear shot on " .. entry.player.Name
end

local function attack(entry)
	if (sniper.noPath[entry.player] or 0) > os.clock() and (legitOn("Stabbing as murderer") or legitOn("Shooting as sheriff")) then
		return false, "no route to " .. entry.player.Name
	end
	if findTool("Knife") and legitOn("Stabbing as murderer") then return legitStab(entry) end
	if findTool("Gun") and legitOn("Shooting as sheriff") then return legitShoot(entry) end
	return killEntry(entry)
end

function sniper.status(label)
	local now = os.clock()
	if now - sniper.labelAt < (label == sniper.label and 0.8 or 0.3) then return end
	sniper.label, sniper.labelAt = label, now
	say(label, "crosshair", "accent", 1)
end

function sniper.blockerName(inst)
	if not inst then return "nothing" end
	local model = inst:FindFirstAncestorOfClass("Model")
	if model and Players:GetPlayerFromCharacter(model) then return model.Name end
	return inst.Name
end

function sniper.steer(run, hum, goal, label)
	sniper.status(label)
	local until_, still, last = os.clock() + 0.5, 0, nil
	while run.active do
		local root = myRoot()
		if not root then return end
		if danger.flat(goal, root.Position).Magnitude < 1.5 then return end
		local speed = math.clamp(run.speed or state.coinSpeed, 16, 25)
		drive(run, root, hum, goal, speed)
		local dt = RunService.Heartbeat:Wait()
		if last and (root.Position - last).Magnitude < speed * dt * 0.2 then
			still += dt
			if still > 0.2 then jumpNow() end
		end
		last = root.Position
		if os.clock() > until_ then return end
	end
end

function sniper.retreat(here, toward, entry, gunOff, who)
	local away = -toward
	local them = entry.root.Position
	local hereFloor = danger.floorAt(here.X, here.Y + 2, here.Z)
	local best, bestScore
	for _, turn in { 0, 35, -35, 70, -70, 100, -100 } do
		local dir = CFrame.Angles(0, math.rad(turn), 0) * away
		local spot = here + dir * 10
		local floor = spotIsStandable(spot) and danger.floorAt(spot.X, spot.Y + 2, spot.Z)
		if floor and hereFloor and math.abs(floor.Y - hereFloor.Y) < 4 and lineIsClear(here, spot, who.Character) then
			local score = (spot - them).Magnitude - (here - them).Magnitude
			if clearAim(spot + gunOff, entry) then score += 25 end
			if not bestScore or score > bestScore then best, bestScore = spot, score end
		end
	end
	return best
end

function sniper.backOff(run, hum, here, toward, entry, gunOff, who)
	local back = sniper.retreat(here, toward, entry, gunOff, who)
	if back then
		sniper.steer(run, hum, back, "Backing off")
		return
	end
	local root = myRoot()
	local legs = root and danger.breakout(root, entry.root)
	if legs then
		sniper.steer(run, hum, legs[1].Position, "Slipping past")
		return
	end
	sniper.status("Cornered")
	local root2 = myRoot()
	run.moveDir = (root2 and danger.openDir(root2, entry.root)) or run.moveDir
	RunService.Heartbeat:Wait()
end

function sniper.strafeSpot(here, toward, entry, gunOff, who, scale)
	local side = Vector3.new(-toward.Z, 0, toward.X) * (sniper.side or 1)
	local them = entry.root.Position
	local hereFloor = danger.floorAt(here.X, here.Y + 2, here.Z)
	for _, off in { { 4, 0 }, { -4, 0 }, { 0, -5 }, { 8, 0 }, { -8, 0 }, { 6, -5 }, { -6, -5 }, { 6, 5 }, { -6, 5 }, { 12, 0 }, { -12, 0 }, { 10, -5 }, { -10, -5 }, { 10, 5 }, { -10, 5 }, { 16, 0 }, { -16, 0 }, { 16, -8 }, { -16, -8 }, { 16, 8 }, { -16, 8 } } do
		local spot = here + side * (off[1] * scale) + toward * (off[2] * scale)
		if danger.flat(them, spot).Magnitude >= sniper.close and spotIsStandable(spot) then
			local floor = danger.floorAt(spot.X, spot.Y + 2, spot.Z)
			if floor and hereFloor and math.abs(floor.Y - hereFloor.Y) < 4 and lineIsClear(here, spot, who.Character) and clearAim(spot + gunOff, entry) then
				if off[1] < 0 then sniper.side = -(sniper.side or 1) end
				return spot
			end
		end
	end
	return nil
end

function sniper.approach(run, hum, who, blocker)
	local root, target = myRoot(), hitPartOf(who)
	if not root or not target then return end
	local them = target.Position
	local goal = them
	sniper.status("Closing in, blocked by " .. sniper.blockerName(blocker))
	local legs = legsTo(root.Position, goal, who.Character)
	local otherFloor = math.abs(them.Y - root.Position.Y) > 8
	for _, part in { 0.75, 0.5, 0.25 } do
		if legs or otherFloor then break end
		local mid = root.Position:Lerp(them, part)
		local floor = danger.floorAt(mid.X, math.max(mid.Y, root.Position.Y) + 6, mid.Z)
		if floor then
			goal = floor + Vector3.new(0, 2, 0)
			legs = legsTo(root.Position, goal, who.Character)
		end
	end
	if not legs and not otherFloor then
		legs, goal = danger.breakout(root, { Position = root.Position * 2 - them, Parent = nil })
	end
	if not legs then
		do
			sniper.status("No way to reach them from here")
			sniper.noPath[who] = os.clock() + 1
			danger.push(run, root, danger.openDir(root, nil) or run.moveDir)
			RunService.Heartbeat:Wait()
			return
		end
	end
	run.retarget = false
	local legAt = os.clock()
	local watch = RunService.Heartbeat:Connect(function()
		local r, t, o = myRoot(), hitPartOf(who), gunOrigin()
		if not r or not t or not o then
			run.retarget = true
			return
		end
		local flat = danger.flat(t.Position, r.Position).Magnitude
		if flat < sniper.hold or (t.Position - them).Magnitude > math.max(flat * 0.35, 8) or os.clock() - legAt > 1.5 or clearAim(o.WorldPosition, { player = who, root = t }) then
			run.retarget = true
		end
	end)
	local before = root.Position
	danger.leg(run, legs, hum, watch)
	local after = myRoot()
	if after and (after.Position - before).Magnitude < 3 then
		sniper.crawls = (sniper.crawls or 0) + 1
		if sniper.crawls >= 2 then
			sniper.crawls = 0
			if not danger.legFailed(run, legs[1], nil, "crawl") then sniper.noPath[who] = os.clock() + 1 end
		end
	else
		sniper.crawls = 0
	end
end

function sniper.vantage(here, entry, gunOff)
	local now = os.clock()
	if not nav.live() or now - (sniper.vantageAt or 0) < 1 then return nil end
	sniper.vantageAt = now
	local them = entry.root.Position
	local near = nav.world:Nearby(here, 60)
	table.sort(near, function(a, b) return (a.Position - here).Magnitude < (b.Position - here).Magnitude end)
	local tested = 0
	for _, n in near do
		local p = n.Position
		local d = (p - here).Magnitude
		if d > 4 and danger.flat(them, p).Magnitude >= sniper.close then
			tested += 1
			if clearAim(p + gunOff, entry) then return p end
			if tested >= 120 then break end
		end
	end
	return nil
end

function sniper.goTo(run, hum, spot, who, label)
	local root = myRoot()
	if not root then return end
	local legs = legsTo(root.Position, spot, who.Character)
	if not legs then return end
	sniper.status(label)
	run.retarget = false
	local legAt = os.clock()
	local watch = RunService.Heartbeat:Connect(function()
		local r, t, o = myRoot(), hitPartOf(who), gunOrigin()
		if not r or not t or not o then
			run.retarget = true
			return
		end
		if os.clock() - legAt > 2 or clearAim(o.WorldPosition, { player = who, root = t }) then run.retarget = true end
	end)
	danger.leg(run, legs, hum, watch)
end

function sniper.settle(run, root, entry, point)
	local o = gunOrigin()
	return o and clearAim(o.WorldPosition, entry) or point
end

function sniper.duel(who, limit)
	local function alive()
		return hitPartOf(who) ~= nil and not isDead(who)
	end
	danger.pursuing = true
	local run = danger.handoff(who, alive, "pursuit")
	run.speed = 25
	local hum = borrowMovement()
	if not hum then
		finishRun()
		return false
	end
	local started, shots, lastCheck = os.clock(), 0, 0
	sniper.waitSince, sniper.backingOff = nil, false
	local okLoop, errLoop = pcall(function()
	while run.active and alive() do
		local now = os.clock()
		if now - started > limit then break end
		if now - lastCheck > 0.25 then
			lastCheck = now
			if not canAct() then break end
		end
		local gun = findTool("Gun")
		local root, target = myRoot(), hitPartOf(who)
		if not gun or not root or not target then break end
		equipTool(gun)
		local origin = gunOrigin()
		if not origin then
			RunService.Heartbeat:Wait()
			continue
		end
		local entry = { player = who, root = target }
		local here = root.Position
		local flat = danger.flat(target.Position, here)
		local dist = flat.Magnitude
		if math.abs(target.Position.Y - here.Y) > 8 then dist = math.max(dist, sniper.hold) end
		local toward = dist > 0.01 and flat.Unit or root.CFrame.LookVector
		local gunOff = origin.WorldPosition - here
		local point, blocker = clearAim(origin.WorldPosition, entry)
		if point and dist > sniper.reach then point = nil end
		if point then sniper.waitSince = nil end
		if dist >= sniper.hold + 6 then sniper.backingOff = false end
		if dist > sniper.reach + 15 then sniper.waitSince = nil end
		if point then
			local shoot = gun:FindFirstChild("Shoot")
			if shoot and now - lastShot >= SHOT_GAP then
				point = sniper.settle(run, root, entry, point)
				origin = gunOrigin() or origin
				if point and fireShot(shoot, origin.WorldCFrame, point, who.Name) then shots += 1 end
			end
			if dist < sniper.close then
				sniper.backOff(run, hum, here, toward, entry, gunOff, who)
			elseif danger.armed(who) then
				sniper.status("Line is clear")
				local side = Vector3.new(-toward.Z, 0, toward.X) * (sniper.side or 1)
				local standUntil = os.clock() + 0.3
				repeat
					local r = myRoot()
					if not r then break end
					run.moveDir = side
					if danger.canMove() then player:Move(side, false) end
					RunService.Heartbeat:Wait()
				until os.clock() >= standUntil or not run.active
				run.moveDir = nil
			else
				sniper.status("Line is clear")
				run.moveDir = nil
				RunService.Heartbeat:Wait()
			end
		elseif dist < sniper.close or (sniper.backingOff and dist < sniper.hold + 6) then
			sniper.backingOff = true
			sniper.backOff(run, hum, here, toward, entry, gunOff, who)
		else
			sniper.backingOff = false
			local spot = danger.armed(who) and dist <= sniper.far and (sniper.strafeSpot(here, toward, entry, gunOff, who, 1) or sniper.strafeSpot(here, toward, entry, gunOff, who, 2))
			local heading = danger.heading(target)
			local closing = heading ~= nil and heading:Dot(-toward) > 0.5
			if spot then
				sniper.steer(run, hum, spot, "Strafing for a line")
			elseif dist < sniper.hold and closing then
				sniper.backOff(run, hum, here, toward, entry, gunOff, who)
			elseif dist < sniper.reach and now - (sniper.waitSince or now) < 2 then
				sniper.waitSince = sniper.waitSince or now
				local vantage = sniper.vantage(here, entry, gunOff)
				if vantage then
					sniper.goTo(run, hum, vantage, who, "Moving for a line")
				else
					sniper.status("Waiting for a line")
					if danger.armed(who) then
						local side = Vector3.new(-toward.Z, 0, toward.X) * (sniper.side or 1)
						local standUntil = os.clock() + 0.2
						repeat
							run.moveDir = side
							if danger.canMove() then player:Move(side, false) end
							RunService.Heartbeat:Wait()
						until os.clock() >= standUntil or not run.active
						sniper.side = -(sniper.side or 1)
					else
						RunService.Heartbeat:Wait()
					end
					run.moveDir = nil
				end
			elseif (sniper.noPath[who] or 0) > now then
				break
			else
				sniper.approach(run, hum, who, blocker)
			end
		end
	end
	end)
	sniper.label = nil
	finishRun(true)
	danger.pursuing = false
	if not okLoop then error(errLoop, 0) end
	return shots > 0
end

local function attackMany(list)
	if findTool("Knife") and not legitOn("Stabbing as murderer") then return stabMany(list) end
	local done, skipped, struck = 0, {}, {}
	while true do
		local root = myRoot()
		if not root then break end
		local holder = gunHolder()
		local now = os.clock()
		local pick, kept
		for _, e in legalTargets() do
			if not skipped[e.player] and (struck[e.player] or 0) < now and (sniper.noPath[e.player] or 0) < now then
				if e.player == holder and e.dist <= 60 then
					pick = e
					break
				end
				if not pick then pick = e end
				if e.player == sniper.prey and (sniper.preyUntil or 0) > now then kept = e end
			end
		end
		if kept and pick and pick.player ~= holder and kept.dist <= pick.dist * 1.5 + 4 then pick = kept end
		if not pick then break end
		if pick.player ~= sniper.prey then sniper.prey, sniper.preyUntil = pick.player, now + 5 end
		if attack(pick) then
			done += 1
			struck[pick.player] = os.clock() + 1.2
		else
			skipped[pick.player] = true
		end
		RunService.Heartbeat:Wait()
		local able = canAct()
		if not able then break end
	end
	return done
end

----------------------------------------------------------------------------------------------- Coins
-- Coin tracking and the sweep that takes anything walked past.
function onCoinAdded(part)
	local run = coinRun
	if not run or not run.active or run.kind ~= "coins" or not run.target then return end
	local root = myRoot()
	if not root then return end
	if (part.Position - root.Position).Magnitude < run.targetDist * COIN_SWITCH_RATIO then
		run.retarget = true
	end
end

function coin.sweep(root)
	local now = os.clock()
	if now - (coin.sweptAt or 0) < 0.1 then return end
	coin.sweptAt = now
	local here = root.Position
	for part in pairs(coin.set) do
		if part.Parent and (part.Position - here).Magnitude < 9 and coinValid(part) then
			pcall(firetouchinterest, root, part, 0)
			pcall(firetouchinterest, root, part, 1)
		end
	end
end

local function rethinkCoin()
	local run = coinRun
	if not run or not run.active or run.kind ~= "coins" or not run.target or run.retarget then return end
	local root = myRoot()
	if not root then return end
	local threat = danger.root()
	if threat then
		local toThem = danger.flat(threat.Position, root.Position)
		local toCoin = danger.flat(run.target.Position, root.Position)
		local coinGap = danger.gap(run.target.Position, threat)
		if danger.pathGap(root.Position, run.target.Position, threat) < 22
			or coinGap < danger.near
			or (toThem.Magnitude < 65 and toCoin.Magnitude > 1 and toCoin.Unit:Dot(toThem.Unit) > 0.6 and coinGap < math.max(danger.gap(root.Position, threat), 45)) then
			run.retarget = true
			return
		end
	end
	local best, dist = nearestCoin(root.Position, os.clock())
	if best and best ~= run.target then
		local current = (run.target.Position - root.Position).Magnitude
		if dist < current * COIN_SWITCH_RATIO then run.retarget = true end
	end
end

local esp = { highlights = {}, nameTags = {}, coinBoxes = {}, gunBoxes = {}, bodies = {} }

esp.tint = {
	coin = COIN_COLOUR,
	gunFill = ROLE_COLOURS.Sheriff,
	gunEdge = Color3.fromRGB(200, 225, 255),
	bodyFill = Color3.fromRGB(235, 235, 245),
	bodyEdge = Color3.fromRGB(255, 255, 255),
}

esp.notBody = {}

function esp.dropLimbs(set)
	for _, hl in pairs(set.parts) do hl:Destroy() end
	table.clear(set.parts)
end

function esp.clearLimbs(store)
	for who, set in pairs(store) do
		esp.dropLimbs(set)
		store[who] = nil
	end
end

function danger.corpseOf(body)
	local hum = body:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health > 0 then return false end
	local who = Players:GetPlayerFromCharacter(body)
	if who then return isDead(who) end
	return roleData()[body.Name] ~= nil
end

------------------------------------------------------------------------------------------------- ESP
-- Highlights and name tags for players, bodies, coins and guns.
local function clearMap(map)
	for key, inst in pairs(map) do
		inst:Destroy()
		map[key] = nil
	end
end

function esp.repaintRoles()
	esp.clearLimbs(esp.highlights)
	clearMap(esp.nameTags)
end

local function updateNameTag(who, char, role, colour)
	local head = char:FindFirstChild("Head")
	if not head then return end
	local tag = esp.nameTags[who]
	if not tag or not tag.Parent or tag.Adornee ~= head then
		if tag then tag:Destroy() end
		tag = Instance.new("BillboardGui")
		tag.Name = "MM2Tag"
		tag.Adornee = head
		tag.Size = UDim2.new(0, 200, 0, 34)
		tag.StudsOffset = Vector3.new(0, 2.4, 0)
		tag.AlwaysOnTop = true
		tag.MaxDistance = 1000
		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextSize = 13
		label.TextStrokeTransparency = 0.4
		label.TextStrokeColor3 = Color3.new(0, 0, 0)
		label.Parent = tag
		tag.Parent = gethui()
		esp.nameTags[who] = tag
	end
	local root, target = myRoot(), char:FindFirstChild("HumanoidRootPart")
	local dist = (root and target) and math.floor((target.Position - root.Position).Magnitude) or 0
	local label = tag.Label
	label.TextColor3 = colour
	label.Text = string.format("%s\n%s  %dm", who.Name, role, dist)
end

local function refreshRoleEsp()
	if not state.roleEsp then
		esp.clearLimbs(esp.highlights)
		clearMap(esp.nameTags)
		return
	end
	local keep = {}
	for _, who in Players:GetPlayers() do
		local char = who ~= player and who.Character
		local role = char and roleOf(who)
		local dead = role and isDead(who)
		local rootPart = char and char:FindFirstChild("HumanoidRootPart")
		local map = getMap()
		local spectating = not rootPart or danger.lobbyHas(rootPart.Position)
		if not spectating and map then
			local box = boundsOf(map)
			spectating = not insideBox(rootPart.Position, box.cf, box.size, 150)
		end
		if role and char.Parent and not spectating and (not dead or state.showDead) then
			keep[who] = true
			local set = esp.highlights[who]
			if not set or set.char ~= char then
				if set then
					for _, old in set.parts do old:Destroy() end
				end
				set = { char = char, parts = {} }
				esp.highlights[who] = set
			end
			local colour = ROLE_COLOURS[role] or Color3.new(1, 1, 1)
			local fill = dead and 0.85 or 0.55
			for _, limb in char:GetChildren() do
				if limb:IsA("BasePart") and not esp.notBody[limb.Name] then
					local hl = set.parts[limb]
					if not hl or hl.Parent ~= limb then
						hl = Instance.new("Highlight")
						hl.Name = "MM2RoleEsp"
						hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
						hl.Adornee = limb
						hl.Parent = limb
						set.parts[limb] = hl
					end
					hl.FillColor = colour
					hl.OutlineColor = colour
					hl.FillTransparency = fill
					hl.OutlineTransparency = 0
				end
			end
			for limb, hl in pairs(set.parts) do
				if limb.Parent ~= char then
					hl:Destroy()
					set.parts[limb] = nil
				end
			end
			if state.nameEsp then
				updateNameTag(who, char, dead and (role .. " (dead)") or role, colour)
			end
		end
	end
	for who, set in pairs(esp.highlights) do
		if not keep[who] then
			esp.dropLimbs(set)
			esp.highlights[who] = nil
		end
	end
	for who, tag in pairs(esp.nameTags) do
		if not keep[who] or not state.nameEsp then
			tag:Destroy()
			esp.nameTags[who] = nil
		end
	end
end

function esp.refreshBodies()
	if not state.showDead then
		clearMap(esp.bodies)
		return
	end
	local keep = {}
	for _, body in CollectionService:GetTagged("Ragdoll") do
		if body:IsA("Model") and body:IsDescendantOf(Workspace) and danger.corpseOf(body) then
			keep[body] = true
			if not esp.bodies[body] then
				local hl = Instance.new("Highlight")
				hl.Name = "MM2BodyEsp"
				hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				hl.FillColor = esp.tint.bodyFill
				hl.OutlineColor = esp.tint.bodyEdge
				hl.FillTransparency = 0.7
				hl.OutlineTransparency = 0.1
				hl.Adornee = body
				hl.Parent = body
				esp.bodies[body] = hl
			end
		end
	end
	for body, hl in pairs(esp.bodies) do
		if not keep[body] then
			hl:Destroy()
			esp.bodies[body] = nil
		end
	end
end

local function adornCoin(part, colour)
	local ball = Instance.new("SphereHandleAdornment")
	ball.Name = "MM2Esp"
	ball.Adornee = part
	ball.Radius = math.max(part.Size.Y, part.Size.Z) / 2 + 0.25
	ball.Color3 = colour
	ball.Transparency = 0.45
	ball.AlwaysOnTop = true
	ball.ZIndex = 5
	ball.Parent = part
	return ball
end

local function adornGun(part, colour)
	local hl = Instance.new("Highlight")
	hl.Name = "MM2GunEsp"
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.FillColor = colour
	hl.OutlineColor = esp.tint.gunEdge
	hl.FillTransparency = 0.3
	hl.OutlineTransparency = 0
	hl.Adornee = part
	hl.Parent = part
	return hl
end

local function syncBoxes(store, parts, colour, make)
	local live = {}
	for _, part in parts do
		live[part] = true
		if not store[part] then store[part] = make(part, colour) end
	end
	for part, box in pairs(store) do
		if not live[part] then
			box:Destroy()
			store[part] = nil
		end
	end
end

local function refreshCoinEsp()
	if not state.coinEsp then
		clearMap(esp.coinBoxes)
		return
	end
	syncBoxes(esp.coinBoxes, coinParts(), esp.tint.coin, adornCoin)
end

local function refreshGunEsp()
	if not state.gunEsp then
		clearMap(esp.gunBoxes)
		return
	end
	local guns = droppedGuns()
	for _, held in danger.heldGuns() do table.insert(guns, held) end
	syncBoxes(esp.gunBoxes, guns, esp.tint.gunFill, adornGun)
end

local function teleportToGameMap()
	local map = getMap()
	if not map then return false, "no map in workspace" end
	local spawns = map:FindFirstChild("Spawns")
	local spawn = spawns and spawns:FindFirstChildWhichIsA("BasePart")
	if not spawn then return false, "map has no spawn part" end
	local char = myChar()
	if not char or not char:FindFirstChild("HumanoidRootPart") then return false, "no character" end
	char:PivotTo(spawn.CFrame)
	return true, map:GetAttribute("MapID")
end

local function teleportToPlayer(who)
	if not who then return false, "nobody with that role" end
	local from, target = myRoot(), hitPartOf(who)
	if not from then return false, "no character" end
	if not target then return false, who.Name .. " has no character" end
	from.CFrame = target.CFrame * CFrame.new(0, 0, 4)
	return true, who.Name
end

local tryAuto

local ui = {}
local plr = { walkSaved = nil, jumpSaved = nil, flyVel = nil, flyGyro = nil, flyNow = Vector3.zero, flyLast = 0, collideWas = {} }

local UserInputService = game:GetService("UserInputService")

---------------------------------------------------------------------------------------------- Player
-- Speed, jump, gravity, flight, noclip and anti-fling.
function plr.plrRestoreWalk()
	local hum = myHumanoid()
	if hum then
		if borrowed then borrowed.walk = 16 else hum.WalkSpeed = 16 end
	end
	plr.walkSaved = nil
end

function plr.plrRestoreJump()
	local hum = myHumanoid()
	if hum and plr.jumpSaved then
		if borrowed then
			borrowed.usePower, borrowed.jump = plr.jumpSaved.use, plr.jumpSaved.power
		else
			hum.UseJumpPower = plr.jumpSaved.use
			hum.JumpPower = plr.jumpSaved.power
		end
	end
	plr.jumpSaved = nil
end

function plr.uncollide(part)
	if part.CanCollide then
		plr.collideWas[part] = true
		part.CanCollide = false
	end
end

function plr.restoreCollisions(model)
	for part in pairs(plr.collideWas) do
		if not part.Parent then
			plr.collideWas[part] = nil
		elseif not model or part:IsDescendantOf(model) then
			part.CanCollide = true
			plr.collideWas[part] = nil
		end
	end
end

function plr.plrStartFly()
	local root, hum = myRoot(), myHumanoid()
	if not root or not hum then return end
	plr.plrStopFly()
	local vel = Instance.new("BodyVelocity")
	vel.Name = "MM2Fly"
	vel.MaxForce = Vector3.new(1e9, 1e9, 1e9)
	vel.Velocity = Vector3.zero
	vel.Parent = root
	local gyro = Instance.new("BodyGyro")
	gyro.Name = "MM2FlyGyro"
	gyro.MaxTorque = Vector3.new(1e9, 1e9, 1e9)
	gyro.P = 6e4
	gyro.D = 1500
	gyro.CFrame = root.CFrame
	gyro.Parent = root
	plr.flyVel, plr.flyGyro = vel, gyro
	plr.flyNow = Vector3.zero
	plr.flyLast = os.clock()
	hum.PlatformStand = true
end

function plr.plrStopFly()
	if plr.flyVel then plr.flyVel:Destroy() end
	if plr.flyGyro then plr.flyGyro:Destroy() end
	plr.flyVel, plr.flyGyro = nil, nil
	local hum = myHumanoid()
	if hum then hum.PlatformStand = false end
end

function plr.flyStep()
	local root, cam = myRoot(), Workspace.CurrentCamera
	if not root or not plr.flyVel or not cam then return end
	if plr.flyVel.Parent ~= root then
		plr.plrStartFly()
		return
	end
	if coinRun then
		plr.flyVel.MaxForce = Vector3.zero
		plr.flyGyro.MaxTorque = Vector3.zero
		return
	end
	plr.flyVel.MaxForce = Vector3.new(1e9, 1e9, 1e9)
	plr.flyGyro.MaxTorque = Vector3.new(1e9, 1e9, 1e9)
	local now = os.clock()
	local dt = math.clamp(now - plr.flyLast, 0, 0.1)
	plr.flyLast = now
	local dir = Vector3.zero
	local look, right = cam.CFrame.LookVector, cam.CFrame.RightVector
	right = Vector3.new(right.X, 0, right.Z)
	if right.Magnitude > 0.01 then right = right.Unit end
	if not UserInputService:GetFocusedTextBox() then
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir += look end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir -= look end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir += right end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir -= right end
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.yAxis end
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then dir -= Vector3.yAxis end
	end
	local target = dir.Magnitude > 0 and dir.Unit * state.flySpeed or Vector3.zero
	plr.flyNow = plr.flyNow:Lerp(target, 1 - math.exp(-dt * 7))
	if plr.flyNow.Magnitude < 0.3 then plr.flyNow = Vector3.zero end
	plr.flyVel.Velocity = plr.flyNow
	local face = Vector3.new(look.X, 0, look.Z)
	if plr.flyNow.Magnitude > 2 then face = plr.flyNow end
	if face.Magnitude > 0.01 then
		plr.flyGyro.CFrame = CFrame.lookAt(root.Position, root.Position + face.Unit)
	end
end

function plr.collisionStep()
	local char = myChar()
	if state.antiFling then
		for _, who in Players:GetPlayers() do
			local c = who ~= player and who.Character
			if c then
				for _, part in c:GetChildren() do
					if part:IsA("BasePart") then plr.uncollide(part) end
				end
			end
		end
	end
	if state.noclip and char then
		for _, part in char:GetChildren() do
			if part:IsA("BasePart") then plr.uncollide(part) end
		end
	end
end

function plr.playerTick()
	local hum = myHumanoid()
	if not hum then return end
	if state.speed ~= 16 and not coinRun then
		if not plr.walkSaved and hum.WalkSpeed > 0 then plr.walkSaved = hum.WalkSpeed end
		if hum.WalkSpeed ~= state.speed then hum.WalkSpeed = state.speed end
	end
	if state.jump ~= 50 and not coinRun then
		if not plr.jumpSaved then plr.jumpSaved = { use = hum.UseJumpPower, power = hum.JumpPower } end
		if not hum.UseJumpPower then hum.UseJumpPower = true end
		if hum.JumpPower ~= state.jump then hum.JumpPower = state.jump end
	end
	if state.gravity ~= 196 and Workspace.Gravity ~= state.gravity then Workspace.Gravity = state.gravity end
	if state.fly then plr.flyStep() end
end

state.booted = os.clock()

ui.controls = {}
do
	local SectionClass = getmetatable(win:Section("Combat", "swords"))
	for _, kind in { "Toggle", "Slider", "Dropdown", "Keybind", "Input" } do
		local build = SectionClass[kind]
		SectionClass[kind] = function(self, first, ...)
			local handle = build(self, first, ...)
			if type(first) == "table" then
				local default = first.ResetTo
				if default == nil then default = first.Default end
				table.insert(ui.controls, { handle = handle, kind = kind, default = default })
			end
			return handle
		end
	end
end
local combatSec = win.Sections[1]

combatSec:Dropdown({
	Text = "Legit mode",
	Description = "Ticked actions move like a real player. Unticked ones teleport. Waiting for the knife holds off hunting the murderer until they have drawn it at least once this round, so the kill looks like a reaction.",
	Icon = "footprints",
	Options = { "Walking to the dropped gun", "Shooting as sheriff", "Stabbing as murderer", "Running as innocent", "Wait until the knife is drawn" },
	Multi = true,
	Style = "check",
	Default = { "Shooting as sheriff", "Stabbing as murderer", "Running as innocent" },
	Save = prefs.key("combat", "legit4"),
	FireOnStart = true,
	Callback = function(list)
		local set = {}
		if type(list) == "table" then
			for _, name in list do set[name] = true end
		end
		state.legitFor = set
		state.legit = next(set) ~= nil
		if not set["Walking to the dropped gun"] then
			if coinRun and coinRun.kind == "gun" then stopCoinRun() end
			grab.nextTry = 0
			table.clear(grab.failed)
		end
		if not set["Shooting as sheriff"] and coinRun and coinRun.kind == "pursuit" then stopCoinRun() end
		if tryAuto then tryAuto() end
	end,
})

combatSec:Toggle({
	Text = "Kill cheaters",
	Description = "Anyone under or outside the map is reached by teleport and hit. The knife takes anyone; the gun takes only the murderer, since shooting anyone else as sheriff kills you.",
	Icon = "crosshair",
	RevertOnClose = true,
	Callback = function(on) state.hvh = on end,
})

combatSec:Toggle({
	Text = "Spare friends",
	Description = "Your Roblox friends are never targeted.",
	Icon = "heart",
	Save = prefs.key("combat", "spareFriends"),
	Callback = function(on)
		state.spareFriends = on
		table.clear(danger.friends)
	end,
})

combatSec:Toggle({
	Text = "Block stabs",
	Description = "Turns off CanTouch on every other player's knife handle, so its Touched handler never fires against you. Your own body stays touchable, so coins still collect. Thrown knives and guns still hit.",
	Icon = "shield-ban",
	Save = prefs.key("combat", "noStab"),
	Callback = function(on)
		state.noStab = on
		danger.guardTouch()
		say(on and "Stab blocking on" or "Stab blocking off", "shield-ban", on and "accent" or "muted")
	end,
})

local innocentSec = combatSec:Group({ Text = "Innocent", Icon = "shield-half" })

innocentSec:Toggle({
	Text = "Survive",
	Description = "Runs from the murderer and shoots them when holding the gun. Turn on auto pickup gun to go for the dropped gun. Coins keep coming if auto coins is on.",
	Icon = "footprints",
	RevertOnClose = true,
	Callback = function(on)
		state.survive = on
		if on then
			danger.moveGate = 0
			if tryAuto then tryAuto() end
		else
			danger.stopAll()
		end
		say(on and "Survive mode on" or "Survive mode off", "shield-half", on and "accent" or "muted")
	end,
})

local murderSec = combatSec:Group({ Text = "Murderer", Icon = "skull" })

ui.targetPick = murderSec:Dropdown({
	Text = "Target",
	Icon = "crosshair",
	Options = { "Everyone", "Nearest", "Gun holder" },
	Default = "Nearest",
	Save = prefs.key("combat", "target"),
})

murderSec:Button({
	Text = "Kill target",
	Icon = "skull",
	ButtonText = "Kill",
	ButtonIcon = "swords",
	Style = "soft",
	Danger = true,
	Callback = function()
		local able, why = canAct()
		if not able then
			report(false, nil, why)
			return
		end
		local choice = tostring(ui.targetPick:Get())
		task.spawn(function()
			if choice == "Everyone" then
				local list = legalTargets()
				if #list == 0 then
					report(false, nil, "nobody you can attack")
					return
				end
				local done = attackMany(list)
				report(done > 0, "Hit " .. done .. " players", "no weapon in hand")
				return
			end
			local who
			if choice == "Nearest" then
				local list = legalTargets()
				who = list[1] and list[1].player
			elseif choice == "Gun holder" then
				who = gunHolder()
			else
				who = Players:FindFirstChild(choice)
			end
			if not who or who == player or isDead(who) or not hitPartOf(who) then
				report(false, nil, "nobody alive matches that")
				return
			end
			local ok, err = attack({ player = who })
			report(ok, "Hit " .. who.Name, err)
		end)
	end,
})

murderSec:Toggle({
	Text = "Auto kill all",
	Icon = "zap",
	RevertOnClose = true,
	Danger = true,
	Callback = function(on)
		state.autoKillAll = on
		if on then danger.moveGate = 0 if tryAuto then tryAuto() end end
		if not on then danger.stopPursuit() end
		say(on and "Auto kill all armed" or "Auto kill all off", "swords", on and "accent" or "muted")
	end,
})

murderSec:Toggle({
	Text = "Auto kill sheriff",
	Icon = "shield-off",
	RevertOnClose = true,
	Danger = true,
	Callback = function(on)
		state.autoKillSheriff = on
		if on then danger.moveGate = 0 if tryAuto then tryAuto() end end
		if not on then danger.stopPursuit() end
		say(on and "Auto kill sheriff armed" or "Auto kill sheriff off", "shield-off", on and "accent" or "muted")
	end,
})

local sheriffSec = combatSec:Group({ Text = "Sheriff", Icon = "shield" })

sheriffSec:Button({
	Text = "Kill murderer",
	Icon = "crosshair",
	ButtonText = "Shoot",
	ButtonIcon = "skull",
	Style = "soft",
	Danger = true,
	Callback = function()
		local able, why = canAct()
		if not able then
			report(false, nil, why)
			return
		end
		local who = findByRole("Murderer")
		if not who or who == player then
			report(false, nil, "no murderer found")
			return
		end
		if danger.friend(who) then
			report(false, nil, who.Name .. " is a friend")
			return
		end
		task.spawn(function()
			sniper.busy = true
			local ok, err = attack({ player = who })
			sniper.busy = false
			report(ok, "Hit " .. who.Name, err)
		end)
	end,
})

sheriffSec:Toggle({
	Text = "Auto kill murderer",
	Icon = "zap",
	RevertOnClose = true,
	Callback = function(on)
		state.autoKillMurderer = on
		if on then danger.moveGate = 0 if tryAuto then tryAuto() end end
		if not on then danger.stopPursuit() end
		say(on and "Auto kill murderer armed" or "Auto kill murderer off", "skull", on and "accent" or "muted")
	end,
})

ui.grabGunBtn = sheriffSec:Button({
	Text = "Grab dropped gun",
	Icon = "hand",
	ButtonText = "Grab",
	ButtonIcon = "hand",
	Callback = function()
		local ok, info = grabDroppedGun()
		report(ok, "Gun: " .. tostring(info), info)
	end,
})

sheriffSec:Toggle({
	Text = "Auto pickup gun",
	Icon = "package",
	Save = prefs.key("combat", "autoPickup"),
	Callback = function(on)
		state.autoPickup = on
		if on then danger.moveGate = 0 if tryAuto then tryAuto() end end
		if not on and coinRun and coinRun.kind == "gun" then
			grab.walking = false
			cutRun()
		end
	end,
})

local function gateFovToggle()
	if not ui.showFovToggle then return end
	if not state.silentAim then
		ui.showFovToggle:Disable("Turn on silent aim first")
	elseif state.aimInfinite then
		ui.showFovToggle:Disable("An infinite FOV has no circle")
	else
		ui.showFovToggle:Enable()
	end
end

sheriffSec:Toggle({
	Text = "Silent aim",
	Icon = "target",
	RevertOnClose = true,
	Callback = function(on)
		state.silentAim = on
		if on then hookSilentAim() end
		say(on and "Silent aim on" or "Silent aim off", "crosshair", on and "accent" or "muted")
		gateFovToggle()
		refreshCircle()
	end,
})

sheriffSec:Slider({
	Text = "Aim FOV",
	Icon = "scan-eye",
	Description = "All the way right is infinite.",
	Min = 20, Max = AIM_FOV_MAX, Default = 160, Step = 10, Suffix = "px",
	Save = prefs.key("combat", "aimFov"),
	Callback = function(v)
		state.aimFov = v
		state.aimInfinite = v >= AIM_FOV_MAX
		gateFovToggle()
		refreshCircle()
	end,
})
Ember.Persist.set("aimInfinite", nil)

ui.showFovToggle = sheriffSec:Toggle({
	Text = "Show FOV circle",
	Icon = "circle",
	Default = true,
	Save = prefs.key("combat", "showFov"),
	Disabled = true,
	DisabledReason = "Turn on silent aim first",
	Callback = function(on)
		state.showFov = on
		refreshCircle()
	end,
})
gateFovToggle()

local auraSec = combatSec:Group({ Text = "Kill aura", Icon = "radar", Open = false })

ui.auraStatus = auraSec:Status({ Text = "Hits", Default = "nobody, you are unarmed", Icon = "crosshair" })

auraSec:Toggle({
	Text = "Enabled",
	Icon = "toggle-left",
	RevertOnClose = true,
	Callback = function(on)
		state.killAura = on
		say(on and "Kill aura on" or "Kill aura off", "radar", on and "accent" or "muted")
	end,
})

auraSec:Slider({
	Text = "Range",
	Icon = "radar",
	Min = 4, Max = 200, Default = 12, Step = 1, Suffix = " studs",
	Save = prefs.key("combat", "killRange"),
	Callback = function(v) state.killRange = v end,
})

auraSec:Slider({
	Text = "Interval",
	Icon = "timer",
	Min = 0.05, Max = 1, Default = 0.2, Step = 0.05, Suffix = "s",
	Save = prefs.key("combat", "killDelay"),
	Callback = function(v) state.killDelay = v end,
})

local mapSec = win:Section("Map", "map")
mapSec:Title({ Text = "TELEPORT", Icon = "move" })

mapSec:Button({
	Text = "Teleport to map",
	Icon = "map-pin",
	ButtonText = "Go",
	ButtonIcon = "crosshair",
	Style = "filled",
	Click = { Icon = "check", Hold = 1 },
	Callback = function()
		local ok, info = teleportToGameMap()
		report(ok, "Teleported to " .. tostring(info), info)
	end,
})

mapSec:IconButton({
	Text = "Teleport to role",
	Icon = "venetian-mask",
	Tooltip = "Red goes to the murderer, blue to whoever holds the gun.",
	Buttons = {
		{
			Icon = "skull",
			Danger = true,
			Callback = function()
				local ok, info = teleportToPlayer((findByRole("Murderer")))
				report(ok, "Went to " .. tostring(info), info)
			end,
		},
		{
			Icon = "shield",
			Callback = function()
				local ok, info = teleportToPlayer((gunHolder()))
				report(ok, "Went to " .. tostring(info), info)
			end,
		},
	},
})

ui.tpPick = mapSec:Dropdown({
	Text = "Player",
	Icon = "user",
	Options = { "nobody" },
	Default = "nobody",
})

mapSec:Button({
	Text = "Teleport to player",
	Icon = "navigation",
	ButtonText = "Go",
	ButtonIcon = "zap",
	Tooltip = "Puts you right behind the player picked above.",
	Callback = function()
		local who = Players:FindFirstChild(tostring(ui.tpPick:Get()))
		local ok, info = teleportToPlayer(who)
		report(ok, "Went to " .. tostring(info), info)
	end,
})

mapSec:Button({
	Text = "Walk to player",
	Icon = "footprints",
	ButtonText = "Walk",
	ButtonIcon = "footprints",
	Tooltip = "Uses the auto walker to reach the player picked above.",
	Callback = function()
		local who = Players:FindFirstChild(tostring(ui.tpPick:Get()))
		if not who or not hitPartOf(who) then
			report(false, nil, "that player has no character")
			return
		end
		if coinRun and coinRun.kind == "pursuit" then
			report(false, nil, "already walking to someone")
			return
		end
		say("Walking to " .. who.Name, "footprints", "accent")
		task.spawn(function()
			local ok, reached = pcall(pursue, who, 6)
			report(ok and reached, "Reached " .. who.Name, ok and ("could not reach " .. who.Name) or reached)
		end)
	end,
})

mapSec:Separator()
mapSec:Title({ Text = "VOTING", Icon = "vote" })

do
	local saved = Ember.Store.get("mm2_maps")
	if type(saved) == "table" then
		local names = {}
		for _, n in saved do
			if type(n) == "string" then table.insert(names, n) end
		end
		vote.learn(names)
	end
	table.sort(vote.known)
end

vote.pick = mapSec:Dropdown({
	Text = "Favourite maps",
	Icon = "map-pinned",
	Description = "Tick any you like and the lobby vote goes to the first ticked one on the board. Nothing ticked means no auto vote.",
	Options = table.clone(vote.known),
	Multi = true,
	Style = "check",
	Default = {},
	Save = prefs.key("coins", "favMaps"),
	Callback = function(list)
		state.favMaps = type(list) == "table" and list or {}
		state.autoVote = #state.favMaps > 0
		task.defer(vote.check)
	end,
})

mapSec:Separator()
mapSec:Title({ Text = "COINS", Icon = "circle-dollar-sign" })

mapSec:Toggle({
	Text = "Coins first",
	Description = "Fills the bag before auto kill, sheriff shots and cheater hunts start. Kill aura and defending yourself stay on.",
	Icon = "list-ordered",
	Save = prefs.key("coins", "coinsFirst"),
	Callback = function(on) state.coinsFirst = on end,
})

mapSec:Toggle({
	Text = "Avoid the murderer",
	Description = "While auto coins runs: skips coins near them and walks away when they get close.",
	Icon = "shield-alert",
	Default = true,
	Save = prefs.key("coins", "avoid"),
	Callback = function(on) state.avoid = on end,
})

mapSec:Toggle({
	Text = "Auto collect coins",
	Description = "Walks the map collecting coins, and keeps wandering with the pathfinder when none are in reach.",
	Icon = "zap",
	RevertOnClose = true,
	Callback = function(on)
		state.autoCoin = on
		if on then
			danger.moveGate = 0
			if not danger.wanting() then startCoinRun() end
		elseif not state.survive then
			danger.stopAll()
		else
			cutRun()
		end
		say(on and "Auto coins on" or "Auto coins off", "circle-dollar-sign", on and "accent" or "muted")
	end,
})

local plrSec = win:Section("Player", "person-standing")
plrSec:Title({ Text = "SAFETY", Icon = "shield-check" })

plrSec:Toggle({
	Text = "Anti-fling",
	Description = "Other players cannot collide with you, so nobody can launch you.",
	Icon = "shield",
	Default = true,
	Save = prefs.key("antifling", "antiFling"),
	Callback = function(on)
		state.antiFling = on
		if not on then
			for _, who in Players:GetPlayers() do
				if who ~= player and who.Character then plr.restoreCollisions(who.Character) end
			end
		end
	end,
})

plrSec:Separator()
plrSec:Title({ Text = "MOVEMENT", Icon = "move" })

plrSec:Slider({
	Text = "Walk speed",
	Icon = "gauge",
	Min = 16, Max = 25, Default = 16, Step = 1, Suffix = " studs/s",
	Save = prefs.key("movement", "walkSpeed"),
	Callback = function(v)
		state.speed = v
		if v == 16 then plr.plrRestoreWalk() end
	end,
})

plrSec:Slider({
	Text = "Jump power",
	Icon = "arrow-up",
	Min = 50, Max = 300, Default = 50, Step = 5,
	Save = prefs.key("movement", "jumpPower"),
	Callback = function(v)
		state.jump = v
		if v == 50 then plr.plrRestoreJump() end
	end,
})

plrSec:Slider({
	Text = "Gravity",
	Icon = "arrow-down",
	Min = 0, Max = 400, Default = 196, Step = 2,
	Save = prefs.key("movement", "gravity"),
	Callback = function(v)
		state.gravity = v
		if v == 196 then Workspace.Gravity = 196.2 end
	end,
})

plrSec:Separator()
plrSec:Title({ Text = "FLIGHT", Icon = "plane" })

plrSec:Toggle({
	Text = "Fly",
	Description = "WASD and the camera steer, Space rises, Shift drops.",
	Icon = "plane",
	RevertOnClose = true,
	Callback = function(on)
		state.fly = on
		if on then plr.plrStartFly() else plr.plrStopFly() end
	end,
})

plrSec:Slider({
	Text = "Fly speed",
	Icon = "wind",
	Min = 10, Max = 300, Default = 60, Step = 5, Suffix = " studs/s",
	Save = prefs.key("movement", "flySpeed"),
	Callback = function(v) state.flySpeed = v end,
})

plrSec:Separator()
plrSec:Title({ Text = "FUN", Icon = "sparkles" })

plrSec:Toggle({
	Text = "Noclip",
	Icon = "ghost",
	RevertOnClose = true,
	Callback = function(on)
		state.noclip = on
		if not on then plr.restoreCollisions(myChar()) end
	end,
})

local espSec = win:Section("Visuals", "eye")
espSec:Title({ Text = "ESP", Icon = "eye" })

espSec:Toggle({
	Text = "Role ESP",
	Icon = "users",
	Save = prefs.key("esp", "roleEsp"),
	RevertOnClose = true,
	Callback = function(on)
		local changed = flip("roleEsp", on)
		refreshRoleEsp()
		if changed then say(on and "Role ESP on" or "Role ESP off", "eye", on and "accent" or "muted") end
	end,
})

espSec:Toggle({
	Text = "Name tags",
	Icon = "tag",
	Save = prefs.key("esp", "nameEsp"),
	RevertOnClose = true,
	Callback = function(on)
		state.nameEsp = on
		refreshRoleEsp()
	end,
})

espSec:Toggle({
	Text = "Show dead players",
	Icon = "skull",
	Save = prefs.key("esp", "showDead"),
	RevertOnClose = true,
	Callback = function(on)
		state.showDead = on
		refreshRoleEsp()
		esp.refreshBodies()
	end,
})

espSec:Toggle({
	Text = "Gun ESP",
	Icon = "package",
	Save = prefs.key("esp", "gunEsp"),
	RevertOnClose = true,
	Callback = function(on)
		local changed = flip("gunEsp", on)
		refreshGunEsp()
		if changed then say(on and "Gun ESP on" or "Gun ESP off", "package", on and "accent" or "muted") end
	end,
})

espSec:Toggle({
	Text = "Coin ESP",
	Icon = "circle-dollar-sign",
	Save = prefs.key("esp", "coinEsp"),
	RevertOnClose = true,
	Callback = function(on)
		local changed = flip("coinEsp", on)
		refreshCoinEsp()
		if changed then say(on and "Coin ESP on" or "Coin ESP off", "circle-dollar-sign", on and "accent" or "muted") end
	end,
})

ui.colourSec = espSec:Group({ Text = "Colours", Icon = "palette" })

ui.colourSec:ColorPicker({
	Text = "Murderer",
	Description = "Role ESP colour for the murderer.",
	Icon = "skull",
	Default = ROLE_COLOURS.Murderer,
	Save = prefs.key("esp", "tintMurderer"),
	Callback = function(colour)
		ROLE_COLOURS.Murderer = colour
		esp.repaintRoles()
	end,
})

ui.colourSec:ColorPicker({
	Text = "Sheriff",
	Description = "Role ESP colour for the sheriff and the hero.",
	Icon = "shield",
	Default = ROLE_COLOURS.Sheriff,
	Save = prefs.key("esp", "tintSheriff"),
	Callback = function(colour)
		ROLE_COLOURS.Sheriff = colour
		ROLE_COLOURS.Hero = colour
		esp.repaintRoles()
	end,
})

ui.colourSec:ColorPicker({
	Text = "Innocent",
	Description = "Role ESP colour for innocents.",
	Icon = "user",
	Default = ROLE_COLOURS.Innocent,
	Save = prefs.key("esp", "tintInnocent"),
	Callback = function(colour)
		ROLE_COLOURS.Innocent = colour
		esp.repaintRoles()
	end,
})

ui.colourSec:ColorPicker({
	Text = "Dead bodies",
	Description = "Highlight colour for corpses.",
	Icon = "skull",
	Default = esp.tint.bodyFill,
	Save = prefs.key("esp", "tintBody"),
	Callback = function(colour)
		esp.tint.bodyFill = colour
		esp.tint.bodyEdge = colour
		clearMap(esp.bodies)
		esp.refreshBodies()
	end,
})

ui.colourSec:ColorPicker({
	Text = "Guns",
	Description = "Highlight colour for dropped and carried guns.",
	Icon = "package",
	Default = esp.tint.gunFill,
	Save = prefs.key("esp", "tintGun"),
	Callback = function(colour)
		esp.tint.gunFill = colour
		esp.tint.gunEdge = colour
		clearMap(esp.gunBoxes)
		refreshGunEsp()
	end,
})

ui.colourSec:ColorPicker({
	Text = "Coins",
	Description = "Marker colour for coins.",
	Icon = "circle-dollar-sign",
	Default = esp.tint.coin,
	Save = prefs.key("esp", "tintCoin"),
	Callback = function(colour)
		esp.tint.coin = colour
		clearMap(esp.coinBoxes)
		refreshCoinEsp()
	end,
})

-------------------------------------------------------------------- BEGIN DEBUG HEATMAP (temporary)
-- Draws the lattice around you, green where the router can reach and red where it cannot.
-- Everything lives on esp.heat and under one MM2Heat folder, so deleting this fenced block
-- and the esp.heat teardown line in OnDestroy removes it completely.
esp.heat = { folder = nil, conn = nil, tiles = {}, at = 0, world = nil, trapsAt = 0,
	pieces = setmetatable({}, { __mode = "k" }), risks = setmetatable({}, { __mode = "k" }),
	shade = setmetatable({}, { __mode = "k" }), traps = setmetatable({}, { __mode = "k" }),
	lit = setmetatable({}, { __mode = "k" }), cutOf = setmetatable({}, { __mode = "k" }),
	owner = setmetatable({}, { __mode = "k" }), cut = nil, seen = nil, eyeAt = nil, eyeDir = nil,
	dirty = true, foeAt = nil, legAt = nil, walk = nil, walkAt = nil }

function esp.heatClear()
	if esp.heat.conn then
		esp.heat.conn:Disconnect()
		esp.heat.conn = nil
	end
	if esp.heat.folder then
		esp.heat.folder:Destroy()
		esp.heat.folder = nil
	end
	table.clear(esp.heat.tiles)
	for _, old in Workspace:GetChildren() do
		if old.Name == "MM2Heat" then old:Destroy() end
	end
end

function esp.heatCone()
	-- What the camera can actually see, as plain arithmetic.
	-- WorldToViewportPoint on every node measured 5.98ms a frame, more than the
	-- draw it was meant to save; a dot product against the look vector is free.
	local cam = Workspace.CurrentCamera
	if not cam then return nil end
	local cf = cam.CFrame
	local vp = cam.ViewportSize
	-- half the diagonal field of view, widened so tiles at the edge are already drawn
	local vertical = math.rad(cam.FieldOfView) / 2
	local aspect = vp.Y > 0 and vp.X / vp.Y or 1.7
	local widest = math.atan(math.tan(vertical) * math.sqrt(1 + aspect * aspect))
	return cf.Position, cf.LookVector, math.cos(math.min(widest + 0.25, 1.5))
end

function esp.heatColour(fraction)
	-- one hue only: quiet slate where it is safe, red where it is not
	local f = math.clamp(fraction, 0, 1)
	local calm = Color3.fromRGB(38, 52, 74)
	local warm = Color3.fromRGB(150, 45, 45)
	local hot = Color3.fromRGB(235, 40, 40)
	if f < 0.65 then return calm:Lerp(warm, f / 0.65) end
	return warm:Lerp(hot, (f - 0.65) / 0.35)
end

function esp.heatPiece(node)
	local known = esp.heat.pieces[node]
	if known ~= nil then return known ~= false and known or nil end
	local ok, label = pcall(function() return nav.world:Piece(node) end)
	label = ok and label or nil
	esp.heat.pieces[node] = label == nil and false or label
	return label
end

function esp.heatTile(index)
	local tile = esp.heat.tiles[index]
	if not tile or not tile.Parent then
		tile = Instance.new("Part")
		tile.Name = "Tile"
		tile.Anchored, tile.CanCollide, tile.CanTouch, tile.CanQuery = true, false, false, false
		tile.Material = Enum.Material.Neon
		tile.TopSurface, tile.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
		tile.Parent = esp.heat.folder
		esp.heat.tiles[index] = tile
	end
	return tile
end

function esp.heatView()
	-- Which cells are on screen only changes when the eye moves or turns.
	local cam = Workspace.CurrentCamera
	if not cam then return false end
	local at, dir = cam.CFrame.Position, cam.CFrame.LookVector
	if not esp.heat.eyeAt then return true end
	return (at - esp.heat.eyeAt).Magnitude >= 2 or dir:Dot(esp.heat.eyeDir) < 0.995
end

function esp.heatStale()
	-- What colour each cell is only changes when the murderer or the route moves.
	if esp.heat.dirty then return true end
	local foe = danger.foe()
	local at = foe and foe.Position or nil
	if (at ~= nil) ~= (esp.heat.foeAt ~= nil) then return true end
	if at and (at - esp.heat.foeAt).Magnitude > 2 then return true end
	local leg = coinRun and coinRun.active and coinRun.leg or nil
	return leg ~= esp.heat.legAt
end

function esp.heatWalk(hunter, reach)
	-- Which cells can he actually WALK to? Straight-line distance calls a cell one
	-- stud behind a wall as dangerous as one in the open: measured on Mansion2,
	-- 396 of 536 cells near him were not reachable at all.
	-- Reach filters by straight line from him, so a band means "connected to him
	-- and within N studs", not N studs of walking. That is what stops the bleed.
	if not hunter or not nav.live() or not nav.navigator then return nil end
	local found = { bands = 4 }
	-- One flood, sized to how far he can actually get. Bands come from distance
	-- inside the walk, which Reach already filters on. Four separate floods to
	-- 120 studs measured 12ms; this is the same answer for about 1.5ms.
	local far = math.max(reach or 48, 24)
	do
		local step = 1
		local ok = pcall(function()
			nav.navigator:Reachable({
				Agent = nav.agent,
				Position = hunter,
				Reach = far,
				Nodes = nav.budget(true),
				Blocked = nav.blocked,
				Score = function(st)
					local key = (st.ix or 0) * 100000 + (st.iz or 0)
					local p = st.Lattice and st.Floor or st.Position
					local d = (p - hunter).Magnitude
					local band = d <= far * 0.25 and 1 or d <= far * 0.5 and 2
						or d <= far * 0.75 and 3 or 4
					if found[key] == nil or band < found[key] then found[key] = band end
					return 0
				end,
			})
		end)
		if not ok then return nil end
	end
	return found
end

function esp.heatDraw()
	local root = myRoot()
	if not root or not nav.live() then
		-- the lattice went away with the map: drop the tiles rather than leave them behind
		if esp.heat.folder then
			esp.heat.folder:Destroy()
			esp.heat.folder = nil
			table.clear(esp.heat.tiles)
		end
		return
	end
	local now = os.clock()
	if esp.heat.world ~= nav.world then
		-- new lattice: draw at once rather than waiting out the throttle
		esp.heat.world = nav.world
		esp.heat.at = 0
		table.clear(esp.heat.pieces)
		table.clear(esp.heat.risks)
		esp.heat.cut, esp.heat.seen = nil, nil
		esp.heat.walk, esp.heat.walkAt = nil, nil
		esp.heat.dirty = true
	end
	-- Nothing on screen can have changed: do not touch a single tile.
	local viewMoved = esp.heatView()
	local heatMoved = esp.heatStale()
	if not viewMoved and not heatMoved and esp.heat.seen then return end
	esp.heat.at = now
	if not esp.heat.folder or not esp.heat.folder.Parent then
		local folder = Instance.new("Folder")
		folder.Name = "MM2Heat"
		folder.Parent = Workspace
		esp.heat.folder = folder
		table.clear(esp.heat.tiles)
	end

	local here = root.Position
	local range = state.heatRange or 200
	local world = nav.world
	local pitch = world.cell or 4
	local standing = world:NodeAt(here, 8)
	local mine = standing and esp.heatPiece(standing) or nil
	local eye, look, minDot = esp.heatCone()
	local budget = state.heatTiles or 2200
	local cut = math.min(esp.heat.cut or range, range)
	local nodes = esp.heat.seen
	if eye and (viewMoved or not nodes) then
		-- the whole map is a candidate; the camera decides what is worth a part
		nodes = {}
		local reach = cut * cut
		for _, byZ in pairs(world.columns) do
			for _, list in pairs(byZ) do
				for _, node in list do
					local to = node.Position - eye
					local far = to.X * to.X + to.Y * to.Y + to.Z * to.Z
					if far <= reach then
						-- behind the camera is never drawn; underfoot is always drawn
						if far < 144 or to:Dot(look) >= minDot * math.sqrt(far) then
							table.insert(nodes, node)
						end
					end
				end
			end
		end
		esp.heat.seen = nodes
		esp.heat.eyeAt, esp.heat.eyeDir = eye, look
		-- how far to draw is not a setting, it is whatever fits the budget here
		-- Aim straight at the reach the count implies rather than creeping toward
		-- it: cells grow with area, so the reach that fits is cut * sqrt(budget/seen).
		-- Fixed ratios overshot to 2896 cells against a 2200 budget (10.8ms a frame).
		-- An empty view says nothing about direction, so scaling the reach by it
		-- pins it at the floor forever: seen=0 left cut stuck at 40 studs on a
		-- node map and nothing drew at all. Open all the way back up instead.
		local seen = #nodes
		if seen == 0 then
			esp.heat.cut = range
		elseif seen > budget or seen < budget * 0.7 then
			-- cells grow with area, so the reach that fits is cut * sqrt(budget/seen)
			local want = cut * math.sqrt(budget / seen)
			esp.heat.cut = math.clamp(cut + (want - cut) * 0.5, pitch * 6, range)
		end
	elseif not eye then
		nodes = world:Nearby(here, range)
	end
	nodes = nodes or {}
	local used = 0
	local flatSize = Vector3.new(pitch, 0.15, pitch)

	-- the murderer drives the heat: everything else is a modifier on top
	local foe = danger.foe()
	local hunter = foe and foe.Position or nil
	-- How far he is dangerous from is how far he can travel while you react, not
	-- a number I picked. Every player measures WalkSpeed 16; use what he is
	-- actually doing when that is faster.
	local pace = 16
	if foe then
		local v = foe.AssemblyLinearVelocity
		pace = math.max(pace, Vector3.new(v.X, 0, v.Z).Magnitude)
	end
	local hunted = math.max(pace * 3, 1)
	if hunter then
		if not esp.heat.walkAt or (hunter - esp.heat.walkAt).Magnitude > 2 then
			esp.heat.walk = esp.heatWalk(hunter, hunted)
			esp.heat.walkAt = hunter
		end
	else
		esp.heat.walk, esp.heat.walkAt = nil, nil
	end

	-- trap and lethal memory, sampled per draw rather than per tile
	if os.clock() - (esp.heat.trapsAt or 0) > 1 then
		esp.heat.trapsAt = os.clock()
		table.clear(esp.heat.traps)
		for _, node in nodes do
			local okT, bad = pcall(nav.blocked, node)
			if okT and bad then esp.heat.traps[node] = true end
		end
	end

	-- the route we are actually walking, so the planned way through stands out
	local plan = {}
	local run = coinRun
	if run and run.active and run.points then
		local leg = math.max(run.leg or 1, 1)
		local ahead = 0
		for i = leg, #run.points do
			local wp = run.points[i]
			local at = type(wp) == "table" and wp.Position or wp
			if at then
				ahead += 1
				if ahead > 14 then break end
				table.insert(plan, { at = at, order = ahead })
			end
		end
	end

	for _, node in nodes do
		used += 1
		if used > (state.heatTiles or 2200) then break end
		local tile = esp.heatTile(used)
		local floor = node.Floor or node.Position
		local head = node.Clear or pitch
		local rest = CFrame.new(floor + Vector3.new(0, 0.12, 0))
		if tile.Size ~= flatSize then tile.Size = flatSize end
		-- tiles are reused between passes: a part that was a rotated link bar must be levelled
		if tile.CFrame ~= rest then tile.CFrame = rest end

		-- how dangerous is it to stand here, not how far away is it
		local risk = esp.heat.risks[node]
		if risk == nil then
			local okRisk, got = pcall(function() return world:Risk(node) end)
			risk = okRisk and type(got) == "number" and got or 0
			esp.heat.risks[node] = risk
		end
		local tight = head < 6 and (6 - head) / 6 or 0
		local heat = risk * 0.8 + tight * 0.35

		if hunter then
			-- hottest where the murderer stands, cooling over his reach
			-- A cell he cannot walk to is not dangerous, however close it looks.
			local walk = esp.heat.walk
			local band = walk and walk[(node.ix or 0) * 100000 + (node.iz or 0)] or nil
			if band then
				local near = 1 - (band - 1) / walk.bands
				heat += near * near * 1.9
			elseif not walk then
				-- no flood this pass: fall back to distance rather than showing nothing
				local toHim = danger.flat(node.Position, hunter).Magnitude
				local drop = math.abs(node.Position.Y - hunter.Y)
				local near = 1 - math.clamp((toHim + drop * 2) / hunted, 0, 1)
				heat += near * near * 1.9
			end
		end
		if esp.heat.traps[node] then heat += 1.2 end
		heat = math.clamp(heat, 0, 1)

		-- ease toward the new value so the wash moves with you instead of snapping
		local was = esp.heat.shade[node]
		heat = was and (was * 0.72 + heat * 0.28) or heat
		esp.heat.shade[node] = heat

		local cut = mine ~= nil and esp.heatPiece(node) ~= mine
		local want, fade
		if cut then
			-- cannot be reached from where you stand: drawn dark and flat, not coloured
			want, fade = Color3.fromRGB(16, 16, 18), 0.55
		else
			want, fade = esp.heatColour(heat), 0.62 - heat * 0.22
		end
		-- only write when it actually differs: property writes are the whole cost here
		local shown = esp.heat.lit[node]
		-- pooled parts change owner as the camera turns: a recycled tile must repaint
		if esp.heat.owner[tile] ~= node then
			shown = nil
			esp.heat.owner[tile] = node
		end
		if not shown or math.abs(shown - heat) > 0.02 or cut ~= esp.heat.cutOf[node] then
			tile.Color = want
			tile.Transparency = fade
			esp.heat.lit[node] = heat
			esp.heat.cutOf[node] = cut
		end

		-- on the planned route: brighten it, strongest at the leg we are walking now
		local onPlan
		for _, step in plan do
			if danger.flat(step.at, node.Position).Magnitude <= pitch and math.abs(step.at.Y - node.Position.Y) < 8 then
				if not onPlan or step.order < onPlan then onPlan = step.order end
			end
		end
		if onPlan then
			local strength = 1 - (onPlan - 1) / 14
			-- the way we are walking: the only bright thing on screen
			tile.Color = Color3.fromRGB(80, 230, 160)
			tile.Transparency = 0.4 - strength * 0.3
			esp.heat.lit[node] = nil
			-- stay flat: widen and sit a little prouder, never grow tall enough to read as a post
			tile.Size = Vector3.new(pitch * 1.02, 0.16, pitch * 1.02)
			tile.CFrame = CFrame.new(floor + Vector3.new(0, 0.16 + strength * 0.06, 0))
		end
	end

	-- every way off this tile that is not plain walking: jumps, drops, climbs, ledges
	-- one bar per affordance, not per entry node, or a shared ledge draws dozens
	-- measured: these alone were 1836 parts and every millisecond of the frame cost
	local drawnAff = {}
	for _, node in (state.heatLinks and nodes or {}) do
		if used > (state.heatTiles or 2200) + 800 then break end
		local okAff, list = pcall(function() return world:AffordancesAt(node) end)
		if okAff and list then
			for _, aff in list do
				local exits = (not drawnAff[aff]) and (aff.Exits or aff.Entries)
				if exits then
					drawnAff[aff] = true
					for _, exit in exits do
						local to = exit.Position or exit.Floor
						if to then
							used += 1
							if used > (state.heatTiles or 2200) + 800 then break end
							local link = esp.heatTile(used)
							local from = (node.Floor or node.Position) + Vector3.new(0, 0.6, 0)
							local span = to - from
							local reach = span.Magnitude
							local rise = reach > 0.01 and math.abs(span.Y) / reach or 0
							-- a climb face is a vertical wall, not a route: mark its foot, do not lance the sky
							if reach > 0.5 and reach <= 26 and rise <= 0.55 then
								link.Size = Vector3.new(0.14, 0.14, reach)
								link.CFrame = CFrame.lookAt(from + span / 2, to)
								link.Color = Color3.fromRGB(120, 132, 150)
								link.Transparency = 0.55
							elseif reach > 0.5 and reach <= 26 then
								link.Size = Vector3.new(0.7, 0.7, 0.7)
								link.CFrame = CFrame.new(from + Vector3.new(0, 0.35, 0))
								link.Color = Color3.fromRGB(120, 132, 150)
								link.Transparency = 0.5
							else
								link.Size = Vector3.new(0.1, 0.1, 0.1)
								link.CFrame = CFrame.new(from)
								link.Transparency = 1
							end
						end
					end
				end
			end
		end
	end

	-- remember what this picture was drawn for, so the next frame can skip it
	esp.heat.dirty = false
	local drawnFoe = danger.foe()
	esp.heat.foeAt = drawnFoe and drawnFoe.Position or nil
	esp.heat.legAt = coinRun and coinRun.active and coinRun.leg or nil

	for i = used + 1, #esp.heat.tiles do
		if esp.heat.tiles[i] then
			esp.heat.tiles[i]:Destroy()
			esp.heat.tiles[i] = nil
		end
	end
end
---------------------------------------------------------------------- END DEBUG HEATMAP (temporary)

local statsSec = win:Section("Stats", "activity")
local S = {}
statsSec:Title({ Text = "YOUR ROLE", Icon = "user" })

S.myRoleStatus = statsSec:Status({ Text = "You are", Default = "waiting for round", Icon = "drama" })
S.weaponStatus = statsSec:Status({ Text = "Weapon", Default = "unarmed", Icon = "swords" })
S.murdererStatus = statsSec:Status({ Text = "Murderer", Default = "waiting for round", Icon = "skull" })
S.sheriffStatus = statsSec:Status({ Text = "Sheriff", Default = "waiting for round", Icon = "shield" })

statsSec:Separator()
statsSec:Title({ Text = "ROUND", Icon = "clock" })

S.readyStatus = statsSec:Status({ Text = "Can act", Default = "no round running", Icon = "shield-check" })
S.timerStatus = statsSec:Status({ Text = "Round timer", Default = "intermission", Icon = "timer" })
S.aliveStatus = statsSec:Status({ Text = "Alive", Default = "waiting for round", Icon = "heart" })
S.coinStatus = statsSec:Status({ Text = "Coins left", Default = "0", Icon = "circle-dollar-sign" })
S.mapStatus = statsSec:Status({ Text = "Current map", Default = "none", Icon = "map-pin" })

statsSec:Separator()
statsSec:Title({ Text = "THIS SESSION", Icon = "activity" })

S.sessCoins = statsSec:Status({ Text = "Coins collected", Default = "0", Icon = "circle-dollar-sign" })
S.sessKnifeKills = statsSec:Status({ Text = "Knife kills", Default = "0", Icon = "skull" })
S.sessGunKills = statsSec:Status({ Text = "Gun kills", Default = "0", Icon = "shield" })
S.sessDeaths = statsSec:Status({ Text = "Deaths", Default = "0", Icon = "heart-crack" })
S.sessKd = statsSec:Status({ Text = "K/D", Default = "-", Icon = "percent" })
S.sessXp = statsSec:Status({ Text = "XP gained", Default = "0", Icon = "trending-up" })
S.sessLevels = statsSec:Status({ Text = "Levels gained", Default = "0", Icon = "star" })
S.sessRounds = statsSec:Status({ Text = "Rounds seen", Default = "0", Icon = "repeat" })
S.sessTime = statsSec:Status({ Text = "Running for", Default = "0m 0s", Icon = "clock" })

statsSec:Separator()
statsSec:Title({ Text = "ALL TIME", Icon = "database" })

S.totCoins = statsSec:Status({ Text = "Coins collected", Default = "0", Icon = "circle-dollar-sign" })
S.totKnifeKills = statsSec:Status({ Text = "Knife kills", Default = "0", Icon = "skull" })
S.totGunKills = statsSec:Status({ Text = "Gun kills", Default = "0", Icon = "shield" })
S.totDeaths = statsSec:Status({ Text = "Deaths", Default = "0", Icon = "heart-crack" })
S.totKd = statsSec:Status({ Text = "K/D", Default = "-", Icon = "percent" })
S.totSurvived = statsSec:Status({ Text = "Rounds survived", Default = "0", Icon = "heart" })
S.totRounds = statsSec:Status({ Text = "Rounds played", Default = "0", Icon = "repeat" })
S.totMurderer = statsSec:Status({ Text = "Rounds as Murderer", Default = "0", Icon = "skull" })
S.totSheriff = statsSec:Status({ Text = "Rounds as Sheriff", Default = "0", Icon = "shield" })
S.totInnocent = statsSec:Status({ Text = "Rounds as Innocent", Default = "0", Icon = "user" })
S.totGuns = statsSec:Status({ Text = "Guns grabbed", Default = "0", Icon = "hand" })
S.totXp = statsSec:Status({ Text = "XP gained", Default = "0", Icon = "trending-up" })
S.totLevels = statsSec:Status({ Text = "Levels gained", Default = "0", Icon = "star" })
S.totTime = statsSec:Status({ Text = "Time with script", Default = "0m 0s", Icon = "clock" })
S.totSessions = statsSec:Status({ Text = "Times launched", Default = "0", Icon = "play" })

statsSec:Separator()
statsSec:Title({ Text = "GAME PROFILE", Icon = "user" })

S.acctLevel = statsSec:Status({ Text = "Level", Default = "loading", Icon = "star" })
S.acctXp = statsSec:Status({ Text = "Total XP", Default = "loading", Icon = "trending-up" })
S.acctElims = statsSec:Status({ Text = "Eliminations", Default = "loading", Icon = "skull" })
S.acctSurvivals = statsSec:Status({ Text = "Survivals", Default = "loading", Icon = "heart" })
S.acctVictories = statsSec:Status({ Text = "Victories", Default = "loading", Icon = "trophy" })

local setSec = win:Section("Settings", "settings")

------------------------------------------------------------------ BEGIN DEBUG TOGGLES (temporary)
setSec:Title({ Text = "DEBUGGING", Icon = "bug" })

setSec:Toggle({
	Text = "Lattice heatmap",
	Description = "Fills the walkable map around you with the pathfinding lattice, cool where it is close and cheap, hot where it is far, raised or awkward. For diagnosing routing; delete when done.",
	Icon = "grid-3x3",
	Callback = function(on)
		state.heatmap = on
		if not on then
			esp.heatClear()
			return
		end
		if esp.heat.conn then return end
		esp.heat.conn = RunService.Heartbeat:Connect(function()
			if not state.heatmap then return end
			pcall(esp.heatDraw)
		end)
	end,
})

setSec:Slider({
	Text = "Heatmap reach",
	Description = "The furthest the heatmap may reach. It draws closer than this when a map is dense enough to need it.",
	Icon = "ruler",
	Min = 40,
	Max = 400,
	Default = 200,
	Suffix = " studs",
	Callback = function(v) state.heatRange = v end,
})

setSec:Separator()
-------------------------------------------------------------------- END DEBUG TOGGLES (temporary)

setSec:Title({ Text = "INTERFACE", Icon = "layout" })

setSec:Keybind({
	Text = "Hide and show",
	Icon = "app-window",
	Default = Enum.KeyCode.RightShift,
	Save = prefs.key("interface", "guiKey"),
	Callback = function() win:Toggle() end,
})

setSec:Toggle({
	Text = "Notifications",
	Icon = "bell",
	Default = true,
	Save = prefs.key("interface", "notify"),
	Callback = function(on) state.notify = on end,
})

setSec:Toggle({
	Text = "Anti-idle",
	Description = "Stops the 20 minute idle kick while the script runs.",
	Icon = "coffee",
	Default = true,
	Save = prefs.key("interface", "antiIdle"),
	Callback = function(on) state.antiIdle = on end,
})

setSec:Dropdown({
	Text = "Reset after a win",
	Description = "Respawns you the moment your side wins, before the camera pans. Pick the roles it applies to, or none to turn it off.",
	Icon = "rotate-cw",
	Options = { "Murderer", "Sheriff", "Innocent", "Hero" },
	Multi = true,
	Style = "check",
	Default = { "Murderer" },
	Save = prefs.key("interface", "resetFor2"),
	FireOnStart = true,
	Callback = function(list)
		local set = {}
		if type(list) == "table" then
			for _, name in list do set[name] = true end
		end
		state.resetFor = set
	end,
})
Ember.Persist.set("resetOnWin", nil)

do
	local keepGroup = setSec:Group({ Text = "Remember between sessions", Icon = "save", Open = false })
	keepGroup:Description("Applies from the next launch.")
	for _, entry in {
		{ key = "movement", text = "Player sliders", desc = "Walk speed, jump power, gravity, fly speed" },
		{ key = "esp", text = "ESP", desc = "Role, name tags, dead players, gun and coin ESP" },
		{ key = "combat", text = "Combat", desc = "Legit mode, aim FOV, FOV circle, kill aura range and interval" },
		{ key = "coins", text = "Coins and voting", desc = "Coins first, avoid the murderer, favourite maps, auto walk speed, route around walls" },
		{ key = "interface", text = "Interface", desc = "Theme, hide key, notifications, anti-idle, reset after a win" },
		{ key = "antifling", text = "Anti-fling", desc = "Just the anti-fling toggle" },
	} do
		keepGroup:Toggle({
			Text = entry.text,
			Description = entry.desc,
			Default = prefs.keep[entry.key] == true,
			ResetTo = prefs.defaults[entry.key],
			Callback = function(on)
				prefs.keep[entry.key] = on
				Ember.Store.set("mm2_prefs", { keep = prefs.keep })
			end,
		})
	end
end

setSec:Separator()
setSec:Title({ Text = "AUTO WALKING", Icon = "footprints" })

setSec:Slider({
	Text = "Auto walk speed",
	Icon = "gauge",
	Description = "Used by coin collecting and Legit mode.",
	Min = 16, Max = 25, Default = 22, Step = 1, Suffix = " studs/s",
	Save = prefs.key("coins", "coinSpeed"),
	Callback = function(v) state.coinSpeed = v end,
})

setSec:Toggle({
	Text = "Route around walls",
	Icon = "route",
	Default = true,
	Save = prefs.key("coins", "coinPath"),
	Callback = function(on) state.coinPath = on end,
})

setSec:Separator()
setSec:Title({ Text = "THEME", Icon = "brush" })

local themePick = setSec:Dropdown({
	Text = "Theme",
	Icon = "palette",
	Options = Ember.ThemeNames(),
	Default = Ember.CurrentTheme or "Dark",
	ResetTo = "Dark",
	Save = prefs.key("interface", "theme"),
	Reapply = false,
	Callback = function(name) Ember.SetTheme(name) end,
})

Ember.OnThemesChanged(function(names) themePick:SetOptions(names) end, win)
Ember.OnThemeApplied(function(name) themePick:Set(name, true) end, win)

setSec:Separator()
setSec:Title({ Text = "CONFIG", Icon = "file-json" })

ui.cfgGroup = setSec:Group({ Text = "Export and import", Icon = "file-json", Open = false })
ui.cfgGroup:Description("Export copies every saved setting to the clipboard and writes rbxlolhub_config.json. Import reads that file back, so edit or replace it to share a default. Relaunch to apply.")

ui.configFile = "rbxlolhub_config.json"

ui.saveKeys = {
	"legit4", "spareFriends", "target", "autoPickup", "aimFov", "showFov",
	"killRange", "killDelay", "favMaps", "coinsFirst", "avoid", "coinSpeed",
	"coinPath", "antiFling", "walkSpeed", "jumpPower", "gravity", "flySpeed",
	"roleEsp", "nameEsp", "showDead", "gunEsp", "coinEsp",
	"guiKey", "notify", "antiIdle", "resetFor2", "theme",
}

function ui.configNow()
	local out = {}
	for _, key in ui.saveKeys do
		local v = Ember.Persist.get(key, nil)
		if v ~= nil then
			if typeof(v) == "EnumItem" then v = "Enum:" .. v.Name end
			out[key] = v
		end
	end
	return { version = 1, keep = prefs.keep, values = out }
end

ui.cfgGroup:Button({
	Text = "Export config",
	Icon = "upload",
	ButtonText = "Export",
	ButtonIcon = "clipboard-copy",
	Callback = function()
		local okJson, json = pcall(function()
			return game:GetService("HttpService"):JSONEncode(ui.configNow())
		end)
		if not okJson then
			report(false, nil, "could not encode: " .. tostring(json))
			return
		end
		local okCopy = pcall(setclipboard, json)
		local okFile = pcall(writefile, ui.configFile, json)
		if okCopy or okFile then
			say("Config saved, " .. #json .. " bytes", "clipboard-check", "accent")
		else
			report(false, nil, "could not copy or write the config")
		end
	end,
})

ui.cfgGroup:Button({
	Text = "Import config",
	Icon = "download",
	Description = "Reads rbxlolhub_config.json from your executor's workspace folder.",
	ButtonText = "Import",
	ButtonIcon = "clipboard-paste",
	Danger = true,
	Click = { Icon = "check", Hold = 1 },
	Callback = function()
		local okRead, text = pcall(readfile, ui.configFile)
		if not okRead or type(text) ~= "string" or #text < 2 then
			report(false, nil, "no " .. ui.configFile .. " to import")
			return
		end
		local okJson, cfg = pcall(function()
			return game:GetService("HttpService"):JSONDecode(text)
		end)
		if not okJson or type(cfg) ~= "table" or type(cfg.values) ~= "table" then
			report(false, nil, "that is not a valid config")
			return
		end
		local known, wrote = {}, 0
		for _, key in ui.saveKeys do known[key] = true end
		for key, v in pairs(cfg.values) do
			if known[key] then
				if type(v) == "string" and v:sub(1, 5) == "Enum:" then
					v = Enum.KeyCode[v:sub(6)] or nil
				end
				if v ~= nil then
					Ember.Persist.set(key, v)
					wrote += 1
				end
			end
		end
		if type(cfg.keep) == "table" then
			for key in pairs(prefs.defaults) do
				if type(cfg.keep[key]) == "boolean" then prefs.keep[key] = cfg.keep[key] end
			end
			Ember.Store.set("mm2_prefs", { keep = prefs.keep })
		end
		Ember.Persist.flush()
		report(wrote > 0, "Imported " .. wrote .. " settings, relaunch to apply", "nothing recognised in that config")
	end,
})

setSec:Separator()
setSec:Title({ Text = "SAVED DATA", Icon = "database" })

local totalsGroup = setSec:Group({ Text = "Manage saved stats", Icon = "wrench", Open = false })

totalsGroup:Button({
	Text = "Reset session only",
	Icon = "rotate-cw",
	ButtonText = "Reset",
	ButtonIcon = "rotate-cw",
	Click = { Rotate = 360 },
	Callback = function()
		for k, v in pairs(session) do
			if type(v) == "number" then session[k] = 0 end
		end
		session.xpStart, session.lastXp, session.levelStart, session.lastLevel = nil, nil, nil, nil
		session.startedAt = os.clock()
		say("Session counters reset", "rotate-cw")
	end,
})

totalsGroup:Button({
	Text = "Reset all-time totals",
	Icon = "trash-2",
	ButtonText = "Wipe",
	ButtonIcon = "trash-2",
	Danger = true,
	Callback = function()
		totals = blankTotals()
		totals.sessions = 1
		saveTotals(true)
		say("All-time totals wiped", "trash-2", "danger")
	end,
})

setSec:Button({
	Text = "Reset settings to default",
	Icon = "rotate-ccw",
	Description = "Puts every control, the theme and the window back to how they were on first launch. Stats stay.",
	ButtonText = "Reset",
	ButtonIcon = "rotate-ccw",
	Danger = true,
	Click = { Icon = "check", Hold = 1.5 },
	Callback = function()
		if win._fxBusy then return end
		task.spawn(function()
			win:Toggle(false)
			repeat RunService.Heartbeat:Wait() until not win._fxBusy
			for _, c in ui.controls do
				if c.kind == "Toggle" then c.handle:Set(c.default == true) end
			end
			for _, c in ui.controls do
				if c.kind ~= "Toggle" and c.default ~= nil then c.handle:Set(c.default) end
			end
			for key, default in pairs(prefs.defaults) do prefs.keep[key] = default end
			Ember.Store.set("mm2_prefs", { keep = prefs.keep })
			Ember.Persist.set("layout/rbxlolhub", nil)
			win:SetSize(760, 520)
			win:Centre()
			win:Toggle(true)
			say("Settings reset to default", "rotate-ccw", "accent")
		end)
	end,
})

setSec:Separator()
setSec:Title({ Text = "ABOUT", Icon = "heart" })

setSec:Credit({
	Text = "Bostonstrong567",
	Copy = "Bostonstrong567",
	Icon = "user",
	Description = "Wrote this script, and rbx.lol.",
})

setSec:Credit({
	Text = "Ember",
	Copy = "https://rbx.lol/docs/ember",
	Icon = "flame",
	Description = "The GUI library this menu is built with. Free, one loadstring, docs at rbx.lol/docs/ember.",
})

setSec:Credit({
	Text = "rbx.lol",
	Copy = "https://rbx.lol",
	Icon = "link",
	Description = "Scripts, a live game debugger and a browser script editor.",
})

setSec:Credit({
	Text = "Discord",
	Copy = "discord.gg/7ZCWaCswsF",
	Icon = "message-circle",
	Description = "Join for updates and support.",
})

----------------------------------------------------------------------------------------------- Stats
-- Session and all-time counters shown in the Stats tab.
local function profileXP()
	return ProfileData.NewXP
end

local function refreshRoundInfo()
	if gone then return end
	local mine = myRole()
	local waiting = getMap() == nil
	local blank = waiting and "waiting for round" or "not assigned"

	S.myRoleStatus:Set(mine or blank)
	win.StatusBar:Item("role", { Text = "Role: " .. (mine or "-") })

	local knife, gun = findTool("Knife"), findTool("Gun")
	S.weaponStatus:Set(knife and "Knife" or gun and "Gun" or (waiting and "waiting for round" or "unarmed"))
	ui.auraStatus:Set(knife and "everyone in range, knife" or gun and "the murderer only, gun" or "nobody, you are unarmed")
	ui.grabGunBtn:SetDisabled(gun ~= nil, "You already have a gun")

	local names = { "Everyone", "Nearest", "Gun holder" }
	for _, e in aliveTargets() do table.insert(names, e.player.Name) end
	ui.targetPick:SetOptions(names)
	if not table.find(names, ui.targetPick:Get()) then ui.targetPick:Set("Nearest") end

	local everyone = {}
	for _, who in Players:GetPlayers() do
		if who ~= player then table.insert(everyone, who.Name) end
	end
	table.sort(everyone)
	if #everyone == 0 then everyone = { "nobody" } end
	ui.tpPick:SetOptions(everyone)
	if not table.find(everyone, ui.tpPick:Get()) then ui.tpPick:Set(everyone[1]) end

	S.murdererStatus:Set(nameFor("Murderer") or blank)
	S.sheriffStatus:Set(nameFor("Sheriff") or nameFor("Hero") or blank)

	local alive, total = 0, 0
	for _, d in pairs(roleData()) do
		total += 1
		if not (d.Dead or d.Killed) then alive += 1 end
	end
	S.aliveStatus:Set(total > 0 and (alive .. " / " .. total) or blank)
	S.coinStatus:Set(tostring(#coinParts()))

	local able, why = canAct()
	S.readyStatus:Set(able and "yes" or why)

	local secs = roundTimer()
	if type(secs) == "number" and secs >= 0 then
		S.timerStatus:Set(string.format("%d:%02d", math.floor(secs / 60), secs % 60))
	else
		S.timerStatus:Set("intermission")
	end

	local sKills = session.killsAsMurderer + session.killsAsSheriff
	S.sessCoins:Set(tostring(session.coins))
	S.sessKnifeKills:Set(tostring(session.killsAsMurderer))
	S.sessGunKills:Set(tostring(session.killsAsSheriff))
	S.sessRounds:Set(tostring(session.rounds))
	S.sessTime:Set(fmtDuration(os.clock() - session.startedAt))
	S.sessDeaths:Set(tostring(session.deaths))
	S.sessKd:Set(session.deaths > 0 and string.format("%.2f", sKills / session.deaths) or tostring(sKills))

	local tKills = totals.killsAsMurderer + totals.killsAsSheriff
	S.totCoins:Set(tostring(totals.coins))
	S.totKnifeKills:Set(tostring(totals.killsAsMurderer))
	S.totGunKills:Set(tostring(totals.killsAsSheriff))
	S.totDeaths:Set(tostring(totals.deaths))
	S.totKd:Set(totals.deaths > 0 and string.format("%.2f", tKills / totals.deaths) or tostring(tKills))
	S.totSurvived:Set(tostring(totals.survived))
	S.totRounds:Set(tostring(totals.rounds))
	S.totMurderer:Set(tostring(totals.roundsAsMurderer))
	S.totSheriff:Set(tostring(totals.roundsAsSheriff))
	S.totInnocent:Set(tostring(totals.roundsAsInnocent))
	S.totGuns:Set(tostring(totals.gunsGrabbed))
	S.totXp:Set(string.format("+%d", math.floor(totals.xp)))
	S.totLevels:Set(string.format("+%d", math.floor(totals.levels)))
	S.totTime:Set(fmtDuration(totals.playtime))
	S.totSessions:Set(tostring(totals.sessions))

	local xp = profileXP()
	if type(xp) == "number" then
		if not session.xpStart then
			session.xpStart, session.lastXp = xp, xp
		end
		S.sessXp:Set(string.format("+%d", math.max(0, xp - session.xpStart)))
		S.acctXp:Set(tostring(math.floor(xp)))
		local lvl = LevelModule.GetLevel(xp)
		if type(lvl) == "number" then
			S.acctLevel:Set(tostring(lvl))
			if not session.levelStart then
				session.levelStart, session.lastLevel = lvl, lvl
			end
			if lvl > session.lastLevel then
				totals.levels += lvl - session.lastLevel
				session.lastLevel = lvl
				saveTotals()
			end
			S.sessLevels:Set(string.format("+%d", math.max(0, lvl - session.levelStart)))
		end
	end

	local s = ProfileData.Season1Stats
	if type(s) == "table" then
		S.acctElims:Set(tostring(s.Eliminations or 0))
		S.acctSurvivals:Set(tostring(s.Survivals or 0))
		S.acctVictories:Set(tostring(s.Victories or 0))
	end
end

local queued = { all = false, coins = false }

local function refreshAll()
	if queued.all then return end
	queued.all = true
	task.defer(function()
		queued.all = false
		refreshRoundInfo()
		refreshRoleEsp()
	end)
end

local function refreshCoins()
	if queued.coins then return end
	queued.coins = true
	task.defer(function()
		queued.coins = false
		refreshCoinEsp()
		refreshRoundInfo()
	end)
end

local autoBusy = false
local attackBusy = false

local function autoPass()
	local mine = myRole()
	if state.autoPickup and mine ~= "Murderer" and not findTool("Gun") then
		grabDroppedGun()
	end
	if not (findTool("Knife") or findTool("Gun")) then return end
	if coin.first() then return end

	if state.autoKillAll then
		local list = legalTargets()
		if #list == 0 then return end
		local holder = gunHolder()
		table.sort(list, function(a, b)
			if a.player == holder then return true end
			if b.player == holder then return false end
			return a.dist < b.dist
		end)
		attackBusy = true
		local done = attackMany(list)
		attackBusy = false
		if done > 0 then say("Auto killed " .. done, "swords", "accent") end
		return
	end

	if state.autoKillSheriff then
		local who = gunHolder()
		if who and not isDead(who) and not danger.friend(who) and hitPartOf(who) then
			attackBusy = true
			attack({ player = who })
			attackBusy = false
		end
	end

	if state.autoKillMurderer then
		for _, e in aliveTargets() do
			if e.role == "Murderer" then
				attackBusy = true
				attack(e)
				attackBusy = false
				break
			end
		end
	end
end

function tryAuto()
	if autoBusy or sniper.busy then return end
	if not (state.autoKillMurderer or state.autoKillAll or state.autoKillSheriff or state.autoPickup or danger.surviving()) then return end
	if not canAct() then return end
	autoBusy = true
	task.spawn(function()
		local ok, err = pcall(autoPass)
		attackBusy = false
		releaseHold()
		if not ok then say("auto error: " .. tostring(err), "triangle-alert", "danger") end
		task.wait(0.15)
		autoBusy = false
	end)
end

local round = { map = nil, countedRole = nil, selfReset = false, died = false, prev = {}, seenGuns = {}, dropNotice = 0 }

---------------------------------------------------------------------------------------- Round events
-- Round start and end, deaths, gun drops and coin collection.
local function onMap(map)
	if map == round.map then return end
	round.map = map
	task.spawn(nav.build, map)
	round.died = false
	round.selfReset = false
	if coinRun and coinRun.kind == "vote" then stopCoinRun() end
	local id = tostring(map:GetAttribute("MapID"))
	S.mapStatus:Set(id)
	win.StatusBar:Item("map", { Text = "Map: " .. id })
	watchMapCoins(map)
	vote.stale = true
	vote.learn({ id })
	bump("rounds")
	refreshAll()
end

local function onMapGone()
	boxCache[round.map] = nil
	round.map = nil
	nav.reset()
	coin.bagFull = false
	table.clear(danger.traps)
	table.clear(danger.trapHits)
	table.clear(danger.badGoals)
	table.clear(danger.beenTo)
	danger.fleeLast, danger.fleeBounce, danger.fleeGoal, danger.roamDud = nil, 0, nil, 0
	if round.countedRole and not round.died and not amDead() then bump("survived") end
	round.countedRole = nil
	table.clear(round.seenGuns)
	table.clear(danger.knifeSeen)
	table.clear(grab.failed)
	table.clear(myAttacks)
	forgetCoinHooks()
	stopCoinRun()
	clearMap(esp.coinBoxes)
	clearMap(esp.gunBoxes)
	clearMap(esp.bodies)
	S.mapStatus:Set("none")
	win.StatusBar:Item("map", { Text = "Map: -" })
	refreshAll()
	vote.stale = true
end

local function countRole(mine)
	if not mine or mine == round.countedRole then return end
	round.countedRole = mine
	if mine == "Murderer" then
		bump("roundsAsMurderer")
		notify("You are the Murderer", "Knife incoming.", "skull", ROLE_COLOURS.Murderer)
	elseif mine == "Sheriff" then
		bump("roundsAsSheriff")
		notify("You are the Sheriff", "Find the murderer.", "shield", ROLE_COLOURS.Sheriff)
	elseif mine == "Innocent" then
		bump("roundsAsInnocent")
		local m = nameFor("Murderer")
		notify("You are Innocent", m and ("Murderer is " .. m) or "Collect coins and survive.", "user", ROLE_COLOURS.Innocent)
	end
end

local function onPlayerData()
	local data = roleData()
	local live = roundLive()
	for name, d in pairs(data) do
		local dead = (d.Dead or d.Killed) == true
		local was = round.prev[name]
		if was and not was.dead and dead then
			creditDeath(name)
			if live and not amDead() and (d.Role == "Sheriff" or d.Role == "Hero") and name ~= player.Name then
				round.dropNotice = os.clock()
				if myRole() == "Murderer" then
					notify("You dropped " .. name, "Their gun is on the ground.", "skull", ROLE_COLOURS.Murderer)
				else
					notify(name .. " dropped the gun", "Grab it before the murderer does.", "package", ROLE_COLOURS.Sheriff)
					if state.autoPickup then tryAuto() end
				end
			end
		end
	end
	table.clear(round.prev)
	for name, d in pairs(data) do
		round.prev[name] = { role = d.Role, dead = (d.Dead or d.Killed) == true }
	end
	countRole(myRole())
	refreshAll()
	tryAuto()
end

local function onGunDropped(gun)
	task.defer(function()
		refreshGunEsp()
		if not roundLive() or round.seenGuns[gun] or not gun:IsDescendantOf(Workspace) then return end
		round.seenGuns[gun] = true
		if amDead() or myRole() == "Murderer" or findTool("Gun") then return end
		if os.clock() - round.dropNotice > 4 then
			notify("Gun on the ground", "A dropped gun is up for grabs.", "package", ROLE_COLOURS.Sheriff)
		end
		if state.autoPickup then tryAuto() end
	end)
end

local function onGunGone(gun)
	refreshGunEsp()
	if not round.seenGuns[gun] then return end
	round.seenGuns[gun] = nil
	if not roundLive() or grab.walking then return end
	task.delay(0.5, function()
		if roundLive() and not amDead() and not findTool("Gun") then
			notify("Gun taken", "Someone else picked it up.", "hand", ROLE_COLOURS.Murderer)
		end
	end)
end

win:Track(Round.PlayerDataChanged.Event:Connect(onPlayerData))

for _, name in { "RoundStart", "GameOver", "RoleSelect", "KillEvent", "ShowRoleSelect" } do
	win:Track(Gameplay:WaitForChild(name).OnClientEvent:Connect(function()
		refreshAll()
		tryAuto()
	end))
end

win:Track(Gameplay:WaitForChild("VictoryScreen").OnClientEvent:Connect(function(_, _, _, winner)
	if amDead() then return end
	local role = myRole()
	if not role or not state.resetFor[role] then return end
	local murderer = findByRole("Murderer")
	local murdererWon = winner ~= nil and winner == murderer
	if (role == "Murderer") ~= murdererWon then return end
	local hum = myHumanoid()
	if not hum then return end
	round.selfReset = true
	hum:ChangeState(Enum.HumanoidStateType.Dead)
	say("Round won, reset", "rotate-cw", "accent")
end))

vote.hook()
vote.stale = roundTimer() ~= -1
win:Track(Workspace.ChildAdded:Connect(function(v)
	if v.Name == "RegularLobby" then task.defer(vote.hook) end
end))
task.defer(vote.check)

win:Track(CollectionService:GetInstanceAddedSignal("GunDrop"):Connect(onGunDropped))
win:Track(CollectionService:GetInstanceRemovedSignal("GunDrop"):Connect(onGunGone))

win:Track(CollectionService:GetInstanceAddedSignal("ServerCoinPart"):Connect(addCoin))
win:Track(CollectionService:GetInstanceRemovedSignal("ServerCoinPart"):Connect(function(part)
	coin.set[part] = nil
end))

win:Track(Gameplay:WaitForChild("CoinsStarted").OnClientEvent:Connect(function()
	table.clear(coin.skipped)
	coin.bagFull = false
	refreshCoins()
end))

local coinCounts = {}

win:Track(Gameplay:WaitForChild("CoinCollected").OnClientEvent:Connect(function(coinId, count, max)
	if type(coinId) == "string" and type(count) == "number" then
		local prev = coinCounts[coinId] or 0
		if count > prev then bump("coins", count - prev) end
		coinCounts[coinId] = count
		if type(max) == "number" and count >= max then
			coin.bagFull = true
			stopCoinRun()
			say("Coin bag full", "circle-dollar-sign", "muted")
		end
	end
	refreshCoins()
end))

win:Track(CollectionService:GetInstanceAddedSignal("CoinVisual"):Connect(function(vis)
	task.defer(function()
		local part = vis.Parent
		if part then addCoin(part) end
		refreshCoins()
	end)
end))

win:Track(CollectionService:GetInstanceRemovedSignal("CoinVisual"):Connect(refreshCoins))
win:Track(CollectionService:GetInstanceAddedSignal("Ragdoll"):Connect(function() task.defer(esp.refreshBodies) end))
win:Track(CollectionService:GetInstanceRemovedSignal("Ragdoll"):Connect(function() task.defer(esp.refreshBodies) end))

win:Track(Workspace.ChildAdded:Connect(function(v)
	if v:GetAttribute("MapID") then onMap(v) end
end))

win:Track(Workspace.ChildRemoved:Connect(function(v)
	if v == round.map then
		table.clear(coinCounts)
		onMapGone()
	end
end))

local charConns = {}

local function watchCharacter(char)
	for _, c in charConns do c:Disconnect() end
	table.clear(charConns)
	local pack = player:WaitForChild("Backpack", 5)
	if pack then
		table.insert(charConns, pack.ChildAdded:Connect(function()
			refreshAll()
			tryAuto()
		end))
		table.insert(charConns, pack.ChildRemoved:Connect(refreshAll))
	end
	local hum = char:WaitForChild("Humanoid", 5)
	refreshAll()
	if not hum then return end
	plr.walkSaved, plr.jumpSaved = nil, nil
	task.delay(1.5, vote.check)
	if state.fly then task.delay(0.5, plr.plrStartFly) end
	table.insert(charConns, hum.Died:Connect(function()
		stopCoinRun()
		releaseHold()
		if round.selfReset then
			round.selfReset = false
		else
			round.died = true
			local r = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if not inLobby() then
				bump("deaths")
				if r then danger.hazard(r.Position) end
			end
			say("You died", "skull", "danger", 2)
		end
		refreshAll()
	end))
end

if player.Character then task.spawn(watchCharacter, player.Character) end
win:Track(player.CharacterAdded:Connect(function(char) task.spawn(watchCharacter, char) end))

esp.charConns = {}
local function watchPlayer(who)
	esp.charConns[who] = who.CharacterAdded:Connect(refreshAll)
end

for _, who in Players:GetPlayers() do
	if who ~= player then watchPlayer(who) end
end

win:Track(Players.PlayerAdded:Connect(function(who)
	watchPlayer(who)
	refreshAll()
end))

win:Track(Players.PlayerRemoving:Connect(function(who)
	if esp.charConns[who] then
		esp.charConns[who]:Disconnect()
		esp.charConns[who] = nil
	end
	if esp.highlights[who] then
		esp.dropLimbs(esp.highlights[who])
		esp.highlights[who] = nil
	end
	if esp.nameTags[who] then
		esp.nameTags[who]:Destroy()
		esp.nameTags[who] = nil
	end
	refreshAll()
end))

local T = { aura = 0, coinStart = 0, tick = 0, autoTick = 0, rethink = 0, actCheck = 0, actOk = false, roam = 0, fall = 0, navFix = 0 }

win:Track(player.Idled:Connect(function()
	if not state.antiIdle then return end
	local vu = game:GetService("VirtualUser")
	vu:CaptureController()
	vu:Button2Down(Vector2.zero, Workspace.CurrentCamera.CFrame)
	task.wait(0.5)
	vu:Button2Up(Vector2.zero, Workspace.CurrentCamera.CFrame)
end))

win:Track(RunService.Stepped:Connect(function()
	if state.antiFling or state.noclip then plr.collisionStep() end
end))

win:Track(RunService.Heartbeat:Connect(function()
	-- A destroyed hub kept ticking: three instances were live at once, each with
	-- its own nav and danger tables, and whichever answered first won.
	if gone then return end
	local now = os.clock()
	if state.speed ~= 16 or state.jump ~= 50 or state.gravity ~= 196 or state.fly then plr.playerTick() end

	if now - T.tick >= 1 then
		local delta = now - T.tick
		T.tick = now
		-- Navigation first, and on its own: a throw in the knife or ESP code
		-- below must never be able to starve the map the router walks on.
		local liveMap = getMap()
		local lost = nav.map ~= nil and nav.map.Parent == nil
		if (liveMap ~= nav.map or lost) and now - T.navFix > 5 then
			T.navFix = now
			if lost and liveMap == nav.map then nav.reset() end
			if liveMap and liveMap.Parent then
				task.spawn(function()
					local built = pcall(nav.build, liveMap)
					if not built then nav.reset() end
				end)
			else
				nav.reset()
			end
		end
		danger.watchThrows()
		danger.guardTouch()
		for _, who in Players:GetPlayers() do
			if who ~= player and not danger.knifeSeen[who] then danger.sawKnife(who) end
		end
		if delta < 5 then totals.playtime += delta end
		if state.roleEsp then refreshRoleEsp() end
		if state.gunEsp then refreshGunEsp() end
		local xp = profileXP()
		if type(xp) == "number" and session.lastXp and xp > session.lastXp then
			totals.xp += xp - session.lastXp
			session.lastXp = xp
		end
		S.sessTime:Set(fmtDuration(now - session.startedAt))
		S.totTime:Set(fmtDuration(totals.playtime))
		saveTotals()
		refreshStatus()
		if borrowed and not coinRun then restoreMovement() end
	end

	if hold.conn and now - hold.since > 0.5 then releaseHold() end

	if coinRun and now - T.rethink >= COIN_RETHINK then
		T.rethink = now
		rethinkCoin()
	end

	if not (state.killAura or state.autoCoin or state.survive or state.hvh or state.autoKillAll or state.autoKillSheriff or state.autoKillMurderer or state.autoPickup) then return end

	if now - T.actCheck >= 0.25 then
		T.actCheck = now
		T.actOk = canAct() == true
	end
	if now - T.fall >= 0.2 and not hold.cf then
		T.fall = now
		danger.fallGuard(now)
	end
	if T.actOk and not danger.routing and now - danger.pathAt >= 0.4 then
		local threat = danger.root()
		local root = threat and myRoot()
		if root and (threat.Position - root.Position).Magnitude < 120 then task.spawn(danger.route, threat) end
	end
	if (state.autoKillMurderer or danger.surviving()) and T.actOk and not attackBusy and findTool("Gun") and not coin.first() then
		sniperTick(now)
	end
	if state.hvh and T.actOk and not attackBusy and not coin.first() then sniper.hvh(now) end

	local inAuraRange = false
	if state.killAura and T.actOk and (findTool("Knife") or findTool("Gun")) then
		local hits = {}
		for _, e in legalTargets() do
			if e.dist <= state.killRange then table.insert(hits, e) end
		end
		inAuraRange = #hits > 0
		if inAuraRange and now - T.aura >= state.killDelay then
			if findTool("Knife") then stabMany(hits) else shootFromHere(hits[1]) end
			T.aura = now
		end
	end
	local killBusy = attackBusy or sniper.busy or inAuraRange

	if killBusy and coinRun and (coinRun.kind == "coins" or coinRun.kind == "survive") then stopCoinRun() end

	if state.avoid and coinRun and coinRun.kind ~= "vote" and not danger.wanting() and T.actOk and not danger.fleeing and not danger.brainOn and not killBusy and now >= (danger.fleeSkipUntil or 0) then
		local threat = danger.root()
		local root = myRoot()
		local closing = false
		if threat and root and coinRun and coinRun.moveDir then
			local toThem = danger.flat(threat.Position, root.Position)
			closing = toThem.Magnitude < 45 and toThem.Magnitude > 0.01 and toThem.Unit:Dot(coinRun.moveDir) > 0.75 and math.abs(threat.Position.Y - root.Position.Y) < 6 and danger.gap(root.Position, threat) < 50
		end
		if threat and root and (closing or danger.dangerous(threat)) then
			task.spawn(function()
				local okFlee, err = pcall(danger.flee, threat)
				if not okFlee then
					danger.fleeing = false
					finishRun()
					say("avoid error: " .. tostring(err), "triangle-alert", "danger")
				end
			end)
		end
	end

	if danger.wanting() and danger.canMove() and not coinRun and not grab.walking and not danger.pursuing and not danger.brainOn and not killBusy and not danger.fleeing and T.actOk and now - T.roam >= 0.05 then
		T.roam = now
		danger.brainOn = true
		task.spawn(function()
			local okBrain, err = pcall(danger.brain)
			if not okBrain then
				danger.brainOn = false
				finishRun()
				say("survive error: " .. tostring(err), "triangle-alert", "danger")
			end
		end)
	end

	if state.autoCoin and danger.canMove() and not coinRun and not grab.walking and not danger.pursuing and not coin.bagFull and not danger.wanting() and not killBusy and not danger.fleeing and T.actOk and now - T.coinStart >= 0.05 then
		T.coinStart = now
		startCoinRun()
	end

	if (state.autoKillMurderer or state.autoKillAll or state.autoKillSheriff or state.autoPickup or danger.surviving()) and not autoBusy and now - T.autoTick >= 0.1 then
		T.autoTick = now
		tryAuto()
	end
end))

win:OnDestroy(function()
	gone = true
	nav.ready, nav.world, nav.map = false, nil, nil
	state.speed = 16
	stopCoinRun()
	finishRun()
	releaseHold()
	plr.restoreCollisions()
	getgenv().__MM2_SILENT = nil
	for _, c in vote.hooks do c:Disconnect() end
	for _, c in pairs(esp.charConns) do c:Disconnect() end
	plr.plrStopFly()
	plr.plrRestoreWalk()
	plr.plrRestoreJump()
	if state.gravity ~= 196 then Workspace.Gravity = 196.2 end
	for _, c in charConns do c:Disconnect() end
	table.clear(charConns)
	clearCircle()
	forgetCoinHooks()
	esp.clearLimbs(esp.highlights)
	esp.heatClear()
	clearMap(esp.nameTags)
	clearMap(esp.coinBoxes)
	clearMap(esp.gunBoxes)
	clearMap(esp.bodies)
	saveTotals(true)
end)

local existing = getMap()
if existing then onMap(existing) end
onPlayerData()
refreshStatus()
