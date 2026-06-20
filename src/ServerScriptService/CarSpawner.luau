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
local GameConfig = require(ReplicatedStorage.GameConfig)
local DataManager = require(script.Parent.DataManager)

local CarSpawner = {}

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

-- 바퀴 4개 생성 (타이어 + 휠 캡)
-- 실린더는 로컬 X축으로 뻗으므로, 회전 없이 두면 원형 면이 좌/우(±X)를 향한다 → 올바른 바퀴 방향
local function buildWheels(model: Model, seat: BasePart, wheelColor: Color3)
	local halfW = BODY_W / 2
	local halfL = BODY_L / 2
	local wheelX = halfW + 0.05 -- 살짝 바깥으로
	local axleZ = halfL - 2.6 -- 앞/뒤 차축 위치
	local wheelY = 0.9 -- 시트 중심 기준 (반경 1.6 → 바닥 ≈ 지면)

	local rimColor = wheelColor:Lerp(Color3.fromRGB(225, 225, 230), 0.55)

	for _, sx in ipairs({ 1, -1 }) do
		for _, sz in ipairs({ 1, -1 }) do
			-- 타이어
			decor(model, seat, CFrame.new(sx * wheelX, wheelY, sz * axleZ), {
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(1.3, 3.2, 3.2),
				Color = wheelColor,
				Material = Enum.Material.SmoothPlastic,
			})
			-- 휠 캡(림) — 타이어보다 살짝 바깥으로 튀어나오게
			decor(model, seat, CFrame.new(sx * (wheelX + 0.18), wheelY, sz * axleZ), {
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(1.3, 1.7, 1.7),
				Color = rimColor,
				Material = Enum.Material.Metal,
			})
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

	-- 앞 후드 (운전자 앞쪽으로 솟은 보닛)
	decor(model, seat, CFrame.new(0, 1.15, -4.4), {
		Size = Vector3.new(BODY_W - 0.4, 1.0, 5.2),
		Color = bodyColor,
		Material = Enum.Material.SmoothPlastic,
	})
	-- 앞 노즈/범퍼
	decor(model, seat, CFrame.new(0, 0.25, -6.9), {
		Size = Vector3.new(BODY_W + 0.1, 1.1, 1.4),
		Color = darkBody,
		Material = Enum.Material.SmoothPlastic,
	})
	-- 뒤 트렁크 데크
	decor(model, seat, CFrame.new(0, 1.1, 4.6), {
		Size = Vector3.new(BODY_W - 0.4, 0.9, 4.8),
		Color = bodyColor,
		Material = Enum.Material.SmoothPlastic,
	})
	-- 뒤 범퍼
	decor(model, seat, CFrame.new(0, 0.25, 6.9), {
		Size = Vector3.new(BODY_W + 0.1, 1.1, 1.4),
		Color = darkBody,
		Material = Enum.Material.SmoothPlastic,
	})

	-- 운전석 뒤 캐빈/롤후프 (머리 위는 비워 탑승 클리핑 방지)
	decor(model, seat, CFrame.new(0, 1.45, 2.4), {
		Size = Vector3.new(BODY_W - 1.2, 1.9, 2.8),
		Color = darkBody,
		Material = Enum.Material.SmoothPlastic,
	})
	-- 앞 유리 (운전자 앞쪽, 뒤로 기울임)
	decor(model, seat, CFrame.new(0, 1.5, -1.3) * CFrame.Angles(math.rad(28), 0, 0), {
		Size = Vector3.new(BODY_W - 1.3, 1.7, 0.22),
		Color = Color3.fromRGB(150, 205, 230),
		Material = Enum.Material.Glass,
		Transparency = 0.45,
	})
	-- 사이드 도어 패널 (벨트라인) — 좌우
	for _, sx in ipairs({ 1, -1 }) do
		decor(model, seat, CFrame.new(sx * (BODY_W / 2 - 0.1), 0.95, 0.6), {
			Size = Vector3.new(0.3, 0.9, 7.5),
			Color = darkBody,
			Material = Enum.Material.SmoothPlastic,
		})
	end

	-- 스포일러(윙) + 지지대
	for _, sx in ipairs({ 1, -1 }) do
		decor(model, seat, CFrame.new(sx * 2.2, 1.9, 6.6), {
			Size = Vector3.new(0.35, 1.1, 0.5),
			Color = trim,
			Material = Enum.Material.Metal,
		})
	end
	decor(model, seat, CFrame.new(0, 2.45, 6.7), {
		Size = Vector3.new(BODY_W - 0.2, 0.28, 1.6),
		Color = darkBody,
		Material = Enum.Material.SmoothPlastic,
	})

	-- 헤드라이트 (앞, 따뜻한 흰색 네온)
	for _, sx in ipairs({ 1, -1 }) do
		decor(model, seat, CFrame.new(sx * 2.4, 0.55, -7.45), {
			Size = Vector3.new(1.2, 0.55, 0.3),
			Color = Color3.fromRGB(255, 245, 200),
			Material = Enum.Material.Neon,
		})
	end
	-- 테일라이트 (뒤, 빨강 네온)
	for _, sx in ipairs({ 1, -1 }) do
		decor(model, seat, CFrame.new(sx * 2.4, 0.7, 7.45), {
			Size = Vector3.new(1.3, 0.5, 0.3),
			Color = Color3.fromRGB(235, 45, 45),
			Material = Enum.Material.Neon,
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

	-- 성능 스탯을 어트리뷰트로 부착 (클라 컨트롤러가 읽음)
	seat:SetAttribute("TopSpeed", carDef.stats.topSpeed)
	seat:SetAttribute("Accel", carDef.stats.accel)
	seat:SetAttribute("Handling", carDef.stats.handling)
	seat:SetAttribute("Grip", carDef.stats.grip)
	model:SetAttribute("CarId", carDef.id)

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
	model.Parent = parent or workspace

	-- 캐릭터를 시트에 앉힘
	local character = player.Character
	local seat = model.PrimaryPart :: VehicleSeat
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			task.defer(function()
				seat:Sit(humanoid)
			end)
		end
	end

	-- 네트워크 소유권을 운전자에게 (아케이드 조작 반응성)
	task.defer(function()
		pcall(function()
			seat:SetNetworkOwner(player)
		end)
	end)

	model:SetAttribute("OwnerUserId", player.UserId)
	return model
end

return CarSpawner
