--!strict
--[[
	Fireball staff (client-side demo).

	Flow: staff activated -> charging (fireball grows, speed rises, aim preview is drawn)
	-> released -> fireball is simulated with custom ballistics (gravity, drag, spherecast
	collisions, bounces) -> explodes after the last allowed bounce.

	Physics run at a fixed step so the aim preview matches the real flight.
	Everything is client-side, so explosions are only visible to the local player.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local mouse = player:GetMouse()

local playerGui = player:WaitForChild("PlayerGui")
local chargeGui = playerGui:WaitForChild("ScreenGui") :: ScreenGui
local background = chargeGui:WaitForChild("Background")
local chargeFill = background:WaitForChild("ChargeBar") :: Frame
local cooldownLabel = background:WaitForChild("Cooldown") :: TextLabel

-- Without this the GUI is destroyed on respawn and the references above go stale
chargeGui.ResetOnSpawn = false

local fireballTemplate = ReplicatedStorage:WaitForChild("FireballModel") :: Model
local staffTemplate = ReplicatedStorage:WaitForChild("Staff") :: Tool

local CONFIG = {
	-- Launch speed range, scaled by charge
	MIN_SPEED = 40,
	MAX_SPEED = 140,

	-- Fireball scale range, scaled by charge
	MIN_SIZE = 0.5,
	MAX_SIZE = 2.5,

	CHARGE_TIME = 1.5,      -- Seconds to reach full charge
	UPWARD_VELOCITY = 20,   -- Vertical velocity added to every launch
	HOLD_DISTANCE = 5,      -- Distance the fireball is held from the player
	HOLD_HEIGHT = 1.5,      -- Height the fireball is held above the player
	COOLDOWN = 0.5,         -- Seconds between shots
	LIFETIME = 10,          -- Seconds before an unexploded fireball is removed
	SKIN = 0.05,            -- Gap kept between the fireball and surfaces it touches

	-- Roblox explosion values
	BLAST_RADIUS = 10,
	BLAST_PRESSURE = 10000,

	MAX_BOUNCES = 3,        -- Bounces before the fireball explodes
	DRAG = 0.15,            -- Air resistance
	RESTITUTION = 0.7,      -- Fraction of speed kept after a bounce

	-- Simulation values
	PHYSICS_STEP = 1 / 60,  -- Fixed time step shared by live physics, aim solver and preview
	MAX_FRAME_TIME = 0.1,   -- Cap on accumulated time so a lag spike can't cause a burst of steps
	PREVIEW_TIME = 2,       -- Seconds of flight shown by the trajectory preview
	AIM_REFINE_STEPS = 10,  -- Bisection passes that refine the aim solution (more = more accurate)
}

local GRAVITY = Vector3.new(0, -workspace.Gravity, 0)   -- Calculated once
local fireballScale = CONFIG.MIN_SIZE                   -- Changes while charging; set here so it's never nil

local fireballFolder = Instance.new("Folder")           -- Holds every fireball and preview part
fireballFolder.Name = "Fireballs"
fireballFolder.Parent = workspace

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude   -- Ignore filtered instances when casting

-- Fields stored on every fireball instance
type FireballData = {
	Model: Model,
	Position: Vector3,
	Velocity: Vector3,
	Radius: number,     -- Collision radius measured from the model at launch
	Bounces: number,
	Age: number,        -- In seconds
	Alive: boolean,
}

-- Rebuild the ignore list so casts skip fireballs and the current character
local function refreshRayFilter()
	local filter: { Instance } = { fireballFolder }

	if player.Character then
		table.insert(filter, player.Character) -- Fireballs dont collide with their owner
	end

	rayParams.FilterDescendantsInstances = filter
end

-- The model is scaled while charging so its radius is read from its current size
local function modelRadius(model: Model): number
	local size = model:GetExtentsSize()
	return math.max(size.X, size.Y, size.Z) / 2 -- Half the largest side of the bounding box
end

-- Advances one step of motion and returns the new position, new velocity and any collision
local function stepMotion(position: Vector3,velocity: Vector3,radius: number,dt: number): (Vector3, Vector3, RaycastResult?)
	local newVelocity = (velocity + GRAVITY * dt) * math.max(0, 1 - CONFIG.DRAG * dt) -- Add gravity, then apply drag
	local newPosition = position + (velocity + newVelocity) * 0.5 * dt -- Trapezoid rule: move by the average velocity
	local offset = newPosition - position

	local hit = if offset.Magnitude > 0
		then workspace:Spherecast(position, radius, offset, rayParams) -- Cast sphere along the movement
	else nil

	if hit then
		-- Pushed away by SKIN so the next cast doesnt start inside it
		return position + offset.Unit * hit.Distance + hit.Normal * CONFIG.SKIN, newVelocity, hit
	end

	return newPosition, newVelocity, nil -- No collision this step 
end

-- Reflects velocity off a surface and removes the energy lost in the bounce
local function bouncedVelocity(velocity: Vector3, normal: Vector3): Vector3
	return (velocity - 2 * velocity:Dot(normal) * normal) * CONFIG.RESTITUTION -- Mirror around the normal, keep part of speed
end

local Fireball = {}
Fireball.__index = Fireball

type Fireball = typeof(setmetatable({} :: FireballData, Fireball))

local activeFireballs: { Fireball } = {}

function Fireball.new(model: Model, position: Vector3, velocity: Vector3): Fireball
	local data: FireballData = {
		Model = model,
		Position = position,
		Velocity = velocity,
		Radius = modelRadius(model), -- Measured once since size stops after release
		Bounces = 0,
		Age = 0,
		Alive = true,
	}

	return setmetatable(data, Fireball)
end

function Fireball.Destroy(self: Fireball)
	self.Alive = false 
	self.Model:Destroy()
end

-- Advance one physics step
function Fireball.Step(self: Fireball, dt: number)
	self.Age += dt	-- Age fireball by delta time

	if self.Age > CONFIG.LIFETIME then -- If too old...
		self:Destroy()	-- Remove
		return
	end

	local newPosition, newVelocity, hit = stepMotion(self.Position, self.Velocity, self.Radius, dt)

	if hit then
		self:OnHit(hit, newVelocity, newPosition) -- Bounce or explode
		return
	end

	-- Save for next step
	self.Position = newPosition
	self.Velocity = newVelocity

	self.Model:PivotTo(CFrame.lookAt(newPosition, newPosition + newVelocity)) -- Point the model along its travel direction
end

function Fireball.OnHit(self: Fireball, hit: RaycastResult, incoming: Vector3, contact: Vector3)
	self.Position = contact	

	if self.Bounces >= CONFIG.MAX_BOUNCES then -- If bounces > limit...
		self:Explode()	--- Remove
		return
	end

	self.Bounces += 1
	self.Velocity = bouncedVelocity(incoming, hit.Normal)	

	-- Move the model to the contact point now so it doesn't visibly clip into the surface
	self.Model:PivotTo(CFrame.lookAt(self.Position, self.Position + self.Velocity))
end

function Fireball.Explode(self: Fireball)

	-- Create Roblox explosion
	local explosion = Instance.new("Explosion")
	explosion.BlastRadius = CONFIG.BLAST_RADIUS
	explosion.BlastPressure = CONFIG.BLAST_PRESSURE
	explosion.DestroyJointRadiusPercent = 0 
	explosion.Position = self.Position
	explosion.Parent = workspace -- Parenting the explosion triggers it

	self:Destroy()
end

local heldFireball: Model? = nil                    -- The fireball being charged (nil when not charging)
local trackConnection: RBXScriptConnection? = nil   -- Heartbeat connection that runs while charging

local canFire = true       -- False during cooldown
local chargeStart = 0       -- os.clock() when the current charge began
local cooldownEnd = 0       -- os.clock() when the current cooldown ends

local function getRoot(): BasePart?
	local character = player.Character

	return character -- Nil if there is no character...
		and character:FindFirstChild("HumanoidRootPart") :: BasePart? -- otherwise its root part
end

-- Held fireballs are anchored and invisible to physics queries so they never push or block anything
local function prepareModel(model: Model)
	for _, descendant in model:GetDescendants() do -- For every descendant of the fireball model...
		if descendant:IsA("BasePart") then -- If it is a part...

			-- Disable physics
			descendant.Anchored = true 
			descendant.CanCollide = false 
			descendant.CanQuery = false 
		end
	end
end

-- Direction from origin to the mouse 
local function getAimDirection(origin: Vector3, fallback: Vector3): Vector3
	local difference = mouse.Hit.Position - origin

	if difference.Magnitude < 0.1 then -- Too close for a reliable direction
		return fallback	-- fallback when the mouse is on top of the origin
	end

	return difference.Unit
end

-- Returns where the fireball is held and the direction it is aimed
local function getFireballPosition(root: BasePart, radius: number): (Vector3, Vector3)
	local origin = root.Position + Vector3.new(0, CONFIG.HOLD_HEIGHT, 0)

	-- Lift the origin if the fireball would sink into the ground
	local groundHit = workspace:Raycast(origin, Vector3.new(0, -radius, 0), rayParams)

	if groundHit and groundHit.Normal.Y > 0 then -- Only upward facing surfaces count as ground
		origin = groundHit.Position + groundHit.Normal * (radius + CONFIG.SKIN)
	end

	local direction = getAimDirection(origin, root.CFrame.LookVector) -- Falls back to where the player is facing

	-- Stop short of any wall between the player and the hold position
	local hit = workspace:Spherecast(origin, radius, direction * CONFIG.HOLD_DISTANCE, rayParams)

	local distance =
		if hit
		then math.max(0, hit.Distance - CONFIG.SKIN) -- Stop just before the wall
		else CONFIG.HOLD_DISTANCE

	return origin + direction * distance, direction
end

-- Convert elapsed charging time to a value from 0 to 1
local function getCharge(): number
	return math.clamp((os.clock() - chargeStart) / CONFIG.CHARGE_TIME, 0, 1)
end

local function updateChargeBar()
	chargeFill.Size = UDim2.fromScale(1, getCharge())
end

local function lerp(min: number, max: number, percent: number): number
	return min + (max - min) * percent
end

--[[
	- Finds the launch velocity that makes the fireball land on the mouse position
	- Position is linear in the launch velocity:
	- position(t) = distanceFactor(t) * launchVelocity + gravityDistance(t)
	- For each flight time, solves for the launch velocity needed to reach the target
	- The first time that fits the charged speed wins 
	- A bisection inside that step refines it 
]]
local function getLaunchVelocity(origin: Vector3, fallback: Vector3): Vector3
	local speed = lerp(CONFIG.MIN_SPEED, CONFIG.MAX_SPEED, getCharge()) -- Speed grows with charge
	local upward = Vector3.new(0, CONFIG.UPWARD_VELOCITY, 0) -- Added to every shot after aiming
	local delta = mouse.Hit.Position - origin

	if delta.Magnitude < 0.1 then -- Target is on top of the fireball
		return fallback * speed + upward 
	end

	local velocityFactor = 1                -- Share of the launch velocity that survived drag so far
	local gravityVelocity = Vector3.zero   -- Velocity contribution from gravity
	local distanceFactor = 0                -- Distance travelled per unit of launch velocity
	local gravityDistance = Vector3.zero   -- Distance travelled because of gravity alone
	local step = CONFIG.PHYSICS_STEP

	for _ = 1, math.floor(CONFIG.LIFETIME / step) do -- For every step the fireball could possibly fly for...
		local drag = math.max(0, 1 - CONFIG.DRAG * step)
		local nextFactor = velocityFactor * drag -- Launch velocity that survives drag after this step
		local nextGravityVelocity = (gravityVelocity + GRAVITY * step) * drag
		local nextDistanceFactor = distanceFactor + (velocityFactor + nextFactor) * 0.5 * step
		local nextGravityDistance = gravityDistance + (gravityVelocity + nextGravityVelocity) * 0.5 * step
		local required = (delta - nextGravityDistance) / nextDistanceFactor - upward -- Launch velocity that reaches the target at this time

		if required.Magnitude <= speed then -- If the charged speed can reach the target by this step...
			local low = 0 -- flight time lies between the start...
			local high = step -- ...and the end of this step
			local aim = required

			for _ = 1, CONFIG.AIM_REFINE_STEPS do -- For every refinement pass...
				local mid = (low + high) * 0.5
				local midDrag = math.max(0, 1 - CONFIG.DRAG * mid)
				local midFactor = velocityFactor * midDrag
				local midGravityVelocity = (gravityVelocity + GRAVITY * mid) * midDrag

				local a = distanceFactor + (velocityFactor + midFactor) * 0.5 * mid -- distance factor at the midpoint time
				local b = gravityDistance + (gravityVelocity + midGravityVelocity) * 0.5 * mid -- Gravity distance at the midpoint time

				local candidate = (delta - b) / a - upward

				if candidate.Magnitude > speed then -- Needs more speed than we have 
					low = mid -- try more flight time
				else -- Reachable 
					high = mid	-- try shorter flight time
					aim = candidate
				end
			end

			return aim.Unit * speed + upward -- Launch at the charged speed along the refined aim
		end

		velocityFactor = nextFactor -- Carry this steps values into the next step
		gravityVelocity = nextGravityVelocity
		distanceFactor = nextDistanceFactor
		gravityDistance = nextGravityDistance
	end

	return fallback * speed + upward -- Target is out of reach
end

local previewParts: { Part } = {}   -- Reused every update instead of creating new parts
local lastPreview = -math.huge      -- os.clock() of the last preview update

-- Hides the trajectory when aiming stops
local function clearPreview()
	for _, part in previewParts do -- For every preview segment...
		part.Transparency = 1 -- Hide it
	end
end

-- Simulates the flight with the same physics as a real fireball and draws it as line segments
local function updatePreview(origin: Vector3, launchVelocity: Vector3, radius: number)
	local position = origin
	local velocity = launchVelocity
	local bounces = 0
	local used = 0 -- Number of segments drawn this update

	for _ = 1, math.floor(CONFIG.PREVIEW_TIME / CONFIG.PHYSICS_STEP) do -- For every step of the previewed flight...
		local nextPosition, nextVelocity, hit = stepMotion(position, velocity, radius, CONFIG.PHYSICS_STEP)
		local length = (nextPosition - position).Magnitude

		if length > 0.001 then -- If the step is long enough to draw...
			used += 1
			local part = previewParts[used] -- Reuse the segment at this index if it exists

			if not part then -- Create a segment only when the path grows
				part = Instance.new("Part")
				part.Name = "TrajectoryPreview"
				part.Anchored = true
				part.CanCollide = false
				part.CanQuery = false -- Keeps the mouse and raycasts from hitting the preview
				part.CanTouch = false
				part.Material = Enum.Material.Neon
				part.Color = Color3.fromRGB(0, 0, 255)
				part.Parent = fireballFolder
				previewParts[used] = part -- Store it for reuse
			end

			part.Size = Vector3.new(0.12, 0.12, length) -- As long as this step
			part.CFrame = CFrame.lookAt((position + nextPosition) * 0.5, nextPosition) -- Centered between the old and new positions
			part.Transparency = 0.25 -- Show it
		end

		position = nextPosition
		velocity = nextVelocity

		if hit then -- If the simulated fireball hit something...
			if bounces >= CONFIG.MAX_BOUNCES then -- If it has no bounces left...
				break -- Real fireball explodes here
			end

			bounces += 1
			velocity = bouncedVelocity(velocity, hit.Normal) -- Same bounce as a real fireball
		end
	end

	for i = used + 1, #previewParts do -- For every segment not used this update...
		previewParts[i].Transparency = 1 -- Hide it
	end
end

-- Keeps the chargin gfireball and preview aimed from the players current position
local function updateHeldFireball(model: Model)
	local root = getRoot()

	if not root then
		clearPreview()
		return
	end

	local radius = modelRadius(model) -- Remeasured each time since the model grows while charging
	local position, direction = getFireballPosition(root, radius)
	local velocity = getLaunchVelocity(position, direction)

	model:PivotTo(CFrame.lookAt(position, position + velocity)) -- Point the held model along its launch velocity

	-- Preview is costly -> measure only 10 times a second to improve performance
	if os.clock() - lastPreview >= 0.1 then
		lastPreview = os.clock()
		updatePreview(position, velocity, radius)
	end
end

local function stopTracking()
	if trackConnection then
		trackConnection:Disconnect()
		trackConnection = nil
	end

	heldFireball = nil
	mouse.TargetFilter = nil -- Let the mouse target the world normally again
	clearPreview()
end

local function SpawnFireball()
	if heldFireball or not canFire or not getRoot() then -- Check if can fire
		return
	end

	chargeStart = os.clock()
	updateChargeBar()

	chargeGui.Enabled = true
	chargeFill.Visible = true
	cooldownLabel.Visible = false -- The cooldown timer is only shown after firing

	local fireball = fireballTemplate:Clone() -- A separate model for this shot
	prepareModel(fireball)
	fireball.Name = "FireballInstance"

	-- Everything in the folder (held model and preview parts) is ignored by the mouse
	-- otherwise the aim point could land on our own preview
	mouse.TargetFilter = fireballFolder
	heldFireball = fireball

	fireballScale = CONFIG.MIN_SIZE -- Every charge starts at the smallest size
	fireball:ScaleTo(fireballScale)

	updateHeldFireball(fireball) -- Place and aim the model before it becomes visible
	fireball.Parent = fireballFolder

	-- While LMB (on pc) is held
	trackConnection = RunService.Heartbeat:Connect(function()
		fireballScale = lerp(CONFIG.MIN_SIZE, CONFIG.MAX_SIZE, getCharge())
		fireball:ScaleTo(fireballScale) -- Scale first so the radius measured below is current

		updateHeldFireball(fireball)	-- Re-Aim fireball
		updateChargeBar()	
	end)
end


local function cancelFireball()
	if heldFireball then		-- If charge is held...
		heldFireball:Destroy()	-- Discard fireball
	end

	chargeGui.Enabled = false
	stopTracking()
end

-- Turn the held model into an active fireball when the button is released
local function ReleaseFireball()
	local fireball = heldFireball

	if not fireball then -- Nothing was being charged
		return
	end

	local pivot = fireball:GetPivot() -- Works even if the model has no PrimaryPart
	local root = getRoot()
	local fallback = getAimDirection( -- Used if the mouse is too close to aim at
		pivot.Position,
		if root then root.CFrame.LookVector else pivot.LookVector	-- Root chheck
	)
	local velocity = getLaunchVelocity(pivot.Position, fallback)

	fireball:PivotTo(CFrame.lookAt(pivot.Position, pivot.Position + velocity))
	table.insert(activeFireballs, Fireball.new(fireball, pivot.Position, velocity)) -- Hand it to the physics loop

	stopTracking()

	canFire = false
	cooldownEnd = os.clock() + CONFIG.COOLDOWN

	-- Swap the charge bar for the cooldown timer
	chargeGui.Enabled = true
	chargeFill.Visible = false
	cooldownLabel.Visible = true

	task.delay(CONFIG.COOLDOWN, function() -- When the cooldown ends...
		canFire = true
		cooldownLabel.Visible = false
		chargeGui.Enabled = false
	end)
end

local function stepFireballs(dt: number)
	for i = #activeFireballs, 1, -1 do -- For every active fireball (backwards so removing one does not skip the next)...
		local fireball = activeFireballs[i]

		if fireball.Alive then -- Step if still alive...
			fireball:Step(dt)
		else -- Otherwise destroy it
			table.remove(activeFireballs, i)
		end
	end
end

local physicsAccumulator = 0    -- Time waiting to be consumed by fixed physics steps

-- Main loop
RunService.Heartbeat:Connect(function(dt: number)
	physicsAccumulator = math.min(physicsAccumulator + dt, CONFIG.MAX_FRAME_TIME) -- Capped so a lag spike can't cause a burst of steps

	while physicsAccumulator >= CONFIG.PHYSICS_STEP do -- While there is enough stored time for another step...
		physicsAccumulator -= CONFIG.PHYSICS_STEP	-- Count down time
		stepFireballs(CONFIG.PHYSICS_STEP)		-- Do a step
	end

	if not canFire then -- If can't fire...

		-- Update cooldown text
		local remaining = math.max(0, cooldownEnd - os.clock())
		cooldownLabel.Text = string.format("%.2f", remaining)
	end
end)

local function giveStaff()
	local staff = staffTemplate:Clone() 

	staff.Activated:Connect(SpawnFireball) -- Start charging on click...
	staff.Deactivated:Connect(ReleaseFireball) -- ...fire on release
	staff.Unequipped:Connect(cancelFireball) -- Cancel an unfinished charge if the staff is put away

	staff.Parent = player:WaitForChild("Backpack") -- Give staff to player
end

refreshRayFilter() -- Init raycast filter
giveStaff() 

player.CharacterAdded:Connect(function() -- When the player respawns...
	cancelFireball() -- Drop any charge from the previous character
	refreshRayFilter() -- Exclude the new character from casts
	giveStaff()
end)