-- Allows easy command bar paste.
if (not script) then
	script = game:GetService("ReplicatedFirst").Rosyn
end

local TableUtil = require(script.Parent:WaitForChild("TableUtil"))
    local Lockdown = TableUtil.Map.Lockdown or TableUtil.Map.MutableLockdown1D
local XSignal = require(script.Parent:WaitForChild("XSignal"))
    type XSignal<T...> = XSignal.XSignal<T...>
    local CreateXSignal = XSignal.new
local Async = require(script.Parent:WaitForChild("Async"))
    local AsyncGetMetadata = Async.GetMetadata
    local AsyncOnFinish = Async.OnFinish
    local AsyncResults = Async.GetMetadata
    local AsyncCancel = Async.Cancel
    local AsyncAwait = Async.Await
    local AsyncSpawn = Async.Spawn
local TG = require(script.Parent:WaitForChild("TypeGuard"))

type RosynOptions = {
    DistributeLoadSeconds: number?;
    InitialTimeoutWarn: number?;
    InitialTimeout: number?;
    WrapDestroy: boolean?;
    WrapInitial: boolean?;
}
local RosynOptions = TG.Object({
    DistributeLoadSeconds = TG.Number():Optional();
    InitialTimeoutWarn = TG.Number():Optional();
    InitialTimeout = TG.Number():Optional();
    WrapDestroy = TG.Boolean():Optional();
    WrapInitial = TG.Boolean():Optional();
}):Strict()

type ValidComponentClass = {
    ValidateStructure: ((ValidComponentClass) -> ())?;
    Options: RosynOptions?;
    Type: string?;
    Name: string?;

    _DESTROY_WRAPPED: boolean?;
    _INITIAL_WRAPPED: boolean?;

    Initial: ((ValidComponentClass) -> ())?;
    Destroy: ((ValidComponentClass) -> ())?;
    new: ((Instance) -> any);
}
local ValidComponentClass = TG.Object({
    ValidateStructure = TG.Function():Optional();
    Options = RosynOptions:Optional();
    Type = TG.String():Optional();
    Name = TG.String():Optional();

    Initial = TG.Function():Optional();
    Destroy = TG.Function():Optional();
    new = TG.Function();
}):CheckMetatable(TG.Nil()):Cached()

type RegisterData = {
    DistributeOverSeconds: boolean?;
    Components: ((((Instance, ValidComponentClass) -> ()), ((Instance, ValidComponentClass) -> ())) -> ());
    Filter: ((Instance) -> boolean)?;
}

local DEFAULT_COMPONENT_OPTIONS = {
    InitialTimeoutWarn = 15;
    InitialTimeout = 120;
    WrapDestroy = true;
    WrapInitial = true;
}

local MEMORY_TAG_SUFFIX = ":Initial()"

-- Associations between Instances, component classes, and component instances, to ensure immediate lookup.
local _ComponentClassToComponents = {}
local _ComponentClassToInstances = {}
local _ComponentsToInitialThread = {} :: {[ValidComponentClass]: thread}
local _InstanceToComponents = {}

local _InitialWrapped = {}

-- Events related to component classes.
local _ComponentClassInitializationFailed = CreateXSignal()
local _ComponentClassRemovingEvents = {}
local _ComponentClassAddedEvents = {}

-- Flags set by user-exposed functions
local _ConstructorTags = false
local _DestructorTags = false
local _InitialTags = false

local Setup = script:WaitForChild("Setup")

local RandomGen = Random.new()

--[[
    Components are composed over Instances and any Instance
    can have multiple components. Multiple components of
    the same type cannot exist concurrently on an Instance.
    @classmod Rosyn

    @todo Detect circular dependencies on AwaitComponentInit.
]]
local Rosyn = {
    ComponentClassInitializationFailed = _ComponentClassInitializationFailed;

    Setup = {
        Descendants = require(Setup:WaitForChild("Descendants"));
        Children = require(Setup:WaitForChild("Children"));
        Tags = require(Setup:WaitForChild("Tags"));
    };

    -- Helps debugging.
    _ComponentClassToComponents = _ComponentClassToComponents;
    _ComponentClassToInstances = _ComponentClassToInstances;
    _ComponentsToInitialThread = _ComponentsToInitialThread;
    _InstanceToComponents = _InstanceToComponents;

    _ComponentClassRemovingEvents = _ComponentClassRemovingEvents;
    _ComponentClassAddedEvents = _ComponentClassAddedEvents;
};

