--- made by navet
--[[
  Player Prediction Library
  25/10/2025 (DD/MM/YYYY)

  This is mostly a conversion from TF2's spaghetti code to Lua
]]

---@alias water_level integer

local E_WaterLevel = {
	WL_NotInWater = 0,
	WL_Feet = 1,
	WL_Waist = 2,
	WL_Eyes = 3,
}

--- Why is this not in the lua docs?
local RuneTypes_t = {
	RUNE_NONE = -1,
	RUNE_STRENGTH = 0,
	RUNE_HASTE = 1,
	RUNE_REGEN = 2,
	RUNE_RESIST = 3,
	RUNE_VAMPIRE = 4,
	RUNE_REFLECT = 5,
	RUNE_PRECISION = 6,
	RUNE_AGILITY = 7,
	RUNE_KNOCKOUT = 8,
	RUNE_KING = 9,
	RUNE_PLAGUE = 10,
	RUNE_SUPERNOVA = 11,
}

local COORD_FRACTIONAL_BITS = 5
local COORD_DENOMINATOR = (1 << COORD_FRACTIONAL_BITS)
local COORD_RESOLUTION = (1.0 / COORD_DENOMINATOR)

local MAX_CLIP_PLANES = 5
local DIST_EPSILON = 0.03125

local clip_planes = {}
for i = 1, MAX_CLIP_PLANES do
	clip_planes[i] = Vector3()
end

---@param text string
local function DebugPrint(text, ...)
	client.ChatPrintf(string.format(text, ...))
end

local function CheckGroundAndCategorize(origin, velocity, mins, maxs, index)
    local down = Vector3(origin.x, origin.y, origin.z - 18)
    local trace = engine.TraceHull(origin, down, mins, maxs, MASK_PLAYERSOLID, function(ent, contentsMask)
        return ent:GetIndex() ~= index
    end)
    
    local is_on_ground = trace and trace.fraction < 1.0 and not trace.startsolid and trace.plane and trace.plane.z >= 0.7
    local ground_normal = is_on_ground and Vector3(trace.plane.x, trace.plane.y, trace.plane.z) or nil
    
    return is_on_ground, ground_normal, 1.0
end

--- Returns the current water level and the velocity if there is any water current
---@param origin Vector3
---@param mins Vector3
---@param maxs Vector3
---@param viewOffset Vector3
---@return integer, Vector3
local function GetWaterLevel(mins, maxs, origin, viewOffset)
	local point = Vector3()
	local cont = 0

	---@type water_level
	local waterlevel = 0

	local v = Vector3()

	point = origin + (mins + maxs) * 0.5
	point.z = origin.z + mins.z + 1

	cont = engine.GetPointContents(point, 0)

	if (cont & MASK_WATER) ~= 0 then
		waterlevel = E_WaterLevel.WL_Feet

		point.z = origin.z + (mins.z + maxs.z) * 0.5
		cont = engine.GetPointContents(point, 1)
		if (cont & MASK_WATER) ~= 0 then
			waterlevel = E_WaterLevel.WL_Waist
			point.z = origin.z + viewOffset.z
			if (cont & MASK_WATER) ~= 0 then
				waterlevel = E_WaterLevel.WL_Eyes
			end
		end

		if (cont & MASK_CURRENT) ~= 0 then
			if (cont & CONTENTS_CURRENT_0) ~= 0 then
				v.x = v.x + 1
			end
			if (cont & CONTENTS_CURRENT_90) ~= 0 then
				v.y = v.y + 1
			end
			if (cont & CONTENTS_CURRENT_180) ~= 0 then
				v.x = v.x - 1
			end
			if (cont & CONTENTS_CURRENT_270) ~= 0 then
				v.y = v.y - 1
			end
			if (cont & CONTENTS_CURRENT_UP) ~= 0 then
				v.z = v.z + 1
			end
			if (cont & CONTENTS_CURRENT_DOWN) ~= 0 then
				v.z = v.z - 1
			end
		end
	end

	return waterlevel, v
end

local function GetCurrentGravity()
	
end

