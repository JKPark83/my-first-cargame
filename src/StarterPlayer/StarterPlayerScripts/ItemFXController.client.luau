--!strict
--[[
	ItemFXController (클라이언트)
	-----------------------------
	아이템 명중/사용의 "타격감" 연출 전담. 서버 RaceManager가 쏘는 ItemEffect 이벤트를 받아
	카메라 흔들림 · 화면 플래시 · 중앙 코믹 텍스트 · 파티클 버스트 · 사운드를 재생한다.
	  • banana      → 피격자 화면 흔들림+노란 플래시+"미끌~!", 차에서 별 버스트, 공격자 "명중!"
	  • slick       → 피격자 흔들림+갈색 플래시+"미끄덩!", 검은 튐 버스트
	  • balloon     → 착지 지점 물보라(파티클+확장 링+물소리), 피격자 흔들림, 공격자 "명중 ×N!"
	  • lightning   → 전원 짧은 백색 플래시, 피격 차량 위 낙뢰 비주얼, 피격자 감전 연출
	  • shield      → 차량을 감싸는 반투명 버블(지속시간 동안, 모든 클라에서 보임)
	  • shieldBlock → 버블 스파크 버스트+"막았다!"
	  • rocket/mushroom → 발사 화염/대시 버스트+텍스트

	게임플레이(속도/판정)는 일절 건드리지 않는 순수 연출.
	내장 텍스처/사운드(rbxasset://)만 기본 사용 → 에셋 로드 실패 없음.
	연출 강도는 GameConfig.ItemFX 에서 조절.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local GameConfig = require(ReplicatedStorage.GameConfig)
local Remotes = require(ReplicatedStorage.Remotes)

local cfg = (GameConfig :: any).ItemFX
if not cfg or cfg.enabled == false then
	return
end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- =====================================================================
-- 유틸: userId → 차량 모델 (경주 중 차량은 workspace.ActiveRace 바로 아래)
-- =====================================================================
local function findCarByUserId(userId: number): Model?
	local folder = workspace:FindFirstChild("ActiveRace")
	if not folder then
		return nil
	end
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("OwnerUserId") == userId then
			return child
		end
	end
	return nil
end

local function carPosition(userId: number): Vector3?
	local car = findCarByUserId(userId)
	local pp = car and car.PrimaryPart
	return pp and pp.Position or nil
end

-- =====================================================================
-- 사운드 (rbxasset 내장음이라 즉시 로드; 후보 리스트의 첫 로드 성공 id 사용)
-- =====================================================================
local soundTemplates: { [string]: Sound } = {}
do
	for name, ids in pairs(cfg.sounds or {}) do
		for _, id in ipairs(ids) do
			local s = Instance.new("Sound")
			s.Name = "ItemFX_" .. name
			s.SoundId = tostring(id)
			s.Volume = 0.7
			s.Parent = SoundService
			soundTemplates[name] = s
			break -- rbxasset은 항상 성공하므로 첫 후보 사용(마켓 id를 앞에 넣으면 그걸 우선)
		end
	end
end

-- 2D(화면) 재생. pitch로 코믹한 변주 가능.
local function playSound(name: string, volume: number?, pitch: number?)
	local tpl = soundTemplates[name]
	if not tpl then
		return
	end
	tpl.Volume = volume or 0.7
	tpl.PlaybackSpeed = pitch or 1
	tpl.TimePosition = 0
	tpl:Play()
end

-- 3D(위치) 재생: 임시 앵커 파트에 복제해 붙이고 재생 후 정리.
local function playSoundAt(name: string, pos: Vector3, volume: number?, pitch: number?)
	local tpl = soundTemplates[name]
	if not tpl then
		return
	end
	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.new(1, 1, 1)
	holder.CFrame = CFrame.new(pos)
	holder.Parent = workspace
	local s = tpl:Clone()
	s.Volume = volume or 1
	s.PlaybackSpeed = pitch or 1
	s.RollOffMaxDistance = 400
	s.RollOffMinDistance = 40
	s.Parent = holder
	s:Play()
	Debris:AddItem(holder, 4)
end

-- =====================================================================
-- 카메라 흔들림 (자체 펀치 값, 다른 카메라 스텝(+1, +2) 이후인 +3에서 합성)
-- =====================================================================
local shakePunch = 0 -- 도 단위 강도, 지수 감쇠

local function addShake(amount: number?)
	shakePunch = math.max(shakePunch, amount or 0)
end

RunService:BindToRenderStep("ItemFXShake", Enum.RenderPriority.Camera.Value + 3, function(dt: number)
	if shakePunch < 0.02 then
		shakePunch = 0
		return
	end
	shakePunch *= math.exp(-(cfg.shakeDecay or 3.2) * dt)
	local cam = workspace.CurrentCamera -- 리스폰 시 카메라가 교체될 수 있어 매 프레임 조회
	if not cam then
		return
	end
	local t = os.clock() * 25
	local a = math.rad(shakePunch)
	cam.CFrame = cam.CFrame
		* CFrame.Angles(math.noise(t, 0.3) * a, math.noise(0.7, t) * a, math.noise(t, t) * a * 0.4)
end)

-- =====================================================================
-- 화면 플래시 + 중앙 코믹 텍스트
-- =====================================================================
local gui = Instance.new("ScreenGui")
gui.Name = "ItemFXGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 40
gui.Parent = playerGui

local flashFrame = Instance.new("Frame")
flashFrame.Size = UDim2.fromScale(1, 1)
flashFrame.BackgroundTransparency = 1
flashFrame.BorderSizePixel = 0
flashFrame.ZIndex = 1
flashFrame.Parent = gui

local function screenFlash(color: Color3, strength: number?)
	flashFrame.BackgroundColor3 = color
	flashFrame.BackgroundTransparency = 1 - (strength or 0.45)
	TweenService:Create(flashFrame, TweenInfo.new(cfg.flashDuration or 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	}):Play()
end

local popLabel = Instance.new("TextLabel")
popLabel.AnchorPoint = Vector2.new(0.5, 0.5)
popLabel.Position = UDim2.fromScale(0.5, 0.34)
popLabel.Size = UDim2.fromScale(0.6, 0.12)
popLabel.BackgroundTransparency = 1
popLabel.Font = Enum.Font.GothamBlack
popLabel.TextScaled = true
popLabel.TextStrokeColor3 = Color3.fromRGB(20, 16, 8)
popLabel.TextStrokeTransparency = 0.2
popLabel.Visible = false
popLabel.ZIndex = 2
popLabel.Parent = gui

local popScale = Instance.new("UIScale")
popScale.Parent = popLabel

local popToken = 0
-- 중앙에 "뿅" 하고 커졌다 사라지는 코믹 텍스트. scale<1이면 보조 알림(공격자 피드백)용으로 작게.
local function popText(text: string, color: Color3, scale: number?)
	popToken += 1
	local myToken = popToken
	popLabel.Text = text
	popLabel.TextColor3 = color
	popLabel.TextTransparency = 0
	popLabel.TextStrokeTransparency = 0.2
	popLabel.Visible = true
	popScale.Scale = 0.25 * (scale or 1)
	TweenService:Create(popScale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = scale or 1,
	}):Play()
	task.delay(cfg.popTextDuration or 1.0, function()
		if popToken ~= myToken then
			return -- 이미 다른 텍스트가 덮어씀
		end
		local fade = TweenService:Create(popLabel, TweenInfo.new(0.25), {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		})
		fade.Completed:Once(function()
			if popToken == myToken then
				popLabel.Visible = false
			end
		end)
		fade:Play()
	end)
end

-- =====================================================================
-- 파티클 버스트 (내장 텍스처만 사용)
-- =====================================================================
local function burstPart(pos: Vector3): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(2, 2, 2)
	p.CFrame = CFrame.new(pos)
	p.Parent = workspace
	Debris:AddItem(p, 3)
	return p
end

-- 별(반짝이) 버스트: 바나나/기름통 명중, 방어막 튕김
local function starBurst(pos: Vector3, color: Color3, count: number)
	local p = burstPart(pos)
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Color = ColorSequence.new(color)
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Lifetime = NumberRange.new(0.4, 0.8)
	e.Rate = 0
	e.Speed = NumberRange.new(18, 34)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Acceleration = Vector3.new(0, -40, 0)
	e.LightEmission = 1
	e.Parent = p
	e:Emit(count)
end

-- 연기 퍼프: 기름통/버섯 대시
local function smokePuff(pos: Vector3, color: Color3, count: number)
	local p = burstPart(pos)
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/smoke_main.dds"
	e.Color = ColorSequence.new(color)
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2),
		NumberSequenceKeypoint.new(1, 6),
	})
	e.Lifetime = NumberRange.new(0.5, 0.9)
	e.Rate = 0
	e.Speed = NumberRange.new(8, 16)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Acceleration = Vector3.new(0, 10, 0)
	e.Parent = p
	e:Emit(count)
