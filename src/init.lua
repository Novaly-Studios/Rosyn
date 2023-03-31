--!nonstrict
-- Allows easy command bar paste
if (not script) then
	script = game:GetService("ReplicatedFirst").Rosyn
end

local TypeGuard = require(script.Parent:WaitForChild("TypeGuard"))
local Cleaner = require(script.Parent:WaitForChild("Cleaner"))
local XSignal = require(script.Parent:WaitForChild("XSignal"))
local Async = require(script.Parent:WaitForChild("Async"))

type XSignal<T...> = XSignal.XSignal<T...>

type RosynOptions = {
    WrapUsingCleaner: boolean?;
    InitialTimeout: number?;
    ProfileCycle: boolean?;
    UseCleaner: boolean?;
    CycleTime: number?;
}

export type ValidComponentClassOrInstance = {
    ValidateStructure: ((ValidComponentClassOrInstance) -> ())?;
    Options: RosynOptions?;
    Type: string?;

    Initial: ((ValidComponentClassOrInstance) -> ());
    Destroy: ((ValidComponentClassOrInstance) -> ());
    Cycle: ((ValidComponentClassOrInstance, number, number) -> ())?;
    new: ((...any) -> any);
}

type RegisterData = {
    Components: {ValidComponentClassOrInstance};
    Collect: ((((Instance) -> ()), ((Instance) -> ())) -> ());
    Filter: ((Instance) -> boolean)?;
};

local DefaultComponentOptions = {
    WrapUsingCleaner = true;
    InitialTimeout = 60;
    ProfileCycle = true;
    UseCleaner = true;
    CycleTime = 0;
}

local ValidRosynOptions = TypeGuard.Object({
    WrapUsingCleaner = TypeGuard.Boolean():Optional();
    InitialTimeout = TypeGuard.Number():Optional();
    ProfileCycle = TypeGuard.Boolean():Optional();
    UseCleaner = TypeGuard.Boolean():Optional();
    CycleTime = TypeGuard.Number():Optional();
}):Strict()

local ValidComponentClass = TypeGuard.Object({
    ValidateStructure = TypeGuard.Object():Optional();
    Options = ValidRosynOptions:Optional();
    Type = TypeGuard.String():Optional();
    
    Initial = TypeGuard.Function();
    Destroy = TypeGuard.Function();
    Cycle = TypeGuard.Function():Optional();
    new = TypeGuard.Function();
}):CheckMetatable(TypeGuard.Nil()):Cached()

local ValidComponentInstance = TypeGuard.Object():CheckMetatable(ValidComponentClass)
local ValidComponentClassOrInstance = ValidComponentClass:Or(ValidComponentInstance)

local ValidGameObject = TypeGuard.Instance()

local DESTROY_SUFFIX = ":Destroy()"
local MEMORY_TAG_SUFFIX = ":Initial()"
local DIAGNOSIS_TAG_PREFIX = "Component."

local TIMEOUT_WARN = 10
local DEFAULT_TIMEOUT = 60

local VALIDATE_PARAMS = true
local WRAP_INITIAL_MEM_TAGS = true

-- Associations between Instances, component classes, and component instances, to ensure immediate lookup
local _InstanceToComponents = {}
local _ComponentsToInitialThread = {} :: {[ValidComponentClassOrInstance]: thread}
local _ComponentClassToInstances = {}
local _ComponentClassToComponents = {}

-- Events related to component classes
local _ComponentClassAddedEvents = {}
local _ComponentClassRemovingEvents = {}

-- local _ComponentClassToCycleThread = {}

local _ComponentClassInitializationFailed = XSignal.new()

local function ReadOnlyProxy(Object)
    local Result; Result = setmetatable({}, {
        __iter = function()
            return next, Object or Result
        end;
        __index = Object;
    })
    table.freeze(Result)
    return Result
end

local Collect = script:WaitForChild("Collect")

