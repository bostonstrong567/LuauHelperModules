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
-- The core notification hook registers late on a cold join, so keep trying for a few seconds
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

-- Libraries come over HTTP; a bad fetch is retried and then reported, never left as a nil index
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
-- UniversalNav, the navigation framework. Normally fetched from GitHub at runtime; inlined here so
-- the script carries its own pathfinding. Ember is still fetched at runtime, just above.
local UniversalNav = (function()
--!native
--!optimize 2
-- UniversalNav: a navigation framework that searches any state space you describe, and discovers
-- what the world lets an agent do rather than being told.
--
-- The core knows only states, transitions, costs, goals and revisions. Around it:
--   Perception   scanners that turn a world into candidate affordances: semantic (what Roblox says a
--                thing is) and geometric (what the lattice's own topology suggests)
--   Affordances  the registry of what the world offers, with evidence from three sources and memory
--                keyed by game, object, kind and mechanism
--   Capabilities what an agent can do, read from the agent, plus the runtime probe that turns an
--                untrusted candidate into a fact by trying it and watching the body
--   Traversal    providers that emit a transition only where an affordance meets a capability
--   Search       backends behind a registry; weighted A* is one of them
--   Cost         models that turn a transition's raw measures into one number
--   Cache        transitions per (world revision, agent signature)
--   Roblox       geometry queries, the humanoid adapter and the climb executor, at the edge
-- Nothing in here knows about any particular game.
local UniversalNav = { Version = "0.7.12" }

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

-------------------------------------------------------------------------------------------------- Core
local Core = {}
UniversalNav.Core = Core

-- A transition is the only thing the search ever reads: where it goes and what it costs in raw terms
function Core.transition(from, to, kind, time, distance, risk, data)
	return { From = from, To = to, Kind = kind, Time = time, Distance = distance, Risk = risk or 0, Data = data }
end

function Core.state(position)
	return { Position = position, Virtual = true }
end

local revision = 0
function Core.nextRevision()
	revision += 1
	return revision
end

local function flatBetween(a, b)
	return Vector3.new(b.X - a.X, 0, b.Z - a.Z).Magnitude
end
Core.flatBetween = flatBetween

---------------------------------------------------------------------------------------------- Search
local Search = { Registry = {} }
UniversalNav.Search = Search

-- Binary heap keyed on f with lazy deletion; stale entries are skipped by the closed set
local Heap = {}
Heap.__index = Heap
Search.PriorityQueue = Heap

function Heap.new()
	return setmetatable({ items = {}, n = 0 }, Heap)
end

function Heap:push(item)
	local items = self.items
	self.n += 1
	local i = self.n
	items[i] = item
	while i > 1 do
		local parent = i // 2
		if items[parent].f <= item.f then break end
		items[i] = items[parent]
		items[parent] = item
		i = parent
	end
end

function Heap:pop()
	local items = self.items
	local n = self.n
	if n == 0 then return nil end
	local top = items[1]
	local last = items[n]
	items[n] = nil
	n -= 1
	self.n = n
	if n > 0 then
		local i = 1
		while true do
			local l, r, small = i * 2, i * 2 + 1, i
			local sf = last.f
			if l <= n and items[l].f < sf then small, sf = l, items[l].f end
			if r <= n and items[r].f < sf then small = r end
			if small == i then break end
			items[i] = items[small]
			i = small
		end
		items[i] = last
	end
	return top
end

-- Weighted A*: f = g + epsilon * h; epsilon 1 is plain A*. Starts and goals are transition sets, so
-- connectors from and to free positions cost nothing special.
-- ctx: Expand(state) -> transitions, Cost(transition), Heuristic(state), Blocked(state), Allowed(transition), Yield(), Cap
function Search.WeightedAStar(starts, goals, ctx, epsilon)
	local open = Heap.new()
	local g, cameBy, closed = {}, {}, {}
	local GOAL = {}
	for _, entry in starts do
		local s = entry.To
		local cost = ctx.Cost(entry)
		if g[s] == nil or cost < g[s] then
			g[s], cameBy[s] = cost, entry
			open:push({ state = s, f = cost + epsilon * ctx.Heuristic(s) })
		end
	end
	local expanded = 0
	while open.n > 0 do
		local current = open:pop().state
		if current == GOAL then break end
		if not closed[current] then
			closed[current] = true
			expanded += 1
			if expanded > ctx.Cap then return nil, "cap", expanded end
			ctx.Yield()
			local gc = g[current]
			local finish = goals[current]
			if finish then
				local total = gc + ctx.Cost(finish)
				if g[GOAL] == nil or total < g[GOAL] then
					g[GOAL], cameBy[GOAL] = total, finish
					open:push({ state = GOAL, f = total })
				end
			end
			for _, t in ctx.Expand(current) do
				local m = t.To
				if not closed[m] and not ctx.Blocked(m) and ctx.Allowed(t) then
					local tentative = gc + ctx.Cost(t)
					if g[m] == nil or tentative < g[m] then
						g[m], cameBy[m] = tentative, t
						open:push({ state = m, f = tentative + epsilon * ctx.Heuristic(m) })
					end
				end
			end
		end
	end
	if not cameBy[GOAL] then return nil, "none", expanded, closed end
	local path = {}
	local t = cameBy[GOAL]
	while t do
		table.insert(path, 1, t)
		if t.From.Virtual then break end
		t = cameBy[t.From]
	end
	return path, "ok", expanded
end

Search.Registry.WeightedAStar = Search.WeightedAStar
function Search.Registry.AStar(starts, goals, ctx)
	return Search.WeightedAStar(starts, goals, ctx, 1)
end

------------------------------------------------------------------------------------------------ Cost
local Cost = {}
UniversalNav.Cost = Cost

Cost.Fastest = {
	Of = function(t) return t.Time end,
	Heuristic = function(a, b, agent) return (b - a).Magnitude / agent:MaxSpeed() end,
}
Cost.Shortest = {
	Of = function(t) return t.Distance end,
	Heuristic = function(a, b) return (b - a).Magnitude end,
}
Cost.Safest = {
	Of = function(t) return t.Time + t.Risk * 3 end,
	Heuristic = function(a, b, agent) return (b - a).Magnitude / agent:MaxSpeed() end,
}
-- Time and distance weights give a lower bound directly; risk is never below zero so it adds nothing
function Cost.Composite(weights)
	local wt, wd, wr = weights.Time or 0, weights.Distance or 0, weights.Risk or 0
	return {
		Of = function(t) return t.Time * wt + t.Distance * wd + t.Risk * wr end,
		Heuristic = function(a, b, agent)
			local d = (b - a).Magnitude
			return wt * d / agent:MaxSpeed() + wd * d
		end,
	}
end

----------------------------------------------------------------------------------------------- Cache
local Cache = {}
UniversalNav.Cache = Cache

-- Transitions out of a state, kept per (world revision, agent signature); a new key drops the old store
local TransitionCache = {}
TransitionCache.__index = TransitionCache
Cache.TransitionCache = TransitionCache

function TransitionCache.new()
	return setmetatable({ key = nil, store = {}, failed = {}, walks = {}, kept = {}, order = {}, hits = 0, misses = 0 }, TransitionCache)
end

-- Every key keeps its own store, so an agent whose signature changes and changes back (a run speed
-- that varies with the errand) finds its transitions where it left them; the oldest of five is dropped
function TransitionCache:use(key)
	if self.key == key then return end
	local set = self.kept[key]
	if not set then
		set = { store = {}, failed = {}, walks = {} }
		self.kept[key] = set
		table.insert(self.order, key)
		if #self.order > 5 then self.kept[table.remove(self.order, 1)] = nil end
	end
	self.key, self.store, self.failed, self.walks = key, set.store, set.failed, set.walks
end

-- A walk reads the same from either end, so the pair measured from one end answers the other
function TransitionCache:walkBetween(a, b)
	local list = self.walks[b]
	return list and list[a]
end

function TransitionCache:rememberWalk(a, b, result)
	local list = self.walks[a]
	if not list then
		list = {}
		self.walks[a] = list
	end
	list[b] = result
end

-- A search that exhausted the graph between two points is remembered for a moment, so the same
-- unreachable goal asked again a frame later costs nothing
function TransitionCache:failedBetween(a, b)
	local list = self.failed[a]
	return list ~= nil and (list[b] or 0) > os.clock()
end

function TransitionCache:rememberFailure(a, b, seconds)
	local list = self.failed[a]
	if not list then
		list = {}
		self.failed[a] = list
	end
	list[b] = os.clock() + seconds
end

function TransitionCache:get(state)
	local list = self.store[state]
	if list then self.hits += 1 else self.misses += 1 end
	return list
end

function TransitionCache:set(state, list)
	self.store[state] = list
end

----------------------------------------------------------------------------------------- Affordances
local Affordances = { Threshold = 0.5 }
UniversalNav.Affordances = Affordances

-- An affordance is what a piece of the world offers an agent that can use it:
-- { Kind, Object, Entry, Exit, Face, Normal, Axis, Height, Mechanism, Evidence, Key }
-- Evidence keeps its three sources apart: Semantic (what the platform says), Geometry (what the shape
-- suggests) and Behavioral (what happened when a body tried). A fact outranks a prior.

-- What makes two objects "the same thing": class, mesh, tags, attributes and size to the stud
function Affordances.signature(object)
	local parts = { object.ClassName }
	if object:IsA("MeshPart") then table.insert(parts, object.MeshId) end
	if object:IsA("BasePart") then
		local s = object.Size
		table.insert(parts, string.format("%.0fx%.0fx%.0f", s.X, s.Y, s.Z))
	end
	local tags = CollectionService:GetTags(object)
	table.sort(tags)
	for _, tag in tags do table.insert(parts, "#" .. tag) end
	local attrs = {}
	for k, v in pairs(object:GetAttributes()) do table.insert(attrs, k .. "=" .. tostring(v)) end
	table.sort(attrs)
	for _, a in attrs do table.insert(parts, "@" .. a) end
	return table.concat(parts, "|")
end

-- What kind of thing this is, with no body in it: whether a ladder can be climbed at all is a fact about
-- ladders, so it is learned once and every agent inherits it.
function Affordances.key(object, kind, mechanism)
	return tostring(game.GameId) .. "|" .. Affordances.signature(object) .. "|" .. kind .. "|" .. mechanism
end

-- The same mechanism as performed by one shape of body. Whether a given agent can actually get up that
-- ladder, and how fast, is a fact about the pairing, so a small agent's success is never a tall one's.
function Affordances.execKey(key, agent)
	return key .. "#" .. agent:Family()
end

local Memory = { known = {} }
Affordances.Memory = Memory

function Memory.entry(key)
	local k = Memory.known[key]
	if not k then
		k = { Successes = 0, Failures = 0, Model = {} }
		Memory.known[key] = k
	end
	return k
end

-- Learned behaviour for a key: nil until a body has tried
function Memory.behavioral(key)
	local k = Memory.known[key]
	if not k or k.Successes + k.Failures == 0 then return nil end
	return (k.Successes + 1) / (k.Successes + k.Failures + 2)
end

function Memory.report(key, ok, measured)
	local k = Memory.entry(key)
	if ok then
		k.Successes += 1
		k.ProbeAgain = nil
	else
		k.Failures += 1
	end
	if measured then
		for name, value in pairs(measured) do
			local had = k.Model[name]
			k.Model[name] = had and (had * 0.7 + value * 0.3) or value
		end
	end
	return Memory.behavioral(key)
end

-- Places that killed an agent with no visible cause, per world: the same outcome feedback as a failed
-- move, kept for as long as the library lives so the next visit to that world routes around them
Memory.lethal = {}

-- One death is a suspicion, a second within 15 studs is a fact: consumers ask with the count they need
function Memory.reportLethal(worldKey, pos)
	local list = Memory.lethal[worldKey]
	if not list then
		list = {}
		Memory.lethal[worldKey] = list
	end
	for _, h in list do
		if math.abs(h.Position.Y - pos.Y) < 8 and Vector3.new(h.Position.X - pos.X, 0, h.Position.Z - pos.Z).Magnitude < 15 then
			h.Count += 1
			return h.Count
		end
	end
	table.insert(list, { Position = pos, Count = 1 })
	return 1
end

function Memory.isLethal(worldKey, pos, within, minCount)
	local list = Memory.lethal[worldKey]
	if not list then return false end
	for _, h in list do
		if h.Count >= (minCount or 2) and math.abs(h.Position.Y - pos.Y) < 8 and Vector3.new(h.Position.X - pos.X, 0, h.Position.Z - pos.Z).Magnitude < within then return true end
	end
	return false
end

function Memory.model(key)
	local k = Memory.known[key]
	return k and k.Model or nil
end

-- Trust: a fact from memory, else a strong platform statement, else nothing until probed. What the
-- platform itself vouches for keeps the benefit of the doubt through a couple of failed attempts,
-- since a missed attach is usually the body's fault, not the surface's.
function Affordances.trust(aff, exec)
	local key = exec or aff.Key
	local learned = Memory.behavioral(key)
	if not learned and exec then learned = Memory.behavioral(aff.Key) end
	if not learned then return aff.Evidence.Semantic end
	local k = Memory.known[key] or Memory.known[aff.Key]
	if aff.Evidence.Semantic >= 0.9 and k.Failures < 3 then return math.max(learned, Affordances.Threshold) end
	return learned
end

function Affordances.plausible(aff)
	return aff.Evidence.Geometry >= 0.5 or aff.Evidence.Semantic >= 0.5
end

------------------------------------------------------------------------------------------ Perception
local Perception = {}
UniversalNav.Perception = Perception

-- Portals: the faces of an object a body can touch, the lattice points that reach each face, and the
-- points a body can step onto from the top. Everything is measured in the object's own frame and
-- verified with casts; nothing here asks what the object is called. The caller supplies the evidence.
Perception.Portals = { Reach = 8, Step = 4 }

local function reachClear(a, b, geo)
	local dy = b.Y - a.Y
	local knee0 = a - Vector3.new(0, 2 - math.max(dy, 0), 0)
	local knee1 = b - Vector3.new(0, 2 - math.max(-dy, 0), 0)
	return not geo:Raycast(a, b) and not geo:Raycast(knee0, knee1)
end

-- The object's own axis that points up in the world, whichever of its three it is, with its extent along
-- it and the two lateral axes with their half extents; a part rotated any way is read the same
function Perception.Portals.frame(part)
	local cf, size = part.CFrame, part.Size
	local axes = { { cf.RightVector, size.X }, { cf.UpVector, size.Y }, { cf.LookVector, size.Z } }
	local upIndex, best = nil, 0.7
	for i, axis in axes do
		if math.abs(axis[1].Y) > best then upIndex, best = i, math.abs(axis[1].Y) end
	end
	if not upIndex then return nil end
	local up = axes[upIndex][1]
	if up.Y < 0 then up = -up end
	local lateral = {}
	for i, axis in axes do
		if i ~= upIndex then table.insert(lateral, { axis[1], axis[2] / 2 }) end
	end
	return { Up = up, Height = axes[upIndex][2], Lateral = lateral }
end

-- A face is real when a ray from a body's width in front of it, at knee height above the foot, hits the object
function Perception.Portals.faces(part, lattice)
	local frame = Perception.Portals.frame(part)
	if not frame then return {} end
	local up, height = frame.Up, frame.Height
	local bottom = part.Position - up * (height / 2)
	local out = {}
	for _, lat in frame.Lateral do
		for _, sign in { 1, -1 } do
			local dir, half = lat[1] * sign, lat[2]
			local foot = bottom + dir * (half + 2.5)
			local hit = lattice.geometry:Raycast(foot + up * 2, foot + up * 2 - dir * (half + 4))
			if hit and hit.Instance == part then
				table.insert(out, { Normal = dir, Foot = foot, Surface = bottom + dir * half, Top = bottom + up * height + dir * (half + 2.5), Height = height })
			end
		end
	end
	return out
end

function Perception.Portals.tall(part)
	local frame = Perception.Portals.frame(part)
	return frame and frame.Height or 0
end

-- Entries: lattice points near the foot that a walk reaches; exits: points around the top a step reaches
function Perception.Portals.portals(face, lattice)
	local geo, lift = lattice.geometry, lattice.lift
	local entries, exits = {}, {}
	local contact = face.Foot + Vector3.new(0, lift, 0)
	for _, n in lattice:Nearby(face.Foot, Perception.Portals.Reach) do
		if math.abs(n.Position.Y - contact.Y) <= Perception.Portals.Step and reachClear(n.Position, contact, geo) then
			table.insert(entries, n)
		end
	end
	local crest = face.Top + Vector3.new(0, lift, 0)
	for _, n in lattice:Nearby(face.Top - face.Normal * 2.5, Perception.Portals.Reach) do
		if math.abs(n.Position.Y - crest.Y) <= Perception.Portals.Step and reachClear(crest, n.Position, geo) then
			table.insert(exits, n)
		end
	end
	return entries, exits
end

-- One SurfaceTraversal affordance per usable face of an object
function Perception.Portals.affordances(part, lattice, mechanism, evidence)
	local out = {}
	for _, face in Perception.Portals.faces(part, lattice) do
		local entries, exits = Perception.Portals.portals(face, lattice)
		if #entries > 0 and #exits > 0 then
			table.insert(out, {
				Kind = "SurfaceTraversal",
				Object = part,
				Face = face.Foot,
				Surface = face.Surface,
				Normal = face.Normal,
				Top = face.Top,
				Axis = face.Top - face.Foot,
				Height = face.Height,
				Entries = entries,
				Exits = exits,
				Mechanism = mechanism,
				Evidence = { Semantic = evidence.Semantic, Geometry = evidence.Geometry, Behavioral = nil },
				Key = Affordances.key(part, "SurfaceTraversal", mechanism),
			})
		end
	end
	return out
end

-- Semantic scanner: the cheap, certain layer. The platform says a truss climbs, so every usable face of
-- a truss is a SurfaceTraversal with semantic evidence 1; the portals are still measured, never assumed.
Perception.SemanticScanner = { Name = "Semantic" }

function Perception.SemanticScanner.scan(model, lattice)
	local found = {}
	for _, part in model:GetDescendants() do
		if part:IsA("TrussPart") and Perception.Portals.tall(part) > 4 then
			for _, aff in Perception.Portals.affordances(part, lattice, "HumanoidClimb", { Semantic = 1, Geometry = 0.9 }) do
				table.insert(found, aff)
			end
		end
	end
	return found
end

-- Surface topology scanner: the lattice's own shape points at interesting places. A low point next to
-- a much higher point, close in plan, with a near-vertical face between them, names an object worth
-- portals; the affordance carries geometric evidence only until a body has tried one of its kind.
-- MaxPair bounds how far apart two lattice points may be in height and still be treated as naming
-- the same face; it is a scan budget, not a statement about how tall a climbable thing may be. The
-- affordance's real extent is measured from the object itself, so a face taller than this is still
-- found and still offered at its true height whenever any pair along it falls inside the budget.
Perception.SurfaceTopology = { Name = "Topology", MaxPair = 40, MinClimb = 6.5, Reach = 2 }

function Perception.SurfaceTopology.scan(model, lattice)
	local found, seen = {}, {}
	local geo = lattice.geometry
	local top = Perception.SurfaceTopology
	local pops = 0
	for _, col in pairs(lattice.columns) do
		for _, list in pairs(col) do
			for _, low in list do
				pops += 1
				if pops % 300 == 0 then RunService.Heartbeat:Wait() end
				if lattice:Risk(low) == 0 then continue end
				for ring = 1, top.Reach do
					for _, high in lattice:Neighbours(low, ring) do
						local dy = high.Position.Y - low.Position.Y
						if dy > top.MinClimb and dy <= top.MaxPair then
							local toward = Vector3.new(high.Position.X - low.Position.X, 0, high.Position.Z - low.Position.Z)
							local flat = toward.Magnitude
							if flat > 0.5 then
								local dir = toward / flat
								local hit = geo:Raycast(low.Position, low.Position + dir * (flat + 1))
								local part = hit and hit.Instance
								if part and math.abs(hit.Normal.Y) < 0.3 and part:IsA("BasePart") and not part:IsA("TrussPart") and Perception.Portals.tall(part) > top.MinClimb and not seen[part] then
									seen[part] = true
									for _, aff in Perception.Portals.affordances(part, lattice, "Unknown", { Semantic = 0, Geometry = 0.7 }) do
										table.insert(found, aff)
									end
								end
							end
						end
					end
				end
			end
		end
	end
	return found
end

----------------------------------------------------------------------------------------- Capabilities
local Capabilities = {}
UniversalNav.Capabilities = Capabilities

-- What a humanoid can do, read from the humanoid rather than assumed; VerifiedClimb is unknown until
-- a probe proves the world's climb surfaces actually move this body
function Capabilities.inspectHumanoid(hum)
	return {
		Ground = true,
		Jump = (hum.UseJumpPower and hum.JumpPower or hum.JumpHeight) > 0,
		HumanoidClimbState = hum:GetStateEnabled(Enum.HumanoidStateType.Climbing),
		Swim = hum:GetStateEnabled(Enum.HumanoidStateType.Swimming),
	}
end

-- Motion observer: one window of watching a body, and what the window says about it
Capabilities.MotionObserver = {}

function Capabilities.MotionObserver.start(root, hum)
	return { at = os.clock(), pos = root.Position, vel = root.AssemblyLinearVelocity, state = hum:GetState(), peakRise = 0, climbingSeen = false, contact = 0 }
end

function Capabilities.MotionObserver.sample(obs, root, hum, touching, dt)
	local rise = root.Position.Y - obs.pos.Y
	if rise > obs.peakRise then obs.peakRise = rise end
	if hum:GetState() == Enum.HumanoidStateType.Climbing then obs.climbingSeen = true end
	if touching then obs.contact += dt end
end

-- Sustained rise while in contact is climbing whatever the platform's state machine says
function Capabilities.MotionObserver.interpret(obs, root, hum, elapsed)
	local rise = root.Position.Y - obs.pos.Y
	local climbing = obs.climbingSeen or (rise >= 2 and obs.contact >= elapsed * 0.6)
	return {
		Translation = root.Position - obs.pos,
		VelocityChange = root.AssemblyLinearVelocity - obs.vel,
		StateBefore = obs.state,
		StateAfter = hum:GetState(),
		ContactMaintained = obs.contact >= elapsed * 0.6,
		Grounded = hum.FloorMaterial ~= Enum.Material.Air,
		Climbing = climbing,
		Speed = elapsed > 0 and rise / elapsed or 0,
	}
end

-- Probes run only when a route needs an untrusted candidate, the geometry is plausible, the kind of
-- surface has never been tried, and the query's probe policy allows it. How long to try, how much
-- movement proves the mechanism, and how much risk to accept come from the policy, never from a fixed
-- world limit: a hundred-stud ladder is proven by the first few studs of ascent. Once proven, the whole
-- traversal is trusted like any known surface.
Capabilities.RuntimeProbe = { Defaults = { MaxTime = 1.5, VerificationRise = 3, MaxRisk = 0.25, Budget = 3 }, spent = 0, world = nil }

-- The effective probe policy for one affordance: the query's values, else the agent's, else defaults
function Capabilities.RuntimeProbe.policy(query, agent, aff)
	local given = type(query.ProbePolicy) == "table" and query.ProbePolicy or {}
	local d = Capabilities.RuntimeProbe.Defaults
	return {
		MaxTime = given.MaxTime or (agent.ProbeTime and agent:ProbeTime(aff)) or d.MaxTime,
		VerificationRise = given.VerificationRise or (agent.VerificationRise and agent:VerificationRise(aff)) or d.VerificationRise,
		MaxRisk = given.MaxRisk or d.MaxRisk,
		Budget = given.Budget or d.Budget,
	}
end

-- Whether an unproven surface is worth an experiment now. One missed attach used to end the matter
-- for good: a single failure gives a behavioral score of 1/3, which is under the trust threshold, and
-- the old rule refused to probe anything that had any observation at all. So the candidate could
-- neither be trusted nor tried again, which is the opposite of learning. A failure now costs
-- confidence and a cooling period, and only a run of them closes the question.
function Capabilities.RuntimeProbe.allowed(aff, policy, exec)
	if not Affordances.plausible(aff) then return false end
	local k = Memory.known[exec or aff.Key]
	if k then
		if k.Successes > 0 then return false end
		if k.Failures >= (policy.MaxFailures or 3) then return false end
		if (k.ProbeAgain or 0) > os.clock() then return false end
	end
	if policy.Allow then return policy.Allow(aff) end
	return (aff.Risk or 0) <= policy.MaxRisk
end

-- A probe that failed backs the surface off for a while, longer each time, so a candidate is retried
-- but never hammered. Cleared by the first success.
function Capabilities.RuntimeProbe.cool(key)
	local k = Memory.entry(key)
	k.ProbeAgain = os.clock() + math.min(20 * (k.Failures + 1), 120)
end

function Capabilities.RuntimeProbe.open(worldKey, budget)
	local probe = Capabilities.RuntimeProbe
	if probe.world ~= worldKey then probe.world, probe.spent = worldKey, 0 end
	return probe.spent < budget
end

function Capabilities.RuntimeProbe.spend()
	Capabilities.RuntimeProbe.spent += 1
end

-- Ready-made policies a consumer picks from; a table of its own works the same
UniversalNav.ProbePolicies = {
	Never = { Mode = "Never" },
	Conservative = { Mode = "WhenNecessary", MaxTime = 1.5, VerificationRise = 3, MaxRisk = 0.25, Budget = 3 },
	Exploratory = { Mode = "WhenNecessary", MaxTime = 4, VerificationRise = 2, MaxRisk = 0.8, Budget = 20 },
}

---------------------------------------------------------------------------------------------- Roblox
local Roblox = {}
UniversalNav.Roblox = Roblox

-- Geometry queries against the Workspace with a caller-supplied ignore list; counts every query
local WorkspaceGeometry = {}
WorkspaceGeometry.__index = WorkspaceGeometry
Roblox.WorkspaceGeometry = WorkspaceGeometry

function WorkspaceGeometry.new(opts)
	return setmetatable({ ignore = opts.Ignore, rays = 0, casts = 0 }, WorkspaceGeometry)
end

function WorkspaceGeometry:params()
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = self.ignore()
	rp.RespectCanCollide = true
	self.rp = rp
	return rp
end

function WorkspaceGeometry:Raycast(from, to)
	self.rays += 1
	return Workspace:Raycast(from, to - from, self.rp)
end

function WorkspaceGeometry:Blockcast(from, to, size)
	self.casts += 1
	return Workspace:Blockcast(CFrame.new(from), size, to - from, self.rp)
end

-- A Roblox humanoid as an agent: body size, the speeds it moves at, and what it can do
local HumanoidAdapter = {}
HumanoidAdapter.__index = HumanoidAdapter
Roblox.HumanoidAdapter = HumanoidAdapter

-- opts: Humanoid (function), Speed (function), JumpVelocity (function), Radius, Height, ClimbFactor
-- Humanoid may be the instance itself or a getter returning it. A character respawns, so callers that
-- can supply a getter should; taking the instance directly is accepted rather than failing later inside
-- a capability check with "attempt to call an Instance value".
function HumanoidAdapter.new(opts)
	local hum = opts.Humanoid
	return setmetatable({
		humanoid = type(hum) == "function" and hum or function() return hum end,
		radius = opts.Radius or 2,
		height = opts.Height or 4.5,
		speed = type(opts.Speed) == "function" and opts.Speed or function() return opts.Speed end,
		jumpVelocity = type(opts.JumpVelocity) == "function" and opts.JumpVelocity or function() return opts.JumpVelocity end,
		climbFactor = opts.ClimbFactor or 0.7,
		step = opts.Step or 2.5,
		slope = opts.Slope,
		maxDrop = opts.MaxDrop or 60,
		gapDown = opts.GapDown or 8,
	}, HumanoidAdapter)
end

function HumanoidAdapter:Speed() return self.speed() end
function HumanoidAdapter:MaxSpeed() return self.speed() end
function HumanoidAdapter:JumpVelocity() return self.jumpVelocity() end
function HumanoidAdapter:Gravity() return Workspace.Gravity end
function HumanoidAdapter:Size() return Vector3.new(self.radius, self.height, self.radius) end

-- What this body steps over without jumping, and the steepest rise per unit of run it walks up a slope
-- or stair: the live humanoid's own slope limit, never past 70 degrees
function HumanoidAdapter:Step() return self.step end
function HumanoidAdapter:Slope()
	if self.slope then return self.slope end
	local hum = self.humanoid()
	return math.tan(math.rad(math.min(hum and hum.MaxSlopeAngle or 70, 70)))
end

-- Where the body's reference point sits above the floor, and the clearance it needs to stand
function HumanoidAdapter:Lift() return self.height / 2 + 0.25 end
function HumanoidAdapter:Headroom() return self.height end

-- How far this body may fall on purpose, and the flat gap past which a downhill move is a jump rather
-- than a walk. Both are properties of the body, not of the world: a Roblox humanoid takes any fall
-- without damage, something else may take none at all.
function HumanoidAdapter:MaxDrop() return self.maxDrop end
function HumanoidAdapter:GapDown() return self.gapDown end

-- The apex is what the body reaches with nothing to spare, and a landing there is one the feet clip:
-- the usable rise keeps a margin below it, so a jump the model offers is one the body still has room
-- to finish. The reach is measured the same way, over the airtime that remains at that rise.
function HumanoidAdapter:JumpEnvelope()
	local v, g, speed = self:JumpVelocity(), self:Gravity(), self:Speed()
	local rise = v * v / (2 * g) - self:Step()
	if rise < 0 then rise = 0 end
	local flat = speed * (2 * v / g)
	return { MaxUp = rise, MaxFlat = flat }
end

-- How fast this body climbs this thing. Only a rate this shape of body actually measured counts; a
-- rate learned by a different shape says nothing about what this one can do.
function HumanoidAdapter:ClimbSpeed(key)
	local model = key and Memory.model(Affordances.execKey(key, self))
	if model and model.Speed and model.Speed > 1 then return model.Speed end
	return self.speed() * self.climbFactor
end

function HumanoidAdapter:Capabilities()
	local hum = self.humanoid()
	return hum and Capabilities.inspectHumanoid(hum) or { Ground = true }
end

-- The providers this agent's capabilities admit
function HumanoidAdapter:Providers()
	local can = self:Capabilities()
	local Traversal = UniversalNav.Traversal
	local list = { Traversal.Ground, Traversal.Drop }
	if can.Jump then table.insert(list, Traversal.Jump) end
	if can.HumanoidClimbState then table.insert(list, Traversal.Climb) end
	return list
end

-- Bodies that execute a mechanism the same way share what they learn about it. Height and reach are
-- bucketed so that a nudge to walk speed does not throw away everything this shape of body has learned.
function HumanoidAdapter:Family()
	return string.format("%d:%d:%d", math.floor(self.height * 2 + 0.5), math.floor(self.radius * 2 + 0.5), math.floor(self:JumpEnvelope().MaxUp / 2 + 0.5))
end

function HumanoidAdapter:Signature()
	local names = {}
	for _, p in self:Providers() do table.insert(names, p.Name) end
	return string.format("%.2f|%.2f|%.2f|%.1f|%.1f|%s", self.speed(), self.jumpVelocity(), Workspace.Gravity, self.radius, self.height, table.concat(names, ","))
end

-- Climb executor and probe in one. Phases: approach the foot of the face, attach by moving into the
-- surface (shifting a little to each side when the body does not take), confirm by the observer, ascend
-- to the crest, dismount toward the chosen exit, confirm ground. Every outcome is reported to memory
-- under the affordance's key, with the measured climb speed.
-- io: Root() -> part, Humanoid() -> humanoid, Move(dir), Jump(), Active() -> bool
Roblox.ClimbExecutor = { Approach = 3, Attach = 1.5, Dismount = 3 }

function Roblox.ClimbExecutor.run(transition, io)
	local aff, exit, foot = transition.Data.Affordance, transition.Data.Exit, transition.Data.Foot
	local hum, root = io.Humanoid(), io.Root()
	if not hum or not root then return { Status = "failed", Phase = "start", Rise = 0, Verified = false } end
	local probe = type(transition.Probe) == "table" and transition.Probe or nil
	local attachLimit = probe and probe.MaxTime or Roblox.ClimbExecutor.Attach
	local verifyRise = probe and probe.VerificationRise or 0
	local verified = probe == nil
	local into = -aff.Normal
	local side = Vector3.new(-into.Z, 0, into.X)
	local function press(here, extra)
		local off = math.clamp((foot - here):Dot(side), -1, 1) * 0.6
		return (into + side * (off + (extra or 0))).Unit
	end
	local crest, exitPos = aff.Top, exit.Position
	local started = os.clock()
	local phase, phaseAt = "approach", os.clock()
	local obs, climbFrom, climbAt
	local shift = 0
	local highest, highestAt = -math.huge, 0
	local hopAt = nil
	local function abort()
		local at = io.Root()
		local nearTop = climbFrom ~= nil and at ~= nil and at.Position.Y >= crest.Y - 2
		local h = io.Humanoid()
		Roblox.ClimbExecutor.Last = { Status = "failed", Phase = phase, Rise = climbFrom and at and at.Position.Y - climbFrom or 0, Verified = verified, Foot = foot, Face = aff.Face, Top = aff.Top, Held = os.clock() - phaseAt, State = h and h:GetState().Name or nil, BelowCrest = at and crest.Y - at.Position.Y or nil }
		if nearTop then
			local toExit = Vector3.new(exitPos.X - at.Position.X, 0, exitPos.Z - at.Position.Z)
			io.Move(toExit.Magnitude > 0.5 and toExit.Unit or into)
			io.Jump()
		end
		local until_ = os.clock() + 1.5
		while io.Active() and os.clock() < until_ do
			root, hum = io.Root(), io.Humanoid()
			if not root or not hum then break end
			if hum:GetState() ~= Enum.HumanoidStateType.Climbing and hum.FloorMaterial ~= Enum.Material.Air then
				if nearTop and root.Position.Y >= crest.Y - 2 and flatBetween(root.Position, exitPos) < 4 then
					Roblox.ClimbExecutor.Last = { Status = "done", Phase = "hop", Rise = crest.Y - climbFrom, Verified = true }
				end
				break
			end
			if not nearTop then io.Move(-into) end
			RunService.Heartbeat:Wait()
		end
		io.Move(Vector3.zero)
		return Roblox.ClimbExecutor.Last
	end
	while io.Active() do
		local dt = RunService.Heartbeat:Wait()
		root, hum = io.Root(), io.Humanoid()
		if not root or not hum then return abort() end
		local here = root.Position
		local toFoot = Vector3.new(foot.X - here.X, 0, foot.Z - here.Z)
		local touching = math.abs(toFoot:Dot(side)) < 0.7 and math.abs(toFoot:Dot(into)) < 2
		if phase == "approach" then
			io.Move(toFoot.Magnitude > 0.4 and toFoot.Unit or into)
			if touching then
				phase, phaseAt = "attach", os.clock()
				obs = Capabilities.MotionObserver.start(root, hum)
			elseif os.clock() - phaseAt > Roblox.ClimbExecutor.Approach then
				break
			end
		elseif phase == "attach" then
			local held = os.clock() - phaseAt
			if held > 0.6 and shift == 0 then shift = 1 elseif held > 1.2 and shift == 1 then shift = -1 elseif held > 1.8 and shift == -1 then shift = 0 end
			io.Move(press(here, shift * 0.4))
			Capabilities.MotionObserver.sample(obs, root, hum, touching, dt)
			local rise = here.Y - obs.pos.Y
			if obs.climbingSeen or rise >= 1 then
				local read = Capabilities.MotionObserver.interpret(obs, root, hum, held)
				if read.Climbing then
					phase, climbFrom, climbAt = "ascend", here.Y, os.clock()
				end
			elseif held > attachLimit then
				break
			end
		elseif phase == "ascend" then
			if here.Y > highest + 0.2 then highest, highestAt = here.Y, os.clock() end
			local stuck = os.clock() - highestAt
			io.Move(press(here, stuck > 0.4 and (stuck % 1 < 0.5 and 0.5 or -0.5) or 0))
			if not verified and here.Y - climbFrom >= verifyRise then verified = true end
			if here.Y >= crest.Y - 1 then
				phase, phaseAt = "dismount", os.clock()
			elseif stuck > 1.2 or os.clock() - climbAt > 1.5 + aff.Height / 6 then
				return abort()
			end
		elseif phase == "dismount" then
			local toExit = Vector3.new(exitPos.X - here.X, 0, exitPos.Z - here.Z)
			local dir = toExit.Magnitude > 0.5 and toExit.Unit or into
			if here.Y < crest.Y - 0.5 then dir = (dir + into).Unit end
			io.Move(dir)
			local held = os.clock() - phaseAt
			if hum:GetState() == Enum.HumanoidStateType.Climbing and held > 0.4 and held - (hopAt or 0) > 0.6 then
				io.Jump()
				hopAt = held
			end
			if flatBetween(here, exitPos) < 2.5 and hum.FloorMaterial ~= Enum.Material.Air then
				io.Move(Vector3.zero)
				local climbed = os.clock() - climbAt
				Roblox.ClimbExecutor.Last = { Status = "done", Phase = "dismount", Rise = crest.Y - climbFrom, Verified = true, Speed = climbed > 0.2 and (crest.Y - climbFrom) / climbed or nil }
				return Roblox.ClimbExecutor.Last
			end
			if held > 0.8 and hum:GetState() ~= Enum.HumanoidStateType.Climbing and (here.Y - climbFrom) < 0.5 then
				return abort()
			end
			if os.clock() - phaseAt > Roblox.ClimbExecutor.Dismount then return abort() end
		end
	end
	return abort()
end

---- Jump executor: one jump between two points, run as the physics says. The body runs at the landing
-- along the move's line and takes off at the speed that lands it a body's width past the landing (so
-- the feet are still above a lip when the front of the body meets it): running flat out when the
-- landing is far, easing off when it is near, backing up when it is too near to jump at all. In the
-- air it holds that speed and confirms where it came down.
-- io: Root(), Humanoid(), Move(dir), Jump(), Active(), Lift() -> the agent's node height
Roblox.JumpExecutor = { Approach = 4, Runway = 3, Landing = 3, Edge = 1.5 }

-- Seconds in the air from a takeoff at v to a landing dy higher, on the way down; nil when out of reach
local function airtime(v, g, dy)
	local under = v * v - 2 * g * dy
	if under < 0 then return nil end
	return (v + math.sqrt(under)) / g
end

function Roblox.JumpExecutor.run(transition, io)
	local hum, root = io.Humanoid(), io.Root()
	if not hum or not root then return { Status = "failed", Phase = "start" } end
	local lift = io.Lift()
	local to = transition.To
	local landing = to.Floor or (to.Position - Vector3.new(0, lift, 0))
	local g = Workspace.Gravity
	local v = hum.UseJumpPower and hum.JumpPower or math.sqrt(2 * g * hum.JumpHeight)
	local height = hum.HipHeight + root.Size.Y / 2
	local phase, phaseAt = "approach", os.clock()
	local airborne, jumpedAt, retried = false, nil, false
	local wasSpeed = hum.WalkSpeed
	local planned = transition.Data and transition.Data.Motion
	local function floorHere(r) return r.Position.Y - height end
	local function toward(r)
		local d = Vector3.new(landing.X - r.Position.X, 0, landing.Z - r.Position.Z)
		return d.Magnitude, d.Magnitude > 0.01 and d.Unit or r.CFrame.LookVector
	end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { root.Parent }
	rp.RespectCanCollide = true
	local function finish(status, extra)
		hum.WalkSpeed = wasSpeed
		io.Move(Vector3.zero)
		local r = io.Root()
		local flat = r and toward(r) or -1
		local out = { Status = status, Phase = phase, Off = flat, Below = r and landing.Y - floorHere(r) or 0, Held = os.clock() - phaseAt }
		for k, val in pairs(extra or {}) do out[k] = val end
		Roblox.JumpExecutor.Last = out
		return out
	end
	while io.Active() do
		RunService.Heartbeat:Wait()
		root, hum = io.Root(), io.Humanoid()
		if not root or not hum then return finish("failed") end
		local flat, dir = toward(root)
		local vel = root.AssemblyLinearVelocity
		local speed = math.max(Vector3.new(vel.X, 0, vel.Z):Dot(dir), 0)
		local dy = landing.Y - floorHere(root)
		if phase == "approach" then
			local top = math.max(wasSpeed, planned and planned.HorizontalSpeed or 0)
			local t = airtime(v, g, dy)
			local need = t and (flat + Roblox.JumpExecutor.Edge) / t or math.huge
			if planned and planned.HorizontalSpeed and flat > 1.5 then
				need = math.max(need, planned.HorizontalSpeed)
			end
			local behind = root.Position - dir * 3 - Vector3.new(0, height - 0.5, 0)
			local runway = Workspace:Raycast(behind + Vector3.new(0, 2, 0), Vector3.new(0, -4, 0), rp) ~= nil
			if flat <= 1.5 and math.abs(dy) < 1.5 then
				return finish("done", { Speed = speed })
			elseif need <= top then
				local scale = math.clamp(need / top, 0.35, 1)
				hum.WalkSpeed = math.max(need, top * 0.35)
				if need < top * 0.35 and runway then
					io.Move(-dir)
				else
					io.Move(dir)
					if speed >= need * 0.85 and speed <= need * 1.2 then
						io.Jump()
						phase, phaseAt, jumpedAt = "air", os.clock(), os.clock()
						io.Move(dir)
					end
				end
			else
				io.Move(dir)
			end
			if os.clock() - phaseAt > Roblox.JumpExecutor.Approach then return finish("failed") end
		else
			io.Move(flat > 1 and dir or Vector3.zero)
			local inAir = hum.FloorMaterial == Enum.Material.Air
			if inAir then airborne = true end
			local since = os.clock() - jumpedAt
			if not airborne and since > 0.25 and not retried then
				retried = true
				io.Jump()
			elseif not airborne and since > 0.6 then
				phase = "takeoff"
				return finish("failed")
			end
			if airborne and not inAir and since > 0.15 then
				if flat <= Roblox.JumpExecutor.Landing and math.abs(dy) <= 2 then return finish("done", { Speed = speed }) end
				return finish("failed")
			end
			if os.clock() - phaseAt > 2.5 then return finish("failed") end
		end
	end
	return finish("failed")
end

----------------------------------------------------------------------------------------- Steering
-- Look is the distance the body checks ahead, and it has to be far enough that the turn can finish
-- before the wall arrives: a fixed six studs at twenty-five studs a second gives a quarter second of
-- warning for a turn that takes a third, so the body is committed to clipping it before it ever sees
-- it. It scales with speed, with the fixed value as a floor for a body barely moving.
local Steering = { Name = "Steering", Look = 6, Ahead = 0.5, Fan = 14, Widest = 170, Keep = 0.35, Clearance = 0.6, Forward = -0.1, Commit = 0.25, Escape = 1.2 }
UniversalNav.Steering = Steering

-- How far the body gets along a heading before something it cannot walk over stops it. The body is
-- swept from where it stands to the far end of the look, at the height it clears steps from, so the
-- answer is the distance the walker really has and not the distance to whatever a thin ray found.
function Steering.Room(from, dir, ctx, look)
	local agent, geo = ctx.Agent, ctx.Geometry
	if not geo.rp then geo:params() end
	local step, size = agent:Step(), agent:Size()
	local body = Vector3.new(size.X, size.Y - step, size.Z)
	local centre = Vector3.new(0, (step + size.Y) / 2 - agent:Lift(), 0)
	look = look or math.max(Steering.Look, agent:Speed() * Steering.Ahead)
	local hit = geo:Blockcast(from + centre, from + dir * look + centre, body)
	if not hit then return look, nil end
	return math.max((hit.Position - (from + centre)).Magnitude - Steering.Clearance, 0), hit
end

-- Whether the body can stand where a heading would put it: floor within a step of the level it walks
-- at, so a heading over a lip the walker would fall off is not offered as open ground.
function Steering.Footing(from, dir, ctx, dist)
	local agent, geo = ctx.Agent, ctx.Geometry
	local at = from + dir * dist
	local hit = geo:Raycast(at + Vector3.new(0, agent:Step(), 0), Vector3.new(0, -(agent:Lift() + agent:Step() * 2 + 1), 0))
	if not hit then return false end
	return math.abs((hit.Position.Y + agent:Lift()) - from.Y) <= agent:Step() * 2
end

-- The heading to walk this frame. The wanted direction is taken whole when the body fits along it.
-- Otherwise headings are tried outward from it in even steps to either side, and the first that has
-- both room and footing wins, so the walk bends by the least it can rather than sliding off a face.
-- A heading already committed to is held while it still has room, which is what stops the left-right
-- flicker of two directions that alternately look best. Nothing open means nothing is returned, and
-- the caller has a real answer to act on instead of a body pushing into a wall.
function Steering.Heading(from, want, ctx, memo)
	memo = memo or {}
	ctx.Geometry:params()
	local look = math.max(Steering.Look, ctx.Agent:Speed() * Steering.Ahead)
	local straight, blocker = Steering.Room(from, want, ctx, look)
	if straight >= look - 0.01 and Steering.Footing(from, want, ctx, math.min(straight, look) * 0.8) then
		memo.Bend, memo.Side = nil, nil
		return want, straight, nil
	end
	if memo.Bend and memo.Bend:Dot(want) > Steering.Forward then
		local held = Steering.Room(from, memo.Bend, ctx, look)
		local fresh = memo.At and (os.clock() - memo.At) < Steering.Commit
		if (held >= look * Steering.Keep or (fresh and held > 1.5)) and Steering.Footing(from, memo.Bend, ctx, math.max(held, 1) * 0.8) then
			return memo.Bend, held, blocker
		end
	end
	local side = memo.Side or 1
	local best, bestRoom
	for turn = Steering.Fan, Steering.Widest, Steering.Fan do
		for _, sign in { side, -side } do
			local dir = CFrame.Angles(0, math.rad(turn * sign), 0) * want
			local room = Steering.Room(from, dir, ctx, look)
			if room >= look - 0.01 and Steering.Footing(from, dir, ctx, room * 0.8) then
				memo.Bend, memo.Side, memo.At = dir, sign, os.clock()
				return dir, room, blocker
			end
			if room > (bestRoom or straight) and Steering.Footing(from, dir, ctx, room * 0.8) then
				best, bestRoom = dir, room
				memo.Side = sign
			end
		end
	end
	if best and bestRoom > math.max(straight, Steering.Escape) then
		memo.Bend, memo.At = best, os.clock()
		return best, bestRoom, blocker
	end
	memo.Bend = nil
	return nil, straight, blocker
end

----------------------------------------------------------------------------------------- Traversal
local Traversal = {}
UniversalNav.Traversal = Traversal

-- Every provider answers two questions: which transitions leave a lattice state, and whether one
-- specific pair of positions is joined by its move. The second is what start and goal connectors use.
Traversal.Ground = { Name = "Ground" }

-- A walk: the body above the height it steps over, swept from one point to the other, meets nothing,
-- so a wall, a beam over a doorway or a frame too narrow refuse it while a step, a curb or a stair
-- does not. A level walk needs floor under its midpoint; a slope or stair steeper than a step but
-- within the agent's slope needs floor at every step-sized interval between the two heights, so a
-- ledge with nothing between, or a stack of ledges, is left to the jump.
function Traversal.Ground.Between(a, b, ctx)
	local dy = b.Y - a.Y
	local rise = math.abs(dy)
	local agent = ctx.Agent
	local step = agent:Step()
	if rise > math.max(flatBetween(a, b), 1) * agent:Slope() then return nil end
	local geo, size, lift = ctx.Geometry, agent:Size(), agent:Lift()
	local body = Vector3.new(size.X, size.Y - step, size.Z)
	local centre = Vector3.new(0, (step + size.Y) / 2 - lift, 0)
	if geo:Blockcast(a + centre, b + centre, body) then return nil end
	local flat = flatBetween(a, b)
	local spacing = math.max(agent:Size().Z, 1)
	local k = math.max(math.ceil(flat / spacing), math.ceil(rise / step), 2)
	for i = 1, k - 1 do
		local p = a:Lerp(b, i / k)
		local hit = geo:Raycast(p + Vector3.new(0, 1, 0), p - Vector3.new(0, lift + step + 2, 0))
		if not hit then return nil end
		if rise > step and math.abs(hit.Position.Y - (p.Y - lift)) > step * 0.6 then return nil end
	end
	local d = (b - a).Magnitude
	return "Walk", d / agent:Speed(), d
end

function Traversal.Ground.Generate(state, ctx, out)
	local cache = ctx.Cache
	for _, m in ctx.World:Neighbours(state, 1) do
		local kind, time, dist
		local known = cache and cache:walkBetween(state, m)
		if known ~= nil then
			if known then kind, time, dist = known[1], known[2], known[3] end
		else
			kind, time, dist = Traversal.Ground.Between(state.Position, m.Position, ctx)
			if cache then cache:rememberWalk(state, m, kind and { kind, time, dist } or false) end
		end
		if kind then table.insert(out, Core.transition(state, m, kind, time, dist, ctx.World:Risk(m))) end
	end
end

Traversal.Drop = { Name = "Drop" }

-- Walk to above the landing, then fall: the body is swept along both parts
function Traversal.Drop.Between(a, b, ctx)
	local dy = b.Y - a.Y
	if dy >= -ctx.Agent:Step() or -dy > ctx.Agent:MaxDrop() then return nil end
	local geo, size = ctx.Geometry, ctx.Agent:Size()
	local over = Vector3.new(b.X, a.Y, b.Z)
	if geo:Blockcast(a, over, size) then return nil end
	if geo:Blockcast(over, b + Vector3.new(0, 1, 0), size) then return nil end
	local flat = flatBetween(a, b)
	local time = math.max(flat / ctx.Agent:Speed(), math.sqrt(-2 * dy / ctx.Agent:Gravity())) + 0.2
	return "Drop", time, (b - a).Magnitude
end

function Traversal.Drop.Generate(state, ctx, out)
	for _, m in ctx.World:Neighbours(state, 1) do
		local kind, time, dist = Traversal.Drop.Between(state.Position, m.Position, ctx)
		if kind then table.insert(out, Core.transition(state, m, kind, time, dist, 0)) end
	end
end

Traversal.Jump = { Name = "Jump", Setup = 0.3 }

-- The arc the executor flies: airborne until the feet come down to the landing's height, at the run
-- speed that covers the flat distance in exactly that time; the body is swept along it in four pieces
function Traversal.Jump.Between(a, b, ctx)
	local flat = flatBetween(a, b)
	local dy = b.Y - a.Y
	local envelope = ctx.Agent:JumpEnvelope()
	if flat < 0.5 or flat > envelope.MaxFlat or dy > envelope.MaxUp then return nil end
	local agent = ctx.Agent
	local speed, g, v = agent:Speed(), agent:Gravity(), agent:JumpVelocity()
	local t = airtime(v, g, dy)
	if not t then return nil end
	local need = (flat + Roblox.JumpExecutor.Edge) / t
	if need > speed then return nil end
	local dir = Vector3.new(b.X - a.X, 0, b.Z - a.Z) / flat
	local geo, size = ctx.Geometry, agent:Size()
	local body = Vector3.new(size.X, size.Y - 1, size.Z)
	local tuck = Vector3.new(0, 0.5, 0)
	local last = a + tuck
	for i = 1, 4 do
		local tt = t * i / 4
		local point = a + dir * need * tt + Vector3.new(0, v * tt - 0.5 * g * tt * tt, 0) + tuck
		if geo:Blockcast(last, point, body) then return nil end
		last = point
	end
	return "Jump", t + Traversal.Jump.Setup, (b - a).Magnitude, {
		HorizontalSpeed = need,
		JumpVelocity = v,
		Airtime = t,
	}
end

-- Only where walking cannot already get there, read off the walks already generated for this state: a
-- neighbour a walk reaches is never jumped to, and a farther cell is jumped to only when the first cell
-- on the way is missing or not walkable, so open floor costs no casts at all. A landing below within a
-- short plan distance is a walk off the edge, never a jump: leaving the rim at full speed carries the
-- body past the opening. Only a gap wider than that is jumped down across.
function Traversal.Jump.Generate(state, ctx, out)
	local envelope = ctx.Agent:JumpEnvelope()
	local rings = math.ceil(envelope.MaxFlat / ctx.World.cell)
	local walk = {}
	for _, t in out do
		if t.Kind == "Walk" then walk[t.To] = true end
	end
	local cell, slope = ctx.World.cell, ctx.Agent:Slope()
	for ring = 1, rings do
		for _, m in ctx.World:Neighbours(state, ring, envelope.MaxFlat) do
			local dy = m.Position.Y - state.Position.Y
			local downGap = dy >= -ctx.Agent:Step() or flatBetween(state.Position, m.Position) >= ctx.Agent:GapDown()
			local onFoot = walk[m] == true
			local flat = Vector3.new(m.Position.X - state.Position.X, 0, m.Position.Z - state.Position.Z)
			if not onFoot and ring >= 2 then
				local mid = ctx.World:NodeInCell(state.Position + flat.Unit * cell, cell * slope)
				onFoot = mid ~= nil and walk[mid] == true
			end
			if dy <= envelope.MaxUp and downGap and (ring >= 2 or dy > flat.Magnitude * slope) and not onFoot then
				local kind, time, dist, motion = Traversal.Jump.Between(state.Position, m.Position, ctx)
				if kind then table.insert(out, Core.transition(state, m, kind, time, dist, ctx.World:Risk(m), { Motion = motion })) end
			end
		end
	end
end

Traversal.Climb = { Name = "Climb", Standoffs = { 1.2, 1.6 } }

-- The column of the face this body rises through: its box is swept from the floor to above the crest
-- where a climbing body hangs, at a few standoffs from the surface and lateral offsets up to its own
-- width, and the first clear one is where the climb starts and is held. Measured once per face and
-- body; a face with no clear column is not climbable by this body from this side.
function Traversal.Climb.Column(aff, floorY, ctx)
	local sig = ctx.Agent:Signature()
	aff.Columns = aff.Columns or {}
	local known = aff.Columns[sig]
	if known ~= nil then return known or nil end
	local out = aff.Normal
	local side = Vector3.new(-out.Z, 0, out.X)
	local size = ctx.Agent:Size()
	local body = Vector3.new(size.X, size.Y + 1, size.Z * 0.6)
	local lift = Vector3.new(0, body.Y / 2 + 0.3, 0)
	local top = Vector3.new(0, aff.Top.Y - floorY + 1, 0)
	local found = false
	for _, standoff in Traversal.Climb.Standoffs do
		for k = 0, math.ceil(size.X / 0.6) * 2 do
			local lateral = math.ceil(k / 2) * 0.6 * (k % 2 == 0 and 1 or -1)
			local centre = aff.Surface + out * standoff + side * lateral
			local base = Vector3.new(centre.X, floorY, centre.Z)
			if not ctx.Geometry:Blockcast(base + lift, base + lift + top, body) then
				found = base
				break
			end
		end
		if found then break end
	end
	aff.Columns[sig] = found
	return found or nil
end

-- A climb exists where the world offers a surface traversal whose entries include this state, the
-- agent can climb, and the body fits the face: one transition per exit, so the search picks the
-- dismount that serves the route. The search decides whether to trust or probe the affordance behind it.
function Traversal.Climb.Generate(state, ctx, out)
	for _, aff in ctx.World:AffordancesAt(state) do
		if aff.Kind == "SurfaceTraversal" then
			local floorY = state.Floor and state.Floor.Y or state.Position.Y - ctx.Agent:Lift()
			local foot = Traversal.Climb.Column(aff, floorY, ctx)
			if foot then
				local walk = flatBetween(state.Position, foot) / ctx.Agent:Speed()
				local rate = ctx.Agent:ClimbSpeed(aff.Key)
				local climb = aff.Height / rate
				for _, exit in aff.Exits do
					local step = flatBetween(aff.Top, exit.Position) / ctx.Agent:Speed()
					table.insert(out, Core.transition(state, exit, "Climb", walk + climb + step + 1, aff.Height + flatBetween(state.Position, exit.Position), 0, { Affordance = aff, Exit = exit, Foot = foot, Rate = rate, Fixed = walk + step + 1 }))
				end
			end
		end
	end
end

function Traversal.Climb.Between()
	return nil
end

----------------------------------------------------------------------------------------------- World
local World = {}
UniversalNav.World = World

-- Surface lattice: a standable point every few studs on every floor of a model, found by casting down
-- each column; a heightfield of spans with headroom. Neighbours by ring, affordances at points, coarse
-- pieces for early rejection. Knows nothing about who walks on it.
local SurfaceLattice = {}
SurfaceLattice.__index = SurfaceLattice
World.SurfaceLattice = SurfaceLattice

-- opts: Model, Geometry, Cell, Lift, Layers, Probe (how far up a ceiling is looked for), MinClear (the
-- smallest ceiling any body could use), Reach (the flat distance a join may span), Step, Rise, Scanners
function SurfaceLattice.new(opts)
	return setmetatable({
		model = opts.Model,
		cell = opts.Cell or 4,
		probe = opts.Probe or 20,
		minClear = opts.MinClear or 2,
		lift = opts.Lift or 2.5,
		layers = opts.Layers or 8,
		reach = opts.Reach or 13,
		rise = opts.Rise or 6,
		step = opts.Step or 2.5,
		geometry = opts.Geometry,
		scanners = opts.Scanners or { Perception.SemanticScanner, Perception.SurfaceTopology },
		columns = {},
		affordances = {},
		byEntry = {},
		piece = {},
		Found = {},
		Count = 0,
		Ready = false,
		revision = Core.nextRevision(),
	}, SurfaceLattice)
end

-- What this world is across rebuilds: the place and the model's name
function SurfaceLattice:Key()
	return tostring(game.PlaceId) .. "|" .. tostring(self.model and self.model.Name)
end

function SurfaceLattice:Revision()
	return self.revision
end

function SurfaceLattice:list(ix, iz)
	local col = self.columns[ix]
	return col and col[iz]
end

function SurfaceLattice:cellOf(pos)
	return math.floor(pos.X / self.cell + 0.5), math.floor(pos.Z / self.cell + 0.5)
end

-- Every floor under one column, top down. The ceiling over each floor is measured, not tested against one
-- body: Clear is how much room the surface actually has, and each agent decides at query time whether it fits.
function SurfaceLattice:column(ix, iz, top, bottom)
	local x, z = ix * self.cell, iz * self.cell
	local geo = self.geometry
	local y = top
	local list
	for _ = 1, self.layers do
		local hit = geo:Raycast(Vector3.new(x, y, z), Vector3.new(x, bottom, z))
		if not hit then break end
		local at = hit.Position
		if hit.Normal.Y > 0.7 then
			local base = at + Vector3.new(0, 0.5, 0)
			local roof = geo:Raycast(base, base + Vector3.new(0, self.probe, 0))
			local clear = roof and (roof.Position.Y - at.Y) or self.probe
			if clear >= self.minClear then
				list = list or {}
				table.insert(list, { ix = ix, iz = iz, Floor = at, Position = at + Vector3.new(0, self.lift, 0), Clear = clear, Lattice = true })
				self.Count += 1
			end
		end
		y = at.Y - 1
		if y <= bottom then break end
	end
	if list then
		local col = self.columns[ix]
		if not col then
			col = {}
			self.columns[ix] = col
		end
		col[iz] = list
	end
end

-- Builds over a few frames once the model's bounding box has stopped growing, then runs the scanners
function SurfaceLattice:Build()
	local model = self.model
	local size
	for _ = 1, 20 do
		local _, now = model:GetBoundingBox()
		if size and (now - size).Magnitude < 1 then break end
		size = now
		task.wait(0.5)
	end
	if not model.Parent or self.aborted then return false end
	local cf, extent = model:GetBoundingBox()
	local c, half = cf.Position, extent / 2
	local top, bottom = c.Y + half.Y + 2, c.Y - half.Y - 2
	self.geometry:params()
	local x0, x1 = math.floor((c.X - half.X) / self.cell), math.ceil((c.X + half.X) / self.cell)
	local z0, z1 = math.floor((c.Z - half.Z) / self.cell), math.ceil((c.Z + half.Z) / self.cell)
	local done = 0
	for ix = x0, x1 do
		for iz = z0, z1 do
			if not model.Parent or self.aborted then return false end
			self:column(ix, iz, top, bottom)
			done += 1
			if done % 250 == 0 then RunService.Heartbeat:Wait() end
		end
	end
	if not model.Parent or self.aborted then return false end
	for _, scanner in self.scanners do
		local found = scanner.scan(model, self)
		self.Found[scanner.Name] = #found
		for _, aff in found do self:AddAffordance(aff) end
		if not model.Parent or self.aborted then return false end
	end
	self:findPieces()
	self.Ready = self.Count > 0 and not self.aborted
	return self.Ready
end

function SurfaceLattice:Abort()
	self.aborted = true
	self.Ready = false
end

-- The same face of the same object seen by two scanners is one affordance with the stronger evidence of each
function SurfaceLattice:AddAffordance(aff)
	for _, had in self.affordances do
		if had.Object == aff.Object and had.Kind == aff.Kind and (had.Normal - aff.Normal).Magnitude < 0.1 then
			had.Evidence.Semantic = math.max(had.Evidence.Semantic, aff.Evidence.Semantic)
			had.Evidence.Geometry = math.max(had.Evidence.Geometry, aff.Evidence.Geometry)
			if had.Mechanism == "Unknown" and aff.Mechanism ~= "Unknown" then
				had.Mechanism, had.Key = aff.Mechanism, aff.Key
			end
			return
		end
	end
	table.insert(self.affordances, aff)
	for _, entry in aff.Entries do
		local list = self.byEntry[entry]
		if not list then
			list = {}
			self.byEntry[entry] = list
		end
		table.insert(list, aff)
	end
end

local none = {}
function SurfaceLattice:AffordancesAt(n)
	return self.byEntry[n] or none
end

-- The node in exactly this cell near this height, or nothing
function SurfaceLattice:NodeInCell(pos, tolerance)
	local list = self:list(self:cellOf(pos))
	if not list then return nil end
	for _, n in list do
		if math.abs(n.Position.Y - pos.Y) < tolerance then return n end
	end
	return nil
end

function SurfaceLattice:NodeAt(pos, tolerance)
	local ix, iz = self:cellOf(pos)
	local best, bestD
	for dx = -1, 1 do
		for dz = -1, 1 do
			local list = self:list(ix + dx, iz + dz)
			if list then
				for _, n in list do
					if math.abs(n.Position.Y - pos.Y) < (tolerance or 4) then
						local d = (n.Position - pos).Magnitude
						if not bestD or d < bestD then best, bestD = n, d end
					end
				end
			end
		end
	end
	return best
end

function SurfaceLattice:Nearby(pos, radius)
	local ix, iz = self:cellOf(pos)
	local cells = math.ceil(radius / self.cell)
	local out = {}
	for dx = -cells, cells do
		for dz = -cells, cells do
			local list = self:list(ix + dx, iz + dz)
			if list then
				for _, n in list do
					if flatBetween(n.Position, pos) <= radius then table.insert(out, n) end
				end
			end
		end
	end
	return out
end

function SurfaceLattice:Neighbours(n, ring, flatLimit)
	local out = {}
	local limit = flatLimit or math.huge
	for dx = -ring, ring do
		for dz = -ring, ring do
			if math.max(math.abs(dx), math.abs(dz)) == ring and math.sqrt(dx * dx + dz * dz) * self.cell <= limit then
				local list = self:list(n.ix + dx, n.iz + dz)
				if list then
					for _, m in list do table.insert(out, m) end
				end
			end
		end
	end
	return out
end

-- A point is a lip when a neighbouring cell has no floor at its level; routes keep off lips when they can
function SurfaceLattice:Risk(n)
	if n.risk == nil then
		n.risk = 0
		for dx = -1, 1 do
			for dz = -1, 1 do
				if dx ~= 0 or dz ~= 0 then
					local level = false
					local list = self:list(n.ix + dx, n.iz + dz)
					if list then
						for _, m in list do
							if math.abs(m.Position.Y - n.Position.Y) <= self.step then level = true end
						end
					end
					if not level then n.risk = 0.2 end
				end
			end
		end
	end
	return n.risk
end

-- Coarse connectivity: whatever a walk, drop, jump or affordance could possibly join, either way.
-- This is only the "certainly apart?" prefilter, so it must be undirected: a climb is offered from
-- its foot to its top, and a flood that happened to start at the top could not walk it backwards,
-- which split a ladder's two ends into different pieces and let FindPath refuse a real route before
-- the search ever saw it. Union-find joins both ends of every possible connection regardless of the
-- direction it would be travelled in. Direction belongs to the search, not to this test.
function SurfaceLattice:findPieces()
	local parent = {}
	local function find(a)
		local root = a
		while parent[root] and parent[root] ~= root do root = parent[root] end
		while parent[a] and parent[a] ~= root do
			local up = parent[a]
			parent[a] = root
			a = up
		end
		return root
	end
	local function union(a, b)
		local ra, rb = find(a), find(b)
		if ra ~= rb then parent[rb] = ra end
	end
	local pops = 0
	for _, col in pairs(self.columns) do
		for _, list in pairs(col) do
			for _, n in list do
				if parent[n] == nil then parent[n] = n end
				pops += 1
				if pops % 400 == 0 then
					RunService.Heartbeat:Wait()
					if self.aborted then return end
				end
				for ring = 1, math.ceil(self.reach / self.cell) do
					for _, m in self:Neighbours(n, ring, self.reach) do
						if ring == 1 or math.abs(m.Position.Y - n.Position.Y) <= self.rise then
							if parent[m] == nil then parent[m] = m end
							union(n, m)
						end
					end
				end
				for _, aff in self:AffordancesAt(n) do
					for _, exit in aff.Exits do
						if parent[exit] == nil then parent[exit] = exit end
						union(n, exit)
					end
				end
			end
		end
	end
	for _, aff in self.affordances do
		for _, entry in aff.Entries do
			if parent[entry] == nil then parent[entry] = entry end
			for _, exit in aff.Exits do
				if parent[exit] == nil then parent[exit] = exit end
				union(entry, exit)
			end
		end
	end
	local piece, labels, pieces = self.piece, {}, 0
	for n in pairs(parent) do
		local root = find(n)
		local label = labels[root]
		if not label then
			pieces += 1
			label = pieces
			labels[root] = label
		end
		piece[n] = label
	end
	self.Pieces = pieces
end

function SurfaceLattice:Piece(n)
	return self.piece[n]
end

------------------------------------------------------------------------------------------- Navigator
local Navigator = {}
Navigator.__index = Navigator
UniversalNav.Navigator = Navigator

-- Ties a world, a cache and a search backend together; every query brings its own agent, cost and goal
function Navigator.new(opts)
	return setmetatable({
		world = opts.World,
		cache = TransitionCache.new(),
		algorithm = opts.Algorithm or "WeightedAStar",
		epsilon = opts.Epsilon or 1.2,
		budget = opts.Budget or 0.003,
		cap = opts.Cap or 6000,
		walkRadius = opts.WalkRadius or 6,
		connectLimit = opts.ConnectLimit or 4,
		probeLimit = opts.ProbeLimit or 24,
		cold = setmetatable({}, { __mode = "k" }),
		loose = {},
		looseRev = nil,
		distrust = setmetatable({}, { __mode = "k" }),
	}, Navigator)
end

-- A move the body failed once is left out for half a minute, one it failed twice for the rest of this world
function Navigator:Distrusted(from, to)
	local list = self.distrust[from]
	local entry = list and list[to]
	return entry ~= nil and entry.until_ > os.clock()
end

-- A move the search would refuse without a probe: an unproven surface is not ground a plan can be
-- made over, so a caller asking where it can get to is told the same thing a route would tell it
function Navigator:trusted(t)
	local aff = t.Data and t.Data.Affordance
	if not aff then return true end
	if (self.cold[self:coldKey(aff)] or 0) > os.clock() then return false end
	return Affordances.trust(aff, self:execKey(aff)) >= Affordances.Threshold
end

-- The record of this mechanism as performed by the body currently being routed
function Navigator:execKey(aff)
	return self.family and (aff.Key .. "#" .. self.family) or nil
end

-- A cold block is about one physical thing, never a kind of thing. The affordance key describes a shape
-- of object, so a building's twelve identical ladders share it; blocking on that key means one bad mount
-- refuses every ladder in the building and strands the body at the foot of all of them.
function Navigator:coldKey(aff)
	return aff.Object or aff.Key
end

-- A search that exhausted the graph has visited everything its start can reach; that closed set is
-- kept for a few seconds, and any later query starting inside it whose goal lies outside it is
-- answered at once without expanding anything
function Navigator:apart(start, goals)
	local kept = self.reach
	if not kept or kept.key ~= self.cache.key or os.clock() - kept.at > 3 or not kept.set[start] then return false end
	for n in pairs(goals) do
		if kept.set[n] then return false end
	end
	return true
end

-- Connectors: the moves that join a free position to the world, validated exactly like any other move.
-- Nearest points first; walks within a short radius are enough when any exist, and only when none do
-- are drops and jumps out to the full radius tried, so a query on open floor costs a handful of rays.
function Navigator:looseKey(pos)
	return string.format("%d,%d,%d", math.floor(pos.X / 4), math.floor(pos.Y / 4), math.floor(pos.Z / 4))
end

function Navigator:connect(pos, ctx, outward)
	local rev = self.world:Revision()
	if self.looseRev ~= rev then
		self.loose, self.looseRev = {}, rev
	end
	local key = not outward and self:looseKey(pos)
	if key and self.loose[key] then return {}, Core.state(pos) end
	local out, count = {}, 0
	local free = Core.state(pos)
	local near = self.world:Nearby(pos, ctx.Agent:JumpEnvelope().MaxFlat)
	table.sort(near, function(a, b) return (a.Position - pos).Magnitude < (b.Position - pos).Magnitude end)
	local function try(provider, n)
		local a, b = pos, n.Position
		if not outward then a, b = n.Position, pos end
		local kind, time, dist, motion = provider.Between(a, b, ctx)
		if not kind then return false end
		local data = motion and { Motion = motion } or nil
		if outward then
			table.insert(out, Core.transition(free, n, kind, time, dist, 0, data))
		else
			out[n] = Core.transition(n, free, kind, time, dist, 0, data)
		end
		count += 1
		return true
	end
	local walk = ctx.Providers[1]
	for _, n in near do
		if (n.Position - pos).Magnitude <= self.walkRadius then try(walk, n) end
		if count >= self.connectLimit then return out, free end
	end
	if count > 0 then return out, free end
	local tried = 0
	for _, n in near do
		for i = 2, #ctx.Providers do
			if try(ctx.Providers[i], n) then break end
		end
		tried += 1
		if count >= self.connectLimit or tried >= self.probeLimit then break end
	end
	if count == 0 and key then self.loose[key] = true end
	return out, free
end

-- The transitions leaving a state, generated once per world revision and agent signature
function Navigator:expand(state, ctx)
	local cache = ctx.Cache
	local list = cache:get(state)
	if list then
		for _, t in list do
			local d = t.Data
			if d and d.Rate and d.Affordance then
				local rate = ctx.Agent:ClimbSpeed(d.Affordance.Key)
				if math.abs(rate - d.Rate) > 0.05 then
					t.Time = (d.Fixed or 0) + d.Affordance.Height / rate
					d.Rate = rate
				end
			end
		end
		return list
	end
	list = {}
	for _, provider in ctx.Providers do provider.Generate(state, ctx, list) end
	local room = ctx.Agent:Headroom()
	for i = #list, 1, -1 do
		local clear = list[i].To.Clear
		if clear and clear < room then table.remove(list, i) end
	end
	cache:set(state, list)
	return list
end

-- Somewhere the agent can actually get to, and get back from. Reachable ground is walked outward from
-- where it stands through the same transitions a route would use, so every answer is a place a plan
-- exists for, not a spot a ray happened to find; a pit floor with no way up is never offered, because
-- nothing reaches it. Candidates are scored by the caller and the best is returned, so the same call
-- serves fleeing, roaming and patrolling. Reach bounds the walk, Nodes the work spent on it.
function Navigator:Reachable(query)
	local world, agent = self.world, query.Agent
	if not world.Ready then return nil end
	local first = world:NodeAt(query.Position, 6)
	if not first then return nil end
	local geo = world.geometry
	geo:params()
	self.cache:use(tostring(world:Revision()) .. "|" .. agent:Signature())
	self.family = agent:Family()
	local ctx = { World = world, Agent = agent, Geometry = geo, Providers = agent:Providers(), Cache = self.cache }
	local reach = query.Reach or 250
	local limit = query.Nodes or 600
	local budget = query.Budget or self.budget
	local queue, seen, head, seenCount = { first }, { [first] = true }, 1, 1
	local best, bestScore
	local slice = os.clock()
	while head <= #queue and seenCount < limit do
		if query.Active and not query.Active() then break end
		local state = queue[head]
		head += 1
		if state ~= first then
			local score = query.Score(state)
			if score and (not bestScore or score > bestScore) then best, bestScore = state, score end
		end
		for _, t in self:expand(state, ctx) do
			local to = t.To
			if not seen[to] and (to.Position - query.Position).Magnitude <= reach
				and not (query.Blocked and query.Blocked(to))
				and not self:Distrusted(state, to)
				and self:trusted(t) then
				seen[to] = true
				seenCount += 1
				table.insert(queue, to)
			end
		end
		if os.clock() - slice > budget then
			RunService.Heartbeat:Wait()
			slice = os.clock()
		end
	end
	return best, bestScore
end

-- Generating the ground around the agent ahead of any route, a slice at a time. The walk is resumed,
-- never restarted: a frontier is kept per world revision and agent, so each call carries on outward
-- from where the last one stopped instead of re-expanding the cached nodes nearest the agent and
-- never reaching new ground. It is re-seeded when the world changes, when the agent's shape changes,
-- or when the agent has walked out of the region the frontier covers.
function Navigator:Warm(query)
	local world, agent = self.world, query.Agent
	if not world.Ready then return 0 end
	local first = world:NodeAt(query.Position, 6)
	if not first then return 0 end
	local geo = world.geometry
	geo:params()
	local key = tostring(world:Revision()) .. "|" .. agent:Signature()
	self.family = agent:Family()
	self.cache:use(key)
	local ctx = { World = world, Agent = agent, Geometry = geo, Providers = agent:Providers(), Cache = self.cache }
	local front = self.frontier
	if not front or front.key ~= key or not front.seen[first] then
		front = { key = key, queue = { first }, seen = { [first] = true }, head = 1 }
		self.frontier = front
	end
	local queue, seen = front.queue, front.seen
	local budget, limit = query.Budget or self.budget, query.Nodes or 300
	local done = 0
	local slice = os.clock()
	while front.head <= #queue and done < limit do
		if query.Active and not query.Active() then break end
		local state = queue[front.head]
		front.head += 1
		if not self.cache:get(state) then done += 1 end
		for _, t in self:expand(state, ctx) do
			if not seen[t.To] then
				seen[t.To] = true
				table.insert(queue, t.To)
			end
		end
		if os.clock() - slice > budget then
			RunService.Heartbeat:Wait()
			slice = os.clock()
		end
	end
	return done
end

-- query: Agent, Start, Goal, Cost (model), Blocked (state -> bool), Algorithm, Epsilon, Cap,
-- ProbePolicy ("WhenNecessary": an unproven plausible surface may be tried when nothing known reaches
-- the goal; "Never": known surfaces only)
-- result: Ok, Why, Path (transitions from the free start to the free goal), Time (seconds along it),
-- Probing (true when the path leans on an untrusted candidate the executor must probe), Stats
function Navigator:FindPath(query)
	local world, agent = self.world, query.Agent
	local t0 = os.clock()
	local geo = world.geometry
	local stats = { Requests = self.cache.hits + self.cache.misses, Hits = self.cache.hits, Rays = geo.rays, Casts = geo.casts }
	local probing = false
	local function finish(why, path, expanded)
		stats.Why, stats.Expanded, stats.Ms = why, expanded or 0, (os.clock() - t0) * 1000
		stats.Requests = self.cache.hits + self.cache.misses - stats.Requests
		stats.Hits = self.cache.hits - stats.Hits
		stats.Rays, stats.Casts = geo.rays - stats.Rays, geo.casts - stats.Casts
		local time = 0
		if path then
			for _, t in path do time += t.Time end
		end
		return { Ok = path ~= nil, Why = why, Path = path, Time = time, Probing = probing, Stats = stats }
	end
	if not world.Ready then return finish("no world", nil, 0) end
	local costModel = query.Cost or Cost.Fastest
	geo:params()
	self.cache:use(tostring(world:Revision()) .. "|" .. agent:Signature())
	self.family = agent:Family()
	local cache = self.cache
	local asked = query.Blocked or function() return false end
	local worldKey = world:Key()
	local blocked = function(state)
		return asked(state) or Memory.isLethal(worldKey, state.Position, 10, 2)
	end
	local providers = agent:Providers()
	local ctx = { World = world, Agent = agent, Geometry = geo, Providers = providers, Cache = cache }
	local starts = self:connect(query.Start, ctx, true)
	if #starts == 0 then return finish("no start", nil, 0) end
	local goals = self:connect(query.Goal, ctx, false)
	local anyGoal, joinable = false, false
	for n in pairs(goals) do
		anyGoal = true
		for _, s in starts do
			if world:Piece(s.To) == world:Piece(n) then joinable = true end
		end
	end
	if not anyGoal then return finish("no goal", nil, 0) end
	if not joinable then return finish("piece", nil, 0) end
	local firstStart, firstGoal = starts[1].To, next(goals)
	if cache:failedBetween(firstStart, firstGoal) then return finish("none", nil, 0) end
	local searchPolicy = query.SearchPolicy or {}
	local slice, budget, goalPos = os.clock(), searchPolicy.TimeSlice or self.budget, query.Goal
	local probePolicy = Capabilities.RuntimeProbe.policy(query, agent, nil)
	local explore = false
	local search = {
		Expand = function(state) return self:expand(state, ctx) end,
		Cost = function(t) return costModel.Of(t) end,
		Heuristic = function(state) return costModel.Heuristic(state.Position, goalPos, agent) end,
		Blocked = blocked,
		Allowed = function(t)
			if self:Distrusted(t.From, t.To) then return false end
			local aff = t.Data and t.Data.Affordance
			if not aff then return true end
			if (self.cold[self:coldKey(aff)] or 0) > os.clock() then return false end
			local exec = self:execKey(aff)
			if Affordances.trust(aff, exec) >= Affordances.Threshold then return true end
			return explore and Capabilities.RuntimeProbe.allowed(aff, probePolicy, exec)
		end,
		Yield = function()
			if os.clock() - slice > budget then
				RunService.Heartbeat:Wait()
				slice = os.clock()
			end
		end,
		Cap = searchPolicy.MaxExpansions or query.Cap or self.cap,
	}
	local backend = Search.Registry[query.Algorithm or self.algorithm]
	local epsilon = query.Epsilon or self.epsilon
	if self:apart(firstStart, goals) then
		cache:rememberFailure(firstStart, firstGoal, 3)
		return finish("apart", nil, 0)
	end
	local path, why, expanded, closed = backend(starts, goals, search, epsilon)
	if not path and why == "none" then
		cache:rememberFailure(firstStart, firstGoal, 3)
		if closed and not explore then self.reach = { set = closed, key = cache.key, at = os.clock() } end
	end
	local mode = type(query.ProbePolicy) == "table" and query.ProbePolicy.Mode or query.ProbePolicy or (query.Explore == false and "Never" or "WhenNecessary")
	if not path and why == "none" and mode ~= "Never" and Capabilities.RuntimeProbe.open(cache.key, probePolicy.Budget) then
		explore = true
		search.Cap = math.min(search.Cap, 600)
		local path2, why2, expanded2 = backend(starts, goals, search, epsilon)
		expanded += expanded2
		if path2 then
			path, why = path2, why2
			for _, t in path do
				if t.Data and t.Data.Affordance and Affordances.trust(t.Data.Affordance, self:execKey(t.Data.Affordance)) < Affordances.Threshold then
					t.Probe = probePolicy
					probing = true
				end
			end
			if probing then Capabilities.RuntimeProbe.spend() end
		end
	end
	return finish(why, path, expanded)
end

-- The one move that joins two free positions directly, if any provider has it; the movement system's
-- answer to "can I just go there", which a clear line of sight is not
function Navigator:DirectTransition(query)
	local world, agent = self.world, query.Agent
	local geo = world.geometry
	geo:params()
	local ctx = { World = world, Agent = agent, Geometry = geo, Providers = agent:Providers() }
	for _, provider in ctx.Providers do
		local kind, time, dist = provider.Between(query.Start, query.Goal, ctx)
		if kind then return Core.transition(Core.state(query.Start), Core.state(query.Goal), kind, time, dist, 0) end
	end
	return nil
end

-- The move the body actually failed earns a lasting refusal; its neighbours, distrusted because they
-- end where it did, earn only a temporary one. A wall is a hint about a place, not proof that every
-- move into it is impassable, and a permanent ban on a neighbour never tried would close ground off
-- for the rest of the map on the strength of one failure somewhere near it.
function Navigator:distrustEdge(from, to, kind, spread)
	local list = self.distrust[from]
	if not list then
		list = {}
		self.distrust[from] = list
	end
	local count = (list[to] and list[to].count or 0) + 1
	local until_
	if kind == "Jump" or spread then
		until_ = os.clock() + math.min(30 * count, 120)
	else
		until_ = count >= 2 and math.huge or os.clock() + 30
	end
	list[to] = { count = count, until_ = until_ }
end

-- Execution feedback of the last kind: the agent died here with nothing visible to blame
function Navigator:ReportLethal(pos)
	self.reach = nil
	return Memory.reportLethal(self.world:Key(), pos)
end

function Navigator:Lethal(pos, within, minCount)
	return Memory.isLethal(self.world:Key(), pos, within, minCount)
end

-- Execution feedback: a failed move is distrusted, a failed walk or jump takes the others of its kind out
-- of the same state that head the same way with it (the wall or ledge that stopped one stops them all),
-- and a transition that worked or failed teaches the memory behind its affordance
function Navigator:Report(transition, outcome, measured)
	local ok = outcome
	if type(outcome) == "table" then
		ok = outcome.Status == "done"
		measured = outcome.Speed and { Speed = outcome.Speed } or nil
	end
	local from, to = transition.From, transition.To
	if not ok and from and to then
		self:distrustEdge(from, to, transition.Kind)
		local aff = transition.Data and transition.Data.Affordance
		local list = aff and self.cache:get(from) or nil
		if list then
			for _, other in list do
				if other.Data and other.Data.Affordance == aff then self:distrustEdge(from, other.To, other.Kind, true) end
			end
		end
		if transition.Kind == "Walk" or transition.Kind == "Jump" or transition.Kind == "Drop" then
			local dir = to.Position - from.Position
			dir = Vector3.new(dir.X, 0, dir.Z)
			local list = dir.Magnitude > 0.01 and self.cache:get(from) or nil
			if list then
				dir = dir.Unit
				for _, other in list do
					local d = other.To.Position - from.Position
					d = Vector3.new(d.X, 0, d.Z)
					if other.Kind == transition.Kind and other.To ~= to and d.Magnitude > 0.01 and d.Unit:Dot(dir) > 0.7 then self:distrustEdge(from, other.To, other.Kind, true) end
				end
			end
			for _, n in self.world:Nearby(from.Position, Steering.Look) do
				local near = self.cache:get(n)
				if near then
					for _, other in near do
						if other.Kind == transition.Kind and (other.To.Position - to.Position).Magnitude < Steering.Look then
							self:distrustEdge(n, other.To, other.Kind, true)
						end
					end
				end
			end
		end
		self.reach = nil
	end
	local aff = transition.Data and transition.Data.Affordance
	if not aff then return nil end
	local exec = self:execKey(aff)
	if ok then
		self.cold[self:coldKey(aff)] = nil
		Memory.report(aff.Key, true)
		return exec and Memory.report(exec, true, measured) or Memory.report(aff.Key, true, measured)
	end
	if type(outcome) == "table" and (outcome.Rise or 1) <= 0.2 and (outcome.Held or 0) >= 1 then
		self.cold[self:coldKey(aff)] = os.clock() + 60
	end
	if type(outcome) == "table" and outcome.Verified then return Memory.behavioral(exec or aff.Key) end
	local scored = Memory.report(exec or aff.Key, false)
	Capabilities.RuntimeProbe.cool(exec or aff.Key)
	return scored
end

return UniversalNav
end)()

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
local AIM_FOV_MAX = 800
local CLAIM_WINDOW = 2.5
local COIN_SWITCH_RATIO = 0.7
local COIN_RETHINK = 0.5
local danger = { near = 40, safe = 60, beenTo = {}, fleeing = false, brainOn = false, friends = {}, badGoals = {}, traps = {}, trapHits = {}, pathLen = math.huge, pathAt = 0, pathFor = nil, routing = false }
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
-- Restored saved values fire callbacks at build time, so only a real flip gets a status line
local function flip(key, on)
	local was = state[key]
	state[key] = on
	return was ~= on
end

local function legitOn(what)
	return state.legit and state.legitFor[what] == true
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

-- Which groups of settings are remembered between sessions; a control in a forgotten group gets no save key
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
-- Round state, all read from the game's own module and workspace
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

-- Friendship is asked once per player and remembered; the option only matters when it is on
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

-- An innocent who picks the gun up becomes the Hero, so both roles are the gun holder
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

-- Cached for three seconds: a map keeps streaming parts in after it appears, so an early box can miss half of it
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

-- Roles arrive about fifteen seconds before the timer starts, and the map is open to walk from the first one
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

-- Survive mode is the whole game plan for anyone without a weapon: flee, take the gun when it drops, shoot, keep farming
function danger.surviving()
	if not state.survive then return false end
	local role = myRole()
	return role == "Innocent" or role == "Hero" or role == "Sheriff"
end

-- Whoever has an auto role on keeps moving between actions: survivors, and hunters with an auto kill armed
function danger.wanting()
	if danger.surviving() then return true end
	local role = myRole()
	if role == "Murderer" then return state.autoKillAll or state.autoKillSheriff end
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

-- A live-round character below the map floor or outside its bounds, not counting the lobby or spectators
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

local function aliveTargets()
	local out = {}
	local root = myRoot()
	if not root then return out end
	local data = roleData()
	for _, who in Players:GetPlayers() do
		if who ~= player and data[who.Name] and not isDead(who) and not danger.friend(who) then
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

local holdUntil = 0
local shownStatus = nil
local gone = false

-- A coin run or auto pass can outlive the window by a frame; a torn-down window takes no status text
local function say(text, icon, colour, holdFor)
	if gone then return end
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

-- The knife goes away a beat after the remotes, so the server still sees it in hand
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

-- Remembers the spots we stood on inside the map; below the map floor with legit off we go back to the
-- last one, and a body that a run wants moving but has not moved half a stud in six seconds is wedged
-- in geometry and steps back to the last spot four studs away, whatever the mode
function danger.fallGuard(now)
	local root, hum = myRoot(), myHumanoid()
	local map = getMap()
	if not root or not hum or not map or hum.Health <= 0 or amDead() then
		danger.safePos = nil
		return
	end
	local box = boundsOf(map)
	local floor = box.cf.Position.Y - box.size.Y / 2
	local wants = coinRun ~= nil and (coinRun.moveDir ~= nil or coinRun.points ~= nil)
	if wants and danger.wedgeAt and (root.Position - danger.wedgeAt).Magnitude < 0.5 then
		if now - danger.wedgeSince > 6 then
			local trail = danger.safeTrail or {}
			for i = #trail, 1, -1 do
				if (trail[i] - root.Position).Magnitude >= 4 then
					danger.wedgeAt, danger.wedgeSince = nil, now
					root.CFrame = CFrame.new(trail[i] + Vector3.new(0, 2, 0)) * root.CFrame.Rotation
					root.AssemblyLinearVelocity = Vector3.zero
					say("Stepped back out of a wedge", "life-buoy", "muted")
					return
				end
			end
		end
	else
		danger.wedgeAt, danger.wedgeSince = root.Position, now
	end
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
local function excludeMe()
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { myChar() }
	return rp
end

-- Aim traces: our own body and the coins never block a shot
local function aimParams()
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	local map = getMap()
	local coins = map and map:FindFirstChild("CoinContainer")
	rp.FilterDescendantsInstances = { myChar(), coins }
	return rp
end

-- Torso, head and both shoulders must all land; one ray slips through doorframes
local function shotIsClear(fromPos, targetPart)
	local body = targetPart.Parent
	if not body then return false end
	local rp = aimParams()
	local centre = targetPart.Position
	local side = centre - fromPos
	side = Vector3.new(-side.Z, 0, side.X)
	if side.Magnitude < 0.01 then return false end
	side = side.Unit * 1.4
	local head = body:FindFirstChild("Head")
	local aims = { centre, head and head.Position or centre + Vector3.new(0, 2, 0), centre + side, centre - side }
	for _, aim in aims do
		local hit = Workspace:Raycast(fromPos, aim - fromPos, rp)
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

-- Re-applied every Heartbeat; anchoring would hold too but stops replicating
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

-- Held a third of a second after landing so the server aims from the new spot, not the old one
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

-- Scores every standable spot with a clear four-ray line outside knife reach
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

-- Every shot the script sends goes through here, because two paths each checking the clock for
-- themselves let the gun fire several times inside one reload: forty shots in ninety seconds were
-- measured that way, most of them into a weapon that was not ready. One owner, one cooldown.
local function fireShot(shoot, originCF, point, name)
	local now = os.clock()
	if now - lastShot < SHOT_GAP then return false end
	lastShot = now
	shoot:FireServer(originCF, CFrame.new(point))
	if name then claimAttack(name, "Gun") end
	return true
end

-- Every candidate point leads him by the round trip plus a replication step, since the server traces
-- against where he is by then; his motion is measured from his positions, never read off a velocity a
-- fling or a ragdoll corrupts. A point is taken when its ray and the two beside it all land, and the
-- ray from our own head lands too, since a muzzle poking past a corner is not a line the server sees
local function clearAim(origin, entry)
	local char = entry.player.Character
	local root = entry.root
	local head = char and char:FindFirstChild("Head")
	if not char or not root then return nil end
	local seen, now = hold.seen[root], os.clock()
	local v = Vector3.zero
	if seen and now - seen.at > 0.04 and now - seen.at < 0.5 then
		v = (root.Position - seen.pos) / (now - seen.at)
		v = Vector3.new(v.X, 0, v.Z)
		if v.Magnitude > 20 then v = v.Unit * (20 + (math.min(v.Magnitude, 60) - 20) * 0.25) end
	end
	if not seen or now - seen.at > 0.04 then hold.seen[root] = { pos = root.Position, at = now } end
	local lead = v * (player:GetNetworkPing() + 0.1)
	local side = root.Position - origin
	side = Vector3.new(-side.Z, 0, side.X)
	side = side.Magnitude > 0.01 and side.Unit * 1.1 or Vector3.zero
	local points = { root.Position + lead, root.Position + lead + Vector3.new(0, 1.3, 0), root.Position + lead + side, root.Position + lead - side }
	if head then table.insert(points, 2, head.Position + lead) end
	local rp = aimParams()
	local blocker
	local function lands(from, ray)
		local hit = Workspace:Raycast(from, ray * 1.5, rp)
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

-- Fires only from where we stand; nothing here moves the player
local function shootFromHere(entry)
	local shoot, aim, origin = readyGun(entry)
	if not shoot then return false, aim end
	return fire(shoot, entry, origin, aim)
end

-- Fires from here when the line is clear, otherwise steps to a spot that has one
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
		return false, why
	end
	task.delay(0.15, releaseHold)
	return true
end

local sniper = { busy = false, blockedSince = nil, close = 22, hold = 34, far = 80, reach = 45, label = nil, labelAt = 0, noPath = {} }

-- Runs every frame as the sheriff: fires the instant the trace is clear, steps into view when it is not
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
				sniper.busy = false
			end)
		end
		return
	end

	sniper.blockedSince = sniper.blockedSince or now
	if (sniper.noPath[target.player] or 0) > now then return end
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

