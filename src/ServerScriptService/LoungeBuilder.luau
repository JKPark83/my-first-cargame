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

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local GameConfig = require(ReplicatedStorage.GameConfig)
local CarSpawner = require(script.Parent.CarSpawner)

local LOUNGE_ORIGIN = Vector3.new(0, 0, 3000) -- 트랙과 멀리 떨어진 위치
local FLOOR_SIZE = Vector3.new(160, 2, 160)

local builtSpawn: SpawnLocation? = nil
local builtQueuePad: BasePart? = nil
local builtCarSelectPad: BasePart? = nil
local leaderboardLabel: TextLabel? = nil

function LoungeBuilder.getSpawnCFrame(): CFrame
	if builtSpawn then
		return builtSpawn.CFrame + Vector3.new(0, 4, 0)
	end
	return CFrame.new(LOUNGE_ORIGIN + Vector3.new(0, 5, 0))
end

function LoungeBuilder.getQueuePad(): BasePart?
	return builtQueuePad
end

function LoungeBuilder.getCarSelectPad(): BasePart?
	return builtCarSelectPad
end

-- =====================================================================
-- 장식 / 전시 헬퍼
-- =====================================================================
-- 장식·패드용 간단한 Part 생성기. 기본은 Anchored + 충돌 없음.
-- props에 Position 또는 CFrame 중 하나를 넣는다(둘 다 넣지 않음).
local function makePart(parent: Instance, props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in pairs(props) do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end

-- 레이싱장 분위기 장식 일체 (출발 아치 / 관중석 / 조명탑 / 배너 / 체커라인 / 타이어더미)
-- 하드 제약: |offset| < 78(벽 안쪽면), 바닥 위 파트의 하단 Y >= 1(바닥 윗면).
local function buildDecorations(folder: Folder)
	if not GameConfig.Lobby.showDecorations then
		return
	end
	local O = LOUNGE_ORIGIN

	-- 출발 아치 (GRAND PRIX)
	local archZ = 15
	local archColor = Color3.fromRGB(255, 220, 50)
	makePart(folder, { Name = "ArchPillarL", Size = Vector3.new(3, 22, 3), Position = O + Vector3.new(-22, 12, archZ), Material = Enum.Material.Neon, Color = archColor })
	makePart(folder, { Name = "ArchPillarR", Size = Vector3.new(3, 22, 3), Position = O + Vector3.new(22, 12, archZ), Material = Enum.Material.Neon, Color = archColor })
	local beam = makePart(folder, { Name = "ArchBeam", Size = Vector3.new(47, 3, 3), Position = O + Vector3.new(0, 23.5, archZ), Material = Enum.Material.Neon, Color = archColor })
	local archGui = Instance.new("SurfaceGui")
	archGui.Face = Enum.NormalId.Front
	archGui.Parent = beam
	local archText = Instance.new("TextLabel")
	archText.Size = UDim2.fromScale(1, 1)
	archText.BackgroundTransparency = 1
	archText.Text = "🏁 GRAND PRIX 🏁"
	archText.TextColor3 = Color3.fromRGB(35, 28, 8)
	archText.Font = Enum.Font.GothamBlack
	archText.TextScaled = true
	archText.Parent = archGui

	-- 관중석 (계단식) — 첫 단 하단 Y=1, 최후단 far edge < 78
	for i = 0, GameConfig.Lobby.grandstandSteps - 1 do
		makePart(folder, {
			Name = "Grandstand" .. i,
			Size = Vector3.new(80, 4, 6),
			Position = O + Vector3.new(0, 3 + i * 4, 55 + i * 6),
			Material = Enum.Material.SmoothPlastic,
			Color = Color3.fromRGB(60, 62, 70),
			CanCollide = true,
		})
	end

	-- 조명탑 ×4 (코너, 관중석/배너와 겹치지 않는 ±70)
	local corners = { Vector3.new(-70, 0, -70), Vector3.new(70, 0, -70), Vector3.new(-70, 0, 70), Vector3.new(70, 0, 70) }
	for _, c in ipairs(corners) do
		makePart(folder, { Name = "LightPole", Size = Vector3.new(2, 26, 2), Position = O + c + Vector3.new(0, 14, 0), Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(80, 82, 90) })
		makePart(folder, { Name = "LightBox", Size = Vector3.new(5, 2, 3), Position = O + c + Vector3.new(0, 28, 0), Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 255, 230) })
	end

	-- 레이싱 배너 (좌 RED / 우 BLUE, 벽 안쪽)
	makePart(folder, { Name = "BannerRed", Size = Vector3.new(1, 8, 60), Position = O + Vector3.new(-78, 12, 0), Material = Enum.Material.Neon, Color = Color3.fromRGB(220, 60, 60) })
	makePart(folder, { Name = "BannerBlue", Size = Vector3.new(1, 8, 60), Position = O + Vector3.new(78, 12, 0), Material = Enum.Material.Neon, Color = Color3.fromRGB(60, 100, 220) })

	-- 체커 피니시 라인 (아치 아래, 2열 흑백 격자)
	for row = 0, 1 do
		for i = 0, 11 do
			local white = (i + row) % 2 == 0
			makePart(folder, {
				Name = "FinishTile",
				Size = Vector3.new(4, 0.4, 4),
				Position = O + Vector3.new(-22 + i * 4, 1.3, 18 + row * 4),
				Material = Enum.Material.SmoothPlastic,
				Color = white and Color3.fromRGB(240, 240, 240) or Color3.fromRGB(20, 20, 20),
			})
		end
	end

	-- 타이어 더미 ×4 (검은 실린더 3단 적층, 축을 세워 평평히 쌓음)
	local tireBases = { Vector3.new(-58, 0, 8), Vector3.new(58, 0, 8), Vector3.new(-58, 0, 48), Vector3.new(58, 0, 48) }
	for _, base in ipairs(tireBases) do
		for s = 0, 2 do
			makePart(folder, {
				Name = "TireStack",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(1.6, 5, 5),
				CFrame = CFrame.new(O + base + Vector3.new(0, 1.8 + s * 1.7, 0)) * CFrame.Angles(0, 0, math.rad(90)),
				Material = Enum.Material.SmoothPlastic,
				Color = Color3.fromRGB(25, 22, 25),
				CanCollide = true,
			})
		end
	end