---@param velocity Vector3
local function CheckVelocity(velocity)
	local _, sv_maxvelocity = client.GetConVar("sv_maxvelocity")
	if velocity.x > sv_maxvelocity then
		velocity.x = sv_maxvelocity
	end

	if velocity.y > sv_maxvelocity then
		velocity.y = sv_maxvelocity
	end

	if velocity.z > sv_maxvelocity then
		velocity.z = sv_maxvelocity
	end

	if velocity.x < -sv_maxvelocity then
		velocity.x = -sv_maxvelocity
	end

	if velocity.y < -sv_maxvelocity then
		velocity.y = -sv_maxvelocity
	end

	if velocity.z < -sv_maxvelocity then
		velocity.z = -sv_maxvelocity
	end
end

local function CheckIsOnGround(origin, mins, maxs, index)
	local down = Vector3(origin.x, origin.y, origin.z - 18)
	local trace = engine.TraceHull(origin, down, mins, maxs, MASK_PLAYERSOLID, function(ent, contentsMask)
		return ent:GetIndex() ~= index
	end)

	return trace and trace.fraction < 1.0 and not trace.startsolid and trace.plane and trace.plane.z >= 0.7
end

---@param velocity Vector3
---@param is_on_ground boolean
---@param frametime number
local function Friction(velocity, is_on_ground, frametime)
	local speed, newspeed, control, friction, drop
	speed = velocity:LengthSqr()
	if speed < 0.01 then
		return
	end

	local _, sv_stopspeed = client.GetConVar("sv_stopspeed")
	drop = 0

	if is_on_ground then
		local _, sv_friction = client.GetConVar("sv_friction")
		friction = sv_friction

		control = speed < sv_stopspeed and sv_stopspeed or speed
		drop = drop + control * friction * frametime
	end

	newspeed = speed - drop
	if newspeed ~= speed then
		newspeed = newspeed / speed
		--velocity = velocity * newspeed
		velocity.x = velocity.x * newspeed
		velocity.y = velocity.y * newspeed
		velocity.z = velocity.z * newspeed
	end
end

---@param index integer
local function StayOnGround(origin, mins, maxs, step_size, index)
	local vstart = Vector3(origin.x, origin.y, origin.z + 2)
	local vend = Vector3(origin.x, origin.y, origin.z - step_size)

	local trace = engine.TraceHull(vstart, vend, mins, maxs, MASK_PLAYERSOLID, function(ent, contentsMask)
		return ent:GetIndex() ~= index
	end)

	if trace and trace.fraction < 1.0 and not trace.startsolid and trace.plane and trace.plane.z >= 0.7 then
		local delta = math.abs(origin.z - trace.endpos.z)
		if delta > (0.5 * COORD_RESOLUTION) then
			origin.x = trace.endpos.x
			origin.y = trace.endpos.y
			origin.z = trace.endpos.z
			return true
		end
	end

	return false
end

---@param velocity Vector3
---@param wishdir Vector3
---@param wishspeed number
---@param accel number
---@param frametime number
local function Accelerate(velocity, wishdir, wishspeed, accel, frametime)
	local addspeed, accelspeed, currentspeed

	currentspeed = velocity:Dot(wishdir)
	addspeed = wishspeed - currentspeed

	if addspeed <= 0 then
		return
	end

	accelspeed = accel * frametime * wishspeed
	if accelspeed > addspeed then
		accelspeed = addspeed
	end

	--print(string.format("Velocity: %s, accelspeed: %s, wishdir: %s", velocity, accelspeed, wishdir))
	velocity.x = velocity.x + wishdir.x * accelspeed
	velocity.y = velocity.y + wishdir.y * accelspeed
	velocity.z = velocity.z + wishdir.z * accelspeed
end

local function ClipVelocity(velocity, normal, overbounce)
	local backoff = velocity.x * normal.x + velocity.y * normal.y + velocity.z * normal.z
	backoff = (backoff < 0) and (backoff * overbounce) or (backoff / overbounce)
	velocity.x = velocity.x - normal.x * backoff
	velocity.y = velocity.y - normal.y * backoff
	velocity.z = velocity.z - normal.z * backoff