-- A knife may hit anyone; a gun only the murderer, since shooting an innocent kills the sheriff
local function legalTargets()
	local list = aliveTargets()
	if findTool("Knife") then return list end
	local out = {}
	for _, e in list do
		if e.role == "Murderer" then table.insert(out, e) end
	end
	return out
end

local fovGui, fovRing = nil, nil

------------------------------------------------------------------------------------------ Silent aim
local function fovWanted()
	return state.silentAim and state.showFov and not state.aimInfinite
end

local function clearCircle()
	if fovGui then
		fovGui:Destroy()
		fovGui, fovRing = nil, nil
	end
end

-- A GUI ring instead of a Drawing so it sits under the hub window, which draws at order 999
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

-- Only legal targets: a sheriff whose shot is bent onto an innocent dies for it
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

-- One namecall hook for the whole session; each load points it at its own state so reloads never stack layers
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
					return old(self, unpack(args))
				end
			end
		end
		return old(self, ...)
	end)
end

--------------------------------------------------------------------------------------------- Pickups
-- The dropped gun is a GunDrop-tagged part with a TouchInterest; touching it is the pickup
local function droppedGuns()
	local out = {}
	for _, gun in CollectionService:GetTagged("GunDrop") do
		if gun:IsA("BasePart") and gun:IsDescendantOf(Workspace) then
			table.insert(out, gun)
		end
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
-- The murderer we keep away from: none while we hold a weapon, and before the round timer starts
-- he has no knife yet, so he only counts inside 25 studs then, and for 4 s after he was that close
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
		local him = findByRole("Murderer")
		local part = him and him ~= player and not isDead(him) and hitPartOf(him)
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

