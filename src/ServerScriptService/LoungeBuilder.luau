--!strict
--[[
	LoungeBuilder
	--------------
	플레이어가 처음 입장하는 3D 라운지(로비) 공간을 코드로 생성합니다.
	- 바닥 / 벽 / 조명 분위기
	- 스폰 위치(SpawnLocation)
	- 경주 대기열 참가 패드(밟으면 대기열 UI 토글 신호)

	라운지는 서버 시작 시 한 번 생성됩니다.
]]

local LoungeBuilder = {}

local LOUNGE_ORIGIN = Vector3.new(0, 0, 3000) -- 트랙과 멀리 떨어진 위치
local FLOOR_SIZE = Vector3.new(160, 2, 160)

local builtSpawn: SpawnLocation? = nil
local builtQueuePad: BasePart? = nil

function LoungeBuilder.getSpawnCFrame(): CFrame
	if builtSpawn then
		return builtSpawn.CFrame + Vector3.new(0, 4, 0)
	end
	return CFrame.new(LOUNGE_ORIGIN + Vector3.new(0, 5, 0))
end

function LoungeBuilder.getQueuePad(): BasePart?
	return builtQueuePad
end

function LoungeBuilder.build(): Folder
	local existing = workspace:FindFirstChild("Lounge")
	if existing then
		return existing :: Folder
	end

	local folder = Instance.new("Folder")
	folder.Name = "Lounge"

	-- 바닥
	local floor = Instance.new("Part")
	floor.Name = "Floor"
	floor.Anchored = true
	floor.Size = FLOOR_SIZE
	floor.Position = LOUNGE_ORIGIN
	floor.Material = Enum.Material.WoodPlanks
	floor.Color = Color3.fromRGB(70, 75, 90)
	floor.TopSurface = Enum.SurfaceType.Smooth
	floor.Parent = folder

	-- 둘레 벽
	local wallHeight = 24
	local wallThickness = 2
	local half = FLOOR_SIZE.X / 2
	local wallDefs = {
		{ size = Vector3.new(FLOOR_SIZE.X, wallHeight, wallThickness), pos = Vector3.new(0, wallHeight / 2, half) },
		{ size = Vector3.new(FLOOR_SIZE.X, wallHeight, wallThickness), pos = Vector3.new(0, wallHeight / 2, -half) },
		{ size = Vector3.new(wallThickness, wallHeight, FLOOR_SIZE.Z), pos = Vector3.new(half, wallHeight / 2, 0) },
		{ size = Vector3.new(wallThickness, wallHeight, FLOOR_SIZE.Z), pos = Vector3.new(-half, wallHeight / 2, 0) },
	}
	for _, def in ipairs(wallDefs) do
		local wall = Instance.new("Part")
		wall.Anchored = true
		wall.Size = def.size
		wall.Position = LOUNGE_ORIGIN + def.pos + Vector3.new(0, 1, 0)
		wall.Material = Enum.Material.SmoothPlastic
		wall.Color = Color3.fromRGB(45, 48, 60)
		wall.Parent = folder
	end

	-- 스폰 위치
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LoungeSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.Position = LOUNGE_ORIGIN + Vector3.new(-40, 2, 0)
	spawn.Material = Enum.Material.Neon
	spawn.Color = Color3.fromRGB(90, 200, 255)
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Parent = folder
	builtSpawn = spawn

	-- 경주 대기열 참가 패드
	local pad = Instance.new("Part")
	pad.Name = "QueuePad"
	pad.Anchored = true
	pad.Size = Vector3.new(20, 1, 20)
	pad.Position = LOUNGE_ORIGIN + Vector3.new(40, 1.5, 0)
	pad.Material = Enum.Material.Neon
	pad.Color = Color3.fromRGB(120, 255, 140)
	pad.Parent = folder
	builtQueuePad = pad

	local padGui = Instance.new("BillboardGui")
	padGui.Size = UDim2.fromScale(8, 3)
	padGui.StudsOffset = Vector3.new(0, 6, 0)
	padGui.AlwaysOnTop = true
	padGui.Parent = pad
	local padLabel = Instance.new("TextLabel")
	padLabel.Size = UDim2.fromScale(1, 1)
	padLabel.BackgroundTransparency = 1
	padLabel.Text = "🏁 경주 참가 패드"
	padLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	padLabel.TextStrokeTransparency = 0.4
	padLabel.Font = Enum.Font.GothamBold
	padLabel.TextScaled = true
	padLabel.Parent = padGui

	folder.Parent = workspace
	return folder
end

return LoungeBuilder
