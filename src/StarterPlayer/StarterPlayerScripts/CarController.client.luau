--!strict
--[[
	CarController (클라이언트)
	---------------------------
	아케이드 주행 물리를 담당합니다.
	- 플레이어가 차량 VehicleSeat에 탑승하면 활성화
	- 시트의 Throttle/Steer(WASD) 입력을 읽어 속도/방향 제어
	- 네트워크 소유권이 운전자에게 있어 조작이 부드럽게 반영됨

	아케이드 모델: 가벼운 가속/감속, 속도 비례 회전, 평면 주행 유지.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local activeSeat: VehicleSeat? = nil
local currentSpeed = 0 -- 현재 전진 속도(음수 = 후진)

-- 현재 탑승 중인 차량 시트를 찾음
local function findCarSeat(): VehicleSeat?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	local seatPart = humanoid.SeatPart
	if seatPart and seatPart:IsA("VehicleSeat") and seatPart:GetAttribute("TopSpeed") then
		return seatPart
	end
	return nil
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

RunService.Heartbeat:Connect(function(dt: number)
	-- 매 프레임 활성 시트 갱신
	local seat = findCarSeat()
	if seat ~= activeSeat then
		activeSeat = seat
		currentSpeed = 0
	end
	if not seat then
		return
	end
	-- 출발 카운트다운 중에는 차량이 고정(Anchored)됨
	if seat.Anchored then
		currentSpeed = 0
		return
	end

	local topSpeed = (seat:GetAttribute("TopSpeed") :: number) or 120
	local accel = (seat:GetAttribute("Accel") :: number) or 30
	local handling = (seat:GetAttribute("Handling") :: number) or 0.65

	-- 입력 (VehicleSeat가 WASD를 자동으로 -1~1 범위로 제공)
	local throttle = seat.ThrottleFloat -- 전/후진
	local steer = seat.SteerFloat -- 좌/우

	-- 목표 속도로 가속/감속
	local target: number
	if throttle ~= 0 then
		-- 후진은 최고속의 40%로 제한
		local maxForThrottle = throttle > 0 and topSpeed or topSpeed * 0.4
		target = throttle * maxForThrottle
	else
		target = 0 -- 입력 없으면 천천히 멈춤
	end

	-- 가속/감속 비율 (가속 스탯과 dt 반영)
	local rate = math.clamp(accel * dt * 0.12, 0, 1)
	if target == 0 then
		rate = math.clamp(dt * 1.5, 0, 1) -- 관성에 의한 감속
	end
	currentSpeed = lerp(currentSpeed, target, rate)
	if math.abs(currentSpeed) < 0.5 then
		currentSpeed = 0
	end

	-- 전진 방향으로 수평 속도 적용 (수직 성분은 중력에 맡김)
	local cf = seat.CFrame
	local forward = cf.LookVector
	local horizontal = Vector3.new(forward.X, 0, forward.Z)
	if horizontal.Magnitude > 0 then
		horizontal = horizontal.Unit
	end
	local vy = seat.AssemblyLinearVelocity.Y
	local desired = horizontal * currentSpeed
	seat.AssemblyLinearVelocity = Vector3.new(desired.X, vy, desired.Z)

	-- 속도에 비례한 회전 (정지 시 회전 약함)
	local speedFactor = math.clamp(math.abs(currentSpeed) / topSpeed, 0, 1)
	local turnRate = handling * 2.6 * (0.25 + 0.75 * speedFactor)
	local direction = currentSpeed >= 0 and 1 or -1
	seat.AssemblyAngularVelocity = Vector3.new(0, -steer * turnRate * direction, 0)
end)
