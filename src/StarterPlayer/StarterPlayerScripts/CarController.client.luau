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
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")

local GameConfig = require(ReplicatedStorage.GameConfig)
local Remotes = require(ReplicatedStorage.Remotes)

local player = Players.LocalPlayer

local activeSeat: VehicleSeat? = nil
local currentSpeed = 0 -- 현재 전진 속도(음수 = 후진)

-- 자가복구(소유권 누락 대비): 출발했는데 방향키를 밟아도 차가 "전혀" 안 움직이면
-- (네트워크 소유권이 서버에 있어 클라 속도 쓰기가 무시되는 상태), 서버에 재탑승을 요청해
-- 사용자가 손으로 "내렸다 다시 타기"를 하던 것을 자동으로 재현한다.
local stuckTime = 0 -- 가속 입력 중 차가 안 움직인 누적 시간
local stuckMove = 0 -- 같은 창(window) 동안 실제로 이동한 거리(평면, studs)
local lastStuckPos: Vector3? = nil -- 직전 프레임 위치(이동량 측정용)
local lastDriveFixAt = -10 -- 마지막 복구 요청 시각(디바운스, os.clock)

-- 점프 잠금 가드: 탑승 중 점프(=VehicleSeat 자동 하차)를 막는다.
-- 서버에서 JumpPower=0만으로는 하차가 확실히 막히지 않으므로,
-- 캐릭터를 소유한 클라이언트에서 Jumping 상태 자체를 비활성화한다.
-- 하차(정상) 시 원래 점프 능력으로 복구한다.
local jumpGuard: { humanoid: Humanoid, power: number, height: number }? = nil
local JUMP_ACTION = "RaceNoJump" -- ContextActionService 액션 이름(점프 입력 가로채기)

local function disableJumpFor(humanoid: Humanoid)
	if jumpGuard and jumpGuard.humanoid == humanoid then
		return -- 이미 같은 휴머노이드에 적용됨
	end
	jumpGuard = { humanoid = humanoid, power = humanoid.JumpPower, height = humanoid.JumpHeight }
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
	-- 가장 확실한 차단: 점프 입력(스페이스/터치 점프버튼/게임패드 A)을 액션 레벨에서 흡수(Sink)해
	-- Humanoid에 점프 요청 자체가 도달하지 않게 한다 → 차에서 튕겨나가지 않음.
	ContextActionService:BindAction(JUMP_ACTION, function()
		return Enum.ContextActionResult.Sink
	end, false, Enum.PlayerActions.CharacterJump)
end

local function restoreJump()
	local g = jumpGuard
	if not g then
		return
	end
	if g.humanoid and g.humanoid.Parent then
		g.humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		g.humanoid.JumpPower = g.power
		g.humanoid.JumpHeight = g.height
	end
	ContextActionService:UnbindAction(JUMP_ACTION)
	jumpGuard = nil
end

-- 바퀴 시각화 상태 (앞바퀴 조향 + 전체 바퀴 굴림)
-- 시트에 Motor6D로 연결된 타이어들의 C0를 매 프레임 회전시킨다.
local wheelMotors: { { motor: Motor6D, base: CFrame, front: boolean } } = {}
local steerVisual = 0 -- 부드럽게 추종하는 현재 조향각(rad)
local wheelSpin = 0 -- 누적 굴림 회전각(rad)
local wheelRadius = 1.65
local MAX_STEER = math.rad(28) -- 앞바퀴 최대 조향각

-- =====================================================================
-- 드리프트 / 니트로 / 로켓 스타트 상태
-- =====================================================================
-- Shift(또는 모바일 DRIFT 버튼)로 핸드브레이크를 잡고 코너를 돌면 드리프트 →
-- 니트로 게이지가 차고, 떼면 충전량에 비례한 부스트(NitroEndTime 속성)가 발사된다.
-- 시각효과(연기/스키드/게이지 UI)는 CarEffectsController가 시트 속성을 읽어 표현한다.
local DRIFT_ACTION = "RaceDrift" -- 핸드브레이크(드리프트) 입력 액션
local handbrakeHeld = false -- Shift/모바일 DRIFT 버튼 눌림 상태
local drifting = false -- 현재 드리프트 중인가
local nitroCharge = 0 -- 니트로 게이지(0~1)
-- 실제 진행 방향(접지 모델). 평소엔 차머리를 빠르게 추종(즉각 주행),
-- 드리프트 중엔 느리게 추종 → 바깥으로 미끄러지는 느낌을 만든다.
local moveDir = Vector3.new(0, 0, -1)
local wasFrozen = false -- 직전 프레임에 출발 동결 상태였는가(GO 전환 감지용)
local throttlePressStart: number? = nil -- 카운트다운 중 가속을 시작한 시각(로켓 스타트 판정)
local lastCollisionPos: Vector3? = nil -- 충돌 감지용 직전 위치
local lastCollisionAt = 0 -- 충돌 디바운스용 시각(os.clock)

