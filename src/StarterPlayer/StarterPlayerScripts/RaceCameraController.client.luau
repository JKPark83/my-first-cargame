--!strict
--[[
	RaceCameraController (클라이언트)
	--------------------------------
	출발 카운트다운 동안 "영화 같은" 카메라 연출로 긴장감을 높인다.
	  • 카운트 3·2 : 출발지(내 차)를 중심으로 카메라가 천천히 회전 → 긴장감 ↑
	  • 카운트 1   : 출발 1초 전, 내 차 뒤로 부드럽게 복귀(이즈아웃)
	  • GO(0)      : 일반 주행 카메라(Custom)로 인계 → 곧바로 운전

	SpeedFXController(흔들림/FOV)와 충돌하지 않는다:
	  - 카운트다운엔 속도 0이라 흔들림 강도 0 → SpeedFX 흔들림 스텝은 일찍 return
	  - 이 컨트롤러는 흔들림(Camera+1)보다 나중(Camera+2) 우선순위로 CFrame을 확정
	  - FOV는 SpeedFX가 base 값으로 두므로 회전 중에도 자연스럽다
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes)

local player = Players.LocalPlayer

local ORBIT_STEP = "RaceOrbitCam"
local RETURN_STEP = "RaceReturnCam"
-- 기본 카메라 갱신 + SpeedFX 흔들림(Camera+1)보다 나중에 CFrame을 확정
local CAM_PRIORITY = Enum.RenderPriority.Camera.Value + 2

local ORBIT_RADIUS = 28 -- 출발지에서 카메라까지 수평 거리
local ORBIT_HEIGHT = 13 -- 카메라 높이
local ORBIT_SPEED = 0.9 -- rad/초 (3→1 약 2초 동안 ~100° 스윕)
local RETURN_TIME = 0.85 -- 차 뒤로 복귀하는 이징 시간(초)

local mode: "idle" | "orbit" | "return" = "idle"
local orbitBound = false
local returnBound = false
local orbitCenter = Vector3.zero
local orbitAngle = 0

local function getCamera(): Camera?
	return workspace.CurrentCamera
end

-- 내 차 시트의 CFrame (탑승 중일 때만)
local function myCarCFrame(): CFrame?
	local char = player.Character
	if not char then
		return nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if seat and seat:IsA("VehicleSeat") then
		return seat.CFrame
	end
	return nil
end

-- 회전 중심: 내 차 → (없으면) 캐릭터 → (없으면) 카메라 앞쪽
local function orbitCenterPos(): Vector3
	local cf = myCarCFrame()
	if cf then
		return cf.Position
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	local cam = getCamera()
	if cam then
		return cam.CFrame.Position + cam.CFrame.LookVector * 25
	end
	return Vector3.zero
end

local function unbindOrbit()
	if orbitBound then
		RunService:UnbindFromRenderStep(ORBIT_STEP)
		orbitBound = false
	end
end

local function unbindReturn()
	if returnBound then
		RunService:UnbindFromRenderStep(RETURN_STEP)
		returnBound = false
	end
end

-- 일반(추적) 카메라로 원복 — 안전망
local function ensureDefault()
	unbindOrbit()
	unbindReturn()
	mode = "idle"
	local cam = getCamera()
	if cam and cam.CameraType == Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Custom
	end
end

-- 출발지 주위를 도는 카메라 시작
local function startOrbit()
	local cam = getCamera()
	if not cam then
		return
	end
	orbitCenter = orbitCenterPos()
	orbitAngle = 0
	mode = "orbit"
	unbindReturn()
	cam.CameraType = Enum.CameraType.Scriptable
	RunService:BindToRenderStep(ORBIT_STEP, CAM_PRIORITY, function(dt: number)
		local c = getCamera()
		if not c then
			return
		end
		orbitAngle += dt * ORBIT_SPEED
		-- 차가 있으면 매 프레임 최신 위치를 중심으로(동결 상태라 사실상 고정)
		local cf = myCarCFrame()
		if cf then
			orbitCenter = cf.Position
		end
		local ex = math.cos(orbitAngle) * ORBIT_RADIUS
		local ez = math.sin(orbitAngle) * ORBIT_RADIUS
		local eye = orbitCenter + Vector3.new(ex, ORBIT_HEIGHT, ez)
		c.CFrame = CFrame.lookAt(eye, orbitCenter + Vector3.new(0, 2.5, 0))
	end)
	orbitBound = true
end

-- 내 차 뒤로 부드럽게 복귀 후 일반 카메라로 인계
local function returnToCar()
	local cam = getCamera()
	if not cam then
		ensureDefault()
		return
	end
	local cf = myCarCFrame()
	if not cf then
		ensureDefault()
		return
	end
	unbindOrbit()
	mode = "return"
	-- 차 뒤 위쪽에서 차 앞을 바라보는 시점(주행 카메라와 유사). 차 전방 = -Z.
	local eye = (cf * CFrame.new(0, 5.8, 15)).Position -- +Z = 차 뒤
	local look = (cf * CFrame.new(0, 1.5, -8)).Position -- -Z = 차 앞
	local targetCFrame = CFrame.lookAt(eye, look)
	local fromCFrame = cam.CFrame
	local elapsed = 0
	cam.CameraType = Enum.CameraType.Scriptable
	RunService:BindToRenderStep(RETURN_STEP, CAM_PRIORITY, function(dt: number)
		local c = getCamera()
		if not c then
			return
		end
		elapsed += dt
		local a = math.clamp(elapsed / RETURN_TIME, 0, 1)
		local e = 1 - (1 - a) * (1 - a) -- 이즈아웃(처음 빠르고 끝에서 부드럽게)
		c.CFrame = fromCFrame:Lerp(targetCFrame, e)
		if a >= 1 then
			unbindReturn()
			c.CameraType = Enum.CameraType.Custom -- 기본 추적 카메라로 인계
			mode = "idle"
		end
	end)
	returnBound = true
end

-- 카운트다운 수신: 3·2 → 회전, 1 → 복귀, 0(GO) → 안전망
Remotes.Event("RaceCountdown").OnClientEvent:Connect(function(info)
	local v = info and info.value
	if v == nil then
		return
	end
	if v >= 2 then
		if mode ~= "orbit" then
			startOrbit()
		end
	elseif v == 1 then
		returnToCar() -- 출발 1초 전 → 내 차 뒤로 복귀 시작
	else -- v == 0 : GO
		if mode == "orbit" then
			returnToCar() -- 혹시 "1" 신호를 놓쳤어도 지금이라도 복귀
		end
	end
end)

-- 경주가 끝나거나 라운지로 돌아가면 카메라 원복(안전망)
Remotes.Event("RaceStateChanged").OnClientEvent:Connect(function(info)
	if info and info.state ~= "Racing" then
		ensureDefault()
	end
end)

Remotes.Event("RaceFinished").OnClientEvent:Connect(function()
	ensureDefault()
end)
