local XSignal = require(script.Parent.Parent:WaitForChild("XSignal"))
local Rosyn = require(script.Parent)

type ValidComponentClassOrInstance = Rosyn.ValidComponentClassOrInstance
type XSignal<T...> = XSignal.XSignal<T...>

type RosynRegistry<T> = {
    GetInstances: ((RosynRegistry<T>) -> ({[Instance]: true}));
    GetComponent: ((RosynRegistry<T>) -> (T));
    GetComponents: ((RosynRegistry<T>) -> ({[T]: true}));
    ExpectComponent: ((RosynRegistry<T>) -> (T));
    AwaitComponentInit: ((RosynRegistry<T>) -> (T));
    GetComponentFromDescendant: ((RosynRegistry<T>) -> (T));

    Events: {
        OnComponentAdded: XSignal<T>;
        OnComponentRemoving: XSignal<T>;
        OnComponentInitialized: XSignal<T>;
    };
};

local _RegistryCache: {[ValidComponentClassOrInstance]: RosynRegistry<any>} = {}

local RosynRegistry = {}
RosynRegistry.__index = RosynRegistry

function RosynRegistry.new(ComponentClass)
    return setmetatable({
        _ComponentClass = ComponentClass;

        Events = {
            OnComponentAdded = Rosyn.GetAddedSignal(ComponentClass);
            OnComponentRemoving = Rosyn.GetRemovingSignal(ComponentClass);
        };
    }, RosynRegistry)
end

--- Obtains all components corresponding to the registry's type.
function RosynRegistry:GetComponents()
    return Rosyn.GetComponentsOfClass(self._ComponentClass)
end

--- Obtains all Instances corresponding to the registry's type.
function RosynRegistry:GetInstances()
    return Rosyn.GetInstancesOfClass(self._ComponentClass)
end

--- Obtains a component corresponding to the registry's type, from the given Instance.
function RosynRegistry:GetComponent(FromInstance)
    return Rosyn.GetComponent(FromInstance, self._ComponentClass)
end

--- Waits for a component to be initialized on the given Instance.
function RosynRegistry:AwaitComponentInit(FromInstance)
    return Rosyn.AwaitComponentInit(FromInstance, self._ComponentClass)
end

--- Obtains a component corresponding to the registry's type, from the given Instance.
function RosynRegistry:ExpectComponent(FromInstance)
    return Rosyn.ExpectComponent(FromInstance, self._ComponentClass)
end

--- Obtains a component corresponding to the registry's type, from a given Instance or any of its ancestors.
function RosynRegistry:GetComponentFromDescendant(FromInstance)
    return Rosyn.GetComponentFromDescendant(FromInstance, self._ComponentClass)
end

--- Finds or creates a registry for the given component type.
function RosynRegistry.GetRegistry<T>(ComponentClass: T & ValidComponentClassOrInstance): RosynRegistry<T>
    local Target = _RegistryCache[ComponentClass]

    if (Target) then
        return Target
    end

    Target = RosynRegistry.new(ComponentClass)
    _RegistryCache[ComponentClass] = Target
    return Target
end

return RosynRegistry