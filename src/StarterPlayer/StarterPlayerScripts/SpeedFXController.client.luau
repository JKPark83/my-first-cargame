--!strict
--[[
	SpeedFXController (클라이언트)
	-----------------------------
	"속도감"을 극대화하는 화면 연출. 차에 탑승해 달릴 때만 작동하고,
	하차/라운지 복귀 시 즉시 원래대로 부드럽게 복구된다. (전부 클라 후처리/카메라 → 에셋 불필요)

	  • FOV 워프   : 빠를수록·가속할수록 시야가 넓어져 "공간이 빨려들어가는" 느낌
	  • 모션블러   : BlurEffect 크기를 속도에 비례시켜 공간이 흐려지는 워프감
	  • 카메라 흔들림 : 고속/부스트일수록 강하게(살짝의 롤 포함)
	  • 비네팅     : 화면 가장자리를 어둡게 → 터널을 통과하는 느낌
	  • 부스트 순간 : FOV 펀치 + 색보정 플래시 + whoosh 효과음(+엔진 굉음은 CarController)

	값 조정은 GameConfig.SpeedFX 에서.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")

local GameConfig = require(ReplicatedStorage.GameConfig)
local cfg = (GameConfig :: any).SpeedFX
if not cfg or cfg.enabled == false then
	return
end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- ── 후처리 효과(Lighting 전역) ───────────────────────────────
local blur = Instance.new("BlurEffect")
blur.Name = "SpeedFXBlur"
blur.Size = 0
blur.Parent = Lighting

local cc = Instance.new("ColorCorrectionEffect")
cc.Name = "SpeedFXColor"
cc.Saturation = 0
cc.Brightness = 0
cc.Contrast = 0
cc.Parent = Lighting

-- ── DOF(로켓 전용, 평소엔 FarIntensity=0으로 비활성) ────────────
local dof = Instance.new("DepthOfFieldEffect")
dof.Name = "SpeedFXDof"
dof.FarIntensity = 0
dof.NearIntensity = 0
dof.InFocusRadius = 22
dof.FocusDistance = 0
dof.Parent = Lighting

-- ── 화면 가장자리 비네팅(4개 그라데이션 바, 에셋 불필요) ──────
local gui = Instance.new("ScreenGui")
gui.Name = "SpeedFX"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = -5 -- HUD 등 다른 UI 뒤에 깔리게
gui.Parent = playerGui

local function makeEdge(anchor: Vector2, pos: UDim2, size: UDim2, rotation: number): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	f.BackgroundTransparency = 1 -- 처음엔 숨김
	f.BorderSizePixel = 0
	f.AnchorPoint = anchor
	f.Position = pos
	f.Size = size
	f.ZIndex = 1
	local g = Instance.new("UIGradient")
	g.Rotation = rotation -- 0=좌→우, 90=상→하
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0), -- 바깥 가장자리: 불투명
		NumberSequenceKeypoint.new(1, 1), -- 안쪽: 투명
	})
	g.Parent = f
	f.Parent = gui
	return f
end

local edges = {
	makeEdge(Vector2.new(0.5, 0), UDim2.fromScale(0.5, 0), UDim2.new(1, 0, 0.32, 0), 90), -- 상단
	makeEdge(Vector2.new(0.5, 1), UDim2.fromScale(0.5, 1), UDim2.new(1, 0, 0.32, 0), 270), -- 하단
	makeEdge(Vector2.new(0, 0.5), UDim2.fromScale(0, 0.5), UDim2.new(0.22, 0, 1, 0), 0), -- 좌측
	makeEdge(Vector2.new(1, 0.5), UDim2.fromScale(1, 0.5), UDim2.new(0.22, 0, 1, 0), 180), -- 우측
}

-- ── 부스트 whoosh 효과음(로드되는 첫 id, 없으면 무음) ─────────
local whoosh: Sound? = nil
task.spawn(function()
	for _, id in ipairs(cfg.whooshIds or {}) do
		local s = Instance.new("Sound")
		s.SoundId = "rbxassetid://" .. tostring(id)
		s.Volume = 0.55
		s.Parent = SoundService
		local t0 = os.clock()
		while not s.IsLoaded and os.clock() - t0 < 4 do
			RunService.Heartbeat:Wait()
		end
		if s.IsLoaded and s.TimeLength > 0 then
			whoosh = s
			return
		end
		s:Destroy()
	end
end)

-- ── 상태 ────────────────────────────────────────────────────
local shakeIntensity = 0 -- 렌더 스텝에서 읽는 흔들림 세기(studs)
local curVig = 0
local boostPunch = 0 -- 부스트 시작 순간의 펀치(0.4초간 감쇠)
local prevBoosting = false
local prevSpeed = 0

local function findSeat(): VehicleSeat?
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local sp = hum and hum.SeatPart
	if sp and sp:IsA("VehicleSeat") and sp:GetAttribute("TopSpeed") then
		return sp :: VehicleSeat
	end
	return nil
end

