--!strict
--[[
	ShowcaseSpin (클라이언트)
	--------------------------
	"ShowcaseSpin" 태그가 붙은 전시용 모델(예: 차량 선택 패드 위 차량)을
	클라이언트에서만 천천히 회전시킵니다. 서버 복제 비용이 없습니다.

	대상 모델은 PrimaryPart가 설정되어 있어야 합니다.
	(CarSpawner.build는 VehicleSeat를 PrimaryPart로 둡니다 — 충족)
]]

local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local SPIN_DEGREES_PER_SEC = 30

RunService.RenderStepped:Connect(function(dt: number)
	for _, m in ipairs(CollectionService:GetTagged("ShowcaseSpin")) do
		if m:IsA("Model") and m.PrimaryPart then
			m:PivotTo(m:GetPivot() * CFrame.Angles(0, math.rad(SPIN_DEGREES_PER_SEC) * dt, 0))
		end
	end
end)
