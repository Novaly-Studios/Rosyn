local XSignal = require(script.Parent.Parent:WaitForChild("XSignal"))
local Rosyn = require(script.Parent)

type ValidComponentClassOrInstance = Rosyn.ValidComponentClassOrInstance
type XSignal<T...> = XSignal.XSignal<T...>

type Registry<T> = {
    GetInstances: ((Registry<T>) -> ({[Instance]: true}));
    GetComponent: ((Registry<T>, Instance) -> (T?));
    GetComponents: ((Registry<T>) -> ({[T]: true}));
    ExpectComponent: ((Registry<T>, Instance) -> (T));
    AwaitComponentInit: ((Registry<T>, Instance) -> (T));
    GetComponentFromDescendant: ((Registry<T>, Instance) -> (T?));

    Events: {
        OnComponentAdded: XSignal<T>;
        OnComponentRemoving: XSignal<T>;
    };
};

local _RegistryCache: {[ValidComponentClassOrInstance]: Registry<any>} = {}

local Registry = {}
Registry.__index = Registry

function Registry.new<T>(ComponentClass: T): Registry<T>
    local self = setmetatable({
        _ComponentClass = ComponentClass;

        Events = {
            OnComponentAdded = Rosyn.GetAddedSignal(ComponentClass);
            OnComponentRemoving = Rosyn.GetRemovingSignal(ComponentClass);
        };
    }, Registry)

    return self
end

--- Obtains all components corresponding to the registry's type.
function Registry:GetComponents()
    return Rosyn.GetComponentsOfClass(self._ComponentClass)
end

--- Obtains all Instances corresponding to the registry's type.
function Registry:GetInstances()
    return Rosyn.GetInstancesOfClass(self._ComponentClass)
end

--- Obtains a component corresponding to the registry's type, from the given Instance.
function Registry:GetComponent(FromInstance)
    return Rosyn.GetComponent(FromInstance, self._ComponentClass)
end

--- Waits for a component to be initialized on the given Instance.
function Registry:AwaitComponentInit(FromInstance)
    return Rosyn.AwaitComponentInit(FromInstance, self._ComponentClass)
end

--- Obtains a component corresponding to the registry's type, from the given Instance.
function Registry:ExpectComponent(FromInstance)
    return Rosyn.ExpectComponent(FromInstance, self._ComponentClass)
end

--- Obtains a component corresponding to the registry's type, from a given Instance or any of its ancestors.
function Registry:GetComponentFromDescendant(FromInstance)
    return Rosyn.GetComponentFromDescendant(FromInstance, self._ComponentClass)
end

--- Finds or creates a registry for the given component type.
function Registry.GetRegistry<T>(ComponentClass: T & ValidComponentClassOrInstance): Registry<T>
    local Target = _RegistryCache[ComponentClass]

    if (Target) then
        return Target
    end

    Target = Registry.new(ComponentClass)
    _RegistryCache[ComponentClass] = Target
    return Target
end

return Registry