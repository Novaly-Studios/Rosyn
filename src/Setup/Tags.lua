local CollectionService = game:GetService("CollectionService")

local TypeGuard = require(script.Parent.Parent.Parent:WaitForChild("TypeGuard"))

local TagsParams = TypeGuard.Variadic(TypeGuard.Object():OfKeyType(TypeGuard.String()):OfValueType(TypeGuard.Table()))

return function(Definitions)
    TagsParams(Definitions)

    return function(Create, Destroy)
        for Tag, ComponentClasses in Definitions do
            -- Turn into an array if it's just one component class.
            ComponentClasses = (ComponentClasses[1] and ComponentClasses or {ComponentClasses})

            for _, ComponentClass in ComponentClasses do
                for _, Item in CollectionService:GetTagged(Tag) do
                    Create(Item, ComponentClass)
                end

                CollectionService:GetInstanceAddedSignal(Tag):Connect(function(Item)
                    Create(Item, ComponentClass)
                end)

                CollectionService:GetInstanceRemovedSignal(Tag):Connect(function(Item)
                    Destroy(Item, ComponentClass)
                end)
            end
        end
    end
end