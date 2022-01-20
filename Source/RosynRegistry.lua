--!nonstrict
export type RosynRegistry<ComponentT> = {
    ComponentInitialized: {[Instance]: BindableEvent},
    ComponentRemoved: {[Instance]: BindableEvent},
    ComponentAdded: {[Instance]: BindableEvent},

    InstanceToComponent: {[Instance]: ComponentT},
    ComponentClass: ComponentT,

    new: (ComponentT) -> RosynRegistry<ComponentT>,

    GetComponent: (Instance) -> ComponentT?,
    AwaitComponent: (Instance) -> ComponentT,
    AwaitComponentInit: (Instance) -> ComponentT,

    _AddComponent: (Instance) -> (),
    _RemoveComponent: (Instance) -> (),
    _GetComponentAddedSignal: (Instance, ComponentT) -> BindableEvent,
    _GetComponentRemovedSignal: (Instance, ComponentT) -> BindableEvent,
}

local RosynRegistry = {}
RosynRegistry.__index = RosynRegistry

function RosynRegistry.new(ComponentClass)
    local self = {
        ComponentInitialized = {};
        ComponentRemoved = {};
        ComponentAdded = {};

        InstanceToComponent = {};
        ComponentClass = ComponentClass;
    }

    return setmetatable(self, ComponentClass)
end

function RosynRegistry:GetComponent(From)
    return self.InstanceToComponent[From]
end

function RosynRegistry:AwaitComponent(From)

end

function RosynRegistry:AwaitComponentInit(From)

end

function RosynRegistry:_AddComponent(To)

end

return RosynRegistry