-- The murderer's root whether or not he counts as a threat yet, for choosing where to go
function danger.shadow()
	local who = findByRole("Murderer")
	if not who or who == player or isDead(who) or danger.offMap(who) then return nil end
	return hitPartOf(who)
end

-- Walking distance between two points for the murderer's agent; huge when there is no route
function danger.walkLength(from, to)
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 4.5,
		AgentCanJump = true,
		AgentCanClimb = true,
		AgentMaxSlope = 60,
		WaypointSpacing = 6,
	})
	local ok = pcall(path.ComputeAsync, path, from, to)
	if not ok or path.Status ~= Enum.PathStatus.Success then return math.huge end
	local len = 0
	local pts = path:GetWaypoints()
	for i = 2, #pts do len += (pts[i].Position - pts[i - 1].Position).Magnitude end
	return len
end

-- Effective gap: for our own position it is the murderer's route length; for other points a floor-aware estimate
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
			local rp = RaycastParams.new()
			rp.FilterType = Enum.RaycastFilterType.Exclude
			rp.FilterDescendantsInstances = { myChar(), threat.Parent }
			if not Workspace:Raycast(threat.Position, from + Vector3.new(0, 1, 0) - threat.Position, rp) then
				gap = math.min(gap, flat)
			end
		end
		return gap
	end
	if dy < 6 then return flat end
	if threat.Position.Y > from.Y - 2 and dy < 40 then return flat + dy * 0.5 end
	local gap = flat + dy * 3
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { myChar(), threat.Parent }
	if Workspace:Raycast(threat.Position, -delta, rp) then gap += 40 end
	return gap
