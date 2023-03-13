local CollectionService = game:GetService("CollectionService")

local TypeGuard = require(script.Parent.Parent.Parent:WaitForChild("TypeGuard"))

local TagsParams = TypeGuard.Variadic(TypeGuard.String())

return function(...)
    TagsParams(...)
    local Tags = {...}

    return function(Create, Destroy)
        for _, Tag in Tags do
            for _, Object in CollectionService:GetTagged(Tag) do
                task.spawn(Create, Object)
            end

            CollectionService:GetInstanceAddedSignal(Tag):Connect(Create)
            CollectionService:GetInstanceRemovedSignal(Tag):Connect(Destroy)
        end
    end
end