--!native
--!optimize 2
local UniversalNav = { Version = "0.7.12" }

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

-------------------------------------------------------------------------------------------------- Core
-- States, transitions and world revisions: the only vocabulary the search reads.
local Core = {}
UniversalNav.Core = Core

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
-- Search backends behind a registry; weighted A* with a binary heap is the default.
local Search = { Registry = {} }
UniversalNav.Search = Search

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
-- Turns a transition's raw time, distance and risk into the one number A* sorts on.
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
-- Transitions per world revision and agent signature; five keys kept, oldest dropped.
local Cache = {}
UniversalNav.Cache = Cache

local TransitionCache = {}
TransitionCache.__index = TransitionCache
Cache.TransitionCache = TransitionCache

function TransitionCache.new()
	return setmetatable({ key = nil, store = {}, failed = {}, walks = {}, kept = {}, order = {}, hits = 0, misses = 0 }, TransitionCache)
end

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
-- What the world offers and what bodies learned by trying it, keyed per game and mechanism.
local Affordances = { Threshold = 0.5 }
UniversalNav.Affordances = Affordances

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

function Affordances.key(object, kind, mechanism)
	return tostring(game.GameId) .. "|" .. Affordances.signature(object) .. "|" .. kind .. "|" .. mechanism
end

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

Memory.lethal = {}

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
-- Scanners that find candidate affordances: what the platform says, and what the shape suggests.
local Perception = {}
UniversalNav.Perception = Perception

Perception.Portals = { Reach = 8, Step = 4 }

local function reachClear(a, b, geo)
	local dy = b.Y - a.Y
	local knee0 = a - Vector3.new(0, 2 - math.max(dy, 0), 0)
	local knee1 = b - Vector3.new(0, 2 - math.max(-dy, 0), 0)
	return not geo:Raycast(a, b) and not geo:Raycast(knee0, knee1)
end

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
-- What an agent can do, plus the runtime probe that proves an untrusted surface by trying it.
local Capabilities = {}
UniversalNav.Capabilities = Capabilities

function Capabilities.inspectHumanoid(hum)
	return {
		Ground = true,
		Jump = (hum.UseJumpPower and hum.JumpPower or hum.JumpHeight) > 0,
		HumanoidClimbState = hum:GetStateEnabled(Enum.HumanoidStateType.Climbing),
		Swim = hum:GetStateEnabled(Enum.HumanoidStateType.Swimming),
	}
end

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

Capabilities.RuntimeProbe = { Defaults = { MaxTime = 1.5, VerificationRise = 3, MaxRisk = 0.25, Budget = 3 }, spent = 0, world = nil }

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

UniversalNav.ProbePolicies = {
	Never = { Mode = "Never" },
	Conservative = { Mode = "WhenNecessary", MaxTime = 1.5, VerificationRise = 3, MaxRisk = 0.25, Budget = 3 },
	Exploratory = { Mode = "WhenNecessary", MaxTime = 4, VerificationRise = 2, MaxRisk = 0.8, Budget = 20 },
}

---------------------------------------------------------------------------------------------- Roblox
-- The platform edge: geometry casts, the humanoid adapter, and the climb and jump executors.
local Roblox = {}
UniversalNav.Roblox = Roblox

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

local HumanoidAdapter = {}
HumanoidAdapter.__index = HumanoidAdapter
Roblox.HumanoidAdapter = HumanoidAdapter

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

function HumanoidAdapter:Step() return self.step end
function HumanoidAdapter:Slope()
	if self.slope then return self.slope end
	local hum = self.humanoid()
	return math.tan(math.rad(math.min(hum and hum.MaxSlopeAngle or 70, 70)))
end

function HumanoidAdapter:Lift() return self.height / 2 + 0.25 end
function HumanoidAdapter:Headroom() return self.height end

function HumanoidAdapter:MaxDrop() return self.maxDrop end
function HumanoidAdapter:GapDown() return self.gapDown end

function HumanoidAdapter:JumpEnvelope()
	local v, g, speed = self:JumpVelocity(), self:Gravity(), self:Speed()
	local rise = v * v / (2 * g) - self:Step()
	if rise < 0 then rise = 0 end
	local flat = speed * (2 * v / g)
	return { MaxUp = rise, MaxFlat = flat }
