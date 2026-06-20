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
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.GameConfig)

local player = Players.LocalPlayer

local activeSeat: VehicleSeat? = nil
local currentSpeed = 0 -- 현재 전진 속도(음수 = 후진)

-- 바퀴 시각화 상태 (앞바퀴 조향 + 전체 바퀴 굴림)
-- 시트에 Motor6D로 연결된 타이어들의 C0를 매 프레임 회전시킨다.
local wheelMotors: { { motor: Motor6D, base: CFrame, front: boolean } } = {}
local steerVisual = 0 -- 부드럽게 추종하는 현재 조향각(rad)
local wheelSpin = 0 -- 누적 굴림 회전각(rad)
local wheelRadius = 1.65
local MAX_STEER = math.rad(28) -- 앞바퀴 최대 조향각

-- 엔진 사운드: 속도에 비례해 피치/볼륨을 조절해 RPM 느낌을 낸다
local function updateEngineSound(seat: VehicleSeat, speedRatio: number, boosting: boolean)
	local engine = seat:FindFirstChild("Engine")
	if not engine or not engine:IsA("Sound") then
		return
	end
	local cfg = GameConfig.Audio
	local pitch = cfg.idlePlaybackSpeed + (cfg.maxPlaybackSpeed - cfg.idlePlaybackSpeed) * speedRatio
	if boosting then
		pitch += cfg.boostPitchBonus
	end
	local volume = cfg.idleVolume + (cfg.maxVolume - cfg.idleVolume) * speedRatio
	-- 부드럽게 추종
	engine.PlaybackSpeed += (pitch - engine.PlaybackSpeed) * 0.2
	engine.Volume += (volume - engine.Volume) * 0.2
end

-- 엔진 사운드 자동 선택: 후보 id를 순회하며 "실제로 로드되는 첫 id"를 고른다.
-- 일부 에셋이 모더레이션/삭제로 죽어도 다른 후보로 소리가 나게 한다.
-- (오디오 로드는 클라이언트에서 일어나므로 여기서 검증/교체한다.)
local function ensureEngineSound(seat: VehicleSeat)
	local engine = seat:FindFirstChild("Engine")
	if not engine or not engine:IsA("Sound") then
		return
	end
	local sound = engine :: Sound
	local ids = GameConfig.Audio.engineSoundIds
	task.spawn(function()
		for _, id in ipairs(ids) do
			-- 차량이 사라졌으면 중단
			if not sound.Parent then
				return
			end
			sound.SoundId = "rbxassetid://" .. tostring(id)
			sound.Looped = true
			sound.Playing = true
			local t0 = os.clock()
			while not sound.IsLoaded and os.clock() - t0 < 2 do
				RunService.Heartbeat:Wait()
				if not sound.Parent then
					return
				end
			end
			if sound.IsLoaded then
				break -- 동작하는 id를 찾음
			end
		end
	end)
end

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

-- 새 차량 탑승 시 바퀴 Motor6D들을 수집하고 기준 C0를 캐시
local function cacheWheels(seat: VehicleSeat)
	wheelMotors = {}
	steerVisual = 0
	wheelSpin = 0
	wheelRadius = (seat:GetAttribute("WheelRadius") :: number?) or 1.65
	for _, m in ipairs(seat:GetChildren()) do
		if m:IsA("Motor6D") and m.Name == "WheelMotor" then
			table.insert(wheelMotors, {
				motor = m,
				base = m.C0,
				front = m:GetAttribute("FrontWheel") == true,
			})
		end
	end
end

-- 매 프레임 바퀴 회전 갱신: 앞바퀴는 조향(Y) + 굴림(X), 뒷바퀴는 굴림(X)만
local function updateWheels(steer: number, dt: number)
	if #wheelMotors == 0 then
		return
	end
	local targetSteer = -steer * MAX_STEER -- 조향 방향을 차체 회전과 일치
	steerVisual = lerp(steerVisual, targetSteer, math.clamp(dt * 9, 0, 1))
	-- 전진(currentSpeed>0) 시 바퀴가 앞으로 구르도록 누적
	wheelSpin -= (currentSpeed * dt) / math.max(wheelRadius, 0.1)
	if wheelSpin > math.pi * 2 or wheelSpin < -math.pi * 2 then
		wheelSpin %= (math.pi * 2)
	end
	local spinCf = CFrame.Angles(wheelSpin, 0, 0)
	local steerCf = CFrame.Angles(0, steerVisual, 0)
	for _, w in ipairs(wheelMotors) do
		if w.motor.Parent then
			if w.front then
				w.motor.C0 = w.base * steerCf * spinCf
			else
				w.motor.C0 = w.base * spinCf
			end
		end
	end