--- Obtains a user-defined or default setting for a component class.
local function _GetOption(ComponentClass, Key: string): any?
    local CustomOptions = ComponentClass.Options

    if (CustomOptions) then
        local Target = CustomOptions[Key]

        if (Target) then
            return Target
        end
    end

    return DEFAULT_COMPONENT_OPTIONS[Key]
end

--- Attempts to get a unique ID from the component class passed. A Name field in all component classes is the recommended approach.
local function _GetComponentClassName(ComponentClass: any): string
    return ComponentClass.Type or ComponentClass.Name or tostring(ComponentClass)
end

local function _GetComponent(Object, ComponentClass)
    local ComponentsForObject = _InstanceToComponents[Object]
    return ComponentsForObject and ComponentsForObject[ComponentClass] or nil
end

local GetComponentParams = TG.Params(TG.Instance(), ValidComponentClass)
--- Attempts to obtain a specific component from an Instance given a component class.
function Rosyn.GetComponent<T>(Object: Instance, ComponentClass: T): T?
    GetComponentParams(Object, ComponentClass)
    return _GetComponent(Object, ComponentClass)
end

local function _GetAddedSignal(ComponentClass)
    local AddedEvent = _ComponentClassAddedEvents[ComponentClass]

    if (AddedEvent) then
        return AddedEvent
    end

    AddedEvent = CreateXSignal()
    _ComponentClassAddedEvents[ComponentClass] = AddedEvent
    return AddedEvent
end

local GetAddedSignalParams = TG.Params(ValidComponentClass)
--- Obtains or creates a Signal which will fire when a component has been instantiated.
function Rosyn.GetAddedSignal(ComponentClass: ValidComponentClass): XSignal<Instance>
    GetAddedSignalParams(ComponentClass)
    return _GetAddedSignal(ComponentClass)
end

local function _GetRemovingSignal(ComponentClass)
    local RemovingEvent = _ComponentClassRemovingEvents[ComponentClass]

    if (RemovingEvent) then
        return RemovingEvent
    end

    RemovingEvent = CreateXSignal()
    _ComponentClassRemovingEvents[ComponentClass] = RemovingEvent
    return RemovingEvent
end

local GetRemovingSignalParams = TG.Params(ValidComponentClass)
--- Obtains or creates a Signal which will fire when a component is about to be destroyed.
function Rosyn.GetRemovingSignal(ComponentClass: ValidComponentClass): XSignal<Instance>
    GetRemovingSignalParams(ComponentClass)
    return _GetRemovingSignal(ComponentClass)
end

local function _InitialWarning(Object, ComponentName, Seconds)
    warn(`Component '{ComponentName}' on '{Object:GetFullName()}' is taking a long time to initialize ({Seconds}s)`)
end