end

-- Try to push origin out of solid by stepping upward up to max_up.
-- Returns true if origin was modified (moved), false otherwise.
local function ResolveStartSolid(origin, mins, maxs, shouldHitEntity, max_up)
	max_up = max_up or 18.0
	local test_up = Vector3(origin.x, origin.y, origin.z + max_up)
	-- Trace from origin upward to try to escape
	local tr_up = engine.TraceHull(origin, test_up, mins, maxs, MASK_PLAYERSOLID, shouldHitEntity)
	-- If allsolid, we are boxed in — give up
	if tr_up and tr_up.allsolid then
		return false
	end
	-- If fraction > 0 we can move to safe endpos
	if tr_up and tr_up.fraction > 0 and not tr_up.startsolid then
		origin.x, origin.y, origin.z = tr_up.endpos.x, tr_up.endpos.y, tr_up.endpos.z
		return true
	end
	-- If startsolid but endpos exists, also move (some engines set startsolid differently)
	if tr_up and tr_up.endpos then
		origin.x, origin.y, origin.z = tr_up.endpos.x, tr_up.endpos.y, tr_up.endpos.z
		return true
	end
	return false
end

local function TryPlayerMove(origin, velocity, frametime, mins, maxs, shouldHitEntity, surface_friction)
	local time_left = frametime
	local numplanes = 0
	local end_pos = Vector3()
	local dir = Vector3()

	-- Early exit for stationary velocity
	local vel_length_sq = velocity.x * velocity.x + velocity.y * velocity.y + velocity.z * velocity.z
	if vel_length_sq < 0.0001 then
		return
	end

	for bumpcount = 0, 3 do
		-- Check if we should continue
		vel_length_sq = velocity.x * velocity.x + velocity.y * velocity.y + velocity.z * velocity.z
		if vel_length_sq < 0.0001 then
			break
		end

		-- Calculate destination
		end_pos.x = origin.x + velocity.x * time_left
		end_pos.y = origin.y + velocity.y * time_left
		end_pos.z = origin.z + velocity.z * time_left

		-- Trace to destination
		local trace = engine.TraceHull(origin, end_pos, mins, maxs, MASK_PLAYERSOLID, shouldHitEntity)

		-- Handle allsolid - completely stuck
		if trace.allsolid then
			velocity.x, velocity.y, velocity.z = 0, 0, 0
			return
		end

		-- Handle startsolid - try to escape upward
		if trace.startsolid then
			local nudge_z = origin.z + 18 + DIST_EPSILON
			local nudge_up = Vector3(origin.x, origin.y, nudge_z)
			local nudge_tr = engine.TraceHull(origin, nudge_up, mins, maxs, MASK_PLAYERSOLID, shouldHitEntity)
			
			if nudge_tr and not nudge_tr.allsolid and nudge_tr.fraction > 0 then
				-- Successfully escaped, update position and retry this iteration
				origin.x, origin.y, origin.z = nudge_tr.endpos.x, nudge_tr.endpos.y, nudge_tr.endpos.z
				-- Don't increment bumpcount, retry with same iteration
				bumpcount = bumpcount - 1
			else
				-- Can't escape, stop
				velocity.x, velocity.y, velocity.z = 0, 0, 0
				return
			end
		else
			-- Normal movement - update position if we moved
			if trace.fraction > 0 then
				origin.x, origin.y, origin.z = trace.endpos.x, trace.endpos.y, trace.endpos.z
			end

			-- Check if we completed the move
			if trace.fraction >= 0.99 then
				break
			end

			-- Update time remaining
			time_left = time_left * (1 - trace.fraction)

			-- Check if we have too many planes
			if numplanes >= MAX_CLIP_PLANES then
				velocity.x, velocity.y, velocity.z = 0, 0, 0
				return
			end

			-- Store the new plane normal
			local plane = clip_planes[numplanes + 1]
			plane.x, plane.y, plane.z = trace.plane.x, trace.plane.y, trace.plane.z
			numplanes = numplanes + 1

			-- Calculate overbounce based on surface angle
			local overbounce = (plane.z > 0.7) and 1.0 or 1.5

			-- Clip velocity against the new plane
			local backoff = velocity.x * plane.x + velocity.y * plane.y + velocity.z * plane.z
			backoff = (backoff < 0) and (backoff * overbounce) or (backoff / overbounce)
			velocity.x = velocity.x - plane.x * backoff
			velocity.y = velocity.y - plane.y * backoff
			velocity.z = velocity.z - plane.z * backoff

			-- Check if velocity is valid against all stored planes
			-- This prevents moving into corners
			local needs_crease_handling = false
			for i = 1, numplanes do
				local dot = velocity.x * clip_planes[i].x + 
				           velocity.y * clip_planes[i].y + 
				           velocity.z * clip_planes[i].z
				if dot < 0 then
					needs_crease_handling = true
					break
				end
			end

			-- Handle crease (corner) collision with two planes
			if needs_crease_handling and numplanes >= 2 then
				-- Calculate crease direction (cross product of last two planes)
				local p1 = clip_planes[numplanes - 1]
				local p2 = clip_planes[numplanes]
				
				dir.x = p1.y * p2.z - p1.z * p2.y
				dir.y = p1.z * p2.x - p1.x * p2.z
				dir.z = p1.x * p2.y - p1.y * p2.x

				-- Normalize the crease direction
				local dir_length_sq = dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
				
				if dir_length_sq > 0.0001 then
					local inv_length = 1.0 / math.sqrt(dir_length_sq)
					dir.x = dir.x * inv_length
					dir.y = dir.y * inv_length
					dir.z = dir.z * inv_length
					
					-- Project velocity onto crease direction
					local scalar = velocity.x * dir.x + velocity.y * dir.y + velocity.z * dir.z
					velocity.x = dir.x * scalar
					velocity.y = dir.y * scalar
					velocity.z = dir.z * scalar
				else
					-- Degenerate crease, stop movement
					velocity.x, velocity.y, velocity.z = 0, 0, 0
					return
				end
			end
		end
	end
