--!optimize 2
-- Storyboard: the Murder Mystery 2 hub tour, piloted by the showcase library

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Showcase = loadstring(game:HttpGet("https://rbx.lol/showcase.lua"))()
local player = Players.LocalPlayer
local Round = require(ReplicatedStorage.Modules.CurrentRoundClient)

local win = Showcase.window("rbxlolhub")
assert(win, "load the hub first")

local s = Showcase.new({ Window = win })
local p, ui, text, fx, cam = s.pointer, s.ui, s.text, s.fx, s.cam

local function inside(model, pos, pad)
	local cf, size = model:GetBoundingBox()
	local rel = cf:PointToObjectSpace(pos)
	return math.abs(rel.X) <= size.X / 2 + pad and math.abs(rel.Y) <= size.Y / 2 + pad and math.abs(rel.Z) <= size.Z / 2 + pad
end

-- Alive, standing on the map, with enough of the round left for the world segments
local function roundLive(minimumLeft)
	local map
	for _, v in Workspace:GetChildren() do
		if v:GetAttribute("MapID") then map = v end
	end
	if not map then return false, "no map" end
	if next(Round.PlayerData) == nil then return false, "no round data" end
	local me = Round.PlayerData[player.Name]
	if not me then return false, "not in round" end
	if me.Dead or me.Killed then return false, "dead in round data" end
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not hum or hum.Health <= 0 or not root then return false, "no living character" end
	local lobby = Workspace:FindFirstChild("RegularLobby")
	if lobby then
		if inside(lobby, root.Position, 20) then return false, "in lobby" end
		local centre = lobby:GetBoundingBox().Position
		if (root.Position - centre).Magnitude < 600 then return false, "near lobby" end
	end
	if not inside(map, root.Position, 150) then return false, "off map" end
	local part = Workspace:FindFirstChild("RoundTimerPart")
	local secs = part and part:GetAttribute("Time")
	if secs ~= nil and secs <= (minimumLeft or 0) then return false, "timer " .. tostring(secs) end
	return true
end

local function stillLive()
	local ok, why = roundLive(0)
	if not ok then s:mark("round lost: " .. tostring(why)) end
	return ok
end

local function viewport()
	return Workspace.CurrentCamera.ViewportSize
end

-- Parks the window at the left edge so the world segments keep the character in view on the right
local function park()
	local v = viewport()
	local w = math.clamp(math.floor(v.X * 0.4), 640, 760)
	local h = math.clamp(math.floor(v.Y * 0.42), 520, 600)
	win:SetSize(w, h)
	win:SetPosition(UDim2.fromOffset(36, math.clamp(math.floor((v.Y - h) / 2), 20, v.Y - h - 20)))
end

local pickupWas = nil

local function reset()
	ui:closeMenus()
	if pickupWas == nil then pickupWas = ui:isOn("Combat", "Auto pickup gun") end
	ui:preset("Combat", "Auto pickup gun", false)
	for _, name in { "Role ESP", "Name tags", "Coin ESP", "Gun ESP" } do ui:preset("Visuals", name, false) end
	ui:preset("Map", "Auto collect coins", false)
	ui:presetOptions("Combat", "Legit mode", {})
	ui:preset("Combat", "Silent aim", false)
	ui:preset("Player", "Fly", false)
	ui:presetSlider("Player", "Walk speed", 0)
	ui:theme("Dark")
	ui:closeMenus()
	ui:scrollTop()
	ui:selectTab("Visuals")
end

-- The world segments need the player alive on the map; they run first and fast, and bail when the round is lost
local function world()
	text:caption("Auto coins: pathfinds to every coin, routes around walls", 4)
	ui:tab("Map")
	fx:pulse(ui:row("Map", "Auto collect coins"), 1)
	ui:toggle("Map", "Auto collect coins")
	s:wait(0.4)
	cam:chase({ distance = 13, height = 8.5, yaw = 6, stiffness = 6 })

	text:caption("ESP for roles, names, coins and the dropped gun", 4)
	ui:tab("Visuals")
	fx:zoom(ui:row("Visuals", "Role ESP"), 1.22, 0.6)
	for _, name in { "Role ESP", "Name tags", "Coin ESP", "Gun ESP" } do ui:toggle("Visuals", name) end
	s:wait(0.4)
	fx:unzoom(0.5)
	fx:callout(ui:row("Visuals", "Show dead players"), "Bodies stay marked", "right", 1.6)
	s:wait(1.8)
	if not stillLive() then return false end

	text:caption("22 studs a second, stall recovery, ladders and jumps", 5)
	p:hide()
	fx:vignette(true, 0.5)
	s:wait(5)
	text:caption("Keeps its distance from the murderer while it farms", 4)
	s:wait(4)
	fx:vignette(false)
	cam:restore()
	s:wait(0.3)
	p:show()
	ui:tab("Map")
	ui:toggle("Map", "Auto collect coins")
	if not stillLive() then return false end

	text:caption("Fly with the camera, Space rises", 4)
	ui:tab("Player")
	ui:toggle("Player", "Fly")
	s:wait(0.3)
	p:hide()
	cam:orbit({ radius = 15, height = 4, degreesPerSecond = 28, start = 20 })
	text:keyHint("W + Space", 2)
	p:holdKeys({ Enum.KeyCode.W, Enum.KeyCode.Space }, 2)
	text:keyHint("W", 2)
	p:holdKeys({ Enum.KeyCode.W }, 2)
	cam:restore()
	s:wait(0.3)
	p:show()
	ui:toggle("Player", "Fly")
	s:wait(0.3)
	return true
