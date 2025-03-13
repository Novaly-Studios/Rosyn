--!optimize 2
--!native

local TypeGuard = require(script.Parent.Parent.Parent:WaitForChild("TypeGuard"))

local DescendantsParams = TypeGuard.Params(
    TypeGuard.Instance(),
    TypeGuard.Object()
)

return function(Root: Instance, ComponentClass)
    DescendantsParams(Root, ComponentClass)

    return function(Create, Destroy)
        local function CreateProxy(Object: Instance)
            task.spawn(Create, Object, ComponentClass)

            local Temp; Temp = Object.AncestryChanged:Connect(function()
                if (Object:IsDescendantOf(game)) then
                    return
                end

                Temp:Disconnect()
                Destroy(Object, ComponentClass)
            end)
        end

        for _, Child in Root:GetDescendants() do
            CreateProxy(Child)
        end

        Root.DescendantAdded:Connect(CreateProxy)
    end
end