end

--[[local function StepMove(
	origin,
	velocity,
	frametime,
	mins,
	maxs,
	shouldHitEntity,
	surface_friction,
	step_size,
	is_on_ground
)
	local orig_x, orig_y, orig_z = origin.x, origin.y, origin.z
	local orig_vx, orig_vy, orig_vz = velocity.x, velocity.y, velocity.z

	local temp_vec1 = Vector3()

	-- Try regular move first
	TryPlayerMove(origin, velocity, frametime, mins, maxs, shouldHitEntity, surface_friction)

	local down_dist = (origin.x - orig_x) + (origin.y - orig_y)

	if not is_on_ground or down_dist > 5.0 or (orig_vx * orig_vx + orig_vy * orig_vy) < 1.0 then
		return
	end

	local down_x, down_y, down_z = origin.x, origin.y, origin.z
	local down_vx, down_vy, down_vz = velocity.x, velocity.y, velocity.z

	-- reset and try step up
	origin.x, origin.y, origin.z = orig_x, orig_y, orig_z
	velocity.x, velocity.y, velocity.z = orig_vx, orig_vy, orig_vz

	-- step up
	temp_vec1.x, temp_vec1.y, temp_vec1.z = origin.x, origin.y, origin.z + step_size + DIST_EPSILON
	local up_trace = engine.TraceHull(origin, temp_vec1, mins, maxs, MASK_PLAYERSOLID, shouldHitEntity)

	if not up_trace.startsolid and not up_trace.allsolid then
		origin.x, origin.y, origin.z = up_trace.endpos.x, up_trace.endpos.y, up_trace.endpos.z
	end

	-- move forward
	local up_orig_x, up_orig_y = origin.x, origin.y
	TryPlayerMove(origin, velocity, frametime, mins, maxs, shouldHitEntity, surface_friction)

	local up_dist = (origin.x - up_orig_x) + (origin.y - up_orig_y)

	-- if stepping up didn't help, revert to original result
	if up_dist <= down_dist then
		origin.x, origin.y, origin.z = down_x, down_y, down_z
		velocity.x, velocity.y, velocity.z = down_vx, down_vy, down_vz
		return
	end

	-- step down to ground
	temp_vec1.x, temp_vec1.y = origin.x, origin.y
	temp_vec1.z = origin.z - step_size - DIST_EPSILON
	local down_trace = engine.TraceHull(origin, temp_vec1, mins, maxs, MASK_PLAYERSOLID, shouldHitEntity)

	if down_trace.plane.z >= 0.7 and not down_trace.startsolid and not down_trace.allsolid then
		origin.x, origin.y, origin.z = down_trace.endpos.x, down_trace.endpos.y, down_trace.endpos.z
	end
end]]

