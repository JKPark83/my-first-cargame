--!strict
--[[
	CarSpawner
	-----------
	플레이어의 선택 차량을 부품으로 조립해 스폰합니다.
	- VehicleSeat를 차체(PrimaryPart)로 사용해 탑승 처리
	- 등급별 성능 스탯을 어트리뷰트로 부착 (클라 컨트롤러가 읽음)
	- 저장된 커스터마이징(색상/휠/네온/번호판)을 적용
	- 네트워크 소유권을 운전자에게 넘겨 아케이드 조작을 부드럽게

	실제 주행 물리는 클라이언트의 CarController가 담당합니다.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.GameConfig)
local DataManager = require(script.Parent.DataManager)

local CarSpawner = {}

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

-- 바퀴(시각용) 4개 생성
local function buildWheels(chassis: BasePart, wheelColor: Color3, parent: Model)
	local halfW = chassis.Size.X / 2
	local halfL = chassis.Size.Z / 2
	local offsets = {
		Vector3.new(halfW, -1.2, halfL - 1.5),
		Vector3.new(-halfW, -1.2, halfL - 1.5),
		Vector3.new(halfW, -1.2, -halfL + 1.5),
		Vector3.new(-halfW, -1.2, -halfL + 1.5),
	}
	for _, off in ipairs(offsets) do
		local wheel = Instance.new("Part")
		wheel.Shape = Enum.PartType.Cylinder
		wheel.Size = Vector3.new(1, 3, 3)
		wheel.Color = wheelColor
		wheel.Material = Enum.Material.SmoothPlastic
		wheel.CanCollide = false
		wheel.Massless = true
		wheel.CFrame = chassis.CFrame * CFrame.new(off) * CFrame.Angles(0, 0, math.rad(90))
		wheel.Parent = parent
		weld(chassis, wheel)
	end
end

-- 차량 모델 조립
-- 반환: Model (PrimaryPart = VehicleSeat)
function CarSpawner.build(carDef: any, custom: any?): Model
	local model = Instance.new("Model")
	model.Name = "Car_" .. carDef.id

	local bodyColor = color3FromArray(custom and custom.bodyColor, carDef.defaultColor)
	local wheelColor = color3FromArray(custom and custom.wheelColor, Color3.fromRGB(20, 20, 20))
	local neonColor = color3FromArray(custom and custom.neonColor, Color3.fromRGB(0, 0, 0))

	-- 차체 = VehicleSeat (탑승 + 물리 본체)
	local seat = Instance.new("VehicleSeat")
	seat.Name = "Chassis"
	seat.Size = Vector3.new(8, 2.5, 16)
	seat.Color = bodyColor
	seat.Material = Enum.Material.SmoothPlastic
	seat.MaxSpeed = carDef.stats.topSpeed
	seat.Torque = 0 -- 직접 물리 제어하므로 시트 기본 구동은 끔
	seat.TurnSpeed = 0
	seat.HeadsUpDisplay = false
	seat.Parent = model
	model.PrimaryPart = seat

	-- 상부 캐빈(장식)
	local cabin = Instance.new("Part")
	cabin.Size = Vector3.new(6, 2, 7)
	cabin.Color = bodyColor:Lerp(Color3.new(0, 0, 0), 0.25)
	cabin.Material = Enum.Material.SmoothPlastic
	cabin.CanCollide = false
	cabin.Massless = true
	cabin.CFrame = seat.CFrame * CFrame.new(0, 2.2, -0.5)
	cabin.Parent = model
	weld(seat, cabin)

	-- 앞 유리(장식)
	local glass = Instance.new("Part")
	glass.Size = Vector3.new(5.5, 1.6, 0.4)
	glass.Color = Color3.fromRGB(120, 200, 230)
	glass.Material = Enum.Material.Glass
	glass.Transparency = 0.4
	glass.CanCollide = false
	glass.Massless = true
	glass.CFrame = seat.CFrame * CFrame.new(0, 2.2, 3)
	glass.Parent = model
	weld(seat, glass)

	-- 바퀴
	buildWheels(seat, wheelColor, model)

	-- 네온 언더글로우 (neonColor가 검정이면 꺼짐 취급)
	if neonColor ~= Color3.fromRGB(0, 0, 0) then
		local neon = Instance.new("Part")
		neon.Size = Vector3.new(8.5, 0.4, 16.5)
		neon.Color = neonColor
		neon.Material = Enum.Material.Neon
		neon.CanCollide = false
		neon.Massless = true
		neon.CFrame = seat.CFrame * CFrame.new(0, -1.4, 0)
		neon.Parent = model
		weld(seat, neon)

		local light = Instance.new("PointLight")
		light.Color = neonColor
		light.Range = 14
		light.Brightness = 2
		light.Parent = neon
	end

	-- 번호판 (BillboardGui 텍스트)
	local plateText = (custom and type(custom.plate) == "string" and custom.plate ~= "") and custom.plate or "RACER"
	local plate = Instance.new("Part")
	plate.Size = Vector3.new(4, 1, 0.2)
	plate.Color = Color3.fromRGB(245, 245, 245)
	plate.Material = Enum.Material.SmoothPlastic
	plate.CanCollide = false
	plate.Massless = true
	plate.CFrame = seat.CFrame * CFrame.new(0, -0.3, -8)
	plate.Parent = model
	weld(seat, plate)

	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Face = Enum.NormalId.Back
	surfaceGui.Parent = plate
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = string.upper(string.sub(plateText, 1, 8))
	label.TextColor3 = Color3.fromRGB(30, 30, 30)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = surfaceGui

	-- 스티커/데칼 적용 (assetId가 0이면 생략)
	if custom and type(custom.sticker) == "string" then
		for _, s in ipairs(GameConfig.Customization.stickers) do
			if s.id == custom.sticker and s.assetId and s.assetId > 0 then
				local decal = Instance.new("Decal")
				decal.Texture = "rbxassetid://" .. tostring(s.assetId)
				decal.Face = Enum.NormalId.Top
				decal.Parent = cabin
			end
		end
	end

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
