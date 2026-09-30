-- Connected Discord-GitHub
--!strict

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

local chargeStart = 0
local cooldownEnd = 0

local fireballTemplate = ReplicatedStorage:WaitForChild("FireballModel") :: Model
local staffTemplate = ReplicatedStorage:WaitForChild("Staff") :: Tool

local CONFIG = {
	-- MIN and MAX speed for the fireball
	MIN_SPEED = 40,			
	MAX_SPEED = 140,	
	
	-- MIN and MAX size for the fireball	
	MIN_SIZE = 0.5,			
	MAX_SIZE = 2.5,		
	
	CHARGE_TIME = 1.5,		-- Maximum charge time of the staff
	UPWARD_VELOCITY = 20,	-- Vertical velocity when the fireball is launched	
	HOLD_DISTANCE = 5,		-- Distance the fireball is held from the player
	HOLD_HEIGHT = 1.5,		-- Height the fireball is held above the player
	COOLDOWN = 0.5,			-- Time between shots
	LIFETIME = 10,			-- Time before fireball is removed
	SKIN = 0.05,			-- Skin thickness for calculating collisions
	
	-- Roblox explosion values
	BLAST_RADIUS = 10,		
	BLAST_PRESSURE = 10000,
	
	MAX_BOUNCES = 3,		-- Bounces before fireball is removed
	DRAG = 0.15,			-- Air resistance
	RESTITUTION = 0.7,		-- % of velocity kept after a bounce
	
	-- Aim preview values
	PREVIEW_STEP = 1 / 30,	-- Time between motion steps 
	PREVIEW_TIME = 2,		-- Time to simulate motion 
	ITERATIONS = 10, 		-- Number of iterations for motion simulation
}

local GRAVITY = Vector3.new(0, -workspace.Gravity, 0)	-- Calculated once
local fireballRadius = CONFIG.MIN_SIZE					-- Changed dynamically, set here so it's not nil


local fireballFolder = Instance.new("Folder")		-- Folder to hold all fireball instances	
fireballFolder.Name = "Fireballs"
fireballFolder.Parent = workspace

local rayParams = RaycastParams.new()					
rayParams.FilterType = Enum.RaycastFilterType.Exclude	-- Set filter to exclude parameters


type FireballData = {		-- Fireball data type, new fireball instaces are created from this
	Model: Model,			
	Position: Vector3,
	Velocity: Vector3,
	Bounces: number,
	Age: number,		-- In seconds
	Alive: boolean,
	Size: number,
}

local function refreshRayFilter()
	local filter: { Instance } = {	-- Add fireballs in fireballFolder to filter...
		fireballFolder,
	}

	if player.Character then
		table.insert(filter, player.Character)	-- Add player's character to filter
	end

	rayParams.FilterDescendantsInstances = filter	
end

local function stepMotion(position: Vector3, velocity: Vector3, size: number, dt: number): (Vector3, Vector3, RaycastResult?)
	
	local newVelocity = (velocity + GRAVITY * dt) * math.max(0, 1 - CONFIG.DRAG * dt) -- Calculate velocity using old velocity, gravity and drag
	
	local newPosition = position + (velocity + newVelocity) * 0.5 * dt	-- Use average of old and new velocity to calculate position
	local offset = newPosition - position	-- Calculate offset...
	
	local hit = if offset.Magnitude > 0 then 	-- return nil if 0
		workspace:Spherecast(position, size, offset, rayParams) -- Spherecast to find collisions
	else nil

	if hit then -- If collision is found...
		return position + offset.Unit * hit.Distance + hit.Normal * CONFIG.SKIN, newVelocity, hit -- Return hit position, velocity, and hit info...
	end

	return newPosition, newVelocity, nil	-- Failsafe since current hit info can't exist without collision
end

local function bouncedVelocity(velocity: Vector3, normal: Vector3): Vector3
	return (velocity - 2 * velocity:Dot(normal) * normal) * CONFIG.RESTITUTION	-- Return velocity after a bounce
end


local Fireball = {}				-- Fireball class
Fireball.__index = Fireball		-- Set the metatable

type Fireball = typeof(			
	setmetatable({} :: FireballData, Fireball)	
)

