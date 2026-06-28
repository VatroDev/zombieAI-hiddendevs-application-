-- Connected Discord-GitHub  -- Your Discord + GitHub linked (mandatory)

-- Main zombie AI controller script for Hidden Devs application
-- This entire script is designed as a single sophisticated Luau file

local PathfindingService = game:GetService("PathfindingService")  -- Get pathfinding service for intelligent movement
local RepStorage = game:GetService("ReplicatedStorage")  -- Access replicated config data
local ServerScriptService = game:GetService("ServerScriptService")  -- Access server-side factory

local DEBUG_MODE = false  -- Debug flag for logging during testing
local rng = Random.new()  -- Random object for natural variation in behavior

local ZombieConfig = require(RepStorage.ZombieConfig)  -- Load balance/config data
local ZombieFactory = require(ServerScriptService.Systems.ZombieFactory)  -- Factory to spawn new zombies on death

local ZOMBIE_TYPE = "Normal"  -- Current zombie variant (can be extended)
local currentStats = ZombieConfig[ZOMBIE_TYPE]  -- Fetch stats for this type

if not currentStats then  -- Safety check for invalid config
	warn("Invalid zombie type:", ZOMBIE_TYPE)
	return
end

local zombie = script.Parent  -- The zombie model this script is parented to

-- Helper function to support both R6 and R15 rigs
local function getRootPart(model)
	return model:FindFirstChild("HumanoidRootPart")  -- Primary for R15
		or model:FindFirstChild("Torso")  -- Fallback for R6
		or model:FindFirstChild("UpperTorso")  -- Another R15 variant
end

local zombieRoot = getRootPart(zombie)  -- Cache root part reference
local zombieHumanoid = zombie:FindFirstChild("Humanoid")  -- Cache Humanoid for health/speed control

if not zombieRoot or not zombieHumanoid then  -- Critical component check
	warn("Zombie is missing root part or humanoid")
	return
end

zombieHumanoid.MaxHealth = currentStats.Health  -- Set max health from config
zombieHumanoid.Health = currentStats.Health  -- Initialize current health
zombieHumanoid.WalkSpeed = currentStats.WalkSpeed  -- Apply movement speed
zombie.Name = currentStats.DisplayName  -- Set model name
zombieHumanoid.DisplayName = currentStats.DisplayName  -- Set overhead name

-- Scale body parts + adjust Motor6D joints so limbs stay attached
local SCALE = currentStats.Size  -- Scaling factor from config
local BODY_PARTS = { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }  -- Parts to scale
local scaledParts = {}  -- Track which parts were scaled for joint adjustment

for _, partName in ipairs(BODY_PARTS) do  -- Loop through body parts
	local part = zombie:FindFirstChild(partName)  -- Find each part
	if part and part:IsA("BasePart") then  -- Only scale valid BaseParts
		part.Size = part.Size * SCALE  -- Apply uniform scale
		scaledParts[part] = true  -- Mark as scaled
	end
end

for _, motor in ipairs(zombie:GetDescendants()) do  -- Find all Motor6D joints
	if motor:IsA("Motor6D") then  -- Only process Motor6D instances
		if scaledParts[motor.Part0] then  -- Adjust C0 if parent part scaled
			local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = motor.C0:GetComponents()  -- Decompose CFrame
			motor.C0 = CFrame.new(x * SCALE, y * SCALE, z * SCALE, r00, r01, r02, r10, r11, r12, r20, r21, r22)  -- Rebuild scaled CFrame
		end
		if scaledParts[motor.Part1] then  -- Adjust C1 if child part scaled
			local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = motor.C1:GetComponents()
			motor.C1 = CFrame.new(x * SCALE, y * SCALE, z * SCALE, r00, r01, r02, r10, r11, r12, r20, r21, r22)
		end
	end
end

local attackTrack  -- Will hold loaded attack animation
local attackSound  -- Will hold attack sound instance