--[[
    Components are composed over Instances and any Instance
    can have multiple components. Multiple components of
    the same type cannot exist concurrently on an Instance.
    @classmod Rosyn

    @todo Detect circular dependencies on AwaitComponentInit
]]
local Rosyn = {
    ComponentClassInitializationFailed = _ComponentClassInitializationFailed;

    Collectors = {
        Descendants = require(Collect:WaitForChild("Descendants"));
        Children = require(Collect:WaitForChild("Children"));
        Tags = require(Collect:WaitForChild("Tags"));
    };

    -- Helps debugging
    _InstanceToComponents = _InstanceToComponents;
    _ComponentsToInitialThread = _ComponentsToInitialThread;
    _ComponentClassToInstances = _ComponentClassToInstances;
    _ComponentClassToComponents = _ComponentClassToComponents;

    _ComponentClassAddedEvents = _ComponentClassAddedEvents;
    _ComponentClassRemovingEvents = _ComponentClassRemovingEvents;
};

function Rosyn._Invariant()
    -- TODO
end

local GetComponentNameParams = TypeGuard.Params(ValidComponentClassOrInstance)
--[[
    Attempts to get a unique ID from the component class or instance passed. A Type field in all component classes is the recommended approach.
    @param Component The component instance or class to obtain the name from.
]]
function Rosyn.GetComponentName(ComponentClassOrInstance: ValidComponentClassOrInstance): string
    if (VALIDATE_PARAMS) then
        GetComponentNameParams(ComponentClassOrInstance)
    end

    return ComponentClassOrInstance.Type or tostring(ComponentClassOrInstance)
end

function Rosyn._GetOption(ComponentClass: ValidComponentClassOrInstance, Key: string): any?
    local CustomOptions = ComponentClass.Options

    if (CustomOptions) then
        local Target = CustomOptions[Key]

        if (Target) then
            return Target
        end
    end

    return DefaultComponentOptions[Key]
end

local RegisterParams = TypeGuard.Params(TypeGuard.Object({
    Filter = TypeGuard.Function():Optional();
    Collect = TypeGuard.Function();
    Components = TypeGuard.Array(ValidComponentClassOrInstance);
}))

function Rosyn.Register(Data: RegisterData)
    if (VALIDATE_PARAMS) then
        RegisterParams(Data)
    end

    local Components = Data.Components

    -- We can wrap methods in memory tags to help diagnose memory leaks
    if (WRAP_INITIAL_MEM_TAGS) then
        for _, Component in Components do
            local MemoryTag = Rosyn.GetComponentName(Component) .. MEMORY_TAG_SUFFIX
            local OldInitial = Component.Initial

            Component.Initial = function(self)
                debug.setmemorycategory(MemoryTag)
                OldInitial(self)
                debug.resetmemorycategory()
            end
        end
    end

    -- Wrap class using Cleaner for memory safety unless user specifies not to
    -- Verify classes have Destroy methods
    for _, Component in Components do
        if (Component.Destroy == nil) then
            warn(`No Destroy method found on component {Rosyn.GetComponentName(Component)}.`)
        end

        if (Rosyn._GetOption(Component, "WrapUsingCleaner") and not Cleaner.IsWrapped(Component)) then
            Cleaner.Wrap(Component)
        end
    end

    local Filter = Data.Filter or function()
        return true
    end

    local function HandleCreation(Item: Instance)
        if (not Filter(Item)) then
            return
        end

        for _, ComponentClass in Components do
            if (Rosyn.GetComponent(Item, ComponentClass)) then
                continue
            end

            Rosyn._AddComponent(Item, ComponentClass)
        end
    end

    local function HandleDestruction(Item: Instance)
        for _, ComponentClass in Components do
            if (not Rosyn.GetComponent(Item, ComponentClass)) then
                continue
            end

            Rosyn._RemoveComponent(Item, ComponentClass)
        end
    end

    Data.Collect(HandleCreation, HandleDestruction)
end

local GetComponentParams = TypeGuard.Params(ValidGameObject, ValidComponentClass)
--[[
    Attempts to obtain a specific component from an Instance given a component class.
    @param Object The Instance to check for the passed ComponentClass
    @param ComponentClass The uninitialized ComponentClass to check for
    @return ComponentInstance or nil
]]
function Rosyn.GetComponent<T>(Object: Instance, ComponentClass: T & ValidComponentClassOrInstance): T?
    if (VALIDATE_PARAMS) then
        GetComponentParams(Object, ComponentClass)
    end

    local ComponentsForObject = _InstanceToComponents[Object]
    return ComponentsForObject and ComponentsForObject[ComponentClass] or nil
end