end

-- Where he is going: his flat velocity while he moves, the way he faces while he stands
function danger.heading(threat)
	local v = threat.AssemblyLinearVelocity
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude > 4 then return flat.Unit, math.min(flat.Magnitude, 20) end
	local look = threat.CFrame.LookVector
	look = Vector3.new(look.X, 0, look.Z)
	return look.Magnitude > 0.1 and look.Unit or nil, 0
end

-- Where he will be a moment and a half from now if he keeps going
function danger.ahead(threat)
	local heading, speed = danger.heading(threat)
	return heading and threat.Position + heading * speed * 1.5 or threat.Position
end

-- A route he cannot cut: no point of it inside knife reach of him, and none he can beat us to
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

-- How close the murderer sits to the straight run from here to there, flat
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

-- Near enough to be stabbed or thrown at, whatever the route says: on our level and inside the given straight-line distance
function danger.closeBy(from, threat, within)
	local flat = Vector3.new(threat.Position.X - from.X, 0, threat.Position.Z - from.Z).Magnitude
	local dy = math.abs(threat.Position.Y - from.Y)
	local above = threat.Position.Y > from.Y - 2 and dy < 40
	return flat < within and (dy < 10 or above or (dy < 20 and flat < within * 0.5))
end

local function nearestCoin(from, now)
	local best, bestDist, bestScore
	local threat = danger.root()
	local parts = coinParts()
	local minGap = danger.safe
	local ourGap = threat and danger.gap(from, threat) or math.huge
	local toThreat = threat and Vector3.new(threat.Position.X - from.X, 0, threat.Position.Z - from.Z) or Vector3.zero
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
				local toCoin = Vector3.new(part.Position.X - from.X, 0, part.Position.Z - from.Z)
				local towardThem = toCoin.Magnitude > 1 and toThreat.Magnitude > 0.01 and toCoin.Unit:Dot(toThreat.Unit) > 0.5 and gap < math.max(ourGap, 50)
				local ahead = danger.ahead(threat)
				local inHisWay = math.abs(threat.Position.Y - part.Position.Y) < 8 and Vector3.new(ahead.X - part.Position.X, 0, ahead.Z - part.Position.Z).Magnitude < 40
				if gap < minGap or towardThem or inHisWay or danger.pathGap(from, part.Position, threat) < 26 then
					score = nil
				elseif gap < 60 then
					score += (60 - gap) * 2
				end
			end
			if score and (not bestScore or score < bestScore) then best, bestDist, bestScore = part, d, score end
		end
	end
	return best, bestDist