local animator = zombieHumanoid:FindFirstChildOfClass("Animator")  -- Get animator for playing animations
if animator then  -- Only setup if Animator exists
	local attackAnim = Instance.new("Animation")  -- Create animation instance
	attackAnim.AnimationId = currentStats.AttackAnimId  -- Set animation ID from config
	attackTrack = animator:LoadAnimation(attackAnim)  -- Load animation track
	
	attackSound = Instance.new("Sound", zombieRoot)  -- Create attack sound
	attackSound.SoundId = currentStats.AttackSoundId  -- Assign sound ID
	
	local groanSound = Instance.new("Sound", zombieRoot)  -- Background groan
	groanSound.SoundId = currentStats.GroanSoundId
	groanSound.Looped = true  -- Make it loop
	groanSound.Volume = 0.5  -- Moderate volume
	groanSound:Play()  -- Start groaning immediately
end

-- Stats table with metatable for default 0 values (clean tracking)
local Stats = setmetatable({}, {
	__index = function(_, _) return 0 end  -- Default any missing stat to 0
})

local spawnTime = tick()  -- Record spawn time for lifetime tracking

local function debugLog(...)  -- Conditional debug function
	if DEBUG_MODE then print(...) end  -- Only prints in debug mode
end

-- Finds closest player with line-of-sight check
local function findTarget()
	local closest = 100  -- Initial large distance
	local target = nil  -- Current best target
	local rayParams = RaycastParams.new()  -- Setup raycast parameters
	rayParams.FilterType = Enum.RaycastFilterType.Blacklist  -- Ignore certain objects
	rayParams.FilterDescendantsInstances = { zombie }  -- Ignore self

	for _, player in ipairs(game.Players:GetPlayers()) do  -- Iterate all players
		local char = player.Character  -- Get character
		if not char then continue end  -- Skip if no character
		
		local human = char:FindFirstChild("Humanoid")  -- Get humanoid
		local root = getRootPart(char)  -- Get root part
		if not human or not root or human.Health <= 0 then continue end  -- Skip invalid targets
		
		local distance = (zombieRoot.Position - root.Position).Magnitude  -- Calculate distance
		
		if distance < closest then  -- Closer than current best
			local origin = zombieRoot.Position  -- Ray start
			local direction = (root.Position - origin).Unit * distance  -- Ray direction
			local result = workspace:Raycast(origin, direction, rayParams)  -- Perform LOS check
			
			if not result or result.Instance:IsDescendantOf(char) then  -- Clear line of sight
				closest = distance  -- Update best distance
				target = root  -- Update best target
			end
		end
	end
	return target  -- Return closest valid target or nil
end

local DAMAGE_AMOUNT = currentStats.Damage  -- Damage per hit
local ATTACK_COOLDOWN = currentStats.AttackCooldown  -- Time between attacks
local lastAttackTime = 0  -- Track last attack timestamp

-- Handles melee attack on touch
local function onTouched(hit)
	local character = hit.Parent  -- Get hit parent
	if character == zombie then return end  -- Prevent self damage
	
	local humanoid = character:FindFirstChild("Humanoid")  -- Check for humanoid
	if not humanoid then return end  -- No humanoid = no damage
	
	if not game.Players:GetPlayerFromCharacter(character) then return end  -- Only damage players
	
	local now = tick()  -- Current time
	if now - lastAttackTime < ATTACK_COOLDOWN then return end  -- Respect cooldown
	
	lastAttackTime = now  -- Update last attack time
	
	-- Delayed attack for more natural feel
	task.delay(rng:NextNumber(0.1, 0.3), function()
		if not zombieRoot or not zombieRoot.Parent then return end  -- Validate zombie still exists
		if not humanoid or not humanoid.Parent then return end  -- Validate target still exists
		
		if attackTrack and attackSound then  -- Play effects if available
			attackTrack:Play()
			attackSound:Play()
		end
		
		local healthBefore = humanoid.Health  -- Record health before hit
		humanoid:TakeDamage(DAMAGE_AMOUNT)  -- Apply damage
		Stats.HitsLanded += 1  -- Track stats
		Stats.DamageDealt += DAMAGE_AMOUNT
		
		if humanoid.Health <= 0 and healthBefore > 0 then  -- Check for kill
			Stats.Kills += 1
			debugLog(character.Name, "got taken out by the zombie!")
		end
	end)