local AddComponentParams = TG.Params(TG.Instance(), ValidComponentClass)
--- Creates and wraps a component around an Instance, given a component class.
function _AddComponent(Object: Instance, ComponentClass: ValidComponentClass)
    AddComponentParams(Object, ComponentClass)

    local ComponentName = _GetComponentClassName(ComponentClass)
    local ExistingComponent = _GetComponent(Object, ComponentClass)

    if (ExistingComponent) then
        error(`Component {ComponentName} already present on {Object:GetFullName()}`)
    end

    local ValidateStructure = ComponentClass.ValidateStructure

    if (ValidateStructure) then
        ValidateStructure(Object)
    end

    if (_ConstructorTags) then
        debug.profilebegin(ComponentName .. ".new()")
    end

    local NewComponent; task.spawn(function()
        NewComponent = ComponentClass.new(Object)
    end)

    if (_ConstructorTags) then
        debug.profileend()
    end

    if (not NewComponent) then
        error(`Component constructor {ComponentName} yielded or threw an error on {Object:GetFullName()}`)
    end

    ---------------------------------------------------------------------------------------------------------
    -- Associate Instance to component instances.
    local ExistingComponentsForInstance = _InstanceToComponents[Object]

    if (ExistingComponentsForInstance) then
        ExistingComponentsForInstance[ComponentClass] = NewComponent
    else
        _InstanceToComponents[Object] = {[ComponentClass] = NewComponent}
    end

    -- Associate component classes to Instances.
    local ExistingInstancesForComponentClass = _ComponentClassToInstances[ComponentClass]

    if (ExistingInstancesForComponentClass) then
        ExistingInstancesForComponentClass[Object] = true
    else
        _ComponentClassToInstances[ComponentClass] = {[Object] = true}
    end

    -- Associate component classes to component instances.
    local ExistingComponentsForComponentClass = _ComponentClassToComponents[ComponentClass]

    if (ExistingComponentsForComponentClass) then
        ExistingComponentsForComponentClass[NewComponent] = true
    else
        _ComponentClassToComponents[ComponentClass] = {[NewComponent] = true}
    end
    ---------------------------------------------------------------------------------------------------------

    local Initial = NewComponent.Initial

    if (Initial) then
        local InitialTimeoutWarn = _GetOption(ComponentClass, "InitialTimeoutWarn") :: number
        local InitialTimeout = _GetOption(ComponentClass, "InitialTimeout") :: number
        local InitialWarning = task.delay(InitialTimeoutWarn, _InitialWarning, Object, ComponentName, InitialTimeoutWarn)

        if (_InitialTags) then
            debug.profilebegin(ComponentName .. ":Initial()")
        end

        local Thread = AsyncSpawn(function()
            AsyncOnFinish(function(Success, Result)
                task.cancel(InitialWarning)

                if (Success) then
                    return
                end

                _ComponentClassInitializationFailed:Fire(ComponentName, Object, Result, "")

                if (Result == "TIMEOUT") then
                    task.spawn(error, `Component {ComponentName} failed to initialize on {Object:GetFullName()} within {InitialTimeout} seconds`)
                    return
                end

                task.spawn(error, `Component {ComponentName} failed to initialize on {Object:GetFullName()}`)
            end)

            local Distribute = _GetOption(ComponentClass, "DistributeLoadSeconds")

            if (Distribute) then
                task.wait(RandomGen:NextNumber(0, Distribute))
            end

            Initial(NewComponent)
        end)

        if (_InitialTags) then
            debug.profileend()
        end

        _ComponentsToInitialThread[NewComponent] = Thread
        -- Terminate all sub-threads only if component explicitly timed out.
        -- Otherwise keep them running (until component is destroyed).
        task.delay(InitialTimeout, function()
            local Success = AsyncResults(Thread).Success

            if (not Success) then
                AsyncCancel(Thread, "TIMEOUT")
            end
        end)
    end

    local AddedSignal = _GetAddedSignal(ComponentClass)
    AddedSignal:Fire(Object)
end

local RemoveComponentParams = TG.Params(TG.Instance(), ValidComponentClass)
--- Removes a component from an Instance, given a component class. Calls Destroy on component.
function _RemoveComponent(Object: Instance, ComponentClass: ValidComponentClass)
    RemoveComponentParams(Object, ComponentClass)

    local ComponentName = _GetComponentClassName(ComponentClass)
    local ExistingComponent = _GetComponent(Object, ComponentClass)

    if (not ExistingComponent) then
        error(`Component {ComponentName} not present on {Object:GetFullName()}`)
    end

    local RemovingSignal = _GetRemovingSignal(ComponentClass)
    RemovingSignal:Fire(Object)

    ---------------------------------------------------------------------------------------------------------
    -- De-associate component from its Instance.
    local ExistingComponentsForInstance = _InstanceToComponents[Object]
    ExistingComponentsForInstance[ComponentClass] = nil

    -- Makes sure Instance refs are cleaned up when they have no components.
    if (next(ExistingComponentsForInstance) == nil) then
        _InstanceToComponents[Object] = nil
    end

    -- De-associate Instance from its component class.
    _ComponentClassToInstances[ComponentClass][Object] = nil

    -- De-associate component from its component class.
    _ComponentClassToComponents[ComponentClass][ExistingComponent] = nil
    ---------------------------------------------------------------------------------------------------------

    -- Wait for Intial to finish if it hasn't already - this way Destroy is guaranteed to be called after Initial.
    -- Initial is guaranteed to timeout using the Async library, so this is safe.
    local InitialThread = _ComponentsToInitialThread[ExistingComponent]

    -- Initial thread being nil implies this is just a raw table w/o the standard lifecycle.
    if (InitialThread) then
        AsyncAwait(InitialThread)

        -- Destroy component to let it clean stuff up.
        if (_DestructorTags) then
            debug.profilebegin(ComponentName .. ":Destroy()")
        end

        _ComponentsToInitialThread[ExistingComponent] = nil

        local Destroy = ExistingComponent.Destroy

        if (Destroy) then
            if (coroutine.status(task.spawn(Destroy, ExistingComponent)) ~= "dead") then
                error(`Component destructor {ComponentName} yielded or threw an error on {Object:GetFullName()}`)
            end
        end

        AsyncCancel(InitialThread, "ROSYN_DESTROY") -- This will terminate all descendant threads spawned in Initial, on component removal / destruction.

        if (_DestructorTags) then
            debug.profileend()
        end
    end
