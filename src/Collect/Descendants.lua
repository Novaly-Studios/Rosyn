local TypeGuard = require(script.Parent.Parent.Parent:WaitForChild("TypeGuard"))

local DescendantsParams = TypeGuard.Params(TypeGuard.Instance())

return function(Root: Instance)
    DescendantsParams(Root)

    return function(Create, Destroy)
        local function CreateProxy(Object: Instance)
            task.spawn(Create, Object)

            local Temp; Temp = Object.AncestryChanged:Connect(function()
                if (Object:IsDescendantOf(game)) then
                    return
                end

                Temp:Disconnect()
                Destroy(Object)
            end)
        end

        for _, Child in Root:GetDescendants() do
            CreateProxy(Child)
        end

        Root.DescendantAdded:Connect(CreateProxy)
    end
end