local activeFireballs: { Fireball } = {}	-- Holds list of active fireballs

function Fireball.new(model: Model, position: Vector3, velocity: Vector3): Fireball

	local data: FireballData = {	
		Model = model,
		Position = position,
		Velocity = velocity,
		Bounces = 0,
		Age = 0,
		Alive = true,
		Size = fireballRadius,
	}

	return setmetatable(data, Fireball)	-- Return new fireball instance
end

function Fireball.Destroy(self: Fireball)
	self.Alive = false			
	self.Model:Destroy()		-- Destroy the fireball model
end

function Fireball.Step(self: Fireball, dt: number)
	self.Age += dt		-- Age fireball using delta time

	if self.Age > CONFIG.LIFETIME then	-- Check age first...
		self:Destroy()		-- destroy and return if too old
		return
	end
	
	-- Calculates the position of the fireball at time t given its initial position and velocity
	local newPosition, newVelocity, hit = stepMotion(self.Position, self.Velocity, self.Size, dt) 

	if hit then		-- If collision occurs...
		self:OnHit(hit, newVelocity, newPosition) -- Handle the collision
		return
	end

	self.Position = newPosition
	self.Velocity = newVelocity

	self.Model:PivotTo(
		CFrame.lookAt(
			newPosition,
			newPosition + newVelocity
		)
	)
end

function Fireball.OnHit(self: Fireball, hit: RaycastResult, incoming: Vector3, contact: Vector3)
	self.Position = contact		-- Save contact point with collision

	if self.Bounces >= CONFIG.MAX_BOUNCES then		-- Check bounces first...
		self:Explode()		-- Explode if max bounces reached
		return
	end

	self.Bounces += 1	-- Increment bounce counter since collision = bounce

	self.Velocity = bouncedVelocity(incoming, hit.Normal)	-- Calculate new velocity after bounce

	self.Model:PivotTo(CFrame.lookAt( self.Position, self.Position + self.Velocity)) -- Update fireball position and direction to avoid clipping issues
end

function Fireball.Explode(self: Fireball)
	
	-- Create Roblox explosion 
	local explosion = Instance.new("Explosion")		
	explosion.BlastRadius = CONFIG.BLAST_RADIUS
	explosion.Position = self.Position
	explosion.BlastPressure = CONFIG.BLAST_PRESSURE
	explosion.Parent = workspace

	self:Destroy()	-- Destroy fireball
end

local heldFireball: Model? = nil					-- Holds reference to currently charging fireball (nil when not charging)
local trackConnection: RBXScriptConnection? = nil	-- Holds connection to  Heartbeat function while fireball is held

local canFire = true	-- Flag to prevent spamming fireballs

local function getRoot(): BasePart?
	local character = player.Character	-- Get character model

	return character	-- Return character model...
		and character:FindFirstChild("HumanoidRootPart") :: BasePart?	-- and its root part
end