end

-- 화염 버스트: 로켓 발사
local function flameBurst(pos: Vector3, count: number)
	local p = burstPart(pos)
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/fire_main.dds"
	e.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 225, 130)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 80, 20)),
	})
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2.4),
		NumberSequenceKeypoint.new(1, 0.3),
	})
	e.Lifetime = NumberRange.new(0.25, 0.5)
	e.Rate = 0
	e.Speed = NumberRange.new(14, 26)
	e.SpreadAngle = Vector2.new(180, 40)
	e.LightEmission = 1
	e.Parent = p
	e:Emit(count)
end

-- 물보라: 물풍선 착지 (물방울 파티클 + 바닥에서 커지는 반투명 링)
local function waterSplash(pos: Vector3)
	local p = burstPart(pos)
	local drops = Instance.new("ParticleEmitter")
	drops.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	drops.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(190, 235, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(90, 170, 255)),
	})
	drops.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.8),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	drops.Lifetime = NumberRange.new(0.5, 0.9)
	drops.Rate = 0
	drops.Speed = NumberRange.new(24, 44)
	drops.SpreadAngle = Vector2.new(70, 70)
	drops.Acceleration = Vector3.new(0, -80, 0)
	drops.LightEmission = 0.6
	drops.Parent = p
	drops:Emit(60)

	local mist = Instance.new("ParticleEmitter")
	mist.Texture = "rbxasset://textures/particles/smoke_main.dds"
	mist.Color = ColorSequence.new(Color3.fromRGB(200, 235, 255))
	mist.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	mist.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 3),
		NumberSequenceKeypoint.new(1, 9),
	})
	mist.Lifetime = NumberRange.new(0.6, 1.0)
	mist.Rate = 0
	mist.Speed = NumberRange.new(6, 12)
	mist.SpreadAngle = Vector2.new(180, 180)
	mist.Parent = p
	mist:Emit(20)

	-- 확장하며 사라지는 물결 링 3겹
	for i = 1, 3 do
		local ring = Instance.new("Part")
		ring.Shape = Enum.PartType.Cylinder
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanQuery = false
		ring.CanTouch = false
		ring.Material = Enum.Material.Neon
		ring.Color = Color3.fromRGB(150, 215, 255)
		ring.Transparency = 0.35
		ring.Size = Vector3.new(0.4, 4, 4)
		ring.CFrame = CFrame.new(pos + Vector3.new(0, 0.5 + i * 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90))
		ring.Parent = workspace
		TweenService:Create(ring, TweenInfo.new(0.55 + i * 0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(0.15, 22 + i * 8, 22 + i * 8),
			Transparency = 1,
		}):Play()
		Debris:AddItem(ring, 1.4)
	end