end

local RegisterParams = TG.Params(TG.Object({
    DistributeOverSeconds = TG.Number():Optional();
    Components = TG.Function();
    Filter = TG.Function():Optional();
}))
function Rosyn.Register(Data: RegisterData)
    RegisterParams(Data)

    local Filter = Data.Filter

    local function HandleCreation(Item: Instance, ComponentClass: ValidComponentClass)
        if (Filter and not Filter(Item, ComponentClass)) then
            return
        end

        if (_GetComponent(Item, ComponentClass)) then
            return
        end

        local OriginalDestroy = ComponentClass.Destroy

        -- Check if destroy exists, else warn user there is none
        if (not OriginalDestroy) then
            local ComponentName = _GetComponentClassName(ComponentClass)
            warn(`Component {ComponentName} has no destructor on {Item:GetFullName()}`)
        end

        -- Wrap destroy option -> completely lock object after its lifecycle finishes, useful for highlighting where users should not be using references to the component.
        local WrapDestroy = _GetOption(ComponentClass, "WrapDestroy")

        if (WrapDestroy and not ComponentClass._DESTROY_WRAPPED) then
            ComponentClass.Destroy = function(self)
                OriginalDestroy(self)
                Lockdown(self)
            end

            ComponentClass._DESTROY_WRAPPED = true
        end

        -- Wrap initial option -> set memory tags, useful for detecting users forgetting to disconnect signals and such.
        local WrapInitial = _GetOption(ComponentClass, "WrapInitial")

        if (WrapInitial and not _InitialWrapped[ComponentClass]) then
            local ComponentName = _GetComponentClassName(ComponentClass)
            local OldInitial = ComponentClass.Initial
            local MemoryTag = ComponentName .. MEMORY_TAG_SUFFIX

            ComponentClass.Initial = function(self)
                debug.setmemorycategory(MemoryTag)
                OldInitial(self)
                debug.resetmemorycategory()
            end

            _InitialWrapped[ComponentClass] = true
        end

        _AddComponent(Item, ComponentClass)
    end

    local function HandleDestruction(Item: Instance, ComponentClass: ValidComponentClass)
        local ExistingComponent = _GetComponent(Item, ComponentClass)

        if (not ExistingComponent) then
            return
        end

        _RemoveComponent(Item, ComponentClass)
    end

    Data.Components(HandleCreation, HandleDestruction)
end

local function _ExpectComponent(Object, ComponentClass)
    local Component = _GetComponent(Object, ComponentClass)

    if (Component == nil) then
        error(`Expected component '{_GetComponentClassName(ComponentClass)}' to exist on Instance '{Object:GetFullName()}'`)
    end

    return Component
end

local ExpectComponentParams = TG.Params(TG.Instance(), ValidComponentClass)
--- Asserts that a component exists on a given Instance.
function Rosyn.ExpectComponent<T>(Object: Instance, ComponentClass: T): T
    ExpectComponentParams(Object, ComponentClass)
    return _ExpectComponent(Object, ComponentClass)
end

local ExpectComponentInitParams = TG.Params(TG.Instance(), ValidComponentClass)
--- Asserts that a component exists on a given Instance and that it has been initialized.
function Rosyn.ExpectComponentInit<T>(Object: Instance, ComponentClass: T): T
    ExpectComponentInitParams(Object, ComponentClass)

    local Component = _ExpectComponent(Object, ComponentClass)
    local Metadata = AsyncGetMetadata(_ComponentsToInitialThread[Component])

    if (Metadata == nil or Metadata.Success == nil) then
        error(`Expected component '{_GetComponentClassName(ComponentClass)}' to be initialized on Instance '{Object:GetFullName()}'`)
    end

    return Component
end