local ExpectComponentParams = TypeGuard.Params(ValidGameObject, ValidComponentClass)
--- Asserts that a component exists on a given Instance.
function Rosyn.ExpectComponent<T>(Object: Instance, ComponentClass: T & ValidComponentClassOrInstance): T
    if (VALIDATE_PARAMS) then
        ExpectComponentParams(Object, ComponentClass)
    end

    local Component = Rosyn.GetComponent(Object, ComponentClass)

    if (Component == nil) then
        error(`Expected component '{Rosyn.GetComponentName(ComponentClass)}' to exist on Instance '{Object:GetFullName()}'.`)
    end

    return Component
end

local ExpectComponentInitParams = TypeGuard.Params(ValidGameObject, ValidComponentClass)
--- Asserts that a component exists on a given Instance and that it has been initialized.
function Rosyn.ExpectComponentInit<T>(Object: Instance, ComponentClass: T & ValidComponentClassOrInstance): T
    if (VALIDATE_PARAMS) then
        ExpectComponentInitParams(Object, ComponentClass)
    end

    local Component = Rosyn.ExpectComponent(Object, ComponentClass)
    local Metadata = Async.GetMetadata(_ComponentsToInitialThread[Component])

    if (Metadata == nil or Metadata.Success == nil) then
        error(`Expected component '{Rosyn.GetComponentName(ComponentClass)}' to be initialized on Instance '{Object:GetFullName()}'.`)
    end

    return Component
end

local AwaitComponentInitParams = TypeGuard.Params(ValidGameObject, ValidComponentClass, TypeGuard.Number():Optional())
--[[
    Waits for a component instance's asynchronous Initial method to complete and returns it.
]]
function Rosyn.AwaitComponentInit<T>(Object: Instance, ComponentClass: T & ValidComponentClassOrInstance, Timeout: number?): T
    if (VALIDATE_PARAMS) then
        AwaitComponentInitParams(Object, ComponentClass, Timeout)
    end

    local CorrectedTimeout = Timeout or DEFAULT_TIMEOUT
    local ComponentName = Rosyn.GetComponentName(ComponentClass)
    local WarningThread = task.delay(TIMEOUT_WARN, warn, `Component '{ComponentName}' is taking a long time to initialize.`)

    local function AwaitComponentInitial(DeductTime)
        local RemainingTimeout = CorrectedTimeout - DeductTime
        local Component = Rosyn.GetComponent(Object, ComponentClass)

        local InitialThread = _ComponentsToInitialThread[Component]
        local Metadata = Async.GetMetadata(InitialThread)

        -- Possibility that Initial has not finished yet. Await will also return if it's already finished.
        Async.Await(InitialThread, math.max(0, RemainingTimeout))
        task.cancel(WarningThread)
        Component = Rosyn.GetComponent(Object, ComponentClass)

        -- 1.1. Component was removed while Initial was running.
        if (not Component) then
            error(`Component '{ComponentName}' was removed while initializing.`)
        end

        local Result = Metadata.Result

        -- 1.2. Initial timed out.
        if (Result == "TIMEOUT") then
            error(`Component '{ComponentName}' timed out while initializing.`)
        end

        local Success = Metadata.Success

        -- 1.3. Wait call timed out before component was initialized.
        if (Success == nil) then
            error(`Component '{ComponentName}' wait call timed out ({RemainingTimeout}s).`)
        end

        -- 1.4. Initial explicitly threw an error after wait call.
        if (not Success) then
            error(`Component '{ComponentName}' threw an error while initializing.`)
        end

        -- 1.5. Initial succeeded.
        return Component
    end

    -- 1. Component is present on Instance.
    -- > Wait for component Initial if it has not finished yet.
    if (Rosyn.GetComponent(Object, ComponentClass)) then
        return AwaitComponentInitial(0)
    end

    -- 2. Component is not present on Instance.
    -- > Wait for component to be added to Instance.
    local Proxy = XSignal.new() :: XSignal<boolean>
    local AddedSignal = Rosyn.GetAddedSignal(ComponentClass)
    local Connection; Connection = AddedSignal:Connect(function(Target)
        if (Target == Object) then
            Connection:Disconnect()
            Proxy:Fire(true)
        end
    end)

    local BeginTime = os.clock()
    local Success = Proxy:Wait(Timeout)

    if (not Success) then
        task.cancel(WarningThread)
        error(`A component type '{ComponentName}' was not added to Instance '{Object:GetFullName()}' on time ({CorrectedTimeout}s).`)
    end

    -- > Wait for component Initial if it has not finished yet. Duration of added wait to carry over to Initial wait timeout.
    return AwaitComponentInitial(os.clock() - BeginTime)