end

-- 낙뢰 비주얼: 차량 위 하늘에서 내리꽂는 지그재그 네온 볼트
local function lightningBolt(pos: Vector3)
	local top = pos + Vector3.new(0, 46, 0)
	local prev = top
	local segments = 6
	for i = 1, segments do
		local t = i / segments
		local nextPos = pos:Lerp(top, 1 - t)
			+ Vector3.new((math.random() - 0.5) * 10, 0, (math.random() - 0.5) * 10)
		if i == segments then
			nextPos = pos
		end
		local seg = Instance.new("Part")
		seg.Anchored = true
		seg.CanCollide = false
		seg.CanQuery = false
		seg.CanTouch = false
		seg.Material = Enum.Material.Neon
		seg.Color = Color3.fromRGB(255, 245, 130)
		local len = (nextPos - prev).Magnitude
		seg.Size = Vector3.new(0.8, 0.8, math.max(len, 0.5))
		seg.CFrame = CFrame.lookAt((prev + nextPos) / 2, nextPos)
		seg.Parent = workspace
		TweenService:Create(seg, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Transparency = 1,
		}):Play()
		Debris:AddItem(seg, 0.6)
		prev = nextPos
	end
	starBurst(pos, Color3.fromRGB(255, 245, 140), 30)
end