end

-- Coins first holds the role actions while the bag has room and a coin is reachable, unless the murderer is
-- already close, or we hold the weapon and a target stands within its reach
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
	local who = findByRole("Murderer")
	local threat = who and who ~= player and not isDead(who) and hitPartOf(who)
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

-- One gate every mover consults. A loop that was already part-way through an iteration when the switch
-- went off still finishes that pass, and a pass ends in a move; that is the third of a second of drift
-- you get from clearing flags alone. While this is held, nothing writes a heading at all, so the body
-- stops on the frame the switch moves rather than on the frame the last loop happens to notice.
-- Refuse every heading for a short window, long enough for any loop already running to finish its pass
-- and see its own cleared flag. Turning a feature back on lifts it at once, so this never delays a start.
-- Kept on the danger table rather than as file locals: this file is at the Luau 200-local ceiling.
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

-- Turning a feature off has to stop the body in the same frame the switch moves. Clearing the run's
-- active flag only asks the loop to notice, and a loop mid-leg or mid-wait notices seconds later, which
-- is the drift you see after untoggling. So the run is cut here: its stepped driver is disconnected so
-- nothing can write a heading after this point, the walk is cancelled, and the body is braked. The loop
-- still exits on its own flag; this makes the stopping immediate rather than eventual.
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