end

local GetComponentFromDescendantParams = TypeGuard.Params(ValidGameObject, ValidComponentClass)
--[[
    Obtains a component instance from an Instance or any of its ascendants.
]]
function Rosyn.GetComponentFromDescendant<T>(Object: Instance, ComponentClass: T & ValidComponentClassOrInstance): T?
    if (VALIDATE_PARAMS) then
        GetComponentFromDescendantParams(Object, ComponentClass)
    end

    while (Object.Parent) do
        local Component = Rosyn.GetComponent(Object, ComponentClass)

        if (Component) then
            return Component
        end

        Object = Object.Parent
    end

    return nil
end

local GetInstancesOfClassParams = TypeGuard.Params(ValidComponentClass)
--[[
    Obtains Map of all Instances for which there exists a given component class on.
    @todo Think of an efficient way to prevent external writes to the returned table.
]]
function Rosyn.GetInstancesOfClass(ComponentClass): {[Instance]: true}
    if (VALIDATE_PARAMS) then
        GetInstancesOfClassParams(ComponentClass)
    end

    return ReadOnlyProxy(_ComponentClassToInstances[ComponentClass])
end

local GetComponentsOfClassParams = TypeGuard.Params(ValidComponentClass)
--[[
    Obtains Map of all components of a particular class.
    @todo Think of an efficient way to prevent external writes to the returned table.
]]
function Rosyn.GetComponentsOfClass<T>(ComponentClass: T): {[T]: true}
    if (VALIDATE_PARAMS) then
        GetComponentsOfClassParams(ComponentClass)
    end

    return ReadOnlyProxy(_ComponentClassToComponents[ComponentClass])
end

local GetComponentsFromInstance = TypeGuard.Params(ValidGameObject)
--[[
    Obtains all components of any class which are associated to a specific Instance.
    @todo Think of an efficient way to prevent external writes to the returned table.
]]
function Rosyn.GetComponentsFromInstance(Object: Instance): {[any]: ValidComponentClassOrInstance}
    if (VALIDATE_PARAMS) then
        GetComponentsFromInstance(Object)
    end

    return ReadOnlyProxy(_InstanceToComponents[Object])
end

------------------------------------------- Internal -------------------------------------------