-- 시트 머리 방향을 평면(수평) 단위벡터로
local function flatLook(seat: VehicleSeat): Vector3
	local fwd = seat.CFrame.LookVector
	local h = Vector3.new(fwd.X, 0, fwd.Z)
	if h.Magnitude > 0 then
		return h.Unit
	end
	return Vector3.new(0, 0, -1)
end

-- 드리프트 상태 초기화(빙글/얼음 등 특수 상태나 하차 시)
local function resetDrift(seat: VehicleSeat?)
	drifting = false
	nitroCharge = 0
	if seat then
		seat:SetAttribute("Drifting", false)
		seat:SetAttribute("NitroCharge", 0)
	end
end

-- 핸드브레이크(Shift) 입력 바인딩. 3번째 인자 true → 모바일 터치 버튼 자동 생성.
local function bindDrift()
	handbrakeHeld = false
	ContextActionService:BindAction(DRIFT_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin then
			handbrakeHeld = true
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			handbrakeHeld = false
		end
		return Enum.ContextActionResult.Pass
	end, true, Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift)
	ContextActionService:SetTitle(DRIFT_ACTION, "DRIFT")
end

local function unbindDrift()
	ContextActionService:UnbindAction(DRIFT_ACTION)
	handbrakeHeld = false
	drifting = false
	nitroCharge = 0
end

