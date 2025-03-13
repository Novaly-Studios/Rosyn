--!optimize 2
--!native

local TypeGuard = require(script.Parent.Parent.Parent:WaitForChild("TypeGuard"))

local ChildrenParams = TypeGuard.Params(
    TypeGuard.Instance(),
    TypeGuard.Object()
)

return function(Root: Instance, ComponentClass)
    ChildrenParams(Root, ComponentClass)

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

        for _, Child in Root:GetChildren() do
            CreateProxy(Child)
        end

        Root.ChildAdded:Connect(CreateProxy)
    end
end