local AddComponentParams = TypeGuard.Params(ValidGameObject, ValidComponentClass)
--[[
    Creates and wraps a component around an Instance, given a component class.
    @usage Private Method
]]
function Rosyn._AddComponent(Object: Instance, ComponentClass: ValidComponentClassOrInstance)
    if (VALIDATE_PARAMS) then
        AddComponentParams(Object, ComponentClass)
    end

    local ComponentName = Rosyn.GetComponentName(ComponentClass)
    local DiagnosisTag = DIAGNOSIS_TAG_PREFIX .. ComponentName

    if (Rosyn.GetComponent(Object, ComponentClass)) then
        error(`Component {ComponentName} already present on {Object:GetFullName()}.`)
    end

    local ValidateStructure = ComponentClass.ValidateStructure

    if (ValidateStructure) then
        ValidateStructure(Object)
    end

    debug.profilebegin(DiagnosisTag)
        ---------------------------------------------------------------------------------------------------------
        local NewComponent

        task.spawn(function()
            NewComponent = ComponentClass.new(Object)
        end)

        if (not NewComponent) then
            error(`Component constructor {ComponentName} yielded or threw an error on {Object:GetFullName()}.`)
        end

        -- _InstanceToComponents = {Instance = {ComponentClass1 = ComponentInstance1, ComponentClass2 = ComponentInstance2, ...}, ...}
        local ExistingComponentsForInstance = _InstanceToComponents[Object]

        if (not ExistingComponentsForInstance) then
            ExistingComponentsForInstance = {}
            _InstanceToComponents[Object] = ExistingComponentsForInstance
        end

        ExistingComponentsForInstance[ComponentClass] = NewComponent

        -- _ComponentClassToInstances = {ComponentClass = {Instance1 = true, Instance2 = true, ...}, ...}
        local ExistingInstancesForComponentClass = _ComponentClassToInstances[ComponentClass]

        if (not ExistingInstancesForComponentClass) then
            ExistingInstancesForComponentClass = {}
            _ComponentClassToInstances[ComponentClass] = ExistingInstancesForComponentClass
        end

        ExistingInstancesForComponentClass[Object] = true

        -- _ComponentClassToComponents = {ComponentClass = {ComponentInstance1 = true, ComponentInstance2 = true, ...}, ...}
        local ExistingComponentsForComponentClass = _ComponentClassToComponents[ComponentClass]

        if (not ExistingComponentsForComponentClass) then
            ExistingComponentsForComponentClass = {}
            _ComponentClassToComponents[ComponentClass] = ExistingComponentsForComponentClass
        end

        ExistingComponentsForComponentClass[NewComponent] = true
        ---------------------------------------------------------------------------------------------------------
    debug.profileend()

    _ComponentsToInitialThread[NewComponent] = Async.SpawnTimeLimit(Rosyn._GetOption(ComponentClass, "InitialTimeout") :: number, function(OnFinish)
        OnFinish(function(Success, Result)
            if (Success) then
                return
            end

            _ComponentClassInitializationFailed:Fire(ComponentName, Object, Result, "")

            if (Result == "TIMEOUT") then
                task.spawn(error, `Component {ComponentName} failed to initialize on {Object:GetFullName()} within {Rosyn._GetOption(ComponentClass, "InitialTimeout")} seconds.`)
            end
        end)

        local Success, Result = pcall(NewComponent.Initial, NewComponent)

        if (not Success) then
            task.spawn(error, `Component {ComponentName} failed to initialize on {Object:GetFullName()} with error: {Result}`)
            return false, Result
        end
    end)

    -- TODO: CycleFilter to force pre-filtered components instead of (_ComponentClassToComponents[ComponentClass] or {})
    -- Cycles are timers on each component of a given class, executed synchronously for performance
    --[[ if (ComponentClass.Cycle and not _ComponentClassToCycleThread[ComponentClass]) then -- Untested, disabled
        local ProfileCycle = Rosyn._GetOption(ComponentClass, "ProfileCycle")
        local WaitTime = Rosyn._GetOption(ComponentClass, "CycleTime")

        _ComponentClassToCycleThread[ComponentClass] = task.defer(function()
            local LastTime = {}
            local Empty = {}

            local RemovingSignal = Rosyn.GetRemovingSignal(ComponentClass)

            RemovingSignal:Connect(function(Root)
                LastTime[Rosyn.ExpectComponent(Root, ComponentClass)] = nil
            end)

            -- Create starting times for each existing component
            for Component in (_ComponentClassToComponents[ComponentClass] or Empty) do
                LastTime[Component] = os.clock()
            end

            while (true) do
                local Count = 0

                if (ProfileCycle) then
                    debug.profilebegin(ComponentName .. ".Cycle")
                end

                for Component in (_ComponentClassToComponents[ComponentClass] or Empty) do
                    if (table.isfrozen(Component)) then
                        continue
                    end

                    Count += 1

                    local CurrentTime = os.clock()
                    Component:Cycle(CurrentTime - (LastTime[Component] or CurrentTime), Count)
                    LastTime[Component] = CurrentTime -- Cycle can yield e.g. for dividing a large operation over multiple frames
                end

                if (ProfileCycle) then
                    debug.profileend()
                end

                task.wait(WaitTime)
            end
        end)
    end ]]

    local AddedSignal = Rosyn.GetAddedSignal(ComponentClass)
    AddedSignal:Fire(Object)
end