end

-- 경주 참가 패드 위 3D 체커 깃발 (깃대 + 깃발천 + 양면 체커 SurfaceGui)
local function buildCheckerFlag(folder: Folder, padPos: Vector3)
	makePart(folder, {
		Name = "FlagPole",
		Size = Vector3.new(0.4, 11, 0.4),
		Position = padPos + Vector3.new(0, 6, 0),
		Material = Enum.Material.Metal,
		Color = Color3.fromRGB(180, 184, 195),
	})
	local cloth = makePart(folder, {
		Name = "FlagCloth",
		Size = Vector3.new(6, 4, 0.3),
		Position = padPos + Vector3.new(3, 9.5, 0),
		Material = Enum.Material.SmoothPlastic,
		Color = Color3.fromRGB(240, 240, 240),
	})
	local function addChecker(face: Enum.NormalId)
		local sg = Instance.new("SurfaceGui")
		sg.Face = face
		sg.CanvasSize = Vector2.new(120, 80)
		sg.Parent = cloth
		local grid = Instance.new("Frame")
		grid.Size = UDim2.fromScale(1, 1)
		grid.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
		grid.BorderSizePixel = 0
		grid.Parent = sg
		local layout = Instance.new("UIGridLayout")
		layout.CellSize = UDim2.fromScale(1 / 6, 1 / 4)
		layout.CellPadding = UDim2.new()
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = grid
		for i = 0, 23 do
			local col = i % 6
			local rown = math.floor(i / 6)
			local cell = Instance.new("Frame")
			cell.BorderSizePixel = 0
			cell.BackgroundColor3 = ((col + rown) % 2 == 0) and Color3.fromRGB(25, 25, 25) or Color3.fromRGB(245, 245, 245)
			cell.LayoutOrder = i
			cell.Parent = grid
		end
	end
	addChecker(Enum.NormalId.Front)
	addChecker(Enum.NormalId.Back)
end