-- =====================================================================
-- 방어막 버블 (모든 클라에서 로컬 생성 → 모두에게 보임, 지속시간 후 제거)
-- =====================================================================
local shieldBubbles: { [number]: BasePart } = {}

local function showShieldBubble(userId: number, duration: number)
	local old = shieldBubbles[userId]
	if old and old.Parent then
		old:Destroy()
	end
	local car = findCarByUserId(userId)
	local seat = car and car.PrimaryPart
	if not seat then
		return
	end
	local bubble = Instance.new("Part")
	bubble.Name = "ShieldBubble"
	bubble.Shape = Enum.PartType.Ball
	bubble.Anchored = false
	bubble.CanCollide = false
	bubble.CanQuery = false
	bubble.CanTouch = false
	bubble.Massless = true
	bubble.Size = Vector3.new(14, 14, 14)
	bubble.Color = Color3.fromRGB(140, 220, 255)
	bubble.Material = Enum.Material.ForceField
	bubble.Transparency = 0.25
	bubble.CFrame = seat.CFrame
	bubble.Parent = workspace
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = seat
	weld.Part1 = bubble
	weld.Parent = bubble
	shieldBubbles[userId] = bubble
	Debris:AddItem(bubble, duration)
end

-- =====================================================================
-- 이벤트 디스패치
-- =====================================================================
local myId = player.UserId

local function contains(list: any, v: number): boolean
	if typeof(list) ~= "table" then
		return false
	end
	for _, x in ipairs(list) do
		if x == v then
			return true
		end
	end
	return false
end