local AwaitComponentInitParams = TG.Params(TG.Instance(), ValidComponentClass, TG.Number():Optional())
--- Waits for a component instance's asynchronous Initial method to complete and returns it.
function Rosyn.AwaitComponentInit<T>(Object: Instance, ComponentClass: T, Timeout: number?): T
    AwaitComponentInitParams(Object, ComponentClass, Timeout)

    local CorrectedTimeout = Timeout or _GetOption(ComponentClass, "InitialTimeout")
    local ComponentName = _GetComponentClassName(ComponentClass)

    local function AwaitComponentInitial(DeductTime)
        local RemainingTimeout = CorrectedTimeout - DeductTime
        local Component = _GetComponent(Object, ComponentClass)

        local InitialThread = _ComponentsToInitialThread[Component]
        local Metadata = AsyncGetMetadata(InitialThread)

        -- Possibility that Initial has not finished yet. Await will also return if it's already finished.
        AsyncAwait(InitialThread, math.max(0, RemainingTimeout))
        Component = _GetComponent(Object, ComponentClass)

        -- 1.1. Component was removed while Initial was running.
        if (not Component) then
            error(`Component '{ComponentName}' was removed while initializing`)
        end

        local Result = Metadata.Result

        -- 1.2. Initial timed out.
        if (Result == "TIMEOUT") then
            error(`Component '{ComponentName}' timed out while initializing`)
        end

        local Success = Metadata.Success

        -- 1.3. Wait call timed out before component was initialized.
        if (Success == nil) then
            error(`Component '{ComponentName}' wait call timed out ({RemainingTimeout}s)`)
        end

        -- 1.4. Initial explicitly threw an error after wait call.
        if (not Success) then
            error(`Component '{ComponentName}' threw an error while initializing`)
        end

        -- 1.5. Initial succeeded.
        return Component
    end

    -- 1. Component is present on Instance.
    -- > Wait for component Initial if it has not finished yet.
    if (_GetComponent(Object, ComponentClass)) then
        return AwaitComponentInitial(0)
    end

    -- 2. Component is not present on Instance.
    -- > Wait for component to be added to Instance.
    local Proxy = CreateXSignal() :: XSignal<boolean>
    local AddedSignal = _GetAddedSignal(ComponentClass)
    local Connection; Connection = AddedSignal:Connect(function(Target)
        if (Target == Object) then
            Connection:Disconnect()
            Proxy:Fire(true)
        end
    end)

    local BeginTime = os.clock()
    local Success = Proxy:Wait(Timeout)

    if (not Success) then
        error(`A component type '{ComponentName}' was not added to Instance '{Object:GetFullName()}' on time ({CorrectedTimeout}s)`)
    end

    -- > Wait for component Initial if it has not finished yet. Duration of added wait to carry over to Initial wait timeout.
    return AwaitComponentInitial(os.clock() - BeginTime)
end

local GetComponentFromDescendantParams = TG.Params(TG.Instance(), ValidComponentClass)
--- Obtains a component instance from an Instance or any of its ascendants.
function Rosyn.GetComponentFromDescendant<T>(Object: Instance, ComponentClass: T): T?
    GetComponentFromDescendantParams(Object, ComponentClass)

    while (Object) do
        local Component = _GetComponent(Object, ComponentClass)

        if (Component) then
            return Component
        end

        Object = Object.Parent :: Instance
    end

    return nil
end

local EMPTY_UNWRITABLE = table.freeze({})

local GetInstancesOfClassParams = TG.Params(ValidComponentClass)
--- Obtains Map of all Instances for which there exists a given component class on.
function Rosyn.GetInstancesOfClass(ComponentClass: ValidComponentClass): {[Instance]: true}
    GetInstancesOfClassParams(ComponentClass)
    return _ComponentClassToInstances[ComponentClass] or EMPTY_UNWRITABLE
end

local GetComponentsOfClassParams = TG.Params(ValidComponentClass)
--- Obtains Map of all components of a particular class.
function Rosyn.GetComponentsOfClass<T>(ComponentClass: T): {[T]: true}
    GetComponentsOfClassParams(ComponentClass)
    return _ComponentClassToComponents[ComponentClass] or EMPTY_UNWRITABLE
end

local GetComponentsFromInstanceParams = TG.Params(TG.Instance())
--- Obtains all components of any class which are associated to a specific Instance.
function Rosyn.GetComponentsFromInstance(Object: Instance): {[any]: ValidComponentClass}
    GetComponentsFromInstanceParams(Object)
    return _InstanceToComponents[Object] or EMPTY_UNWRITABLE
end

--- Determines whether to microprofile Initial calls.
function Rosyn.SetInitialTagsEnabled(Value: boolean)
    _InitialTags = Value
end

--- Determines whether to microprofile constructor calls.
function Rosyn.SetConstructorTagsEnabled(Value: boolean)
    _ConstructorTags = Value
end

--- Determines whether to microprofile destructor calls.
function Rosyn.SetDestructorTagsEnabled(Value: boolean)
    _DestructorTags = Value
end

Rosyn.GetComponentClassName = _GetComponentClassName

return Rosyn