local function StepMove(
	origin,
	velocity,
	frametime,
	mins,
	maxs,
	shouldHitEntity,
	surface_friction,
	step_size,
	is_on_ground
)
	local orig_pos = Vector3(origin.x, origin.y, origin.z)
	local orig_vel = Vector3(velocity.x, velocity.y, velocity.z)

	-- Try moving normally
	local start_pos = Vector3(origin.x, origin.y, origin.z)
	TryPlayerMove(origin, velocity, frametime, mins, maxs, shouldHitEntity, surface_friction)
	local ground_pos = Vector3(origin.x, origin.y, origin.z)
	local ground_vel = Vector3(velocity.x, velocity.y, velocity.z)

	local down_dist = (ground_pos - start_pos):Length2D()

	-- Reset to start position and velocity
	origin.x, origin.y, origin.z = orig_pos:Unpack()
	velocity.x, velocity.y, velocity.z = orig_vel:Unpack()

	-- Step up
	local up_pos = Vector3(origin.x, origin.y, origin.z + step_size + DIST_EPSILON)
	local up_trace = engine.TraceHull(origin, up_pos, mins, maxs, MASK_PLAYERSOLID, shouldHitEntity)

	--DebugPrint("StepMove: %s", up_trace.fraction)

	if up_trace.allsolid then
		return -- Can't step up, ceiling
	end

	-- Move to top of step
	if up_trace.fraction > 0 then
		origin.x, origin.y, origin.z = up_trace.endpos:Unpack()
	end

	-- Move forward from raised position
	TryPlayerMove(origin, velocity, frametime, mins, maxs, shouldHitEntity, surface_friction)
	local step_up_end = Vector3(origin.x, origin.y, origin.z)

	-- Step down to ground
	local down_end = Vector3(step_up_end.x, step_up_end.y, step_up_end.z - step_size - DIST_EPSILON)
	local down_trace = engine.TraceHull(step_up_end, down_end, mins, maxs, MASK_PLAYERSOLID, shouldHitEntity)

	if not down_trace.startsolid and down_trace.fraction < 1.0 and down_trace.plane and down_trace.plane.z >= 0.7 then
		origin.x, origin.y, origin.z = down_trace.endpos:Unpack()
	end

	local step_up_dist = (origin - orig_pos):Length2D()

	-- Only accept step-up if we moved further horizontally
	if step_up_dist <= down_dist then
		-- revert to original ground move
		origin.x, origin.y, origin.z = ground_pos.x, ground_pos.y, ground_pos.z
		velocity.x, velocity.y, velocity.z = ground_vel.x, ground_vel.y, ground_vel.z
	end
end

