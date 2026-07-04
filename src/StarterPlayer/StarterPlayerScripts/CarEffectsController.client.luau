--!strict
--[[
	CarEffectsController (클라이언트)
	--------------------------------
	차량의 "손맛" 시각효과를 담당한다. 메커니즘(드리프트/니트로/충돌 판정)은
	CarController가 처리하고, 그 결과를 시트의 로컬 속성으로 읽어 여기서 표현한다.
	  • Drifting     (bool)   → 뒷바퀴 타이어 연기 + 스키드마크
	  • NitroEndTime (number) → 배기 불꽃 + 니트로 게이지 "발사중" 표시
	  • NitroCharge  (0~1)    → 화면 하단 니트로 게이지 채움
	  • ImpactAt     (number) → 벽/차 충돌 순간 불꽃 버스트
	  • PerfectStart (number) → "퍼펙트 스타트!" 토스트

	전부 클라 로컬 + 내장 파티클 텍스처(rbxasset://textures/particles/...)만 사용 →
	에셋 로드 실패가 없다. 스키드마크는 클라 로컬 Part 풀(재활용)로 그린다.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage.GameConfig)
local cfg = (GameConfig :: any).CarFX
if not cfg or cfg.enabled == false then
	return
end
local dcfg = (GameConfig :: any).Drift

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local function flatLook(seat: VehicleSeat): Vector3
	local fwd = seat.CFrame.LookVector
	local h = Vector3.new(fwd.X, 0, fwd.Z)
	if h.Magnitude > 0 then
		return h.Unit
	end
	return Vector3.new(0, 0, -1)
end

-- =====================================================================
-- 파티클 이미터 팩토리 (내장 텍스처)
-- =====================================================================
local function makeSmoke(): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/smoke_main.dds"
	e.Color = ColorSequence.new(Color3.fromRGB(238, 238, 238))
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(0.2, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.2),
		NumberSequenceKeypoint.new(1, 4.5),
	})
	e.Lifetime = NumberRange.new(0.35, 0.7)
	e.Rate = 70
	e.Speed = NumberRange.new(2, 5)
	e.SpreadAngle = Vector2.new(28, 28)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-60, 60)
	e.Acceleration = Vector3.new(0, 6, 0) -- 위로 피어오름
	e.LightEmission = 0
	e.Enabled = false
	return e
end

local function makeFlame(): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/fire_main.dds"
	e.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 225, 130)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 140, 30)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 60, 20)),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.7),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	e.Lifetime = NumberRange.new(0.18, 0.38)
	e.Rate = 90
	e.Speed = NumberRange.new(7, 13)
	e.SpreadAngle = Vector2.new(10, 10)
	e.Acceleration = Vector3.new(0, 2, 0)
	e.LightEmission = 1
	e.LightInfluence = 0
	e.EmissionDirection = Enum.NormalId.Back -- 차 뒤쪽으로
	e.Enabled = false
	return e
end

local function makeSpark(): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 240, 150)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 120, 20)),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.7),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Lifetime = NumberRange.new(0.25, 0.5)
	e.Rate = 0 -- 평소엔 안 나오고 충돌 순간 Emit으로만 분출
	e.Speed = NumberRange.new(16, 30)
	e.SpreadAngle = Vector2.new(70, 70)
	e.Acceleration = Vector3.new(0, -50, 0) -- 중력처럼 떨어짐
	e.LightEmission = 1
	e.Enabled = false
	return e
end

-- =====================================================================
-- 스키드마크 (클라 로컬 Part 풀)
-- =====================================================================
local skidFolder = Instance.new("Folder")
skidFolder.Name = "SkidMarksClient"
skidFolder.Parent = workspace

local skidParts: { Part } = {}
local skidIndex = 1
local lastSkidPos: Vector3? = nil

local function getSkidPart(): Part
	local p = skidParts[skidIndex]
	if not p then
		p = Instance.new("Part")
		p.Size = Vector3.new(0.75, 0.05, 1.7)
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.SmoothPlastic
		p.Color = Color3.fromRGB(28, 28, 30)
		p.Transparency = 0.3
		p.Parent = skidFolder
		skidParts[skidIndex] = p
	end
	skidIndex += 1
	if skidIndex > cfg.skidPoolSize then
		skidIndex = 1
	end
	return p
end

local function clearSkids()
	for _, p in ipairs(skidParts) do
		p:Destroy()
	end
	table.clear(skidParts)
	skidIndex = 1
	lastSkidPos = nil
end

-- =====================================================================
-- 니트로 게이지 + 퍼펙트 스타트 토스트 (UI)
-- =====================================================================
local hud = Instance.new("ScreenGui")
hud.Name = "CarFXHud"
hud.ResetOnSpawn = false
hud.IgnoreGuiInset = true
hud.DisplayOrder = 6
hud.Enabled = true
hud.Parent = playerGui