end

function HumanoidAdapter:ClimbSpeed(key)
	local model = key and Memory.model(Affordances.execKey(key, self))
	if model and model.Speed and model.Speed > 1 then return model.Speed end
	return self.speed() * self.climbFactor
end

function HumanoidAdapter:Capabilities()
	local hum = self.humanoid()
	return hum and Capabilities.inspectHumanoid(hum) or { Ground = true }
end

function HumanoidAdapter:Providers()
	local can = self:Capabilities()
	local Traversal = UniversalNav.Traversal
	local list = { Traversal.Ground, Traversal.Drop }
	if can.Jump then table.insert(list, Traversal.Jump) end
	if can.HumanoidClimbState then table.insert(list, Traversal.Climb) end
	return list
end

function HumanoidAdapter:Family()
	return string.format("%d:%d:%d", math.floor(self.height * 2 + 0.5), math.floor(self.radius * 2 + 0.5), math.floor(self:JumpEnvelope().MaxUp / 2 + 0.5))
end

function HumanoidAdapter:Signature()
	local names = {}
	for _, p in self:Providers() do table.insert(names, p.Name) end
	return string.format("%.2f|%.2f|%.2f|%.1f|%.1f|%s", self.speed(), self.jumpVelocity(), Workspace.Gravity, self.radius, self.height, table.concat(names, ","))
end

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

Roblox.JumpExecutor = { Approach = 4, Runway = 3, Landing = 3, Edge = 1.5 }

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
-- Per-frame heading: the wanted way when the body fits, else the smallest bend that has room.
local Steering = { Name = "Steering", Look = 6, Ahead = 0.5, Fan = 14, Widest = 170, Keep = 0.35, Clearance = 0.6, Forward = -0.1, Commit = 0.25, Escape = 1.2 }
UniversalNav.Steering = Steering

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

function Steering.Footing(from, dir, ctx, dist)
	local agent, geo = ctx.Agent, ctx.Geometry
	local at = from + dir * dist
	local hit = geo:Raycast(at + Vector3.new(0, agent:Step(), 0), Vector3.new(0, -(agent:Lift() + agent:Step() * 2 + 1), 0))
	if not hit then return false end
	return math.abs((hit.Position.Y + agent:Lift()) - from.Y) <= agent:Step() * 2
end

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
-- Providers that emit a move only where an affordance meets a capability.
local Traversal = {}
UniversalNav.Traversal = Traversal

Traversal.Ground = { Name = "Ground" }

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
-- Surface lattice: a standable point every few studs on every floor, with headroom and neighbours.
local World = {}
UniversalNav.World = World

local SurfaceLattice = {}
SurfaceLattice.__index = SurfaceLattice
World.SurfaceLattice = SurfaceLattice

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
-- Ties world, cache and backend together; every query brings its own agent, cost and goal.
local Navigator = {}
Navigator.__index = Navigator
UniversalNav.Navigator = Navigator

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

function Navigator:Distrusted(from, to)
	local list = self.distrust[from]
	local entry = list and list[to]
	return entry ~= nil and entry.until_ > os.clock()
end

function Navigator:trusted(t)
	local aff = t.Data and t.Data.Affordance
	if not aff then return true end
	if (self.cold[self:coldKey(aff)] or 0) > os.clock() then return false end
	return Affordances.trust(aff, self:execKey(aff)) >= Affordances.Threshold
end

function Navigator:execKey(aff)
	return self.family and (aff.Key .. "#" .. self.family) or nil
end

function Navigator:coldKey(aff)
	return aff.Object or aff.Key
end

function Navigator:apart(start, goals)
	local kept = self.reach
	if not kept or kept.key ~= self.cache.key or os.clock() - kept.at > 3 or not kept.set[start] then return false end
	for n in pairs(goals) do
		if kept.set[n] then return false end
	end
	return true
end

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

function Navigator:ReportLethal(pos)
	self.reach = nil
	return Memory.reportLethal(self.world:Key(), pos)
end

function Navigator:Lethal(pos, within, minCount)
	return Memory.isLethal(self.world:Key(), pos, within, minCount)
end

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