-- 엔진 사운드: 속도에 비례해 피치/볼륨을 조절해 RPM 느낌을 낸다
local function updateEngineSound(seat: VehicleSeat, speedRatio: number, boosting: boolean)
	local engine = seat:FindFirstChild("Engine")
	if not engine or not engine:IsA("Sound") then
		return
	end
	local cfg = GameConfig.Audio
	local pitch = cfg.idlePlaybackSpeed + (cfg.maxPlaybackSpeed - cfg.idlePlaybackSpeed) * speedRatio
	local volume = cfg.idleVolume + (cfg.maxVolume - cfg.idleVolume) * speedRatio
	-- 부스트 순간 엔진음 극대화: 피치를 더 끌어올리고 볼륨을 최대로(굉음) + 빠르게 추종.
	local follow = 0.2
	if boosting then
		pitch += cfg.boostPitchBonus * 1.6
		volume = math.max(volume, cfg.maxVolume) * 1.15
		follow = 0.45 -- 부스트 시 더 즉각적으로 치고 올라오게
	end
	engine.PlaybackSpeed += (pitch - engine.PlaybackSpeed) * follow
	engine.Volume += (volume - engine.Volume) * follow
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
		-- 자가복구 상태 초기화(차가 바뀌면 새로 측정)
		lastStuckPos = nil
		stuckTime = 0
		stuckMove = 0
		if seat then
			ensureEngineSound(seat) -- 새 차량 탑승 시 동작하는 엔진 사운드 선택
			cacheWheels(seat) -- 바퀴 Motor6D 캐시
			-- 드리프트/니트로 상태 초기화
			moveDir = flatLook(seat)
			wasFrozen = false
			throttlePressStart = nil
			lastCollisionPos = nil
			resetDrift(seat)
			bindDrift() -- 핸드브레이크(Shift/모바일 버튼) 입력 활성화
			-- 탑승 즉시 점프 잠금(점프로 차에서 내려지는 것 방지)
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				disableJumpFor(humanoid)
			end
		else
			restoreJump() -- 차에서 내리면(라운지 복귀 등) 점프 복구
			unbindDrift() -- 핸드브레이크 입력 해제
		end
	end
	if not seat then
		return
	end
	-- 탑승 중에는 매 프레임 점프 잠금을 재확인(다른 스크립트/리스폰이 풀어도 유지)
	if jumpGuard then
		jumpGuard.humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		jumpGuard.humanoid.Jump = false -- 점프 요청 플래그가 서면 즉시 끔(이중 안전장치)
	end
	-- 출발 카운트다운 중에는 차량이 동결됨.
	-- ⚠️ 앵커(Anchored)로 동결하면 네트워크 소유권이 서버로 넘어가버려서, GO 후에도
	--    클라이언트 조작이 차에 반영되지 않는 버그가 있었다(=내렸다 다시 타야 움직임).
	--    그래서 앵커 대신 RaceFrozen 속성으로 동결한다 → 소유권은 운전자에게 유지되고,
	--    클라이언트가 직접 속도를 0으로 눌러 제자리를 지킨다 → GO 즉시 방향키로 출발 가능.
	if seat.Anchored or seat:GetAttribute("RaceFrozen") then
		currentSpeed = 0
		if not seat.Anchored then
			local vy = seat.AssemblyLinearVelocity.Y -- 중력(수직)은 보존해 지면에 안착
			seat.AssemblyLinearVelocity = Vector3.new(0, vy, 0)
			seat.AssemblyAngularVelocity = Vector3.zero
		end
		-- 로켓 스타트: 카운트다운 중 "가속을 시작한 시각"을 기록(GO 때 타이밍 판정).
		-- 카운트다운 내내 밟고 있으면 throttlePressStart가 오래전 값이라 퍼펙트 윈도우를 벗어난다(부정출발 방지).
		if seat.ThrottleFloat > 0.1 then
			if throttlePressStart == nil then
				throttlePressStart = os.clock()
			end
		else
			throttlePressStart = nil -- 뗐다 다시 밟으면 타이밍 갱신
		end
		wasFrozen = true
		moveDir = flatLook(seat) -- 동결 중엔 진행방향을 차머리에 고정(출발 시 깔끔)
		resetDrift(seat)
		updateEngineSound(seat, 0, false)
		-- 동결 중엔 자가복구 측정을 멈추고 창을 리셋(GO 직후부터 새로 측정)
		lastStuckPos = nil
		stuckTime = 0
		stuckMove = 0
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
		resetDrift(seat)
		moveDir = flatLook(seat)
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
		resetDrift(seat)
		moveDir = flatLook(seat)
		updateEngineSound(seat, 0.2, false)
		return
	end

	-- GO 순간 감지(동결 해제로 막 빠져나온 프레임) → 로켓 스타트(퍼펙트 스타트) 판정
	if wasFrozen then
		wasFrozen = false
		local rcfg = GameConfig.RocketStart
		if
			rcfg.enabled
			and seat.ThrottleFloat > 0.1
			and throttlePressStart ~= nil
			and (os.clock() - throttlePressStart) <= rcfg.window
		then
			-- 퍼펙트! 기존 부스트 파이프라인(NitroEndTime)으로 출발 부스트 + 연출 신호
			seat:SetAttribute("NitroEndTime", now + rcfg.boostDuration)
			seat:SetAttribute("PerfectStart", os.clock()) -- 이펙트 컨트롤러 토스트용 신호
		end
		throttlePressStart = nil
		moveDir = flatLook(seat)
	end

	-- 부스트(패드) / 로켓(아이템) / 니트로(드리프트·로켓스타트) / 감속(오일) 적용
	local boostingPad = boostEnd ~= nil and now < boostEnd
	local rocketing = rocketEnd ~= nil and now < rocketEnd
	local slowed = slowEnd ~= nil and now < slowEnd
	local nitroEnd = seat:GetAttribute("NitroEndTime") :: number?
	local nitroing = nitroEnd ~= nil and now < nitroEnd
	local boosting = boostingPad or rocketing or nitroing -- 엔진 굉음/속도감 연출 트리거
	if rocketing then
		topSpeed *= GameConfig.Items.rocket.speedMultiplier
		accel *= GameConfig.Items.rocket.accelMultiplier
	elseif boostingPad then
		topSpeed *= GameConfig.Boost.speedMultiplier
		accel *= GameConfig.Boost.accelMultiplier
	end
	if nitroing then
		topSpeed *= GameConfig.Drift.speedMultiplier
		accel *= GameConfig.Drift.accelMultiplier
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

	-- 전진 방향(차머리)
	local heading = flatLook(seat)

	-- 드리프트 판정: 핸드브레이크 + 충분한 속도 + 충분한 조향
	local dcfg = GameConfig.Drift
	local canDrift = dcfg.enabled
		and handbrakeHeld
		and currentSpeed > dcfg.minSpeed
		and math.abs(steer) > dcfg.steerThreshold
	if canDrift then
		drifting = true
		-- 게이지 충전(핸들을 더 꺾을수록 빨리 참)
		nitroCharge = math.min(1, nitroCharge + dt * dcfg.chargeRate * (0.5 + 0.5 * math.abs(steer)))
	elseif drifting then
		-- 드리프트 종료 → 충전량에 비례한 미니터보 발사
		drifting = false
		if nitroCharge >= dcfg.minChargeToFire then
			local dur = lerp(dcfg.minBoost, dcfg.maxBoost, math.clamp(nitroCharge, 0, 1))
			seat:SetAttribute("NitroEndTime", now + dur)
		end
		nitroCharge = 0
	end
	seat:SetAttribute("Drifting", drifting)
	seat:SetAttribute("NitroCharge", nitroCharge)

	-- 접지 모델:
	--  • 평소  : moveDir = heading (진행방향=차머리) → 일반 주행과 100% 동일(조작감 유지)
	--  • 드리프트: moveDir가 heading을 "느리게" 추종 → 차는 안쪽을 보는데 바깥으로 미끄러짐
	if drifting then
		moveDir = moveDir:Lerp(heading, math.clamp(dt * dcfg.driftGrip, 0, 1))
		if moveDir.Magnitude > 0 then
			moveDir = moveDir.Unit
		else
			moveDir = heading
		end
	else
		moveDir = heading
	end

	local vy = seat.AssemblyLinearVelocity.Y
	local desired = moveDir * currentSpeed
	seat.AssemblyLinearVelocity = Vector3.new(desired.X, vy, desired.Z)

	-- 속도에 비례한 회전 (정지 시 회전 약함). 드리프트 중엔 더 날카롭게.
	local speedFactor = math.clamp(math.abs(currentSpeed) / topSpeed, 0, 1)
	local turnRate = handling * 2.6 * (0.25 + 0.75 * speedFactor)
	if drifting then
		turnRate *= dcfg.turnBoost
	end
	local direction = currentSpeed >= 0 and 1 or -1
	seat.AssemblyAngularVelocity = Vector3.new(0, -steer * turnRate * direction, 0)

	-- 충돌 감지: 빠르게 가려는데 실제 이동이 막히면 벽/차 충돌로 간주 → 불꽃 신호 + 튕김 감속
	local fxcfg = GameConfig.CarFX
	if fxcfg.enabled and fxcfg.sparksEnabled then
		local pos = seat.Position
		local lp = lastCollisionPos
		if lp then
			local moved = Vector3.new(pos.X - lp.X, 0, pos.Z - lp.Z).Magnitude / math.max(dt, 1 / 240)
			if
				math.abs(currentSpeed) > fxcfg.collisionSpeed
				and moved < math.abs(currentSpeed) * 0.35
				and (os.clock() - lastCollisionAt) > 0.45
			then
				lastCollisionAt = os.clock()
				seat:SetAttribute("ImpactAt", os.clock())
				currentSpeed *= 0.4 -- 충돌 감속(튕기는 느낌)
			end
		end
		lastCollisionPos = pos
	end

	-- 앞바퀴 조향 + 전체 바퀴 굴림 시각화
	updateWheels(steer, dt)

	-- 엔진 사운드 갱신 (속도 비례 피치/볼륨)
	updateEngineSound(seat, speedFactor, boosting)

	-- ── 자가복구: 출발 후에도 차가 안 움직이면 서버에 재탑승 요청 ──────────
	-- 방향키(가속/후진)를 확실히 밟고 있는데 0.5초 동안 차가 거의(1.5 studs 미만) 안 움직였다면,
	-- 네트워크 소유권이 운전자에게 없어 속도 쓰기가 무시되는 상태로 보고 서버에 복구를 요청한다.
	-- 서버는 운전자가 이미 소유 중이면(벽에 막힌 정상 상황 등) 무시하므로 오작동이 없다.
	do
		local p = seat.Position
		local lsp = lastStuckPos
		if lsp then
			stuckMove += Vector3.new(p.X - lsp.X, 0, p.Z - lsp.Z).Magnitude
		end
		lastStuckPos = p
		-- "운전자가 움직이려는 의도"를 시트 입력(ThrottleFloat)뿐 아니라 실제 키보드(WASD/방향키)로도
		-- 감지한다 → 혹시 입력 자체가 안 잡히는 드문 경우에도 재탑승으로 함께 복구된다.
		local wantsDrive = math.abs(throttle) > 0.5
			or UserInputService:IsKeyDown(Enum.KeyCode.W)
			or UserInputService:IsKeyDown(Enum.KeyCode.Up)
			or UserInputService:IsKeyDown(Enum.KeyCode.S)
			or UserInputService:IsKeyDown(Enum.KeyCode.Down)
		if wantsDrive then
			stuckTime += dt
			if stuckTime >= 0.5 then
				if stuckMove < 1.5 and (os.clock() - lastDriveFixAt) > 2 then
					lastDriveFixAt = os.clock()
					Remotes.Event("RequestDriveFix"):FireServer()
				end
				stuckTime = 0
				stuckMove = 0
			end
		else
			stuckTime = 0
			stuckMove = 0
		end
	end
end)