end

RunService.Heartbeat:Connect(function(dt: number)
	-- 매 프레임 활성 시트 갱신
	local seat = findCarSeat()
	if seat ~= activeSeat then
		activeSeat = seat
		currentSpeed = 0
		wheelMotors = {}
		if seat then
			ensureEngineSound(seat) -- 새 차량 탑승 시 동작하는 엔진 사운드 선택
			cacheWheels(seat) -- 바퀴 Motor6D 캐시
		end
	end
	if not seat then
		return
	end
	-- 출발 카운트다운 중에는 차량이 고정(Anchored)됨
	if seat.Anchored then
		currentSpeed = 0
		updateEngineSound(seat, 0, false)
		return
	end

	local topSpeed = (seat:GetAttribute("TopSpeed") :: number) or 120
	local accel = (seat:GetAttribute("Accel") :: number) or 30
	local handling = (seat:GetAttribute("Handling") :: number) or 0.65

	-- 효과 어트리뷰트 (서버 시각 기준)
	local now = workspace:GetServerTimeNow()
	local boostEnd = seat:GetAttribute("BoostEndTime") :: number?
	local slowEnd = seat:GetAttribute("SlowEndTime") :: number?
	local rocketEnd = seat:GetAttribute("RocketEndTime") :: number?
	local spinEnd = seat:GetAttribute("SpinEndTime") :: number?
	local freezeEnd = seat:GetAttribute("FreezeEndTime") :: number?

	-- 물풍선에 맞음: 완전히 갇힘(정지 + 입력 무시)
	if freezeEnd ~= nil and now < freezeEnd then
		currentSpeed = 0
		local vy = seat.AssemblyLinearVelocity.Y
		seat.AssemblyLinearVelocity = Vector3.new(0, vy, 0)
		seat.AssemblyAngularVelocity = Vector3.zero
		updateWheels(0, dt)
		updateEngineSound(seat, 0, false)
		return
	end

	-- 바나나를 밟음: 빙글빙글 미끄러짐(주행/조향 불가)
	if spinEnd ~= nil and now < spinEnd then
		currentSpeed = lerp(currentSpeed, 0, math.clamp(dt * 2.5, 0, 1))
		local cf = seat.CFrame
		local horizontal = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
		if horizontal.Magnitude > 0 then
			horizontal = horizontal.Unit
		end
		local vy = seat.AssemblyLinearVelocity.Y
		seat.AssemblyLinearVelocity = Vector3.new(horizontal.X * currentSpeed, vy, horizontal.Z * currentSpeed)
		seat.AssemblyAngularVelocity = Vector3.new(0, 9, 0) -- 강하게 회전(스핀아웃)
		updateWheels(1, dt)
		updateEngineSound(seat, 0.2, false)
		return
	end

	-- 부스트(패드) / 로켓(아이템) / 감속(오일) 적용
	local boostingPad = boostEnd ~= nil and now < boostEnd
	local rocketing = rocketEnd ~= nil and now < rocketEnd
	local slowed = slowEnd ~= nil and now < slowEnd
	local boosting = boostingPad or rocketing -- 엔진 사운드 가속 연출용
	if rocketing then
		topSpeed *= GameConfig.Items.rocket.speedMultiplier
		accel *= GameConfig.Items.rocket.accelMultiplier
	elseif boostingPad then
		topSpeed *= GameConfig.Boost.speedMultiplier
		accel *= GameConfig.Boost.accelMultiplier
	end
	if slowed then
		topSpeed *= GameConfig.Obstacles.slowFactor
	end

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

	-- 앞바퀴 조향 + 전체 바퀴 굴림 시각화
	updateWheels(steer, dt)

	-- 엔진 사운드 갱신 (속도 비례 피치/볼륨)
	updateEngineSound(seat, speedFactor, boosting)
end)
