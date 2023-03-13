local TypeGuard = require(script.Parent.Parent.Parent:WaitForChild("TypeGuard"))

local DescendantsParams = TypeGuard.Params(TypeGuard.Instance())

return function(Root: Instance)
    DescendantsParams(Root)

    return function(Create, Destroy)
        local function CreateProxy(Instance)
            task.spawn(Create, Instance)

            local Temp; Temp = Instance.Destroyed:Connect(function()
                Temp:Disconnect()
                Destroy(Instance)
            end)
        end

        for _, Child in Root:GetDescendants() do
            CreateProxy(Child)
        end

        Root.DescendantAdded:Connect(CreateProxy)
    end
end