end

zombieRoot.Touched:Connect(onTouched)  -- Connect touch event

-- Handle zombie death
zombieHumanoid.Died:Connect(function()
	Stats.Deaths += 1  -- Increment death stat
	Stats.TimeAlive = tick() - spawnTime  -- Calculate lifetime
	
	-- Log final stats for debugging
	debugLog("--- Zombie Stats ---")
	debugLog("Time Alive:", string.format("%.2f", Stats.TimeAlive) .. "s")
	debugLog("Kills:", Stats.Kills)
	debugLog("Hits:", Stats.HitsLanded)
	debugLog("Damage:", Stats.DamageDealt)
	debugLog("Chases:", Stats.ChasesStarted)
	debugLog("Wanders:", Stats.TimesWandered)
	debugLog("--------------------")
	
	task.wait(5)  -- Brief delay before respawn
	ZombieFactory.Spawn(ZOMBIE_TYPE)  -- Delegate new spawn
	zombie:Destroy()  -- Cleanup this zombie
end)

-- Pathfinding helper function
local function pathfindTo(destination)
	local path = PathfindingService:CreatePath()  -- Create new path object
	path:ComputeAsync(zombieRoot.Position, destination)  -- Compute path
	
	if path.Status == Enum.PathStatus.Success then  -- Valid path found
		zombieHumanoid:MoveTo(destination)  -- Move to target
		for _, wp in ipairs(path:GetWaypoints()) do  -- Check for jump waypoints
			if wp.Action == Enum.PathWaypointAction.Jump then
				zombieHumanoid.Jump = true  -- Trigger jump
				break
			end
		end
	else
		zombieHumanoid:MoveTo(destination)  -- Fallback direct move
	end
end

-- Wander settings
local WANDER_RADIUS = 50  -- How far to wander
local WANDER_INTERVAL = 2  -- Time between wanders when idle
local PATH_UPDATE_THRESHOLD = 5  -- Distance threshold for path recompute

local lastWanderTime = 0  -- Last wander timestamp
local lastTargetPos = nil  -- Last known target position

-- Main AI loop
while task.wait(0.1) do  -- Run at ~10Hz for smooth but efficient updates
	if not zombie.Parent or zombieHumanoid.Health <= 0 then  -- Exit if destroyed or dead
		break
	end
	
	local targetRoot = findTarget()  -- Attempt to find target
	
	if targetRoot then  -- Target acquired
		local targetPos = targetRoot.Position  -- Get position
		
		-- Only update path if target moved enough (optimization)
		if not lastTargetPos or (targetPos - lastTargetPos).Magnitude >= PATH_UPDATE_THRESHOLD then
			pathfindTo(targetPos)
			lastTargetPos = targetPos  -- Cache position
			Stats.ChasesStarted += 1  -- Track chase
		end
		lastWanderTime = tick()  -- Reset wander timer
	else
		-- No target - wander behavior
		if tick() - lastWanderTime > WANDER_INTERVAL then
			lastWanderTime = tick()
			Stats.TimesWandered += 1
			
			local angle = rng:NextNumber() * 2 * math.pi  -- Random direction
			local offset = Vector3.new(  -- Calculate random offset
				WANDER_RADIUS * math.cos(angle),
				0,
				WANDER_RADIUS * math.sin(angle)
			)
			zombieHumanoid:MoveTo(zombieRoot.Position + offset)  -- Wander to point
		end
	end
end