-- Ending a run to start another one is a handover, not a stop: braking the body to zero and letting
-- the next walker accelerate it again is the pause you see between one plan and the next, so the
-- momentum is left alone unless the character is genuinely being put down.
local function finishRun(keepMoving)
	local run = coinRun
	coinRun = nil
	if run and run.stepConn then run.stepConn:Disconnect() end
	if not keepMoving then halt() end
	restoreMovement(keepMoving)
end

local lastHop = 0

local function jumpNow()
	local now = os.clock()
	if now - lastHop < 0.6 then return end
	local hum = myHumanoid()
	if not hum then return end
	local st = hum:GetState()
	if st == Enum.HumanoidStateType.Freefall or st == Enum.HumanoidStateType.Jumping then return end
	lastHop = now
	hum:ChangeState(Enum.HumanoidStateType.Jumping)
end

local function routeTo(from, to)
	local path = PathfindingService:CreatePath({
		AgentRadius = 2.2,
		AgentHeight = 4.5,
		AgentCanJump = true,
		AgentCanClimb = true,
		AgentMaxSlope = 60,
		WaypointSpacing = 4,
	})
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
			jumpNow()
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

-- A stall gets one hop for a lip; a second stall on the same leg replans around the wedge
local function unstick(fix, hum)
	fix.level += 1
	if fix.level > 1 then return "replan" end
	jumpNow()
	return true
end

-- Without a route we only go straight when nothing solid sits between us and the goal
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

-- The point to run from: the murderer himself when he can see us, else the doorway his route brings him through
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
				jumpNow()
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
			local flat = Vector3.new(target.X - here.X, 0, target.Z - here.Z).Magnitude
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
					flat = Vector3.new(target.X - here.X, 0, target.Z - here.Z).Magnitude
					dy = target.Y - here.Y
					bestFlat, bestAt = flat, now
				end
			end
			local goal = target
			if final and flat < math.max(3, step) and dy < 1.5 and dy > -7 then
				closing = closing or now
				if run.moveDir then
					goal = here + run.moveDir * 6
					if Vector3.new(target.X - here.X, 0, target.Z - here.Z):Dot(run.moveDir) < 0 then break end
				end
				if now - closing > 0.4 then break end
			end
			local climb = climbLeg and dy > 2
			if flat > 3 and not climb then
				local ahead = Vector3.new(goal.X - here.X, 0, goal.Z - here.Z)
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
					if hop and fix.stalled > 0.15 and hum.FloorMaterial ~= Enum.Material.Air then
						jumpNow()
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

			local flatNow = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z).Magnitude
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

-- Walks a leg with a watcher attached, and drops the watcher even when the leg throws
function danger.leg(run, legs, hum, watch)
	local ok, outcome = pcall(travel, run, legs, hum)
	if watch then watch:Disconnect() end
	if not ok then error(outcome, 0) end
	return outcome
end

-- The map as a UniversalNav surface lattice, our humanoid as its agent, and routes as legs the walker understands
local nav = { ready = false, count = 0, map = nil, calls = 0, used = 0, stats = {}, world = nil, navigator = nil, agent = nil }

------------------------------------------------------------------------------------------ Navigation
function nav.reset()
	if nav.world then nav.world:Abort() end
	nav.world, nav.navigator, nav.map, nav.ready, nav.count = nil, nil, nil, false, 0
end

-- Bodies are never geometry: live characters, and the corpses and ragdolls the round leaves lying about
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

-- The flat speed the running walker actually uses and the jump it makes, so planned arcs match the real ones
function nav.speed()
	return math.clamp(coinRun and coinRun.speed or state.coinSpeed, 16, 25)
end

function nav.jumpV()
	local hum = myHumanoid()
	if not hum then return 50 end
	if hum.UseJumpPower then return hum.JumpPower end
	return math.sqrt(2 * Workspace.Gravity * hum.JumpHeight)
end

-- The lattice is shaped by the agent that will walk it: its body sets headroom and lift, its jump sets reach
function nav.build(map)
	nav.reset()
	nav.map = map
	local agent = UniversalNav.Roblox.HumanoidAdapter.new({ Humanoid = myHumanoid, Speed = nav.speed, JumpVelocity = nav.jumpV })
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
	if ok then task.spawn(nav.warm, world) end
end

-- While this map stands, the ground around us is generated ahead of any route, a small slice per frame
function nav.warm(world)
	nav.warmed = 0
	while nav.world == world and nav.ready do
		local root = myRoot()
		local from = root and not inLobby() and root.Position
		if not from then
			local spawns = nav.map and nav.map:FindFirstChild("Spawns")
			local spawn = spawns and spawns:FindFirstChildWhichIsA("BasePart")
			from = spawn and spawn.Position
		end
		if from then
			nav.warmed += nav.navigator:Warm({ Agent = nav.agent, Position = from, Nodes = 200, Budget = 0.002, Active = function() return nav.world == world end })
		end
		task.wait(0.5)
	end
end

-- A leg the world model offered and the body could not do is reported back once, with the executor's
-- outcome when there is one, so the next route avoids it instead of the spot being treated as a trap
function danger.legFailed(run, wp, outcome, why)
	if not (nav.ready and nav.navigator and type(wp) == "table" and wp.Transition) then return false end
	nav.navigator:Report(wp.Transition, outcome or false)
	local at = wp.Position
	run.learned = string.format("%s %s at (%.0f,%.0f,%.0f)", wp.Transition.Kind, why or "failed", at.X, at.Y, at.Z)
	return true
end

-- A climb that worked teaches the movement system how fast this kind of surface climbs
function danger.legDone(wp, outcome)
	if nav.ready and nav.navigator and type(wp) == "table" and wp.Transition then nav.navigator:Report(wp.Transition, outcome) end
end

-- The agent's node height above the floor, for the executors that land on nodes
function danger.lift()
	return nav.agent:Lift()
end

-- Whether the body can walk straight from here to a route point, by the movement system's own rule
function danger.straight(here, floorPoint)
	if not nav.ready then return false end
	local lift = nav.agent:Lift()
	local ctx = { Agent = nav.agent, Geometry = nav.world.geometry, World = nav.world }
	return UniversalNav.Traversal.Ground.Between(here - Vector3.new(0, 3 - lift, 0), floorPoint + Vector3.new(0, lift, 0), ctx) ~= nil
