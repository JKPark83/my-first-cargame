--!strict
--[[
	CarSpawner
	-----------
	플레이어의 선택 차량을 부품으로 조립해 스폰합니다.
	- VehicleSeat를 차체(PrimaryPart)로 사용해 탑승 처리 + 물리 본체
	- 그 위에 후드/캐빈/범퍼/스포일러/헤드·테일라이트/바퀴를 용접해 "차" 실루엣 구성
	- 등급별 성능 스탯을 어트리뷰트로 부착 (클라 컨트롤러가 읽음)
	- 저장된 커스터마이징(색상/휠/네온/번호판)을 적용
	- 루프되는 3D 엔진 사운드를 부착 (클라 CarController가 속도에 맞춰 피치 조절)
	- 네트워크 소유권을 운전자에게 넘겨 아케이드 조작을 부드럽게

	좌표 규약: 시트 로컬에서 전진 방향은 -Z (LookVector). 따라서
	  앞(후드/헤드라이트/앞범퍼) = -Z,  뒤(트렁크/스포일러/테일라이트) = +Z.

	실제 주행 물리는 클라이언트의 CarController가 담당합니다.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local GameConfig = require(ReplicatedStorage.GameConfig)
local DataManager = require(script.Parent.DataManager)

local CarSpawner = {}

-- =====================================================================
-- 운전자 착석 + 네트워크 소유권 "확실히" 부여 (검증 + 재시도)
-- =====================================================================
-- ⚠️ "출발 직후 차가 안 움직이고, 내렸다 다시 타야 가던" 버그의 근본 해결.
--    원인: 착석/소유권 설정을 단발(pcall) 호출로만 했더니, 스폰 직후 프레임 경합·
--    스트리밍 타이밍에서 조용히 실패해도 그냥 넘어가 소유권이 서버에 남았다.
--    그러면 클라이언트(CarController)가 매 프레임 쓰는 속도가 무시되어 차가 안 움직였고,
--    재탑승하면 엔진이 착석 시 소유권을 자동으로 운전자에게 줘서 그제서야 풀렸다.
--    → 여기서 "착석됨 + 소유권=운전자"가 될 때까지 검증하며 재시도해 확실히 굳힌다.
function CarSpawner.seatDriver(seat: VehicleSeat, humanoid: Humanoid, player: Player): boolean
	for _ = 1, 14 do
		-- 차/캐릭터가 사라졌으면 중단
		if not seat.Parent or not humanoid.Parent or humanoid.Health <= 0 then
			return false
		end
		-- 아직 이 시트에 안 앉아 있으면 앉힌다(이미 앉아 있으면 건드리지 않음 → 재탑승 히치 방지)
		if seat.Occupant ~= humanoid then
			pcall(function()
				seat:Sit(humanoid)
			end)
		end
		RunService.Heartbeat:Wait() -- 착석/물리 반영에 한 프레임 양보
		-- 소유권을 운전자에게(앵커를 안 쓰므로 정상 동작). 실패해도 다음 루프에서 재시도.
		local setOk = pcall(function()
			seat:SetNetworkOwner(player)
		end)
		if setOk and seat.Occupant == humanoid then
			-- 검증: 실제로 소유권이 운전자에게 박혔는가
			local owner: Player? = nil
			local getOk = pcall(function()
				owner = seat:GetNetworkOwner()
			end)
			if getOk and owner == player then
				return true -- 성공: 착석 + 소유권 확정
			end
		end
		task.wait(0.07)
	end
	return false
end

-- 차체 기본 치수 (시트 = 하부 바디)
local BODY_W = 6.6
local BODY_H = 1.4
local BODY_L = 14

local function color3FromArray(arr: { number }?, fallback: Color3): Color3
	if type(arr) == "table" and #arr >= 3 then
		return Color3.fromRGB(arr[1], arr[2], arr[3])
	end
	return fallback
end

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = a
end

-- 시트에 용접되는 장식 파트 생성 헬퍼 (충돌 없음 / 질량 없음)
-- offset: 시트 중심 기준 로컬 오프셋 CFrame
local function decor(model: Model, seat: BasePart, offset: CFrame, props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = false
	p.CanCollide = false
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in pairs(props) do
		(p :: any)[k] = v
	end
	p.CFrame = seat.CFrame * offset
	p.Parent = model
	weld(seat, p)
	return p
end

-- 타이어 반경(3.3/2). 클라이언트 CarController가 굴림 회전량 계산에 사용 (시트 어트리뷰트로 전달)
local WHEEL_RADIUS = 1.65

-- 바퀴 4개 생성 (타이어 + 휠 캡 + 브레이크 디스크)
-- 실린더는 로컬 X축으로 뻗으므로, 회전 없이 두면 원형 면이 좌/우(±X)를 향한다 → 올바른 바퀴 방향.
-- 핵심: 타이어를 WeldConstraint가 아니라 Motor6D로 시트에 연결한다. 클라이언트가 매 프레임
--       Motor6D.C0를 회전시켜 앞바퀴 조향(Y축 yaw) + 전체 바퀴 굴림(X축 spin)을 시각화한다.
--       림/디스크는 타이어에 강체 용접되어 타이어와 함께 돈다.
local function buildWheels(model: Model, seat: BasePart, wheelColor: Color3)
	local halfW = BODY_W / 2
	local halfL = BODY_L / 2
	local wheelX = halfW + 0.05 -- 살짝 바깥으로
	local axleZ = halfL - 2.6 -- 앞/뒤 차축 위치
	local wheelY = 0.9 -- 시트 중심 기준 (반경 1.65 → 바닥 ≈ 지면)

	local rimColor = wheelColor:Lerp(Color3.fromRGB(225, 225, 230), 0.55)

	local function spinPart(props: { [string]: any }, attachTo: BasePart, cf: CFrame): Part
		local p = Instance.new("Part")
		p.Anchored = false
		p.CanCollide = false
		p.Massless = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		for k, v in pairs(props) do
			(p :: any)[k] = v
		end
		p.CFrame = cf
		p.Parent = model
		weld(attachTo, p)
		return p
	end

	for _, sx in ipairs({ 1, -1 }) do
		for _, sz in ipairs({ 1, -1 }) do
			-- 전진 = -Z 이므로 -Z축(sz<0) 바퀴가 앞바퀴 → 조향 대상
			local isFront = sz < 0
			local center = CFrame.new(sx * wheelX, wheelY, sz * axleZ)

			-- 타이어(메인): Motor6D로 시트에 연결
			local tire = Instance.new("Part")
			tire.Name = isFront and "WheelFront" or "WheelRear"
			tire.Shape = Enum.PartType.Cylinder
			tire.Size = Vector3.new(1.6, 3.3, 3.3)
			tire.Color = wheelColor
			tire.Material = Enum.Material.SmoothPlastic
			tire.Anchored = false
			tire.CanCollide = false
			tire.Massless = true
			tire.TopSurface = Enum.SurfaceType.Smooth
			tire.BottomSurface = Enum.SurfaceType.Smooth
			tire.CFrame = seat.CFrame * center
			tire.Parent = model

			local motor = Instance.new("Motor6D")
			motor.Name = "WheelMotor"
			motor.Part0 = seat
			motor.Part1 = tire
			motor.C0 = center -- 회전=단위 → 실린더 축 = 시트 X = 좌우 (올바른 바퀴 방향)
			motor.C1 = CFrame.new()
			motor:SetAttribute("FrontWheel", isFront)
			motor.Parent = seat

			-- 림 + 브레이크 디스크: 타이어에 강체 용접 (타이어와 함께 회전)
			spinPart({
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(1.5, 2.0, 2.0),
				Color = rimColor,
				Material = Enum.Material.Metal,
			}, tire, tire.CFrame * CFrame.new(sx * 0.22, 0, 0))
			spinPart({
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.2, 0.9, 0.9),
				Color = Color3.fromRGB(60, 63, 72),
				Material = Enum.Material.Metal,
			}, tire, tire.CFrame * CFrame.new(sx * 0.34, 0, 0))
		end
	end
end

-- 차량 모델 조립
-- 반환: Model (PrimaryPart = VehicleSeat)
function CarSpawner.build(carDef: any, custom: any?): Model
	local model = Instance.new("Model")
	model.Name = "Car_" .. carDef.id

	local bodyColor = color3FromArray(custom and custom.bodyColor, carDef.defaultColor)
	local wheelColor = color3FromArray(custom and custom.wheelColor, Color3.fromRGB(25, 25, 28))
	local neonColor = color3FromArray(custom and custom.neonColor, Color3.fromRGB(0, 0, 0))
	local darkBody = bodyColor:Lerp(Color3.new(0, 0, 0), 0.35)
	local trim = Color3.fromRGB(35, 37, 45)

	-- 하부 바디 = VehicleSeat (탑승 + 물리 본체)
	local seat = Instance.new("VehicleSeat")
	seat.Name = "Chassis"
	seat.Size = Vector3.new(BODY_W, BODY_H, BODY_L)
	seat.Color = bodyColor
	seat.Material = Enum.Material.SmoothPlastic
	seat.MaxSpeed = carDef.stats.topSpeed
	seat.Torque = 0 -- 직접 물리 제어하므로 시트 기본 구동은 끔
	seat.TurnSpeed = 0
	seat.HeadsUpDisplay = false
	seat.TopSurface = Enum.SurfaceType.Smooth
	seat.BottomSurface = Enum.SurfaceType.Smooth
	seat.Parent = model
	model.PrimaryPart = seat

	-- ── 전면부 ──────────────────────────────────────────────
	-- 낮고 길게 깔린 후드(보닛): 앞으로 살짝 내려가는 웨지 실루엣
	decor(model, seat, CFrame.new(0, 1.0, -4.3) * CFrame.Angles(math.rad(-3), 0, 0), {
		Size = Vector3.new(BODY_W - 0.5, 0.85, 5.6),
		Color = bodyColor,
		Material = Enum.Material.SmoothPlastic,
	})
	-- 후드 에어 스쿱(통풍구)
	decor(model, seat, CFrame.new(0, 1.5, -3.7), {
		Size = Vector3.new(1.7, 0.5, 2.2),
		Color = trim,
		Material = Enum.Material.SmoothPlastic,
	})
	-- 프런트 노즈/범퍼
	decor(model, seat, CFrame.new(0, 0.35, -6.7), {
		Size = Vector3.new(BODY_W + 0.2, 1.2, 1.5),
		Color = darkBody,
		Material = Enum.Material.SmoothPlastic,
	})
	-- 프런트 그릴(흡기구, 무광 블랙)
	decor(model, seat, CFrame.new(0, 0.15, -7.35), {
		Size = Vector3.new(BODY_W - 1.8, 0.7, 0.4),
		Color = Color3.fromRGB(18, 19, 24),
		Material = Enum.Material.SmoothPlastic,
	})
	-- 프런트 스플리터(립) — 바닥에 낮게 깔림
	decor(model, seat, CFrame.new(0, -0.4, -6.95), {
		Size = Vector3.new(BODY_W + 1.0, 0.25, 1.6),
		Color = trim,
		Material = Enum.Material.SmoothPlastic,
	})
	-- 카나드(앞 코너 핀) 좌우
	for _, sx in ipairs({ 1, -1 }) do
		decor(model, seat, CFrame.new(sx * (BODY_W / 2 + 0.15), 0.05, -6.5), {
			Size = Vector3.new(0.9, 0.12, 1.3),
			Color = trim,
			Material = Enum.Material.Metal,
		})
	end
	-- 헤드라이트(앞, 얇은 LED 바 — 따뜻한 흰색 네온)
	for _, sx in ipairs({ 1, -1 }) do
		decor(model, seat, CFrame.new(sx * 2.45, 0.7, -7.0), {
			Size = Vector3.new(1.5, 0.35, 0.3),
			Color = Color3.fromRGB(255, 246, 205),
			Material = Enum.Material.Neon,
		})
	end

	-- ── 캐빈/그린하우스 ────────────────────────────────────
	-- 앞 유리 (뒤로 기울임)
	decor(model, seat, CFrame.new(0, 1.55, -1.2) * CFrame.Angles(math.rad(30), 0, 0), {
		Size = Vector3.new(BODY_W - 1.4, 1.6, 0.22),
		Color = Color3.fromRGB(155, 210, 235),
		Material = Enum.Material.Glass,
		Transparency = 0.4,
	})
	-- 운전석 뒤 패스트백 캐빈/롤후프 (머리 위는 비워 클리핑 방지)
	decor(model, seat, CFrame.new(0, 1.5, 2.5), {
		Size = Vector3.new(BODY_W - 1.1, 1.8, 3.0),
		Color = darkBody,
		Material = Enum.Material.SmoothPlastic,
	})
	-- 리어 윈도(뒤로 누운 글라스)
	decor(model, seat, CFrame.new(0, 1.5, 1.0) * CFrame.Angles(math.rad(-32), 0, 0), {
		Size = Vector3.new(BODY_W - 1.6, 1.4, 0.2),
		Color = Color3.fromRGB(150, 205, 230),
		Material = Enum.Material.Glass,
		Transparency = 0.45,
	})
	-- 사이드 윈도(그린하우스) 좌우
	for _, sx in ipairs({ 1, -1 }) do
		decor(model, seat, CFrame.new(sx * (BODY_W / 2 - 0.55), 1.5, 1.9), {
			Size = Vector3.new(0.18, 1.0, 2.6),
			Color = Color3.fromRGB(40, 44, 52),
			Material = Enum.Material.Glass,
			Transparency = 0.35,
		})
	end
	-- 사이드 미러 좌우
	for _, sx in ipairs({ 1, -1 }) do
		decor(model, seat, CFrame.new(sx * (BODY_W / 2 + 0.35), 1.45, -0.7), {
			Size = Vector3.new(0.7, 0.32, 0.5),
			Color = darkBody,
			Material = Enum.Material.SmoothPlastic,
		})
	end

	-- ── 측면 ───────────────────────────────────────────────
	-- 사이드 도어 패널(벨트라인)
	for _, sx in ipairs({ 1, -1 }) do
		decor(model, seat, CFrame.new(sx * (BODY_W / 2 - 0.1), 0.95, 0.6), {
			Size = Vector3.new(0.3, 0.9, 7.6),
			Color = darkBody,
			Material = Enum.Material.SmoothPlastic,
		})
	end
	-- 사이드 스커트(낮게 깔린 느낌)
	for _, sx in ipairs({ 1, -1 }) do
		decor(model, seat, CFrame.new(sx * (BODY_W / 2 - 0.02), -0.35, 0.4), {
			Size = Vector3.new(0.35, 0.7, 9.4),
			Color = trim,
			Material = Enum.Material.SmoothPlastic,
		})
	end
	-- 펜더 플레어 ×4 (바퀴 위 근육질 아치)
	local flareZ = BODY_L / 2 - 2.6
	for _, sx in ipairs({ 1, -1 }) do
		for _, sz in ipairs({ 1, -1 }) do
			decor(model, seat, CFrame.new(sx * (BODY_W / 2 + 0.05), 0.7, sz * flareZ), {
				Size = Vector3.new(0.9, 1.3, 4.0),
				Color = darkBody,
				Material = Enum.Material.SmoothPlastic,
			})
		end
	end

	-- ── 후면부 ─────────────────────────────────────────────
	-- 트렁크 데크(패스트백에서 이어지는 낮은 데크)
	decor(model, seat, CFrame.new(0, 1.1, 4.7), {
		Size = Vector3.new(BODY_W - 0.5, 0.8, 4.6),
		Color = bodyColor,
		Material = Enum.Material.SmoothPlastic,
	})
	-- 리어 범퍼
	decor(model, seat, CFrame.new(0, 0.35, 6.75), {
		Size = Vector3.new(BODY_W + 0.2, 1.2, 1.4),
		Color = darkBody,
		Material = Enum.Material.SmoothPlastic,
	})
	-- 리어 디퓨저(무광 블랙, 바닥)
	decor(model, seat, CFrame.new(0, -0.35, 6.9), {
		Size = Vector3.new(BODY_W - 0.2, 0.5, 1.2),
		Color = Color3.fromRGB(18, 19, 24),
		Material = Enum.Material.SmoothPlastic,
	})
	-- 듀얼 배기구 (뒤로 향한 실린더)
	for _, sx in ipairs({ 1, -1 }) do
		decor(model, seat, CFrame.new(sx * 1.3, -0.2, 7.5) * CFrame.Angles(0, math.rad(90), 0), {
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.9, 0.62, 0.62),
			Color = Color3.fromRGB(150, 152, 160),
			Material = Enum.Material.Metal,
		})
	end
	-- 풀폭 LED 테일라이트 바 (빨강 네온)
	decor(model, seat, CFrame.new(0, 0.95, 7.45), {
		Size = Vector3.new(BODY_W - 0.6, 0.4, 0.24),
		Color = Color3.fromRGB(235, 45, 45),
		Material = Enum.Material.Neon,
	})

	-- ── 리어 윙(대형 스포일러) ─────────────────────────────
	for _, sx in ipairs({ 1, -1 }) do
		decor(model, seat, CFrame.new(sx * (BODY_W / 2 - 0.5), 2.05, 6.5), {
			Size = Vector3.new(0.3, 1.3, 1.9),
			Color = trim,
			Material = Enum.Material.Metal,
		})
	end
	decor(model, seat, CFrame.new(0, 2.65, 6.55) * CFrame.Angles(math.rad(-8), 0, 0), {
		Size = Vector3.new(BODY_W + 0.3, 0.28, 1.7),
		Color = darkBody,
		Material = Enum.Material.SmoothPlastic,
	})

	-- ── 레이싱 스트라이프(후드/데크, 운전석 영역은 피함) ──
	local accent = Color3.fromRGB(245, 246, 250)
	for _, sx in ipairs({ 1, -1 }) do
		decor(model, seat, CFrame.new(sx * 0.95, 1.46, -4.3), {
			Size = Vector3.new(0.55, 0.08, 5.4),
			Color = accent,
			Material = Enum.Material.SmoothPlastic,
		})
		decor(model, seat, CFrame.new(sx * 0.95, 1.52, 4.7), {
			Size = Vector3.new(0.55, 0.08, 4.4),
			Color = accent,
			Material = Enum.Material.SmoothPlastic,
		})
	end

	-- 바퀴
	buildWheels(model, seat, wheelColor)

	-- 네온 언더글로우 (neonColor가 검정이면 꺼짐 취급)
	if neonColor ~= Color3.fromRGB(0, 0, 0) then
		local neon = decor(model, seat, CFrame.new(0, -0.75, 0), {
			Size = Vector3.new(BODY_W + 0.3, 0.4, BODY_L + 0.4),
			Color = neonColor,
			Material = Enum.Material.Neon,
			Transparency = 0.1,
		})
		local light = Instance.new("PointLight")
		light.Color = neonColor
		light.Range = 14
		light.Brightness = 2
		light.Parent = neon
	end

	-- 번호판 (뒤 범퍼, SurfaceGui 텍스트)
	local plateText = (custom and type(custom.plate) == "string" and custom.plate ~= "") and custom.plate or "RACER"
	local plate = decor(model, seat, CFrame.new(0, 0.55, 7.62), {
		Size = Vector3.new(3.4, 0.9, 0.16),
		Color = Color3.fromRGB(245, 245, 245),
		Material = Enum.Material.SmoothPlastic,
	})
	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Face = Enum.NormalId.Front
	surfaceGui.Parent = plate
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = string.upper(string.sub(plateText, 1, 8))
	label.TextColor3 = Color3.fromRGB(30, 30, 30)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = surfaceGui

	-- 스티커/데칼 적용 (assetId가 0이면 생략) — 후드 위
	if custom and type(custom.sticker) == "string" then
		for _, s in ipairs(GameConfig.Customization.stickers) do
			if s.id == custom.sticker and s.assetId and s.assetId > 0 then
				local decal = Instance.new("Decal")
				decal.Texture = "rbxassetid://" .. tostring(s.assetId)
				decal.Face = Enum.NormalId.Top
				decal.Parent = seat
			end
		end
	end

	-- 루프 엔진 사운드 (3D 위치) — 클라가 속도에 맞춰 피치/볼륨 조절
	local engine = Instance.new("Sound")
	engine.Name = "Engine"
	engine.SoundId = "rbxassetid://" .. tostring(GameConfig.Audio.engineSoundIds[1])
	engine.Looped = true
	engine.Volume = GameConfig.Audio.idleVolume
	engine.PlaybackSpeed = GameConfig.Audio.idlePlaybackSpeed
	engine.RollOffMode = Enum.RollOffMode.InverseTapered
	engine.RollOffMinDistance = GameConfig.Audio.rollOffMinDistance
	engine.RollOffMaxDistance = GameConfig.Audio.rollOffMaxDistance
	engine.Playing = true -- 서버에서 켜두면 모든 클라가 위치 기반으로 듣는다
	engine.Parent = seat

	-- 차 이름표: 차량 위에 떠 있는 BillboardGui (기본값 "박서우차")
	local carName = (custom and type(custom.name) == "string" and custom.name ~= "") and custom.name or "박서우차"
	local nameGui = Instance.new("BillboardGui")
	nameGui.Name = "CarName"
	nameGui.Size = UDim2.fromOffset(220, 52)
	nameGui.StudsOffset = Vector3.new(0, 4.6, 0)
	nameGui.AlwaysOnTop = false
	nameGui.MaxDistance = 280
	nameGui.LightInfluence = 0
	nameGui.Adornee = seat
	nameGui.Parent = seat
	local nameBg = Instance.new("Frame")
	nameBg.Size = UDim2.fromScale(1, 1)
	nameBg.BackgroundColor3 = Color3.fromRGB(12, 14, 20)
	nameBg.BackgroundTransparency = 0.35
	nameBg.BorderSizePixel = 0
	nameBg.Parent = nameGui
	local nameCorner = Instance.new("UICorner")
	nameCorner.CornerRadius = UDim.new(0.5, 0)
	nameCorner.Parent = nameBg
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.fromScale(0.9, 0.74)
	nameLabel.Position = UDim2.fromScale(0.05, 0.13)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = carName
	nameLabel.TextColor3 = Color3.fromRGB(245, 246, 250)
	nameLabel.TextStrokeTransparency = 0.4
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextScaled = true
	nameLabel.Parent = nameBg

	-- 성능 스탯을 어트리뷰트로 부착 (클라 컨트롤러가 읽음)
	seat:SetAttribute("TopSpeed", carDef.stats.topSpeed)
	seat:SetAttribute("Accel", carDef.stats.accel)
	seat:SetAttribute("Handling", carDef.stats.handling)
	seat:SetAttribute("Grip", carDef.stats.grip)
	seat:SetAttribute("WheelRadius", WHEEL_RADIUS) -- 클라 CarController 바퀴 굴림 계산용
	model:SetAttribute("CarId", carDef.id)

	return model
end

-- 차 위 이름표(BillboardGui "CarName")의 텍스트를 운전자 이름으로 교체
function CarSpawner.setNameTag(model: Model, text: string)
	local seat = model.PrimaryPart
	if not seat then
		return
	end
	local gui = seat:FindFirstChild("CarName")
	if not gui then
		return
	end
	local label = gui:FindFirstChildWhichIsA("TextLabel", true)
	if label then
		(label :: TextLabel).Text = text
	end
end

-- AI 봇 차량 스폰 (키네매틱: 앵커 + 충돌 없음, RaceManager가 경로를 따라 매 프레임 이동)
function CarSpawner.spawnBot(spawnCFrame: CFrame, parent: Instance?, botName: string, bodyColor: { number }?): Model?
	local botCfg = (GameConfig :: any).Bots
	local carDef = GameConfig.CarsById[botCfg.carId] or GameConfig.CarsById[GameConfig.Economy.defaultCarId]
	if not carDef then
		return nil
	end

	local model = CarSpawner.build(carDef, { bodyColor = bodyColor })
	model:PivotTo(spawnCFrame)

	-- 봇은 물리 시뮬레이션 대신 서버가 CFrame으로 직접 이동시킨다.
	-- PrimaryPart(시트)를 앵커하면 용접/Motor6D로 붙은 차체 전체가 함께 따라온다.
	local seat = model.PrimaryPart :: VehicleSeat
	seat.Anchored = true
	seat.Disabled = true -- 플레이어가 봇 차에 우발적으로 탑승하지 못하게
	-- 바퀴/장식 파트는 충돌을 끄되, 차체(시트) 한 개만 충돌을 켜서
	-- 플레이어 차와 봇이 실제로 "부딪히게" 한다. 봇은 앵커 상태라 밀리지 않는
	-- "움직이지 않는 범퍼"가 되고, 플레이어는 부딪히면 튕기며 감속한다(충돌 불꽃 FX 트리거).
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			(d :: BasePart).CanCollide = false
		elseif d:IsA("Sound") then
			d:Destroy() -- 봇 엔진음 제거(다수 봇의 소음 누적 방지)
		end
	end
	seat.CanCollide = true -- 차체 충돌 박스: 플레이어와의 차대차 충돌 활성화

	CarSpawner.setNameTag(model, "🤖 " .. botName)
	model:SetAttribute("IsBot", true)
	model.Parent = parent or workspace
	return model
end

-- 플레이어를 위해 차량을 스폰하고 탑승시킴
function CarSpawner.spawnFor(player: Player, spawnCFrame: CFrame, parent: Instance?): Model?
	local data = DataManager.get(player)
	if not data then
		return nil
	end
	local carDef = GameConfig.CarsById[data.selectedCar] or GameConfig.CarsById[GameConfig.Economy.defaultCarId]
	if not carDef then
		return nil
	end
	local custom = data.customizations[carDef.id]

	local model = CarSpawner.build(carDef, custom)
	model:PivotTo(spawnCFrame)
	-- 이름표를 운전자(플레이어) 이름으로 표시 → 누가 누구인지 식별
	CarSpawner.setNameTag(model, player.DisplayName)

	local seat = model.PrimaryPart :: VehicleSeat
	-- 태어날 때부터 동결 상태로 둔다(클라가 RaceFrozen을 보고 제자리 유지) → 출발 카운트다운
	-- 시작 전에 차가 굴러가거나 미끄러지지 않는다. GO 때 RaceManager가 false로 푼다.
	seat:SetAttribute("RaceFrozen", true)
	model.Parent = parent or workspace

	-- 캐릭터를 시트에 앉히고 네트워크 소유권을 운전자에게 "확실히" 부여한다(검증 + 재시도).
	-- 단발 호출이 아니라 seatDriver로 끝까지 확인해야 출발 직후 멈춤 버그가 안 난다.
	local character = player.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			task.spawn(function()
				CarSpawner.seatDriver(seat, humanoid, player)
			end)
		end
	end

	model:SetAttribute("OwnerUserId", player.UserId)
	return model
end

-- 차고 UI의 3D 미리보기용: 각 차량을 한 번씩 빌드해 ReplicatedStorage.CarPreviews 에 보관한다.
-- 클라이언트가 ViewportFrame에 이 모델을 복제해 실제 차 외형을 보여준다.
-- 정적 표시용이므로 모든 파트를 앵커하고 충돌/사운드/이름표를 제거한다.
function CarSpawner.setupPreviews()
	local existing = ReplicatedStorage:FindFirstChild("CarPreviews")
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "CarPreviews"
	for _, carDef in ipairs(GameConfig.Cars) do
		local m = CarSpawner.build(carDef)
		m.Name = carDef.id
		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("BasePart") then
				(d :: BasePart).Anchored = true
				;(d :: BasePart).CanCollide = false
			elseif d:IsA("Sound") or d:IsA("BillboardGui") then
				d:Destroy()
			end
		end
		m.Parent = folder
	end
	folder.Parent = ReplicatedStorage
end

return CarSpawner