-- 니트로 게이지(하단 중앙)
local gauge = Instance.new("Frame")
gauge.Name = "NitroGauge"
gauge.AnchorPoint = Vector2.new(0.5, 1)
gauge.Position = UDim2.new(0.5, 0, 1, -64)
gauge.Size = UDim2.new(0, 240, 0, 18)
gauge.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
gauge.BackgroundTransparency = 0.25
gauge.BorderSizePixel = 0
gauge.Visible = false
gauge.Parent = hud
do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 9)
	c.Parent = gauge
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Transparency = 0.4
	stroke.Thickness = 1.5
	stroke.Parent = gauge
end

local fill = Instance.new("Frame")
fill.Name = "Fill"
fill.AnchorPoint = Vector2.new(0, 0.5)
fill.Position = UDim2.new(0, 3, 0.5, 0)
fill.Size = UDim2.new(0, 0, 1, -6)
fill.BackgroundColor3 = Color3.fromRGB(90, 170, 255)
fill.BorderSizePixel = 0
fill.Parent = gauge
do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 7)
	c.Parent = fill
end

local gaugeLabel = Instance.new("TextLabel")
gaugeLabel.BackgroundTransparency = 1
gaugeLabel.Size = UDim2.fromScale(1, 1)
gaugeLabel.Font = Enum.Font.GothamBold
gaugeLabel.Text = "NITRO"
gaugeLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
gaugeLabel.TextTransparency = 0.25
gaugeLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
gaugeLabel.TextStrokeTransparency = 0.5
gaugeLabel.TextScaled = false
gaugeLabel.TextSize = 12
gaugeLabel.ZIndex = 3
gaugeLabel.Parent = gauge

-- 퍼펙트 스타트 토스트(중앙)
local toast = Instance.new("TextLabel")
toast.Name = "PerfectToast"
toast.AnchorPoint = Vector2.new(0.5, 0.5)
toast.Position = UDim2.fromScale(0.5, 0.34)
toast.Size = UDim2.new(0, 460, 0, 64)
toast.BackgroundTransparency = 1
toast.Font = Enum.Font.GothamBlack
toast.Text = "🚀 퍼펙트 스타트!"
toast.TextColor3 = Color3.fromRGB(255, 220, 80)
toast.TextStrokeColor3 = Color3.fromRGB(80, 40, 0)
toast.TextScaled = true
toast.TextTransparency = 1
toast.TextStrokeTransparency = 1
toast.Parent = hud