local function prepareModel(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
		end
	end
end

local function getAimDirection(origin: Vector3, fallback: Vector3): Vector3

	local difference = mouse.Hit.Position - origin -- Get direction from fireball origin to mouse position

	if difference.Magnitude < 0.1 then -- If mouse is too close to fireball origin...
		return fallback	-- Use fallback direction instead 
	end

	return difference.Unit
end

local function getFireballPosition(root: BasePart): (Vector3, Vector3)

	local origin = root.Position + Vector3.new(0, CONFIG.HOLD_HEIGHT, 0) -- Set fireball origin to be held above the player at CONFIG.HOLD_HEIGHT studs

	local groundHit = workspace:Raycast(origin, Vector3.new(0, -fireballRadius, 0), rayParams) -- Raycast from fireball origin to the ground 

	if groundHit and groundHit.Normal.Y > 0 then	-- If ray hits ground...
		origin = groundHit.Position + groundHit.Normal * (fireballRadius + CONFIG.SKIN) -- Raise origin to be above the ground
	end

	local direction = getAimDirection(origin, root.CFrame.LookVector) -- Calculate direction to aim fireball, using root part direction as fallback

	local hit = workspace:Spherecast(origin, fireballRadius, direction * CONFIG.HOLD_DISTANCE, rayParams)	-- Check for a wall along the hold distance

	-- Use the nearest obstruction to keep the held fireball clear of walls.
	local distance =
		if hit
		then math.max(
			0,
			hit.Distance - CONFIG.SKIN
		)
		else CONFIG.HOLD_DISTANCE

	return origin + direction * distance, direction	-- Return a position before the obstruction and the aim direction
end

-- Convert elapsed charging time to a value from 0 to 1.
local function getCharge(): number
	return math.clamp((os.clock() - chargeStart)/ CONFIG.CHARGE_TIME, 0, 1)
end



-- Show charge progress in the GUI.
local function updateChargeBar()
	chargeFill.Size = UDim2.fromScale(1, getCharge())
end

local function lerp(min: number, max: number, percent: number): number
	return min + (max - min) * percent	-- Linear interpolation between two values
end

local function getLaunchVelocity(origin: Vector3, fallback: Vector3): Vector3
	local speed = lerp(CONFIG.MIN_SPEED, CONFIG.MAX_SPEED, getCharge())	-- Increase launch speed as the staff charges
	local upward = Vector3.new(0, CONFIG.UPWARD_VELOCITY, 0)	-- Keep an upward component on every shot
	local delta = mouse.Hit.Position - origin	-- Direction from origin to mouse position

	if delta.Magnitude < 0.1 then	-- Use the character's facing direction for a nearby target
		return fallback * speed + upward	-- Keep the same speed and upward lift on fallback
	end

	local velocityFactor = 1				-- Initial launch velocity after drag that survived up to this point
	local gravityVelocity = Vector3.zero	-- Velocity contribution from gravity
	local distanceFactor = 0				-- Distance one unit of launch velocity travels by this time
	local gravityDistance = Vector3.zero	-- Distance gravity alone pulled the projectile by this time
	local step = CONFIG.PREVIEW_STEP		

	-- Test flight times until the target can be reached at the charged speed.
	for _ = 1, math.floor(CONFIG.LIFETIME / step) do	-- For every simulation step...
		
		local drag = math.max(0, 1 - CONFIG.DRAG * step)	-- Apply drag 
		local nextFactor = velocityFactor * drag	-- Update the launch velocity contribution
		local nextGravityVelocity = (gravityVelocity + GRAVITY * step) * drag	-- Update gravity's velocity contribution
		local nextDistanceFactor = distanceFactor + (velocityFactor + nextFactor) * 0.5 * step	-- Accumulate launch velocity's distance contribution
		local nextGravityDistance = gravityDistance + (gravityVelocity + nextGravityVelocity) * 0.5 * step	-- Accumulate gravity's distance contribution
		local required = (delta - nextGravityDistance) / nextDistanceFactor - upward	-- Find the aim velocity needed to hit the mouse target

		if required.Magnitude <= speed then	-- Stop at the first flight time that fits the charged speed
			local low = 0
			local high = step
			local aim = required
			
			
			-- Iterate sub steps to narrow down the aim direction
			for _ = 1, CONFIG.ITERATIONS do		-- More iterations = slower but more accurate aim prediction
				local mid = (low + high) * 0.5	-- Midpoint of the current time interval
				local midDrag = math.max(0, 1 - CONFIG.DRAG * mid)
				local midFactor = velocityFactor * midDrag
				local midGravityVelocity = (gravityVelocity + GRAVITY * mid) * midDrag
				
				local a = distanceFactor + (velocityFactor + midFactor) * 0.5 * mid
				local b = gravityDistance + (gravityVelocity + midGravityVelocity) * 0.5 * mid
				
				local candidate = (delta - b) / a - upward	-- Find the aim needed at this midpoint
				if candidate.Magnitude > speed then	-- If too slow...
					low = mid	-- move lower bound up
				else			-- Else if too fast...
					high = mid	-- move upper bound down
					aim = candidate
				end
			end
			return aim.Unit * speed + upward	-- Launch at charged speed using the reachable aim
		end
		
		-- Carry this step's motion factors into the next step
		velocityFactor = nextFactor	
		gravityVelocity = nextGravityVelocity
		distanceFactor = nextDistanceFactor
		gravityDistance = nextGravityDistance
	end

	return fallback * speed + upward	-- Use the fallback direction if the target is out of reach
end

-- Reuse preview parts instead of creating them every frame.
local previewParts: { Part } = {}
local lastPreview = -math.huge	-- Time of the last preview update

-- Hide the trajectory when aiming stops.
local function clearPreview()
	for _, part in previewParts do	-- For each preview segment...
		part.Transparency = 1	-- Make the segment invisible
	end
end

-- Simulate and draw the predicted path using the live motion step.
local function updatePreview(origin: Vector3, launchVelocity: Vector3)
	local position = origin			-- Begin the preview at the held fireball
	local velocity = launchVelocity	-- Start with the calculated launch velocity
	local bounces = 0				-- Count predicted bounces
	local used = 0					-- Count visible preview segments

	for _ = 1, math.floor(CONFIG.PREVIEW_TIME / CONFIG.PREVIEW_STEP) do	-- For each preview step...
		
		-- Calculate the motion of the fireball for this step
		local nextPosition, nextVelocity, hit = stepMotion(position, velocity, fireballRadius, CONFIG.PREVIEW_STEP)	
		
		local length = (nextPosition - position).Magnitude -- Lenght of this step's motion

		if length > 0.001 then	-- Skip steps too short to draw
			used += 1	-- Increment the number of drawn segments
			local part = previewParts[used]	-- Reuse the segment at this path index
			if not part then	-- Create a segment only when the path grows
				part = Instance.new("Part")
				part.Name = "TrajectoryPreview"
				part.Anchored = true
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.Material = Enum.Material.Neon
				part.Color = Color3.fromRGB(0, 0, 255)
				part.Parent = fireballFolder
				previewParts[used] = part
			end
			part.Size = Vector3.new(0.12, 0.12, length)	-- Match the segment to this step's length
			part.CFrame = CFrame.lookAt((position + nextPosition) * 0.5, nextPosition)	-- Place it between the old and new positions
			part.Transparency = 0.25	-- Show the segment
		end

		position = nextPosition	-- Carry over this step's position and velocity for the next step
		velocity = nextVelocity
		
		-- Apply the same bounce limit and reflection as a real fireball.
		if hit then		-- If bounce...
			if bounces >= CONFIG.MAX_BOUNCES then	-- If bounces > limit...
				break	-- Stop preview
			end
			bounces += 1	-- Count this bounce
			velocity = bouncedVelocity(velocity, hit.Normal)	-- Calculate the same bounce as a real fireball
		end
	end


	for i = used + 1, #previewParts do		-- For all unused preview segments...
		previewParts[i].Transparency = 1	-- Hide the preview segment
	end
end

-- Keep the charging fireball and preview aimed from the player's current position.
local function updateHeldFireball(model: Model)
	local root = getRoot()	-- Find the player's root part
	if not root then
		clearPreview()	-- Clear the path when no character root is available
		return
	end

	local position, direction = getFireballPosition(root)		-- Find the held position and direction
	local velocity = getLaunchVelocity(position, direction)		-- Aim with the current charge
	model:PivotTo(CFrame.lookAt(position, position + velocity))	-- Point the held model along its launch velocity

	
	if os.clock() - lastPreview >= 0.1 then -- Refresh the trajectory at most ten times per second
		lastPreview = os.clock()	-- Save the preview update time
		updatePreview(position, velocity)	-- Draw the new path
	end
end


local function stopTracking()
	if trackConnection then	
		trackConnection:Disconnect()	-- Disconnect aim tracking...
		trackConnection = nil			-- and clear the held state
	end

	heldFireball = nil	-- Clear the held model reference
	mouse.TargetFilter = nil	-- Allow the mouse to target the world again
	clearPreview()
end

local function SpawnFireball()
	if heldFireball or not canFire or not getRoot() then	-- Ignore duplicate, cooling-down, or rootless activation
		return
	end

	chargeStart = os.clock()	-- Record when charging began

	updateChargeBar()	-- Update charge bar
	
	-- Show the charge bar
	chargeGui.Enabled = true		
	chargeFill.Visible = true		
	
	cooldownLabel.Visible = false	-- Disable the cooldown display when charging

	local fireball = fireballTemplate:Clone()	-- Make a separate model for this shot

	prepareModel(fireball)	-- Anchor the model and disable physical collisions

	fireball.Name = "FireballInstance"

	mouse.TargetFilter = fireball	-- Keep the held model out of mouse targeting
	heldFireball = fireball			-- Set this fireball as being held

	fireballRadius = CONFIG.MIN_SIZE	-- Start each charge at the minimum size

	fireball:ScaleTo(fireballRadius)	-- Scale the held model to its initial size

	updateHeldFireball(fireball)	-- Place and aim the held model immediately

	fireball.Parent = fireballFolder	-- Put the model with the other fireballs

	-- Grow the held fireball and charge bar while the button is down.
	trackConnection = RunService.Heartbeat:Connect(function()	
		fireballRadius = lerp(CONFIG.MIN_SIZE, CONFIG.MAX_SIZE, getCharge())
		fireball:ScaleTo(fireballRadius)	-- Grow the model to match charge

		updateHeldFireball(fireball)	-- Reposition the model and refresh the charge display
		updateChargeBar()
	end)
end

-- Discard a charge when the staff is unequipped or the character changes.
local function cancelFireball()
	if heldFireball then heldFireball:Destroy() end -- Remove the held model if charging was interrupted

	chargeGui.Enabled = false	-- Hide the charge GUI

	stopTracking()	-- Clear tracking, target filtering, and the preview
end

-- Turn the held model into an active fireball when the button is released.
local function ReleaseFireball()
	local fireball = heldFireball	-- Read the model held during charging
	local primary = fireball and fireball.PrimaryPart

	if not fireball or not primary then	-- Ignore release when there is no usable model
		return
	end

	local root = getRoot()	-- Find the root for a fallback aim direction
	local fallback = getAimDirection(primary.Position, if root then root.CFrame.LookVector else primary.CFrame.LookVector) -- Get a fallback aim direction
	local velocity = getLaunchVelocity(primary.Position, fallback)	-- Calculate launch velocity at the model's current position
	fireball:PivotTo(CFrame.lookAt(primary.Position, primary.Position + velocity))	-- Face the model along its launch direction

	-- Add the released model to the physics update list.
	table.insert(activeFireballs, Fireball.new( fireball, primary.Position, velocity))

	stopTracking()	-- Stop following the mouse after release

	-- Start cooldown
	canFire = false
	cooldownEnd = os.clock() + CONFIG.COOLDOWN

	-- Keep GUI enabled so the cooldown can be seen.
	chargeGui.Enabled = true
	chargeFill.Visible = false
	cooldownLabel.Visible = true
	
	
	task.delay(CONFIG.COOLDOWN, function()	
		canFire = true					-- Reset after cooldown
		cooldownLabel.Visible = false	
		chargeGui.Enabled = false
	end)
end

-- Main physics heartbeat function
RunService.Heartbeat:Connect(function(dt: number)
	

	for i = #activeFireballs, 1, -1 do		-- For all fireballs (backwards so it doesn't delete new fireballs)...
		local fireball = activeFireballs[i]

		if fireball.Alive then	
			fireball:Step(dt)	-- Advance each living fireball
		else
			table.remove(activeFireballs, i)	-- Remove destroyed fireballs from the list
		end
	end

	
	if not canFire then
		local remaining = math.max(0, cooldownEnd - os.clock()) -- Remaining cooldown time

		cooldownLabel.Text = string.format("%.2f", remaining) -- Show remaining cooldown on GUI
	end
end)


local function giveStaff()
	local staff = staffTemplate:Clone()	-- Clone the staff template for this player

	staff.Activated:Connect(SpawnFireball)	-- Charge on activation (LMB)...
	staff.Deactivated:Connect(ReleaseFireball)	-- fire on release
	staff.Unequipped:Connect(cancelFireball)	-- Cancel an unfinished charge when unequipped

	staff.Parent = player:WaitForChild("Backpack") -- Put staff in player backpack
end

refreshRayFilter()	-- Initialize the collision filter
giveStaff()	-- Give the initial staff

player.CharacterAdded:Connect(function() -- When player respawns...
	cancelFireball()	-- Cancel a charge from the previous character
	refreshRayFilter()	-- Exclude the new character from fireball casts
	giveStaff()	-- Give the respawned character a staff
end)