local RemoveComponentParams = TypeGuard.Params(ValidGameObject, ValidComponentClass)
--[[
    Removes a component from an Instance, given a component class. Calls Destroy on component.
    @usage Private Method
]]
function Rosyn._RemoveComponent(Object: Instance, ComponentClass: ValidComponentClassOrInstance)
    if (VALIDATE_PARAMS) then
        RemoveComponentParams(Object, ComponentClass)
    end

    local ComponentName = Rosyn.GetComponentName(ComponentClass)
    local DiagnosisTag = DIAGNOSIS_TAG_PREFIX .. ComponentName
    local ExistingComponent = Rosyn.GetComponent(Object, ComponentClass)

    if (not ExistingComponent) then
        error(`Component {ComponentName} not present on {Object:GetFullName()}.`)
    end

    local RemovingSignal = Rosyn.GetRemovingSignal(ComponentClass)
    RemovingSignal:Fire(Object)

    debug.profilebegin(DiagnosisTag)
        ---------------------------------------------------------------------------------------------------------
        -- _InstanceToComponents = {Instance = {ComponentClass1 = ComponentInstance1, ComponentClass2 = ComponentInstance2, ...}, ...}
        local ExistingComponentsForInstance = _InstanceToComponents[Object]

        if (not ExistingComponentsForInstance) then
            ExistingComponentsForInstance = {}
            _InstanceToComponents[Object] = ExistingComponentsForInstance
        end

        ExistingComponentsForInstance[ComponentClass] = nil

        if (next(ExistingComponentsForInstance) == nil) then
            _InstanceToComponents[Object] = nil
        end

        -- _ComponentClassToInstances = {ComponentClass = {Instance1 = true, Instance2 = true, ...}, ...}
        local ExistingInstancesForComponentClass = _ComponentClassToInstances[ComponentClass]
        ExistingInstancesForComponentClass[Object] = nil

        if (next(ExistingInstancesForComponentClass) == nil) then
            _ComponentClassToInstances[ComponentClass] = nil
        end

        -- _ComponentClassToComponents = {ComponentClass = {ComponentInstance1 = true, ComponentInstance2 = true, ...}, ...}
        local ExistingComponentsForComponentClass = _ComponentClassToComponents[ComponentClass]
        ExistingComponentsForComponentClass[ExistingComponent] = nil

        if (next(ExistingComponentsForComponentClass) == nil) then
            _ComponentClassToComponents[ComponentClass] = nil
        end
        ---------------------------------------------------------------------------------------------------------
    debug.profileend()

    -- Wait for Intial to finish if it hasn't already - this way Destroy is guaranteed to be called after Initial.
    -- Initial is guaranteed to timeout using the Async library, so this is safe.
    local InitialThread = _ComponentsToInitialThread[ExistingComponent]
    Async.Await(InitialThread)

    -- Destroy component to let it clean stuff up
    debug.profilebegin(DiagnosisTag .. DESTROY_SUFFIX)
    _ComponentsToInitialThread[ExistingComponent] = nil

    if (coroutine.status(task.spawn(ExistingComponent.Destroy, ExistingComponent)) ~= "dead") then
        error(`Component destructor {ComponentName} yielded or threw an error on {Object:GetFullName()}.`)
    end

    Async.Cancel(InitialThread, "ROSYN_DESTROY") -- This will terminate all descendant threads spawned in Initial, on component removal / destruction
    debug.profileend()
end

local GetAddedSignalParams = TypeGuard.Params(ValidComponentClass)
--[[
    Obtains or creates a Signal which will fire when a component has been instantiated.
    @todo Refactor these 3 since they have a lot of repeated code
]]
function Rosyn.GetAddedSignal(ComponentClass): XSignal<Instance>
    if (VALIDATE_PARAMS) then
        GetAddedSignalParams(ComponentClass)
    end

    local AddedEvent = _ComponentClassAddedEvents[ComponentClass]

    if (AddedEvent) then
        return AddedEvent
    end

    AddedEvent = XSignal.new()
    _ComponentClassAddedEvents[ComponentClass] = AddedEvent
    return AddedEvent
end

local GetRemovingSignalParams = TypeGuard.Params(ValidComponentClass)
--[[
    Obtains or creates a Signal which will fire when a component is about to be destroyed.
]]
function Rosyn.GetRemovingSignal(ComponentClass): XSignal<Instance>
    if (VALIDATE_PARAMS) then
        GetRemovingSignalParams(ComponentClass)
    end

    local RemovingEvent = _ComponentClassRemovingEvents[ComponentClass]

    if (RemovingEvent) then
        return RemovingEvent
    end

    RemovingEvent = XSignal.new()
    _ComponentClassRemovingEvents[ComponentClass] = RemovingEvent
    return RemovingEvent
end

return Rosyn