end

-- Whether the body fits along a heading for a given distance, by the movement system's own body sweep
function danger.roomAhead(from, dir, want)
	if not nav.ready then return true end
	local lift = nav.agent:Lift()
	local ctx = { Agent = nav.agent, Geometry = nav.world.geometry, World = nav.world }
	return UniversalNav.Steering.Room(from - Vector3.new(0, 3 - lift, 0), dir, ctx, want + 1) >= want
end

-- The nearest heading with real room, found by sweeping outward from the one we wanted. Returns nil when
-- the body is boxed in on every side, which the caller answers by not driving into anything at all.
function danger.bendAround(from, dir, memo)
	if not nav.ready then return nil end
	local lift = nav.agent:Lift()
	local ctx = { Agent = nav.agent, Geometry = nav.world.geometry, World = nav.world }
	local bent = UniversalNav.Steering.Heading(from - Vector3.new(0, 3 - lift, 0), dir, ctx, memo)
	if not bent or bent == dir then return nil end
	return bent
end

-- Send a heading now, bending it around anything in the way. Every place that decides on a direction
-- while no leg is being walked must call this: storing run.moveDir sets intent, it does not move the
-- body, and a stored heading nothing sends is exactly a body standing still with a plan.
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
	if not nav.ready then return dir, false, false end
	local lift = nav.agent:Lift()
	local from = root.Position - Vector3.new(0, 3 - lift, 0)
	local ctx = { Agent = nav.agent, Geometry = nav.world.geometry, World = nav.world }
	fix.memo = fix.memo or {}
	local bent, room, blocker = UniversalNav.Steering.Heading(from, dir, ctx, fix.memo)
	if bent == dir then return dir, false, false end
	fix.wallHit = blocker
	local knee = Workspace:Raycast(root.Position + Vector3.new(0, -2, 0), dir * 3, excludeMe())
	local chest = Workspace:Raycast(root.Position + Vector3.new(0, 1, 0), dir * 3, excludeMe())
	if knee and not chest then return dir, true, false end
	if bent then return bent, false, true end
	return nil, false, true
end

-- What no query routes through: a cell we were wedged in twice lately
function nav.blocked(s)
	return (danger.traps[danger.goalKey(s.Position)] or 0) > os.clock()
end

function danger.lethal(pos, within)
	return nav.navigator ~= nil and nav.navigator:Lethal(pos, within, 1)
end

-- What a query pays beyond time: the risk of a lip, a second and a half for a jump while he is near (a
-- stall waiting to happen), and four seconds for every step on his side of the map within 30 of him,
-- so routes keep off his ground unless there is no other way and the goal itself is never walled off
function nav.costFor(him, me, careful)
	return {
		Of = function(t)
			local cost = t.Time + t.Risk * 3
			if careful and t.Kind == "Jump" then cost += 1.5 end
			if him then
				local p = t.To.Position
				if math.abs(p.Y - him.Y) < 10 then
					local his = Vector3.new(p.X - him.X, 0, p.Z - him.Z).Magnitude
					if his < 30 and his < Vector3.new(p.X - me.X, 0, p.Z - me.Z).Magnitude then cost += 4 end
				end
			end
			return cost
		end,
		Heuristic = UniversalNav.Cost.Fastest.Heuristic,
	}
end

-- How much floor lies around a point on its level: a hall counts high, a dead-end corner low
function nav.openness(pos)
	if not nav.ready then return 0 end
	local count = 0
	for _, n in nav.world:Nearby(pos, 24) do
		if math.abs(n.Position.Y - pos.Y) <= 6 then count += 1 end
	end
	return count
end

-- A route as waypoints; each leg keeps its transition so climbs run through the climb executor.
-- An unproven surface may be tried only when nothing known reaches the goal and no murderer is within
-- reach; cheap queries, whose answer is advisory, never try one
function nav.route(from, goal, cheap)
	if not nav.ready then return nil end
	nav.calls += 1
	local who = findByRole("Murderer")
	local foe = who and who ~= player and not isDead(who) and hitPartOf(who) or nil
	local gap = foe and danger.gap(from, foe) or math.huge
	local policies = UniversalNav.ProbePolicies
	local policy = (cheap or gap < 90 or danger.pursuing) and policies.Never or policies.Conservative
	local search = cheap and { MaxExpansions = 400, TimeSlice = 0.002 } or gap < 60 and { MaxExpansions = 2500, TimeSlice = 0.008 } or { MaxExpansions = 6000, TimeSlice = 0.005 }
	local him = (not cheap and foe and danger.root() ~= nil) and foe.Position or nil
	local result = nav.navigator:FindPath({ Agent = nav.agent, Start = from, Goal = goal, Blocked = nav.blocked, SearchPolicy = search, ProbePolicy = policy, Cost = nav.costFor(him, from, gap < 90) })
	local st = result.Stats
	nav.stats = { why = result.Why, expanded = st.Expanded, ms = st.Ms, legs = result.Path and #result.Path or 0, jumps = 0, req = st.Requests, hits = st.Hits, rays = st.Rays, casts = st.Casts, probing = result.Probing }
	nav.lastTime = result.Time
	if not result.Path then return nil end
	local legs = {}
	for _, t in result.Path do
		if t.Kind == "Jump" then nav.stats.jumps += 1 end
		local to = t.To
		table.insert(legs, { Position = to.Lattice and to.Floor or to.Position, Action = t.Kind == "Jump" and Enum.PathWaypointAction.Jump or Enum.PathWaypointAction.Walk, Label = t.Kind == "Climb" and "Climb" or "", Transition = t })
	end
	return legs
end

-- The murderer's walking route to us, refreshed in the background: the navmesh's route, else the lattice's
function danger.route(threat)
	local root = myRoot()
	if not root then return end
	danger.routing = true
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 4.5,
		AgentCanJump = true,
		AgentCanClimb = true,
		AgentMaxSlope = 60,
		WaypointSpacing = 6,
	})
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

-- The way to a goal, decided by the movement system: one direct move when a provider has it; otherwise
-- the Roblox navmesh route and the lattice route compete on the seconds they take. A navmesh route is
-- out when it crosses a trap or ends in a climb the walker cannot make, and never asked from inside a trap.
local function legsTo(from, goal, ignore)
	local finalLeg = { Position = goal, Action = Enum.PathWaypointAction.Walk, Label = "" }
	local direct = nav.ready and nav.navigator:DirectTransition({ Agent = nav.agent, Start = from, Goal = goal })
	if direct then
		return { {
			Position = goal,
			Action = direct.Kind == "Jump" and Enum.PathWaypointAction.Jump or Enum.PathWaypointAction.Walk,
			Label = direct.Kind == "Climb" and "Climb" or "",
			Transition = direct,
		} }
	end
	if not nav.ready and lineIsClear(from, goal, ignore) then return { finalLeg } end
	local best, bestTime = nil, math.huge
	if state.coinPath and (danger.traps[danger.goalKey(from)] or 0) < os.clock() then
		local rp = excludeMe()
		if ignore then rp.FilterDescendantsInstances = { myChar(), ignore } end
		local floor = Workspace:Raycast(goal, Vector3.new(0, -12, 0), rp)
		local legs = routeTo(from, floor and floor.Position or goal)
		if legs and not danger.throughTrap(legs) then
			local climbs, length, prev = false, 0, from
			for _, wp in legs do
				if wp.Label == "Climb" then climbs = true end
				length += (wp.Position - prev).Magnitude
				prev = wp.Position
			end
			if not climbs then
				table.insert(legs, finalLeg)
				best, bestTime = legs, length / nav.speed()
			end
		end
	end
	local legs = nav.route(from, goal)
	if legs and nav.lastTime < bestTime then
		nav.used += 1
		best = legs
	end
	return best
end

local function newRun(target, valid, kind)
	local run = { active = true, kind = kind, target = target, targetDist = math.huge, retarget = false, trail = {}, moveDir = nil, valid = valid }
	run.stepConn = RunService.RenderStepped:Connect(function()
		if run.active and coinRun == run and run.moveDir and danger.canMove() then player:Move(run.moveDir, false) end
	end)
	coinRun = run
	return run
end

------------------------------------------------------------------------------------------- Coin runs
local function coinLoop(run)
	local hum = borrowMovement()
	if not hum then return "no character" end
	local lastCheck = 0

	while run.active do
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
				danger.push(run, root, danger.openDir(root, danger.root()) or run.moveDir or root.CFrame.LookVector)
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

-- The pickup is the touch. With legit walking off it is fired the instant a gun is seen, before any other
-- consideration, since it costs nothing; only the walk that follows a refused touch weighs the murderer.
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
			stopCoinRun()
			while coinRun do RunService.Heartbeat:Wait() end
			run = newRun(gun, gunStillThere, "gun")
			run.targetDist = dist
			local hum = borrowMovement()
			if not hum then return end
			local from = myRoot()
			if not from then return end
			local legs = legsTo(from.Position, gun.Position)
			if not legs then return end
			local watch = RunService.Heartbeat:Connect(function()
				local r, t = myRoot(), danger.root()
				if not r or not t then return end
				if danger.gap(r.Position, t) < 40 or danger.pathGap(r.Position, gun.Position, t) < 25 then run.active = false end
			end)
			local outcome = danger.leg(run, legs, hum, watch)
			run.moveDir = nil
			grab.cut = outcome == "stopped"
			if outcome == "arrived" and gunStillThere(gun) then touchGun(gun) end
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

-- Legs toward a player: to them, else to floor points part of the way, so a target in a room we
-- cannot enter still draws us to its door
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

-- The chase is only taken up once a route exists; a target with none is remembered so the errand at hand goes on
local function pursue(who, reach)
	local function alive()
		return hitPartOf(who) ~= nil and not isDead(who)
	end
	local root0, target0 = myRoot(), hitPartOf(who)
	if not root0 or not target0 then return false end
	if (target0.Position - root0.Position).Magnitude > reach and not sniper.legsToward(root0, who, target0) then
		sniper.noPath[who] = os.clock() + 4
		return false
	end
	danger.pursuing = true
	stopCoinRun()
	while coinRun do RunService.Heartbeat:Wait() end
	local run = newRun(who, alive, "pursuit")
	run.weave = who == gunHolder()
	local hum = borrowMovement()
	if not hum then
		finishRun()
		return false
	end
	local reached = false
	local okLoop, errLoop = pcall(function()
	for _ = 1, 24 do
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
			sniper.noPath[who] = os.clock() + 4
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
-- The freest direction around us that does not lead at him: the only heading ever taken without a route
function danger.openDir(root, threat)
	local here = root.Position
	local rp = excludeMe()
	if threat and threat.Parent then rp.FilterDescendantsInstances = { myChar(), threat.Parent } end
	rp.RespectCanCollide = true
	local toThem = threat and Vector3.new(threat.Position.X - here.X, 0, threat.Position.Z - here.Z)
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

-- Cornered: the open direction with the most floor before a wall, and a dash past the murderer when the room is behind them
function danger.breakout(root, threat)
	local here = root.Position
	local from = danger.threatFrom(here, threat)
	local away = Vector3.new(here.X - from.X, 0, here.Z - from.Z)
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

-- A death with a live murderer far away is the map's doing: the movement system remembers the spot for this world
function danger.hazard(pos)
	if not nav.navigator then return end
	local who = findByRole("Murderer")
	local part = who and who ~= player and not isDead(who) and hitPartOf(who)
	if not part or (part.Position - pos).Magnitude < 60 then return end
	nav.navigator:ReportLethal(pos)
end

-- Wedged twice within 10 studs inside 20 s makes both spots traps for half a minute
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

-- A route is poisoned when any waypoint sits in a cell we recently got wedged in
function danger.throughTrap(legs)
	local now = os.clock()
	for _, wp in legs do
		if (danger.traps[danger.goalKey(wp.Position)] or 0) > now then return true end
	end
	return false
end

-- The way back out of a wedge: the newest trail point far enough away and outside every trap cell
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

-- Where to run: a place the movement system can actually reach that he cannot cut us off from. Every
-- candidate is a node a route exists to, scored on the ground it puts between us once we are there,
-- how much of the run he wins the race to, and whether it leads across his heading. The chosen goal
-- is kept for six seconds so the run commits to it instead of picking a new ten-stud dash every leg.
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
		Nodes = 700,
		Blocked = nav.blocked,
		Score = function(state)
			local p = state.Position
			if (danger.badGoals[danger.goalKey(p)] or 0) > now then return nil end
			if danger.lethal(p, 12) then return nil end
			local run = (p - here).Magnitude
			if run < 10 then return nil end
			local his = danger.gap(p, threat)
			local score = math.min(his, 120) + math.min(run, 80) * 0.8
			if his < math.max(mine, danger.safe) then score -= 60 end
			if his / 18 < run / math.max(state.coinSpeed or 22, 16) + 0.5 then score -= 80 end
			local hisWay = Vector3.new(p.X - threat.Position.X, 0, p.Z - threat.Position.Z)
			if heading and hisWay.Magnitude > 1 then score -= 40 * math.max(0, heading:Dot(hisWay.Unit)) end
			local worst = best[#best]
			if #best < 8 or score > worst.score then
				table.insert(best, { at = state.Lattice and state.Floor or p, score = score })
				table.sort(best, function(a, b) return a.score > b.score end)
				if #best > 8 then table.remove(best) end
			end
			return score
		end,
	})
	for _, entry in best do
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

-- Avoid mode without Survive: a short retreat run that ends once the gap is safe again
function danger.flee(threat)
	danger.fleeing = true
	stopCoinRun()
	while coinRun do RunService.Heartbeat:Wait() end
	local run = newRun(threat, function(t) return t.Parent ~= nil end, "flee")
	run.speed = 25
	local hum = borrowMovement()
	if hum then
		for _ = 1, 12 do
			local root = myRoot()
			if not run.active or not root or not threat.Parent then break end
			if danger.gap(root.Position, threat) > danger.safe then break end
			local legs, legsGoal = danger.fleeLegs(root, threat)
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

-- Solid floor under a point near our own height; invisible shells like the map's glitch-proof roof are skipped
function danger.floorAt(x, y, z)
	local ignore = {}
	for _, who in Players:GetPlayers() do
		if who.Character then table.insert(ignore, who.Character) end
	end
	for _ = 1, 4 do
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.FilterDescendantsInstances = ignore
		local hit = Workspace:Raycast(Vector3.new(x, y, z), Vector3.new(0, -45, 0), rp)
		if not hit then return nil end
		if hit.Instance.Transparency < 0.99 and hit.Instance.CanCollide then return hit.Position end
		table.insert(ignore, hit.Instance)
	end
	return nil
end

-- A far-side goal with a route: random among the clean ones, else the one farthest from the murderer, else anywhere near
function danger.roamLegs(root, threatRoot)
	local map = getMap()
	if not (map and nav.ready) then return nil end
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
			Nodes = 900,
			Budget = 0.004,
			Blocked = nav.blocked,
			Score = function(state)
				local p = state.Position
				local run = Vector3.new(p.X - here.X, 0, p.Z - here.Z).Magnitude
				if run < 25 or run > 250 then return nil end
				if (danger.badGoals[danger.goalKey(p)] or 0) > now then return nil end
				if danger.lethal(p, 12) then return nil end
				for i, was in danger.beenTo do
					local near = avoid and 25 or (i > #danger.beenTo - 2 and 15 or 0)
					if near > 0 and (p - was).Magnitude < near then return nil end
				end
				local score = math.min(run, 120) * 0.4
				if threatRoot then
					local his = (p - threatRoot.Position).Magnitude
					if his < math.min(math.max(mine - 10, danger.near), danger.safe) then return nil end
					if ahead and (p - ahead).Magnitude < 40 then return nil end
					score += math.min(his, 150) * 0.6
				end
				local worst = best[#best]
				if #best < 8 or score > worst.score then
					table.insert(best, { at = state.Lattice and state.Floor or p, score = score })
					table.sort(best, function(a, b) return a.score > b.score end)
					if #best > 8 then table.remove(best) end
				end
				return score
			end,
		})
		return best
	end
	local tries = shortlist(true)
	if #tries == 0 then tries = shortlist(false) end
	for _, entry in tries do
		local at = entry.at
		local seen = threatRoot and (at - threatRoot.Position).Magnitude < 90
			and not Workspace:Raycast(threatRoot.Position, at + Vector3.new(0, 1, 0) - threatRoot.Position, eyes)
		local legs = not seen and legsTo(here, at + Vector3.new(0, 2, 0))
		if legs and (not threatRoot or danger.routeSafe(legs, here, threatRoot)) then
			local been = danger.beenTo
			table.insert(been, at)
			if #been > 8 then table.remove(been, 1) end
			return legs, at + Vector3.new(0, 2, 0)
		end
		danger.badGoals[danger.goalKey(at)] = now + 1.5
	end
	return nil
end

-- Somewhere far from him that the walker can carry on from. A downward ray finds any surface at all --
-- a roof, a prop outside the walls, terrain under the floor -- and landing on one of those is how you
-- end up off the map with nothing to route from. So candidates are taken from the navigation lattice
-- instead: a node exists only where the body fits and stands, and it is already joined to its
-- neighbours, which is what makes the run resume normally rather than strand him.
function danger.farSpot(root, threat)
	local map = getMap()
	if not map or not nav.ready or not nav.world then return nil end
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

-- Inside the map's own footprint, with margin, so a node on some outlying prop is not chosen
function danger.inBounds(at, box)
	local c, half = box.cf.Position, box.size / 2
	return math.abs(at.X - c.X) <= half.X - 4
		and math.abs(at.Z - c.Z) <= half.Z - 4
		and at.Y >= c.Y - half.Y and at.Y <= c.Y + half.Y