-- ── 매 프레임 효과 갱신 ─────────────────────────────────────
RunService.Heartbeat:Connect(function(dt: number)
	local k = math.clamp(dt * cfg.smooth, 0, 1)
	local seat = findSeat()

	local speedF, accelF, boostF = 0, 0, 0
	local rocketBoosting = false -- 로켓 전용 플래그(DOF/비네팅 분기용)
	if seat then
		local v = seat.AssemblyLinearVelocity
		local speed = Vector3.new(v.X, 0, v.Z).Magnitude
		local topSpeed = (seat:GetAttribute("TopSpeed") :: number?) or 120
		speedF = math.clamp(speed / math.max(topSpeed, 1), 0, 1.15)
		accelF = math.clamp((speed - prevSpeed) / math.max(dt, 1 / 240) / 220, 0, 1)
		prevSpeed = speed

		local now = workspace:GetServerTimeNow()
		local boostEnd = seat:GetAttribute("BoostEndTime") :: number?
		local rocketEnd = seat:GetAttribute("RocketEndTime") :: number?
		local nitroEnd = seat:GetAttribute("NitroEndTime") :: number? -- 드리프트 미니터보/로켓스타트
			rocketBoosting = (rocketEnd ~= nil and now < rocketEnd) -- 로켓 전용 플래그
			local boosting = (boostEnd ~= nil and now < boostEnd)
				or rocketBoosting
				or (nitroEnd ~= nil and now < nitroEnd)
			boostF = boosting and 1 or 0

		-- 부스트 시작 순간: 펀치 + whoosh
		if boosting and not prevBoosting then
			boostPunch = 1
			if whoosh then
				whoosh.TimePosition = 0
				whoosh:Play()
			end
		end
		prevBoosting = boosting
	else
		prevBoosting = false
		prevSpeed = 0
		dof.FarIntensity = 0 -- 하차 시 DOF 즉시 0 복구
	end

	boostPunch = math.max(0, boostPunch - dt / 0.4)

	-- 목표값
	local targetFov = cfg.baseFov
		+ cfg.maxFovAdd * speedF
		+ cfg.accelFovAdd * accelF
		+ cfg.boostFovPunch * (boostF + 0.5 * boostPunch)
	local targetBlur = cfg.blurBoostExtra * boostF -- 일반속도 블러 제거(speedF 항 삭제)
	-- 로켓 중이면 터널 비네팅 강화, 아니면 속도/부스트 비례
	local targetVig = rocketBoosting
		and cfg.rocketTunnelVignette
		or math.clamp(cfg.vignetteMax * speedF + cfg.vignetteBoostExtra * boostF, 0, 0.72)
	local targetShake = cfg.shakeMax * speedF + cfg.shakeBoostExtra * (boostF * 0.5 + boostPunch)

	-- 적용(부드럽게 추종)
	local cam = workspace.CurrentCamera
	if cam then
		cam.FieldOfView = lerp(cam.FieldOfView, targetFov, k)
	end
	-- 로켓 중: 전역 블러 0 강제, 아니면 부스트 블러 추종
	if rocketBoosting then
		blur.Size = 0
	else
		blur.Size = lerp(blur.Size, targetBlur, k)
	end
	shakeIntensity = lerp(shakeIntensity, targetShake, k)
	cc.Saturation = lerp(cc.Saturation, 0.18 * (boostF * 0.5 + boostPunch * 0.5), k)
	cc.Brightness = lerp(cc.Brightness, 0.05 * boostPunch, k)
	cc.Contrast = lerp(cc.Contrast, 0.12 * boostF, k)

	-- 로켓 DOF: 내 차 선명 + 원경 흐림(FarIntensity), 로켓 종료·하차 시 즉시 0
	if rocketBoosting and cam and seat then
		local carPos = seat.Position
		local camPos = cam.CFrame.Position
		dof.FocusDistance = (camPos - carPos).Magnitude
		dof.FarIntensity = cfg.rocketDofFarIntensity
		dof.NearIntensity = 0
		dof.InFocusRadius = cfg.rocketDofInFocusRadius
	else
		dof.FarIntensity = 0 -- 로켓 종료 시 DOF 즉시 복구
	end

	curVig = lerp(curVig, targetVig, k)
	-- 로켓 중: 흰빛(220,240,255) 터널 틴트; 일반 부스트: 파랑빛 틴트
	local tint = rocketBoosting
		and Color3.fromRGB(220, 240, 255)
		or Color3.fromRGB(0, 0, 0):Lerp(Color3.fromRGB(40, 90, 170), boostF * 0.6)
	for _, e in ipairs(edges) do
		e.BackgroundTransparency = 1 - curVig
		e.BackgroundColor3 = tint
	end
end)

-- ── 카메라 흔들림(기본 카메라가 CFrame을 정한 "다음"에 오프셋) ──
RunService:BindToRenderStep("SpeedFXShake", Enum.RenderPriority.Camera.Value + 1, function()
	if shakeIntensity <= 0.002 then
		return
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local t = os.clock()
	local ox = math.noise(t * 23, 1.3) * shakeIntensity * 2
	local oy = math.noise(2.7, t * 23) * shakeIntensity * 2
	local roll = math.noise(t * 17, 5.1) * shakeIntensity * 0.05
	cam.CFrame = cam.CFrame * CFrame.new(ox, oy, 0) * CFrame.Angles(0, 0, roll)
end)