---@param velocity Vector3
---@param origin Vector3
---@param mins Vector3
---@param maxs Vector3
---@param step_size number
---@param frametime number
---@param index integer
local function WalkMove(velocity, origin, mins, maxs, step_size, frametime, index, maxspeed)
	local wishdir = Vector3()
	local wishspeed

	-- Infer desired movement direction from current velocity
	local speed2d = velocity:Length2D()
	if speed2d < 0.001 then
		return
	end
	wishdir.x = velocity.x / speed2d
	wishdir.y = velocity.y / speed2d
	wishdir.z = 0
	wishspeed = maxspeed

	-- Clamp to server-defined max speed
	local _, sv_maxspeed = client.GetConVar("sv_maxspeed")
	if wishspeed > sv_maxspeed then
		wishspeed = sv_maxspeed
	end

	-- Zero out vertical velocity before acceleration
	velocity.z = 0

	local _, accel = client.GetConVar("sv_accelerate")
	Accelerate(velocity, wishdir, wishspeed, accel, frametime)
	velocity.z = 0

	local spd = velocity:Length()
	if spd < 1.0 then
		return
	end

	-- Attempt to move to destination
	local dest = Vector3(origin.x + velocity.x * frametime, origin.y + velocity.y * frametime, origin.z)

	local trace = engine.TraceHull(origin, dest, mins, maxs, MASK_PLAYERSOLID, function(ent, contentsMask)
		return ent:GetIndex() ~= index
	end)

	if trace.fraction == 1.0 then
		-- Full unobstructed move
		origin.x, origin.y, origin.z = trace.endpos.x, trace.endpos.y, trace.endpos.z
		StayOnGround(origin, mins, maxs, step_size, index)
	end

	-- Stop if airborne
	local is_on_ground = CheckIsOnGround(origin, mins, maxs)
	if not is_on_ground then
		return
	end

	-- Try step move if blocked
	if trace.fraction < 1.0 then
		StepMove(origin, velocity, frametime, mins, maxs, function(ent, contentsMask)
			return ent:GetIndex() ~= index
		end, 1.0, step_size, is_on_ground)
	end

	--StayOnGround(origin, mins, maxs, step_size, index)
end

---@param target Entity
---@return number
local function GetAirSpeedCap(target)
	local m_hGrapplingHookTarget = target:GetPropEntity("m_hGrapplingHookTarget")
	if m_hGrapplingHookTarget then
		if target:GetCarryingRuneType() == RuneTypes_t.RUNE_AGILITY then
			local m_iClass = target:GetPropInt("m_iClass")
			return (m_iClass == E_Character.TF2_Soldier or E_Character.TF2_Heavy) and 850 or 950
		end
		local _, tf_grapplinghook_move_speed = client.GetConVar("tf_grapplinghook_move_speed")
		return tf_grapplinghook_move_speed
	elseif target:InCond(E_TFCOND.TFCond_Charging) then
		local _, tf_max_charge_speed = client.GetConVar("tf_max_charge_speed")
		return tf_max_charge_speed
	else
		local flCap = 30.0
		if target:InCond(E_TFCOND.TFCond_ParachuteDeployed) then
			local _, tf_parachute_aircontrol = client.GetConVar("tf_parachute_aircontrol")
			flCap = flCap * tf_parachute_aircontrol
		end
		if target:InCond(E_TFCOND.TFCond_HalloweenKart) then
			if target:InCond(E_TFCOND.TFCond_HalloweenKartDash) then
				local _, tf_halloween_kart_dash_speed = client.GetConVar("tf_halloween_kart_dash_speed")
				return tf_halloween_kart_dash_speed
			end
			local _, tf_hallowen_kart_aircontrol = client.GetConVar("tf_hallowen_kart_aircontrol")
			flCap = flCap * tf_hallowen_kart_aircontrol
		end
		return flCap * target:AttributeHookFloat("mod_air_control")
	end
end

---@param v Vector3 Velocity
---@param wishdir Vector3
---@param wishspeed number
---@param accel number
---@param dt number globals.TickInterval()
---@param surf number Is currently surfing?
---@param target Entity
local function AirAccelerate(v, wishdir, wishspeed, accel, dt, surf, target)
	wishspeed = math.min(wishspeed, GetAirSpeedCap(target))
	local currentspeed = v:Dot(wishdir)
	local addspeed = wishspeed - currentspeed
	if addspeed <= 0 then
		return
	end

	local accelspeed = math.min(accel * wishspeed * dt * surf, addspeed)
	v.x = v.x + accelspeed * wishdir.x
	v.y = v.y + accelspeed * wishdir.y
	v.z = v.z + accelspeed * wishdir.z
end

