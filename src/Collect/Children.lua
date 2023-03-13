local TypeGuard = require(script.Parent.Parent.Parent:WaitForChild("TypeGuard"))

local ChildrenParams = TypeGuard.Params(TypeGuard.Instance())

return function(Root: Instance)
    ChildrenParams(Root)

    return function(Create, Destroy)
        local function CreateProxy(Instance)
            task.spawn(Create, Instance)

            local Temp; Temp = Instance.Destroyed:Connect(function()
                Temp:Disconnect()
                Destroy(Instance)
            end)
        end

        for _, Child in Root:GetChildren() do
            CreateProxy(Child)
        end

        Root.ChildAdded:Connect(CreateProxy)
    end
end