local function showPerfectToast()
	toast.Text = "🚀 퍼펙트 스타트!"
	toast.TextTransparency = 0
	toast.TextStrokeTransparency = 0.15
	local ti = TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(toast, ti, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
end

-- =====================================================================
-- 현재 차량 이펙트 인스턴스 관리
-- =====================================================================
local activeSeat: VehicleSeat? = nil
local smokeEmitters: { ParticleEmitter } = {}
local flameEmitters: { ParticleEmitter } = {}
local sparkEmitter: ParticleEmitter? = nil
local rearTires: { BasePart } = {}
local fxInstances: { Instance } = {} -- teardown 시 파괴할 우리가 만든 인스턴스
local prevImpact: number? = nil
local prevPerfect: number? = nil

local function teardown()
	for _, inst in ipairs(fxInstances) do
		if inst and inst.Parent then
			inst:Destroy()
		end
	end
	table.clear(fxInstances)
	table.clear(smokeEmitters)
	table.clear(flameEmitters)
	table.clear(rearTires)
	sparkEmitter = nil
	clearSkids()
end

local function buildFor(seat: VehicleSeat)
	teardown()
	-- 뒷바퀴 연기 이미터 + 스키드용 뒷바퀴 참조
	for _, m in ipairs(seat:GetChildren()) do
		if m:IsA("Motor6D") and m.Name == "WheelMotor" and m:GetAttribute("FrontWheel") ~= true then
			local tire = m.Part1
			if tire and tire:IsA("BasePart") then
				table.insert(rearTires, tire)
				if cfg.smokeEnabled then
					local smoke = makeSmoke()
					smoke.Parent = tire
					table.insert(smokeEmitters, smoke)
					table.insert(fxInstances, smoke)
				end
			end
		end
	end
	-- 배기 불꽃(차 뒤 좌/우 2곳)
	if cfg.smokeEnabled then
		for _, dx in ipairs({ -1.6, 1.6 }) do
			local att = Instance.new("Attachment")
			att.Position = Vector3.new(dx, -0.3, 5.6) -- 차 뒤쪽 범퍼(+Z)·약간 아래
			att.Parent = seat
			local flame = makeFlame()
			flame.Parent = att
			table.insert(flameEmitters, flame)
			table.insert(fxInstances, att) -- att 파괴 시 자식 이미터도 파괴
		end
	end
	-- 충돌 불꽃(차 앞)
	if cfg.sparksEnabled then
		local fatt = Instance.new("Attachment")
		fatt.Position = Vector3.new(0, -0.1, -6.2) -- 차 앞쪽 범퍼(-Z)
		fatt.Parent = seat
		local spark = makeSpark()
		spark.Parent = fatt
		sparkEmitter = spark
		table.insert(fxInstances, fatt)
	end
end

local function placeSkids(seat: VehicleSeat)
	local heading = flatLook(seat)
	local wr = (seat:GetAttribute("WheelRadius") :: number?) or 1.65
	for _, tire in ipairs(rearTires) do
		if tire.Parent then
			local pos = tire.Position
			local at = Vector3.new(pos.X, pos.Y - wr + 0.06, pos.Z)
			local mark = getSkidPart()
			mark.CFrame = CFrame.lookAt(at, at + heading)
			mark.Transparency = 0.3
		end
	end
end

local function findSeat(): VehicleSeat?
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local sp = hum and hum.SeatPart
	if sp and sp:IsA("VehicleSeat") and sp:GetAttribute("TopSpeed") then
		return sp :: VehicleSeat
	end
	return nil
end

-- =====================================================================
-- 매 프레임 갱신
-- =====================================================================
RunService.Heartbeat:Connect(function()
	local seat = findSeat()
	if seat ~= activeSeat then
		activeSeat = seat
		prevImpact = nil
		prevPerfect = nil
		if seat then
			buildFor(seat)
		else
			teardown()
		end
	end

	if not seat then
		gauge.Visible = false
		return
	end

	local now = workspace:GetServerTimeNow()
	local drifting = seat:GetAttribute("Drifting") == true
	local charge = (seat:GetAttribute("NitroCharge") :: number?) or 0
	local nitroEnd = seat:GetAttribute("NitroEndTime") :: number?
	local nitroActive = nitroEnd ~= nil and now < nitroEnd
	local boostEnd = seat:GetAttribute("BoostEndTime") :: number?
	local rocketEnd = seat:GetAttribute("RocketEndTime") :: number?
	local boosting = nitroActive
		or (boostEnd ~= nil and now < boostEnd)
		or (rocketEnd ~= nil and now < rocketEnd)

	local v = seat.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude

	-- 연기/불꽃 토글
	for _, s in ipairs(smokeEmitters) do
		s.Enabled = drifting
	end
	for _, f in ipairs(flameEmitters) do
		f.Enabled = boosting
	end

	-- 스키드마크: 드리프트 중 일정 거리마다 뒷바퀴 자국
	if cfg.skidEnabled and drifting and speed > 6 then
		local cp = Vector3.new(seat.Position.X, 0, seat.Position.Z)
		if lastSkidPos == nil or (cp - lastSkidPos).Magnitude >= cfg.skidInterval then
			placeSkids(seat)
			lastSkidPos = cp
		end
	elseif not drifting then
		lastSkidPos = nil -- 드리프트 재개 시 즉시 첫 자국
	end

	-- 충돌 불꽃: ImpactAt 값이 바뀌면 버스트
	local impactAt = seat:GetAttribute("ImpactAt") :: number?
	if impactAt ~= nil and impactAt ~= prevImpact then
		prevImpact = impactAt
		if sparkEmitter and cfg.sparksEnabled then
			sparkEmitter:Emit(26)
		end
	end

	-- 퍼펙트 스타트 토스트
	local perfect = seat:GetAttribute("PerfectStart") :: number?
	if perfect ~= nil and perfect ~= prevPerfect then
		prevPerfect = perfect
		showPerfectToast()
	end

	-- 니트로 게이지
	gauge.Visible = true
	local shown = nitroActive and 1 or math.clamp(charge, 0, 1)
	fill.Size = UDim2.new(shown, -6, 1, -6)
	local col: Color3
	if nitroActive then
		col = Color3.fromRGB(120, 235, 255) -- 발사 중: 밝은 청록
	elseif charge >= 0.9 then
		col = Color3.fromRGB(200, 120, 255) -- 가득: 보라(최대 부스트)
	elseif dcfg and charge >= dcfg.minChargeToFire then
		col = Color3.fromRGB(255, 170, 60) -- 발사 가능: 주황
	else
		col = Color3.fromRGB(90, 170, 255) -- 충전 중: 파랑
	end
	fill.BackgroundColor3 = col
end)