Remotes.Event("ItemEffect").OnClientEvent:Connect(function(info: any)
	if typeof(info) ~= "table" then
		return
	end
	local kind = info.kind

	if kind == "banana" then
		local pos = carPosition(info.userId)
		if pos then
			starBurst(pos, Color3.fromRGB(255, 225, 80), 34)
			playSoundAt("splat", pos, 1, 1.05)
		end
		if info.userId == myId then
			addShake(cfg.shake.banana)
			screenFlash(Color3.fromRGB(255, 220, 60), 0.4)
			popText("🍌 미끌~!", Color3.fromRGB(255, 230, 90))
			playSound("spin", 0.8, 1.1)
		elseif info.fromUserId == myId then
			popText("🍌 명중!", Color3.fromRGB(255, 240, 150), 0.7)
			playSound("pop", 0.6, 1.2)
		end
	elseif kind == "slick" then
		local pos = carPosition(info.userId)
		if pos then
			smokePuff(pos, Color3.fromRGB(60, 55, 50), 24)
			starBurst(pos, Color3.fromRGB(120, 100, 70), 16)
			playSoundAt("splat", pos, 0.9, 0.75)
		end
		if info.userId == myId then
			addShake(cfg.shake.slick)
			screenFlash(Color3.fromRGB(90, 70, 40), 0.45)
			popText("🛢️ 미끄덩!", Color3.fromRGB(230, 200, 120))
			playSound("swoosh", 0.8, 0.85)
		elseif info.fromUserId == myId then
			popText("🛢️ 명중!", Color3.fromRGB(230, 210, 150), 0.7)
			playSound("pop", 0.6, 1.2)
		end
	elseif kind == "balloon" then
		local landPos = Vector3.new(info.landX or 0, info.landY or 0, info.landZ or 0)
		waterSplash(landPos)
		playSoundAt("splash", landPos, 1, 1)
		if contains(info.victims, myId) then
			addShake(cfg.shake.balloon)
			screenFlash(Color3.fromRGB(110, 190, 255), 0.5)
			popText("💦 갇혔다!", Color3.fromRGB(170, 225, 255))
		else
			-- 구경꾼 근접 흔들림(가까울수록 크게)
			local cam = workspace.CurrentCamera
			local dist = cam and (cam.CFrame.Position - landPos).Magnitude or math.huge
			local r = cfg.nearMissRadius or 40
			if dist < r then
				addShake(cfg.shake.balloon * 0.4 * (1 - dist / r))
			end
		end
		if info.fromUserId == myId then
			local hit = tonumber(info.hit) or 0
			if hit > 0 then
				popText(("💦 명중 ×%d!"):format(hit), Color3.fromRGB(170, 225, 255), 0.7)
				playSound("pop", 0.7, 1.3)
			else
				popText("💦 빗나감…", Color3.fromRGB(200, 210, 225), 0.6)
			end
		end
	elseif kind == "lightning" then
		screenFlash(Color3.fromRGB(255, 255, 220), 0.25)
		playSound("zap", 0.8, 0.9)
		if typeof(info.victims) == "table" then
			for _, vid in ipairs(info.victims) do
				local pos = carPosition(vid)
				if pos then
					lightningBolt(pos)
				end
			end
		end
		if contains(info.victims, myId) then
			addShake(cfg.shake.lightning)
			screenFlash(Color3.fromRGB(255, 250, 160), 0.5)
			popText("⚡ 감전!", Color3.fromRGB(255, 245, 140))
		elseif info.userId == myId then
			popText("⚡ 번개 발사!", Color3.fromRGB(255, 245, 160), 0.7)
		end
	elseif kind == "shield" then
		local duration = ((GameConfig.Items :: any).shield or {}).duration or 5
		showShieldBubble(info.userId, duration)
		if info.userId == myId then
			popText("🛡️ 방어막 ON!", Color3.fromRGB(150, 225, 255), 0.8)
			playSound("pop", 0.6, 1)
		end
	elseif kind == "shieldBlock" then
		local pos = carPosition(info.userId)
		if pos then
			starBurst(pos, Color3.fromRGB(140, 225, 255), 40)
			playSoundAt("block", pos, 1, 1.1)
		end
		if info.userId == myId then
			addShake(cfg.shake.shieldBlock)
			popText("🛡️ 막았다!", Color3.fromRGB(160, 230, 255), 0.8)
		end
	elseif kind == "rocket" then
		local pos = carPosition(info.userId)
		if pos then
			flameBurst(pos, 40)
			playSoundAt("swoosh", pos, 0.9, 1.1)
		end
		if info.userId == myId then
			addShake(cfg.shake.rocket)
			popText("🚀 발사!", Color3.fromRGB(255, 190, 120), 0.8)
		end
	elseif kind == "mushroom" then
		local pos = carPosition(info.userId)
		if pos then
			smokePuff(pos, Color3.fromRGB(150, 235, 130), 20)
		end
		if info.userId == myId then
			popText("🍄 대시!", Color3.fromRGB(170, 240, 150), 0.8)
			playSound("pop", 0.6, 1.4)
		end
	end
end)
