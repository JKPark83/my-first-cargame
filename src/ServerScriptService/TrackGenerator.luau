--!strict
--[[
	TrackGenerator
	---------------
	코드로 트랙을 절차적으로 생성합니다.
	- 시드(seed) 기반으로 매번 동일하게 재현되는 닫힌 루프 트랙 10종
	- 도로 세그먼트 / 체크포인트 / 출발 스폰 / 결승선을 배치
	- 경주 시작 시 RaceManager가 랜덤으로 하나를 골라 build() 호출

	트랙은 평면(아케이드)으로 생성되며, 체크포인트를 순서대로 통과하면
	랩이 인정됩니다(결승선 = 1번 체크포인트).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.GameConfig)

local TrackGenerator = {}

local ROAD_WIDTH = 48
local ROAD_THICKNESS = 2
local WALL_HEIGHT = 5 -- 가드레일(충돌 벽) 높이
local RAIL_HEIGHT = 0.6 -- 벽 위 색 레일 두께
local SAMPLES_PER_SEGMENT = 14 -- 노드 사이 보간 샘플 수 (높을수록 매끄러움)
local CHECKPOINT_EVERY = 1 -- 모든 경로 노드를 체크포인트로 사용
local NODE_COUNT = 16 -- 루프를 구성하는 제어점 수
local BASE_RADIUS = 320 -- 트랙 기본 반경

-- 도로/마킹/벽 색
local ROAD_COLOR = Color3.fromRGB(48, 49, 56)
local WALL_COLOR = Color3.fromRGB(70, 73, 84)
local RAIL_LEFT = Color3.fromRGB(225, 80, 80) -- 왼쪽 레일(빨강 계열)
local RAIL_RIGHT = Color3.fromRGB(235, 235, 240) -- 오른쪽 레일(흰색)
local LANE_COLOR = Color3.fromRGB(240, 215, 90) -- 중앙 차선(노랑)
local EDGE_COLOR = Color3.fromRGB(225, 228, 235) -- 가장자리 라인(흰색)

export type TrackInfo = {
	index: number,
	displayName: string,
	model: Model,
	startCFrame: CFrame,
	spawnCFrames: { CFrame },
	checkpoints: { BasePart }, -- 순서대로 통과해야 하는 체크포인트
	checkpointCount: number,
	minimapPath: { Vector3 }, -- 미니맵 외곽선용 다운샘플 경로
	bounds: { minX: number, maxX: number, minZ: number, maxZ: number },
	boostPads: { BasePart }, -- 부스트 패드
	oilSlicks: { BasePart }, -- 오일 슬릭(감속)
	itemBoxes: { BasePart }, -- 아이템 박스(통과 시 랜덤 아이템)
}

-- 시드 기반 의사난수 생성기 (재현 가능)
local function makeRandom(seed: number): Random
	return Random.new(seed)
end

-- 루프를 구성하는 평면상의 노드(위치) 목록 생성
local function generateNodes(rng: Random): { Vector3 }
	local nodes: { Vector3 } = {}
	for i = 1, NODE_COUNT do
		local angle = (i - 1) / NODE_COUNT * math.pi * 2
		-- 반경에 완만한 노이즈를 주어 트랙마다 모양이 달라지되, 너무 들쭉날쭉하지 않게 함
		local radiusJitter = rng:NextNumber(0.82, 1.16)
		local radius = BASE_RADIUS * radiusJitter
		-- 살짝 타원으로 변형(자연스러운 곡선)
		local x = math.cos(angle) * radius
		local z = math.sin(angle) * radius * rng:NextNumber(0.92, 1.08)
		nodes[i] = Vector3.new(x, 0, z)
	end
	return nodes
end

-- Catmull-Rom 스플라인으로 노드 사이를 부드럽게 보간
local function catmullRom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local t2 = t * t
	local t3 = t2 * t
	return 0.5
		* (
			(2 * p1)
			+ (-p0 + p2) * t
			+ (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
			+ (-p0 + 3 * p1 - 3 * p2 + p3) * t3
		)
end

-- 노드를 보간해 촘촘한 경로 점 목록 생성
local function buildPath(nodes: { Vector3 }, samplesPerSegment: number): { Vector3 }
	local path: { Vector3 } = {}
	local n = #nodes
	for i = 1, n do
		local p0 = nodes[(i - 2) % n + 1]
		local p1 = nodes[(i - 1) % n + 1]
		local p2 = nodes[i % n + 1]
		local p3 = nodes[(i + 1) % n + 1]
		for s = 0, samplesPerSegment - 1 do
			local t = s / samplesPerSegment
			path[#path + 1] = catmullRom(p0, p1, p2, p3, t)
		end
	end
	return path
end

-- 얇은 시각용 파트(충돌 없음) — 도로 마킹/레일
local function makeStripe(look: CFrame, offset: CFrame, size: Vector3, color: Color3, parent: Instance)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.Size = size
	p.CFrame = look * offset
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
end

local function makeRoadSegment(a: Vector3, b: Vector3, parent: Instance, index: number): ()
	local mid = (a + b) / 2
	local dir = b - a
	local length = dir.Magnitude
	if length < 0.05 then
		return
	end
	local look = CFrame.lookAt(mid, b)
	local segLen = length + 1 -- 세그먼트끼리 살짝 겹쳐 틈 제거

	-- 도로 바닥
	local road = Instance.new("Part")
	road.Anchored = true
	road.Material = Enum.Material.Asphalt
	road.Color = ROAD_COLOR
	road.Size = Vector3.new(ROAD_WIDTH, ROAD_THICKNESS, segLen)
	road.CFrame = look * CFrame.new(0, -ROAD_THICKNESS / 2, 0)
	road.TopSurface = Enum.SurfaceType.Smooth
	road.BottomSurface = Enum.SurfaceType.Smooth
	road.Parent = parent

	-- 양쪽 솔리드 가드레일(충돌) + 색 레일 캡
	for _, side in ipairs({ -1, 1 }) do
		local wall = Instance.new("Part")
		wall.Anchored = true
		wall.Material = Enum.Material.SmoothPlastic
		wall.Color = WALL_COLOR
		wall.Size = Vector3.new(1.4, WALL_HEIGHT, segLen)
		wall.CFrame = look * CFrame.new(side * (ROAD_WIDTH / 2), WALL_HEIGHT / 2, 0)
		wall.TopSurface = Enum.SurfaceType.Smooth
		wall.BottomSurface = Enum.SurfaceType.Smooth
		wall.Parent = parent
		-- 레일 캡(색): 왼쪽/오른쪽 다른 색으로 방향감
		makeStripe(
			look,
			CFrame.new(side * (ROAD_WIDTH / 2), WALL_HEIGHT + RAIL_HEIGHT / 2, 0),
			Vector3.new(1.7, RAIL_HEIGHT, segLen),
			side == -1 and RAIL_LEFT or RAIL_RIGHT,
			parent
		)
	end

	-- 가장자리 흰색 라인 (도로면 살짝 위)
	for _, side in ipairs({ -1, 1 }) do
		makeStripe(
			look,
			CFrame.new(side * (ROAD_WIDTH / 2 - 2), 0.06, 0),
			Vector3.new(0.7, 0.12, segLen),
			EDGE_COLOR,
			parent
		)
	end

	-- 중앙 차선(노랑 점선) — 한 칸 걸러 하나
	if index % 2 == 0 then
		makeStripe(look, CFrame.new(0, 0.06, 0), Vector3.new(0.8, 0.12, segLen * 0.6), LANE_COLOR, parent)
	end
end

-- 경로 위 한 지점의 진행 방향 CFrame (i번째 점에서 다음 점을 바라봄)
local function pathCFrameAt(path: { Vector3 }, i: number): CFrame
	local a = path[i]
	local b = path[(i % #path) + 1]
	return CFrame.lookAt(a, b)
end

-- 부스트 패드 생성
local function makeBoostPad(cf: CFrame, parent: Instance): BasePart
	local pad = Instance.new("Part")
	pad.Name = "BoostPad"
	pad.Anchored = true
	pad.CanCollide = false
	pad.Material = Enum.Material.Neon
	pad.Color = GameConfig.Boost.padColor
	pad.Size = Vector3.new(14, 0.4, 10)
	pad.CFrame = cf * CFrame.new(0, 0.3, 0)
	pad.Transparency = 0.15
	pad.Parent = parent

	-- 화살표 표시(SurfaceGui 텍스트)
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Top
	sg.Parent = pad
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Text = "▲▲▲"
	lbl.TextColor3 = Color3.fromRGB(255, 255, 255)
	lbl.Font = Enum.Font.GothamBold
	lbl.TextScaled = true
	lbl.Rotation = 90
	lbl.Parent = sg
	return pad
end

-- 오일 슬릭(감속) 생성
local function makeOilSlick(cf: CFrame, parent: Instance): BasePart
	local oil = Instance.new("Part")
	oil.Name = "OilSlick"
	oil.Shape = Enum.PartType.Cylinder
	oil.Anchored = true
	oil.CanCollide = false
	oil.Material = Enum.Material.Glass
	oil.Color = GameConfig.Obstacles.oilColor
	oil.Size = Vector3.new(0.3, 11, 11)
	oil.CFrame = cf * CFrame.new(0, 0.2, 0) * CFrame.Angles(0, 0, math.rad(90))
	oil.Transparency = 0.25
	oil.Reflectance = 0.4
	oil.Parent = parent
	return oil
end

-- 아이템 박스 생성 (통과하면 랜덤 아이템 획득)
local function makeItemBox(cf: CFrame, parent: Instance): BasePart
	local size = GameConfig.Items.boxSize
	local box = Instance.new("Part")
	box.Name = "ItemBox"
	box.Anchored = true
	box.CanCollide = false
	box.Material = Enum.Material.Neon
	box.Color = GameConfig.Items.boxColor
	box.Size = Vector3.new(size, size, size)
	box.CFrame = cf * CFrame.new(0, size / 2 + 1.5, 0)
	box.Transparency = 0.2
	box:SetAttribute("Active", true) -- 획득 후 비활성화/재생성 토글
	box.Parent = parent

	-- 물음표 표시 (모든 방향에서 보이도록 BillboardGui 사용)
	local bg = Instance.new("BillboardGui")
	bg.Name = "Mark"
	bg.Size = UDim2.fromOffset(60, 60)
	bg.AlwaysOnTop = false
	bg.Adornee = box
	bg.Parent = box
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Text = "?"
	lbl.TextColor3 = Color3.fromRGB(255, 255, 255)
	lbl.TextStrokeTransparency = 0.3
	lbl.Font = Enum.Font.GothamBlack
	lbl.TextScaled = true
	lbl.Parent = bg
	return box
end

-- 장식용 라바콘 생성 (시각적 장애물)
local function makeCone(cf: CFrame, parent: Instance)
	local cone = Instance.new("Part")
	cone.Name = "Cone"
	cone.Anchored = true
	cone.CanCollide = false
	cone.Material = Enum.Material.SmoothPlastic
	cone.Color = Color3.fromRGB(245, 140, 30)
	cone.Size = Vector3.new(2, 4, 2)
	cone.CFrame = cf * CFrame.new(0, 2, 0)
	cone.Parent = parent
end

-- =====================================================================
-- 공개 API
-- =====================================================================

-- 트랙 메타 정보(미생성). 미리보기/목록 표시에 사용 가능.
function TrackGenerator.getTrackMeta(index: number)
	return {
		index = index,
		seed = 1000 + index * 7919, -- 트랙별 고정 시드 (소수 곱)
		displayName = ("트랙 #%d"):format(index),
	}
end

-- 트랙을 실제로 생성하여 Workspace에 배치하고 정보를 반환
function TrackGenerator.build(index: number, parent: Instance?): TrackInfo
	local meta = TrackGenerator.getTrackMeta(index)
	local rng = makeRandom(meta.seed)

	local model = Instance.new("Model")
	model.Name = ("Track_%d"):format(index)

	local nodes = generateNodes(rng)
	local path = buildPath(nodes, SAMPLES_PER_SEGMENT)

	-- 도로 생성
	for i = 1, #path do
		local a = path[i]
		local b = path[(i % #path) + 1]
		makeRoadSegment(a, b, model, i)
	end

	-- 커브 이음새(틈) 메우기
	-- 직선 박스 세그먼트는 커브에서 끝면이 각을 이뤄 바깥 모서리에 삼각형 틈이 생긴다.
	-- 각 꼭짓점에 진행 방향 평균(바이섹터)으로 정렬한 도로/레일 캡을 덧대 매끄럽게 잇는다.
	-- 캡은 살짝 띄워 z-fighting을 피하고, 도로 캡은 CanCollide=false(주행 범프 방지)로 둔다.
	do
		local np = #path
		for i = 1, np do
			local prev = path[(i - 2) % np + 1]
			local cur = path[i]
			local nxt = path[i % np + 1]
			local dIn = cur - prev
			local dOut = nxt - cur
			if dIn.Magnitude < 0.05 or dOut.Magnitude < 0.05 then
				continue
			end
			local uIn, uOut = dIn.Unit, dOut.Unit
			-- 거의 직선인 이음새는 캡이 불필요 → 건너뛰어 파트 수 절약
			if uIn:Dot(uOut) > 0.99985 then
				continue
			end
			local bis = uIn + uOut
			if bis.Magnitude < 1e-3 then
				continue
			end
			local look = CFrame.lookAt(cur, cur + bis.Unit)
			local capLen = 4

			-- 도로 바닥 캡 (양쪽 벽 아래로 살짝 파묻히게 폭을 키움, 0.04 띄워 z-fighting 방지)
			local cap = Instance.new("Part")
			cap.Anchored = true
			cap.CanCollide = false
			cap.Material = Enum.Material.Asphalt
			cap.Color = ROAD_COLOR
			cap.Size = Vector3.new(ROAD_WIDTH + 1.2, ROAD_THICKNESS, capLen)
			cap.CFrame = look * CFrame.new(0, -ROAD_THICKNESS / 2 + 0.04, 0)
			cap.TopSurface = Enum.SurfaceType.Smooth
			cap.BottomSurface = Enum.SurfaceType.Smooth
			cap.Parent = model

			-- 레일 캡(좌 빨강 / 우 흰색) — 색 레일 라인을 끊김 없이 연결
			for _, side in ipairs({ -1, 1 }) do
				makeStripe(
					look,
					CFrame.new(side * (ROAD_WIDTH / 2), WALL_HEIGHT + RAIL_HEIGHT / 2 + 0.03, 0),
					Vector3.new(1.7, RAIL_HEIGHT, capLen),
					side == -1 and RAIL_LEFT or RAIL_RIGHT,
					model
				)
			end
		end
	end

	-- 체크포인트 생성 (경로 노드 위치 기반, 순서대로)
	local checkpoints: { BasePart } = {}
	local cpFolder = Instance.new("Folder")
	cpFolder.Name = "Checkpoints"
	cpFolder.Parent = model

	for i = 1, #nodes, CHECKPOINT_EVERY do
		local pos = nodes[i]
		local nextPos = nodes[i % #nodes + 1]
		local look = CFrame.lookAt(pos, nextPos)

		local cp = Instance.new("Part")
		cp.Name = ("Checkpoint_%d"):format(#checkpoints + 1)
		cp.Anchored = true
		cp.CanCollide = false
		cp.Transparency = 1
		cp.Size = Vector3.new(ROAD_WIDTH, WALL_HEIGHT * 2, 4)
		cp.CFrame = look * CFrame.new(0, WALL_HEIGHT, 0)
		cp:SetAttribute("Order", #checkpoints + 1)
		cp.Parent = cpFolder
		checkpoints[#checkpoints + 1] = cp
	end

	-- 결승선(1번 체크포인트) 시각 표시
	local startNode = nodes[1]
	local secondNode = nodes[2]
	local startLook = CFrame.lookAt(startNode, secondNode)

	local finishLine = Instance.new("Part")
	finishLine.Name = "FinishLine"
	finishLine.Anchored = true
	finishLine.CanCollide = false
	finishLine.Material = Enum.Material.SmoothPlastic
	finishLine.Color = Color3.fromRGB(245, 245, 245)
	finishLine.Size = Vector3.new(ROAD_WIDTH, 0.3, 6)
	finishLine.CFrame = startLook * CFrame.new(0, 0.2, 0)
	finishLine.Parent = model

	-- 출발 스폰 위치들 (결승선 뒤쪽, 그리드 배치)
	local spawnCFrames: { CFrame } = {}
	local rows = math.ceil(GameConfig.Race.maxPlayers / 2)
	local idx = 0
	for row = 0, rows - 1 do
		for col = -1, 1, 2 do
			idx += 1
			if idx > GameConfig.Race.maxPlayers then
				break
			end
			local offset = CFrame.new(col * (ROAD_WIDTH / 4), 4, 10 + row * 12)
			spawnCFrames[idx] = startLook * offset
		end
	end

	-- ───────── 부스트 패드 / 오일 슬릭 / 콘 배치 ─────────
	local boostPads: { BasePart } = {}
	local oilSlicks: { BasePart } = {}
	local itemFolder = Instance.new("Folder")
	itemFolder.Name = "TrackItems"
	itemFolder.Parent = model

	-- 출발선 주변(앞부분)은 비워두기 위해 일부 구간 제외
	local startGap = math.floor(#path * 0.06)
	local usable = #path - startGap * 2

	-- 부스트 패드: 도로 중앙에 균등 배치
	for i = 1, GameConfig.Boost.padsPerTrack do
		local idx = startGap + math.floor(usable * (i - 0.5) / GameConfig.Boost.padsPerTrack) + 1
		idx = ((idx - 1) % #path) + 1
		local cf = pathCFrameAt(path, idx)
		boostPads[i] = makeBoostPad(cf, itemFolder)
	end

	-- 오일 슬릭: 좌우로 살짝 비껴 배치(피할 수 있게)
	for i = 1, GameConfig.Obstacles.oilPerTrack do
		local idx = startGap + math.floor(usable * (i - 0.5) / GameConfig.Obstacles.oilPerTrack) + 1
		idx = ((idx + 4 - 1) % #path) + 1 -- 부스트와 겹치지 않게 오프셋
		local side = (i % 2 == 0) and 1 or -1
		local cf = pathCFrameAt(path, idx) * CFrame.new(side * (ROAD_WIDTH / 4), 0, 0)
		oilSlicks[i] = makeOilSlick(cf, itemFolder)
	end

	-- 아이템 박스: 도로 폭 방향으로 좌/중/우 번갈아 배치(주워 먹는 재미)
	local itemBoxes: { BasePart } = {}
	for i = 1, GameConfig.Items.boxesPerTrack do
		local idx = startGap + math.floor(usable * (i - 0.5) / GameConfig.Items.boxesPerTrack) + 1
		idx = ((idx + 2 - 1) % #path) + 1 -- 부스트/오일과 다른 위치로 오프셋
		local lane = ((i % 3) - 1) -- -1, 0, 1 순환
		local cf = pathCFrameAt(path, idx) * CFrame.new(lane * (ROAD_WIDTH / 4), 0, 0)
		itemBoxes[i] = makeItemBox(cf, itemFolder)
	end

	-- 장식용 콘: 도로 가장자리에 배치
	for i = 1, GameConfig.Obstacles.conesPerTrack do
		local idx = math.floor(#path * (i - 0.5) / GameConfig.Obstacles.conesPerTrack) + 1
		idx = ((idx - 1) % #path) + 1
		local side = (i % 2 == 0) and 1 or -1
		local cf = pathCFrameAt(path, idx) * CFrame.new(side * (ROAD_WIDTH / 2 - 2), 0, 0)
		makeCone(cf, itemFolder)
	end

	-- ───────── 미니맵용 외곽선 & 바운드 ─────────
	local minimapPath: { Vector3 } = {}
	for i = 1, #path, 2 do -- 다운샘플
		minimapPath[#minimapPath + 1] = path[i]
	end
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	for _, p in ipairs(path) do
		minX = math.min(minX, p.X)
		maxX = math.max(maxX, p.X)
		minZ = math.min(minZ, p.Z)
		maxZ = math.max(maxZ, p.Z)
	end

	model.Parent = parent or workspace

	return {
		index = index,
		displayName = meta.displayName,
		model = model,
		startCFrame = startLook,
		spawnCFrames = spawnCFrames,
		checkpoints = checkpoints,
		checkpointCount = #checkpoints,
		minimapPath = minimapPath,
		bounds = { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ },
		boostPads = boostPads,
		oilSlicks = oilSlicks,
		itemBoxes = itemBoxes,
	}
end

return TrackGenerator