---@param pos Vector3
---@param vel Vector3
---@param mins Vector3
---@param maxs Vector3
---@param shouldHitEntity fun(ent: Entity, contentsMask: integer): boolean
local function CategorizePosition(pos, vel, mins, maxs, shouldHitEntity)
	local down = Vector3(pos.x, pos.y, pos.z - 18)
	local is_on_ground = false
	local ground_normal = nil
	local surface_friction = 1.0

	if vel.z <= 180.0 then
		local trace = engine.TraceHull(pos, down, mins, maxs, MASK_PLAYERSOLID, shouldHitEntity)
		if trace and trace.fraction < 1.0 and trace.plane and trace.plane.z >= 0.7 then
			is_on_ground = true
			ground_normal = Vector3(trace.plane.x, trace.plane.y, trace.plane.z)
		end
	end

	return is_on_ground, ground_normal, surface_friction
end

---@param velocity Vector3
---@param origin Vector3
---@param mins Vector3
---@param maxs Vector3
---@param frametime number
---@param player Entity
---@param index integer
local function AirMove(velocity, origin, mins, maxs, frametime, player, index)
	local wishdir = Vector3()
	local wishspeed

	local speed2d = velocity:Length2D()
	if speed2d < 0.001 then
		return
	end

	wishdir.x = velocity.x / speed2d
	wishdir.y = velocity.y / speed2d
	wishdir.z = 0
	wishspeed = speed2d

	local _, maxspeed = client.GetConVar("sv_maxspeed")
	if wishspeed > maxspeed then
		wishspeed = maxspeed
	end

	local _, airaccel = client.GetConVar("sv_airaccelerate")
	AirAccelerate(velocity, wishdir, wishspeed, airaccel, frametime, 1.0, player)

	-- move player
	TryPlayerMove(origin, velocity, frametime, mins, maxs, function(ent, contentsMask)
		return ent:GetIndex() ~= index
	end, 1.0)
end

--- Returns the player's predicted path and the last position
---@param player Entity
---@param time_seconds number
---@param lazyness number
---@return Vector3[], Vector3, number
local function SimulatePlayer(player, time_seconds, lazyness)
	local velocity = player:EstimateAbsVelocity()
	local tickinterval = globals.TickInterval()
	local mins, maxs, origin, viewOffset
	local step_size
	mins = player:GetMins()
	maxs = player:GetMaxs()
	origin = player:GetAbsOrigin() + Vector3(0, 0, 1)

	viewOffset = player:GetPropVector("localdata", "m_vecViewOffset[0]")
	step_size = player:GetPropFloat("localdata", "m_Local", "m_flStepSize")
	local index = player:GetIndex()
	local maxspeed = player:GetPropFloat("m_flMaxspeed")
	lazyness = lazyness or 10.0

	local path = {}

	if velocity:Length() == 0.0 then
		return { origin }, origin, 0.0
	end

	tickinterval = tickinterval * lazyness

	local simTime = 0.0
	local _, gravity = client.GetConVar("sv_gravity")

	while simTime < time_seconds do
		--- Start Gravity
		if GetWaterLevel(mins, maxs, origin, viewOffset) == 0 then
			velocity.z = velocity.z - gravity * tickinterval
			CheckVelocity(velocity)
		end

		local is_on_ground = CheckIsOnGround(origin, mins, maxs, index)

		CheckVelocity(velocity)

		if is_on_ground then
			Friction(velocity, is_on_ground, tickinterval)
			WalkMove(velocity, origin, mins, maxs, step_size, tickinterval, index, maxspeed)
		else
			AirMove(velocity, origin, mins, maxs, tickinterval, player, index)
		end

		CheckVelocity(velocity)

		--- Finish Gravity
		if GetWaterLevel(mins, maxs, origin, viewOffset) == 0 then
			velocity.z = velocity.z - gravity * tickinterval
			CheckVelocity(velocity)
		end

		if is_on_ground then
			velocity.z = 0
		end

		path[#path + 1] = Vector3(origin.x, origin.y, origin.z)
		simTime = simTime + tickinterval
	end

	return path, path[#path], simTime
end

return SimulatePlayer