-- 차량 선택 패드 위에 띄울 전시 차량 (3D 미니 차량, 회전 태그)
local function buildShowcaseCar(folder: Folder, padPos: Vector3)
	local carDef = GameConfig.CarsById[GameConfig.Lobby.showcaseCarId]
	if not carDef then
		return
	end
	local model = CarSpawner.build(carDef, nil)
	-- 전시용: 물리 비활성 + 충돌 제거 + 탑승 불가 + 엔진음 제거
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
		elseif d:IsA("Sound") then
			d:Destroy()
		end
	end
	local seat = model.PrimaryPart
	if seat and seat:IsA("VehicleSeat") then
		seat.Disabled = true
	end
	model:ScaleTo(0.6)
	model:PivotTo(CFrame.new(padPos + Vector3.new(0, 7, 0)))
	CollectionService:AddTag(model, "ShowcaseSpin")
	model.Parent = folder
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
	pad.Position = LOUNGE_ORIGIN + GameConfig.Lobby.queuePadOffset
	pad.Material = Enum.Material.Neon
	pad.Color = Color3.fromRGB(120, 255, 140)
	pad.Parent = folder
	builtQueuePad = pad

	local padGui = Instance.new("BillboardGui")
	padGui.Size = UDim2.fromScale(8, 3)
	padGui.StudsOffset = Vector3.new(0, 3.5, 0)
	padGui.AlwaysOnTop = true
	padGui.Parent = pad
	local padLabel = Instance.new("TextLabel")
	padLabel.Size = UDim2.fromScale(1, 1)
	padLabel.BackgroundTransparency = 1
	padLabel.Text = "🏁 경주 참가"
	padLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	padLabel.TextStrokeTransparency = 0.4
	padLabel.Font = Enum.Font.GothamBold
	padLabel.TextScaled = true
	padLabel.Parent = padGui

	-- 경주 참가 패드 위 3D 체커 깃발
	buildCheckerFlag(folder, pad.Position)

	-- 차량 선택 패드 (밟으면 차고 UI 열림)
	local csPad = Instance.new("Part")
	csPad.Name = "CarSelectPad"
	csPad.Anchored = true
	csPad.Size = Vector3.new(20, 1, 20)
	csPad.Position = LOUNGE_ORIGIN + GameConfig.Lobby.carSelectPadOffset
	csPad.Material = Enum.Material.Neon
	csPad.Color = Color3.fromRGB(255, 220, 50)
	csPad.Parent = folder
	builtCarSelectPad = csPad

	local csGui = Instance.new("BillboardGui")
	csGui.Size = UDim2.fromScale(8, 3)
	csGui.StudsOffset = Vector3.new(0, 3.5, 0)
	csGui.AlwaysOnTop = true
	csGui.Parent = csPad
	local csLabel = Instance.new("TextLabel")
	csLabel.Size = UDim2.fromScale(1, 1)
	csLabel.BackgroundTransparency = 1
	csLabel.Text = "🚗 차량 선택"
	csLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	csLabel.TextStrokeTransparency = 0.4
	csLabel.Font = Enum.Font.GothamBold
	csLabel.TextScaled = true
	csLabel.Parent = csGui

	-- 차량 선택 패드 위 전시 차량 (회전)
	buildShowcaseCar(folder, csPad.Position)

	-- 글로벌 순위 전광판
	local board = Instance.new("Part")
	board.Name = "LeaderboardBoard"
	board.Anchored = true
	board.Size = Vector3.new(2, 30, 44)
	board.Position = LOUNGE_ORIGIN + Vector3.new(0, 16, -half + 2)
	board.Material = Enum.Material.SmoothPlastic
	board.Color = Color3.fromRGB(18, 20, 28)
	board.Parent = folder

	local boardGui = Instance.new("SurfaceGui")
	boardGui.Face = Enum.NormalId.Front
	boardGui.CanvasSize = Vector2.new(440, 300)
	boardGui.Parent = board

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 50)
	title.BackgroundTransparency = 1
	title.Text = "🏆 글로벌 최고 기록"
	title.TextColor3 = Color3.fromRGB(245, 220, 90)
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.Parent = boardGui

	local body = Instance.new("TextLabel")
	body.Size = UDim2.new(1, -20, 1, -60)
	body.Position = UDim2.new(0, 10, 0, 56)
	body.BackgroundTransparency = 1
	body.Text = "기록을 불러오는 중..."
	body.TextColor3 = Color3.fromRGB(230, 235, 245)
	body.Font = Enum.Font.GothamMedium
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.TextScaled = false
	body.TextSize = 22
	body.Parent = boardGui
	leaderboardLabel = body

	-- 레이싱장 분위기 장식 (showDecorations=false면 건너뜀)
	buildDecorations(folder)

	folder.Parent = workspace
	return folder
end

-- 개발 편의: 기존 라운지를 지우고 새로 생성 (Studio에서 레이아웃 변경 즉시 반영)
function LoungeBuilder.rebuild(): Folder
	local old = workspace:FindFirstChild("Lounge")
	if old then
		old:Destroy()
	end
	builtSpawn = nil
	builtQueuePad = nil
	builtCarSelectPad = nil
	leaderboardLabel = nil
	return LoungeBuilder.build()
end

-- 전광판 텍스트 갱신 (Main의 주기 루프에서 호출)
function LoungeBuilder.updateLeaderboard(entries: { { rank: number, name: string, time: number } })
	if not leaderboardLabel then
		return
	end
	if #entries == 0 then
		leaderboardLabel.Text = "아직 기록이 없습니다.\n첫 번째 챔피언이 되어보세요!"
		return
	end
	local lines = {}
	for _, e in ipairs(entries) do
		local medal = e.rank == 1 and "🥇" or (e.rank == 2 and "🥈" or (e.rank == 3 and "🥉" or (" " .. e.rank .. ".")))
		lines[#lines + 1] = ("%s  %-12s  %.2f초"):format(medal, string.sub(e.name, 1, 12), e.time)
	end
	leaderboardLabel.Text = table.concat(lines, "\n")
end

return LoungeBuilder