end

-- No route from here: the lowest standable ledge within a jump that a roam route continues from
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
-- Survive planner: one loop picks flee, coin or roam for each leg from the same facts, and never halts in between
function danger.brain()
	danger.brainOn = true
	local map = getMap()
	if not map or not myRoot() then
		danger.brainOn = false
		return
	end
	stopCoinRun()
	while coinRun do RunService.Heartbeat:Wait() end
	local run = newRun(nil, function() return true end, "survive")
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
				local out = Vector3.new(root.Position.X - from.X, 0, root.Position.Z - from.Z)
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
					sniper.noPath[hunt.player] = now + 4
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

-- Hack versus hack: a cheater under or outside the map is reached by teleport, hit, and left behind again
function sniper.hvh(now)
	if not state.hvh or sniper.busy or now - (sniper.hvhAt or 0) < 1 then return end
	local knife, gun = findTool("Knife"), findTool("Gun")
	if not knife and not gun then return end
	for _, e in aliveTargets() do
		if danger.offMap(e.player) and (knife or e.role == "Murderer") then
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

-- Lobby vote: three pads with a map label each; standing inside a pad's detector is the vote
local vote = { stale = true, known = { "Bank2", "Factory", "Hotel", "House2", "Mansion2", "MilBase", "PoliceStation", "ResearchFacility", "Workplace" }, walking = false, hooks = {}, pick = nil }

-- Everything that can be walking the body, stopped in this frame. Each walker owns a flag its own loop
-- watches, so clearing the flags ends them; cutting the run first means nothing writes another heading
-- in the meantime. Used when a switch goes off, where "it will stop shortly" is the bug being fixed.
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
-- "Bank2" on the map and "BANK" on the pad are the same place
function vote.same(a, b)
	local function fold(t)
		return (tostring(t):lower():gsub("[%s%d_%-]", ""))
	end
	local x, y = fold(a), fold(b)
	return x == y or (x ~= "" and y ~= "" and (x:find(y, 1, true) or y:find(x, 1, true)) ~= nil)
end

-- The pad models carry the live labels; the icon boards above them are placeholders. The vote is open during intermission.
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
	stopCoinRun()
	while coinRun do RunService.Heartbeat:Wait() end
	local run = newRun(det, function(d) return d.Parent ~= nil end, "vote")
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

-- Standing inside a pad is a vote for it, so a pad that is not a favourite is stepped off
function vote.stepOff(board)
	local root = myRoot()
	if not root then return end
	for _, entry in board do
		local det = entry.detector
		local flat = Vector3.new(det.Position.X - root.Position.X, 0, det.Position.Z - root.Position.Z)
		if flat.Magnitude < 4.5 then
			vote.walking = true
			stopCoinRun()
			while coinRun do RunService.Heartbeat:Wait() end
			local run = newRun(det, function(d) return d.Parent ~= nil end, "vote")
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

-- Runs whenever the board changes: learns the names, then walks to the favourite if it is up.
-- The board shows last round's maps for the first seconds of intermission; it counts once its labels refresh.
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
-- Legit mode: nothing teleports and nothing reaches through walls; the walker closes the distance first
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

-- One movement decision is held for half a second, so the duel commits to a strafe instead of twitching
function sniper.steer(run, hum, goal, label)
	sniper.status(label)
	local until_, still, last = os.clock() + 0.5, 0, nil
	while run.active do
		local root = myRoot()
		if not root then return end
		if Vector3.new(goal.X - root.Position.X, 0, goal.Z - root.Position.Z).Magnitude < 1.5 then return end
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

-- The way out that gains the most ground while keeping a line on them; a wall in that direction rules it out
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

-- Steps back to a checked spot; with nowhere to step, stands for the frame instead of pushing a wall
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

-- Nearest spot with a clear trace, the side we last strafed to first, never inside knife range; the wide ring looks past corners
function sniper.strafeSpot(here, toward, entry, gunOff, who, scale)
	local side = Vector3.new(-toward.Z, 0, toward.X) * (sniper.side or 1)
	local them = entry.root.Position
	local hereFloor = danger.floorAt(here.X, here.Y + 2, here.Z)
	for _, off in { { 4, 0 }, { -4, 0 }, { 0, -5 }, { 8, 0 }, { -8, 0 }, { 6, -5 }, { -6, -5 }, { 6, 5 }, { -6, 5 }, { 12, 0 }, { -12, 0 }, { 10, -5 }, { -10, -5 }, { 10, 5 }, { -10, 5 }, { 16, 0 }, { -16, 0 }, { 16, -8 }, { -16, -8 }, { 16, 8 }, { -16, 8 } } do
		local spot = here + side * (off[1] * scale) + toward * (off[2] * scale)
		if Vector3.new(them.X - spot.X, 0, them.Z - spot.Z).Magnitude >= sniper.close and spotIsStandable(spot) then
			local floor = danger.floorAt(spot.X, spot.Y + 2, spot.Z)
			if floor and hereFloor and math.abs(floor.Y - hereFloor.Y) < 4 and lineIsClear(here, spot, who.Character) and clearAim(spot + gunOff, entry) then
				if off[1] < 0 then sniper.side = -(sniper.side or 1) end
				return spot
			end
		end
	end
	return nil
end

-- Approach by route; two legs in a row that moved the body under 3 studs report the first move as failed,
-- so a rim the walk cannot reach is unlearned instead of pushed at every 1.5 s
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
			sniper.noPath[who] = os.clock() + 4
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
		local flat = Vector3.new(t.Position.X - r.Position.X, 0, t.Position.Z - r.Position.Z).Magnitude
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
			if not danger.legFailed(run, legs[1], nil, "crawl") then sniper.noPath[who] = os.clock() + 4 end
		end
	else
		sniper.crawls = 0
	end
end

-- A spot with a line on him from beyond knife reach: the nearest lattice point within 60 whose aim ray
-- lands, so a standoff around a corner ends by going where the corner is not; asked once a second
function sniper.vantage(here, entry, gunOff)
	local now = os.clock()
	if not nav.ready or now - (sniper.vantageAt or 0) < 1 then return nil end
	sniper.vantageAt = now
	local them = entry.root.Position
	local near = nav.world:Nearby(here, 60)
	table.sort(near, function(a, b) return (a.Position - here).Magnitude < (b.Position - here).Magnitude end)
	local tested = 0
	for _, n in near do
		local p = n.Position
		local d = (p - here).Magnitude
		if d > 4 and Vector3.new(them.X - p.X, 0, them.Z - p.Z).Magnitude >= sniper.close then
			tested += 1
			if clearAim(p + gunOff, entry) then return p end
			if tested >= 120 then break end
		end
	end
	return nil
end

-- Walks a route to a spot, and turns back the moment a line opens or he moves
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

-- Both measured hits landed at a full run and five measured misses came from a dead stop, so the
-- body is never halted to shoot: the aim is re-taken from where the gun is this instant and fired.
function sniper.settle(run, root, entry, point)
	local o = gunOrigin()
	return o and clearAim(o.WorldPosition, entry) or point
end

-- Gunfight on foot: fires the instant a trace is clear, strafes for a line when blocked, backs off inside
-- knife range or when he comes at us inside the hold range, and otherwise waits there for him to show
function sniper.duel(who, limit)
	local function alive()
		return hitPartOf(who) ~= nil and not isDead(who)
	end
	danger.pursuing = true
	stopCoinRun()
	while coinRun do RunService.Heartbeat:Wait() end
	local run = newRun(who, alive, "pursuit")
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
		local flat = Vector3.new(target.Position.X - here.X, 0, target.Position.Z - here.Z)
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
			else
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
			end
		elseif dist < sniper.close or (sniper.backingOff and dist < sniper.hold + 6) then
			sniper.backingOff = true
			sniper.backOff(run, hum, here, toward, entry, gunOff, who)
		else
			sniper.backingOff = false
			local spot = dist <= sniper.far and (sniper.strafeSpot(here, toward, entry, gunOff, who, 1) or sniper.strafeSpot(here, toward, entry, gunOff, who, 2))
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
					local side = Vector3.new(-toward.Z, 0, toward.X) * (sniper.side or 1)
					local standUntil = os.clock() + 0.2
					repeat
						run.moveDir = side
						if danger.canMove() then player:Move(side, false) end
						RunService.Heartbeat:Wait()
					until os.clock() >= standUntil or not run.active
					sniper.side = -(sniper.side or 1)
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

-- Kill all on foot: after every attempt the list is drawn again from where we stand, nearest first, the
-- gun holder ahead of the rest only while he is within 60, and the one already being chased kept for
-- five seconds while he is not much farther than the nearest, so a crowd is not hopped between; a
-- target that could not be reached is left out, one with no route for the moment is not even tried,
-- one just struck is left alone for a second so the server can take him off the list
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
-- A freshly spawned coin that is much closer than the current one interrupts the leg
function onCoinAdded(part)
	local run = coinRun
	if not run or not run.active or run.kind ~= "coins" or not run.target then return end
	local root = myRoot()
	if not root then return end
	if (part.Position - root.Position).Magnitude < run.targetDist * COIN_SWITCH_RATIO then
		run.retarget = true
	end
end

-- Anything the body walks past is taken, whatever it set out for. Coins are collected by touch and
-- the walker often passes within a body's width of one on its way somewhere else; crossing the map
-- for a distant coin while stepping over three others is the opposite of efficient.
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
		local toThem = Vector3.new(threat.Position.X - root.Position.X, 0, threat.Position.Z - root.Position.Z)
		local toCoin = Vector3.new(run.target.Position.X - root.Position.X, 0, run.target.Position.Z - root.Position.Z)
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

------------------------------------------------------------------------------------------------- ESP
local function clearMap(map)
	for key, inst in pairs(map) do
		inst:Destroy()
		map[key] = nil
	end
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
		clearMap(esp.highlights)
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
			local hl = esp.highlights[who]
			if not hl or hl.Adornee ~= char then
				if hl then hl:Destroy() end
				hl = Instance.new("Highlight")
				hl.Name = "MM2RoleEsp"
				hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				hl.Adornee = char
				hl.Parent = char
				esp.highlights[who] = hl
			end
			local colour = ROLE_COLOURS[role] or Color3.new(1, 1, 1)
			hl.FillColor = colour
			hl.OutlineColor = colour
			hl.FillTransparency = dead and 0.85 or 0.55
			hl.OutlineTransparency = 0
			if state.nameEsp then
				updateNameTag(who, char, dead and (role .. " (dead)") or role, colour)
			end
		end
	end
	for who, hl in pairs(esp.highlights) do
		if not keep[who] then
			hl:Destroy()
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

-- The game leaves a ragdoll tagged Ragdoll where each victim fell; that is the body worth marking
function esp.refreshBodies()
	if not state.showDead then
		clearMap(esp.bodies)
		return
	end
	local keep = {}
	for _, body in CollectionService:GetTagged("Ragdoll") do
		if body:IsA("Model") and body:IsDescendantOf(Workspace) then
			keep[body] = true
			if not esp.bodies[body] then
				local hl = Instance.new("Highlight")
				hl.Name = "MM2BodyEsp"
				hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				hl.FillColor = Color3.fromRGB(235, 235, 245)
				hl.OutlineColor = Color3.fromRGB(255, 255, 255)
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

-- A sphere reads as a coin from every angle while the mesh inside keeps spinning
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

-- There is one gun at a time, so a Highlight is affordable and follows the mesh outline
local function adornGun(part, colour)
	local hl = Instance.new("Highlight")
	hl.Name = "MM2GunEsp"
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.FillColor = colour
	hl.OutlineColor = Color3.fromRGB(200, 225, 255)
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
	syncBoxes(esp.coinBoxes, coinParts(), COIN_COLOUR, adornCoin)
end

local function refreshGunEsp()
	if not state.gunEsp then
		clearMap(esp.gunBoxes)
		return
	end
	syncBoxes(esp.gunBoxes, droppedGuns(), ROLE_COLOURS.Sheriff, adornGun)
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

-- Parts forced through walls remember they were solid, so switching off puts them back the same frame
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

-- Collision edits happen on Stepped, before physics resolves the frame
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

-- Every value control is recorded as it is built so the reset button can put each one back to its default
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
	Description = "Ticked actions move like a real player. Unticked ones teleport.",
	Icon = "footprints",
	Options = { "Walking to the dropped gun", "Shooting as sheriff", "Stabbing as murderer", "Running as innocent" },
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
	Options = { "Everyone", "Nearest", "Gun holder" },
	Default = "Nearest",
	Save = prefs.key("combat", "target"),
})

murderSec:Button({
	Text = "Kill target",
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
		if not on and coinRun and coinRun.kind == "pursuit" then
			danger.pursuing = false
			sniper.busy = false
			cutRun()
		end
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
		if not on and coinRun and coinRun.kind == "pursuit" then
			danger.pursuing = false
			sniper.busy = false
			cutRun()
		end
		say(on and "Auto kill sheriff armed" or "Auto kill sheriff off", "shield-off", on and "accent" or "muted")
	end,
})

local sheriffSec = combatSec:Group({ Text = "Sheriff", Icon = "shield" })

sheriffSec:Button({
	Text = "Kill murderer",
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
		if not on and coinRun and coinRun.kind == "pursuit" then
			danger.pursuing = false
			sniper.busy = false
			cutRun()
		end
		say(on and "Auto kill murderer armed" or "Auto kill murderer off", "skull", on and "accent" or "muted")
	end,
})

ui.grabGunBtn = sheriffSec:Button({
	Text = "Grab dropped gun",
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
	Icon = "crosshair",
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
	RevertOnClose = true,
	Callback = function(on)
		state.killAura = on
		say(on and "Kill aura on" or "Kill aura off", "radar", on and "accent" or "muted")
	end,
})

auraSec:Slider({
	Text = "Range",
	Min = 4, Max = 200, Default = 12, Step = 1, Suffix = " studs",
	Save = prefs.key("combat", "killRange"),
	Callback = function(v) state.killRange = v end,
})

auraSec:Slider({
	Text = "Interval",
	Min = 0.05, Max = 1, Default = 0.2, Step = 0.05, Suffix = "s",
	Save = prefs.key("combat", "killDelay"),
	Callback = function(v) state.killDelay = v end,
})

local mapSec = win:Section("Map", "map-pin")
mapSec:Title({ Text = "TELEPORT", Icon = "move" })

mapSec:Button({
	Text = "Teleport to map",
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
	Options = { "nobody" },
	Default = "nobody",
})

mapSec:Button({
	Text = "Teleport to player",
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

local statsSec = win:Section("Stats", "list")
local S = {}
statsSec:Title({ Text = "YOUR ROLE", Icon = "user" })

S.myRoleStatus = statsSec:Status({ Text = "You are", Default = "waiting for round" })
S.weaponStatus = statsSec:Status({ Text = "Weapon", Default = "unarmed", Icon = "sword" })
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
setSec:Title({ Text = "INTERFACE", Icon = "layout" })

setSec:Keybind({
	Text = "Hide and show",
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
setSec:Title({ Text = "SAVED DATA", Icon = "database" })

local totalsGroup = setSec:Group({ Text = "Manage saved stats", Icon = "wrench", Open = false })

totalsGroup:Button({
	Text = "Reset session only",
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

	if state.autoKillSheriff and findTool("Knife") then
		local who = gunHolder()
		if who and not isDead(who) and not danger.friend(who) and hitPartOf(who) then
			attackBusy = true
			attack({ player = who })
			attackBusy = false
		end
	end

	if state.autoKillMurderer and findTool("Knife") then
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
	if state.autoKillMurderer and not (state.autoKillAll or state.autoKillSheriff or state.autoPickup or danger.surviving()) and not findTool("Knife") then return end
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

-- Only a name that was alive in the last snapshot and is dead now counts as a death
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

-- Our own pickup removes the part a beat before the tool lands, so the verdict waits half a second
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

-- The murderer wins when the winner is them; everyone else wins whenever the murderer did not
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

-- A full bag makes every coin untouchable, so the walker stands down until the next round hands out a new one
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
		esp.highlights[who]:Destroy()
		esp.highlights[who] = nil
	end
	if esp.nameTags[who] then
		esp.nameTags[who]:Destroy()
		esp.nameTags[who] = nil
	end
	refreshAll()
end))

local T = { aura = 0, coinStart = 0, tick = 0, autoTick = 0, rethink = 0, actCheck = 0, actOk = false, roam = 0, fall = 0 }

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
	local now = os.clock()
	if state.speed ~= 16 or state.jump ~= 50 or state.gravity ~= 196 or state.fly then plr.playerTick() end

	if now - T.tick >= 1 then
		local delta = now - T.tick
		T.tick = now
		if delta < 5 then totals.playtime += delta end
		if state.roleEsp then refreshRoleEsp() end
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

	if state.avoid and state.autoCoin and not danger.wanting() and T.actOk and not danger.fleeing and not danger.brainOn and not killBusy and now >= (danger.fleeSkipUntil or 0) then
		local threat = danger.root()
		local root = myRoot()
		local closing = false
		if threat and root and coinRun and coinRun.moveDir then
			local toThem = Vector3.new(threat.Position.X - root.Position.X, 0, threat.Position.Z - root.Position.Z)
			closing = toThem.Magnitude < 45 and toThem.Magnitude > 0.01 and toThem.Unit:Dot(coinRun.moveDir) > 0.75 and math.abs(threat.Position.Y - root.Position.Y) < 6 and danger.gap(root.Position, threat) < 50
		end
		if threat and root and (danger.gap(root.Position, threat) < danger.near or closing) then
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
	clearMap(esp.highlights)
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
