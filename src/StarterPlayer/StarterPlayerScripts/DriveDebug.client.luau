--!strict
--[[
	DriveDebug (클라이언트) — "출발이 안 된다" 문제를 눈으로 확인하기 위한 임시 진단 오버레이.
	------------------------------------------------------------------------------------
	화면 좌상단에 빌드 마커 + 실시간 주행 상태를 띄운다. 이걸로 두 가지를 한 번에 확인한다.

	1) "예전 빌드를 로딩 중인가?" → 화면에 아래 BUILD_TAG가 보이면 = 최신 빌드를 돌리는 중.
	   (아무것도 안 보이면 예전 파일을 열고 있는 것 → 파일을 닫았다가 다시 열거나 Rojo 재동기화)
	2) "왜 안 가는가?" → frozen / throttle / speed / 키입력 값을 보고 원인을 바로 가린다.
	      • frozen=true 가 GO 후에도 계속이면      → 동결 해제 문제
	      • 키는 눌리는데 throttle=0 이면           → 입력 미반영 문제
	      • 입력은 있는데 speed/moved≈0 이면        → 네트워크 소유권 문제
	      • speed가 오르고 moved>0 이면             → 정상 주행

	문제 해결이 확인되면 이 파일은 삭제한다.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

-- 새 빌드를 로딩했는지 한눈에 확인하는 마커(수정할 때마다 숫자를 올린다)
-- v3: 시트 ThrottleFloat 무시하고 키보드를 직접 읽어 구동하도록 바꿈. throttle 표시는 참고용(0이어도 정상).
local BUILD_TAG = "🔧 DRIVE DEBUG · build 0621-v3 (키보드 직접구동)"

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "DriveDebug"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 9999 -- 다른 UI보다 위에
gui.Parent = playerGui

local label = Instance.new("TextLabel")
label.Size = UDim2.new(0, 560, 0, 132)
label.Position = UDim2.new(0, 12, 0, 12)
label.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
label.BackgroundTransparency = 0.25
label.BorderSizePixel = 0
label.TextColor3 = Color3.fromRGB(120, 255, 160)
label.Font = Enum.Font.Code
label.TextSize = 18
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextYAlignment = Enum.TextYAlignment.Top
label.Text = BUILD_TAG
label.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = label
local pad = Instance.new("UIPadding")
pad.PaddingLeft = UDim.new(0, 10)
pad.PaddingTop = UDim.new(0, 8)
pad.Parent = label

local function findSeat(): VehicleSeat?
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local sp = hum and hum.SeatPart
	if sp and sp:IsA("VehicleSeat") and sp:GetAttribute("TopSpeed") then
		return sp :: VehicleSeat
	end
	return nil
end

local lastPos: Vector3? = nil

RunService.Heartbeat:Connect(function(dt: number)
	local seat = findSeat()
	if not seat then
		lastPos = nil
		label.TextColor3 = Color3.fromRGB(170, 170, 170)
		label.Text = BUILD_TAG .. "\n\n차에 타고 있지 않음.\n경주를 시작하면 자동으로 차에 탑승합니다."
		return
	end

	local frozen = seat:GetAttribute("RaceFrozen") == true
	local throttle = seat.ThrottleFloat
	local steer = seat.SteerFloat
	local v = seat.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude

	local pos = seat.Position
	local moved = 0
	if lastPos then
		moved = (Vector3.new(pos.X - lastPos.X, 0, pos.Z - lastPos.Z)).Magnitude / math.max(dt, 1 / 240)
	end
	lastPos = pos

	local keyFwd = UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up)
	local keyBack = UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down)
	local wantsDrive = math.abs(throttle) > 0.1 or keyFwd or keyBack

	local verdict: string
	local color: Color3
	if frozen then
		verdict = "동결 중(카운트다운). GO 되면 풀립니다."
		color = Color3.fromRGB(255, 210, 0)
	elseif not wantsDrive then
		verdict = "입력 대기 — 방향키(↑/↓) 또는 W/S를 눌러보세요."
		color = Color3.fromRGB(170, 170, 170)
	elseif speed < 3 and moved < 3 then
		-- v3부터 키보드 직접구동이라 throttle=0이어도 키만 눌리면 가야 정상.
		-- 그래도 안 가면 = 네트워크 소유권 문제(0.5초 후 자가복구가 재착석 시도).
		verdict = "❌ 안 움직임 — 소유권 문제 의심(자가복구 시도 중...)"
		color = Color3.fromRGB(255, 90, 90)
	else
		verdict = "✅ 정상 주행 중! (키보드 직접구동)"
		color = Color3.fromRGB(120, 255, 160)
	end

	label.TextColor3 = color
	label.Text = string.format(
		"%s\nfrozen=%s   throttle=%.2f   steer=%.2f\nspeed=%.1f   moved=%.1f/s   keyFwd=%s  keyBack=%s\n→ %s",
		BUILD_TAG,
		tostring(frozen),
		throttle,
		steer,
		speed,
		moved,
		tostring(keyFwd),
		tostring(keyBack),
		verdict
	)
end)