end

local function interface()
	local v = viewport()
	text:caption("Drag it anywhere, resize it, hide it with Right Shift", 5)
	local wantW = math.clamp(math.floor(v.X * 0.46), 700, 860)
	local wantH = math.clamp(math.floor(v.Y * 0.46), 540, 640)
	ui:place(math.floor((v.X - wantW) / 2), math.floor((v.Y - wantH) / 2), wantW, wantH)
	s:wait(0.3)
	text:keyHint("Right Shift", 1.2)
	p:key(Enum.KeyCode.RightShift)
	s:wait(1.6)
	text:keyHint("Right Shift", 1.2)
	p:key(Enum.KeyCode.RightShift)
	s:wait(1.4)

	text:caption("Player tools: speed, jump, gravity, fly, noclip, anti-fling", 4)
	ui:tab("Player")
	fx:spotlight(ui:row("Player", "Walk speed"), 8)
	ui:slider("Player", "Walk speed", 1)
	s:wait(0.6)
	ui:slider("Player", "Walk speed", 0)
	fx:unspotlight()
	s:wait(0.4)

	text:caption("Combat: legit mode walks, otherwise it never misses", 4)
	ui:tab("Combat")
	ui:option("Combat", "Legit mode", "Stabbing as murderer")
	s:wait(0.6)
	ui:option("Combat", "Legit mode", "Stabbing as murderer")
	ui:closeMenu("Combat", "Legit mode", "Stabbing as murderer")
	s:wait(0.4)
	ui:group("Combat", "Kill aura")
	s:wait(0.8)
	ui:group("Combat", "Kill aura")
	text:caption("Silent aim with a FOV circle you can size", 4)
	ui:toggle("Combat", "Silent aim")
	ui:toggle("Combat", "Show FOV circle")
	ui:slider("Combat", "Aim FOV", 0.55, 1)
	s:wait(0.5)
	ui:slider("Combat", "Aim FOV", 0.17, 0.8)
	s:wait(0.4)
	ui:toggle("Combat", "Show FOV circle")
	ui:toggle("Combat", "Silent aim")

	text:caption("Auto vote for your favourite maps", 3.5)
	ui:tab("Map")
	ui:option("Map", "Favourite maps", "Bank2")
	s:wait(0.6)
	ui:option("Map", "Favourite maps", "Bank2")
	ui:closeMenu("Map", "Favourite maps", "Bank2")
	s:wait(0.3)

	text:caption("Every theme in the Ember library, live", 4)
	ui:tab("Settings")
	ui:option("Settings", "Theme", "Slate")
	s:wait(2.2)
	ui:option("Settings", "Theme", "Dark")
	s:wait(0.6)

	text:caption("Session and lifetime stats", 3)
	ui:tab("Stats")
	s:wait(3)
end

local function attempt()
	win:Toggle(true)
	s:wait(0.4)
	ui:keepLayout("mm2")
	park()
	reset()

	if not roundLive(110) then
		text:caption("Waiting for the next round")
		s:untilTrue(function() return roundLive(110) end)
		text:clearCaption()
	end
	do
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		local lobby = Workspace:FindFirstChild("RegularLobby")
		local part = Workspace:FindFirstChild("RoundTimerPart")
		s:mark(string.format("round check: timer=%s pos=%s lobbyGap=%s", tostring(part and part:GetAttribute("Time")), root and tostring(root.Position) or "nil", (root and lobby) and tostring(math.floor((root.Position - lobby:GetBoundingBox().Position).Magnitude)) or "?"))
	end

	fx:fade(true, 0)
	s:wait(0.2)
	win:Toggle(false)
	s:wait(1)
	fx:watermark("rbx.lol")
	cam:orbit({ radius = 16, height = 6, degreesPerSecond = 22, start = 40 })
	fx:letterbox(true, 0)
	fx:fade(false, 1)
	text:title("RBX.lol Hub", "Murder Mystery 2", 3)
	fx:letterbox(false, 0.5)
	cam:restore()
	s:wait(0.3)
	s:untilTrue(function() return not win._fxBusy end, 3)
	win:Toggle(true)
	s:wait(1.2)

	local v = viewport()
	p:place(v.X * 0.5, v.Y * 0.55)
	p:show()

	if not world() then
		cam:restore()
		fx:vignette(false)
		fx:clearCallouts()
		p:show()
		return false
	end

	interface()

	s:wait(0.4)
	p:hide()
	s:untilTrue(function() return not win._fxBusy end, 3)
	win:Toggle(false)
	fx:letterbox(true, 0.6)
	cam:dolly({ from = 34, to = 11, seconds = 3.5, height = 9, angle = 50 })
	s:wait(0.6)
	text:title("rbx.lol", "scripts, tools and the community", 3.5)
	fx:fade(true, 1)
	if pickupWas then ui:preset("Combat", "Auto pickup gun", true) end
	s:cue("Stop recording", 4)
	return true
end

s:run(function()
	s:hud({ chat = false, mouse = false })
	while not attempt() do
		text:caption("Round lost, restarting on the next round", 3)
		s:mark("restart")
		fx:fade(true, 0.8)
		s:wait(2)
		fx:fade(false, 0.5)
	end
end)
