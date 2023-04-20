-- Allows easy command bar paste.
if (not script) then
	script = game:GetService("ReplicatedFirst").Rosyn
end

local TableUtil = require(script.Parent:WaitForChild("TableUtil"))
    local MutableLockdown1D = TableUtil.Map.MutableLockdown1D
local XSignal = require(script.Parent:WaitForChild("XSignal"))
    type XSignal<T...> = XSignal.XSignal<T...>
local Async = require(script.Parent:WaitForChild("Async"))
local TG = require(script.Parent:WaitForChild("TypeGuard"))

type RosynOptions = {
    InitialTimeout: number?;
    WrapDestroy: boolean?;
    WrapInitial: boolean?;
}
local RosynOptions = TG.Object({
    InitialTimeout = TG.Number():Optional();
    WrapDestroy = TG.Boolean():Optional();
    WrapInitial = TG.Boolean():Optional();
}):Strict()

type ValidComponentClass = {
    ValidateStructure: ((ValidComponentClass) -> ())?;
    Options: RosynOptions?;
    Type: string?;

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

    Initial = TG.Function():Optional();
    Destroy = TG.Function():Optional();
    new = TG.Function();
}):CheckMetatable(TG.Nil()):Cached()

type RegisterData = {
    Components: ((((Instance, ValidComponentClass) -> ()), ((Instance, ValidComponentClass) -> ())) -> ());
    Filter: ((Instance) -> boolean)?;
}

local DefaultComponentOptions = {
    InitialTimeout = 60;
    WrapDestroy = true;
    WrapInitial = true;
}

local DIAGNOSIS_TAG_PREFIX = "Component."
local MEMORY_TAG_SUFFIX = ":Initial()"
local DESTROY_SUFFIX = ":Destroy()"

local DEFAULT_TIMEOUT = 60
local TIMEOUT_WARN = 10

local VALIDATE_PARAMS = true

-- Associations between Instances, component classes, and component instances, to ensure immediate lookup.
local _ComponentClassToComponents = {}
local _ComponentClassToInstances = {}
local _ComponentsToInitialThread = {} :: {[ValidComponentClass]: thread}
local _InstanceToComponents = {}

-- Events related to component classes.
local _ComponentClassRemovingEvents = {}
local _ComponentClassAddedEvents = {}

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

local Setup = script:WaitForChild("Setup")

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

function Rosyn._Invariant()
    -- TODO
end

--- Attempts to get a unique ID from the component class passed. A Type field in all component classes is the recommended approach.
function Rosyn._GetComponentClassName(ComponentClass: ValidComponentClass): string
    return ComponentClass.Type or tostring(ComponentClass)
end

--- Obtains a user-defined or default setting for a component class.
function Rosyn._GetOption(ComponentClass: ValidComponentClass, Key: string): any?
    local CustomOptions = ComponentClass.Options

    if (CustomOptions) then
        local Target = CustomOptions[Key]

        if (Target) then
            return Target
        end
    end

    return DefaultComponentOptions[Key]
end

local RegisterParams = TG.Params(TG.Object({
    Filter = TG.Function():Optional();
    Components = TG.Function();
}))

function Rosyn.Register(Data: RegisterData)
    if (VALIDATE_PARAMS) then
        RegisterParams(Data)
    end

    local Filter = Data.Filter or function()
        return true
    end

    local function HandleCreation(Item: Instance, ComponentClass: ValidComponentClass)
        if (not Filter(Item, ComponentClass)) then
            return
        end

        if (Rosyn.GetComponent(Item, ComponentClass)) then
            return
        end

        -- Wrap destroy option -> completely lock object after its lifecycle finishes, useful for highlighting where users should not be using references to the component.
        if (Rosyn._GetOption(ComponentClass, "WrapDestroy") and not ComponentClass._DESTROY_WRAPPED) then
            local Original = ComponentClass.Destroy

            ComponentClass.Destroy = function(self, ...)
                Original(self, ...)
                MutableLockdown1D(self)
            end

            ComponentClass._DESTROY_WRAPPED = true
        end

        -- Wrap intiial option -> set memory tags, useful for detecting users forgetting to disconnect signals and such.
        if (Rosyn._GetOption(ComponentClass, "WrapInitial") and not ComponentClass._INITIAL_WRAPPED) then
            local MemoryTag = Rosyn._GetComponentClassName(ComponentClass) .. MEMORY_TAG_SUFFIX
            local OldInitial = ComponentClass.Initial

            ComponentClass.Initial = function(self)
                debug.setmemorycategory(MemoryTag)
                OldInitial(self)
                debug.resetmemorycategory()
            end

            ComponentClass._INITIAL_WRAPPED = true
        end

        Rosyn._AddComponent(Item, ComponentClass)
    end

    local function HandleDestruction(Item: Instance, ComponentClass: ValidComponentClass)
        if (not Rosyn.GetComponent(Item, ComponentClass)) then
            return
        end

        Rosyn._RemoveComponent(Item, ComponentClass)
    end

    Data.Components(HandleCreation, HandleDestruction)
end

local GetComponentParams = TG.Params(TG.Instance(), ValidComponentClass)
--- Attempts to obtain a specific component from an Instance given a component class.
function Rosyn.GetComponent<T>(Object: Instance, ComponentClass: T & ValidComponentClass): T?
    if (VALIDATE_PARAMS) then
        GetComponentParams(Object, ComponentClass)
    end

    local ComponentsForObject = _InstanceToComponents[Object]
    return ComponentsForObject and ComponentsForObject[ComponentClass] or nil
end

local ExpectComponentParams = TG.Params(TG.Instance(), ValidComponentClass)
--- Asserts that a component exists on a given Instance.
function Rosyn.ExpectComponent<T>(Object: Instance, ComponentClass: T & ValidComponentClass): T
    if (VALIDATE_PARAMS) then
        ExpectComponentParams(Object, ComponentClass)
    end

    local Component = Rosyn.GetComponent(Object, ComponentClass)

    if (Component == nil) then
        error(`Expected component '{Rosyn._GetComponentClassName(ComponentClass)}' to exist on Instance '{Object:GetFullName()}'`)
    end

    return Component
end

local ExpectComponentInitParams = TG.Params(TG.Instance(), ValidComponentClass)
--- Asserts that a component exists on a given Instance and that it has been initialized.
function Rosyn.ExpectComponentInit<T>(Object: Instance, ComponentClass: T & ValidComponentClass): T
    if (VALIDATE_PARAMS) then
        ExpectComponentInitParams(Object, ComponentClass)
    end

    local Component = Rosyn.ExpectComponent(Object, ComponentClass)
    local Metadata = Async.GetMetadata(_ComponentsToInitialThread[Component])

    if (Metadata == nil or Metadata.Success == nil) then
        error(`Expected component '{Rosyn._GetComponentClassName(ComponentClass)}' to be initialized on Instance '{Object:GetFullName()}'`)
    end

    return Component
end

local AwaitComponentInitParams = TG.Params(TG.Instance(), ValidComponentClass, TG.Number():Optional())
--- Waits for a component instance's asynchronous Initial method to complete and returns it.
function Rosyn.AwaitComponentInit<T>(Object: Instance, ComponentClass: T & ValidComponentClass, Timeout: number?): T
    if (VALIDATE_PARAMS) then
        AwaitComponentInitParams(Object, ComponentClass, Timeout)
    end

    local CorrectedTimeout = Timeout or DEFAULT_TIMEOUT
    local ComponentName = Rosyn._GetComponentClassName(ComponentClass)
    local WarningThread = task.delay(TIMEOUT_WARN, warn, `Component '{ComponentName}' is taking a long time to initialize`)

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
        error(`A component type '{ComponentName}' was not added to Instance '{Object:GetFullName()}' on time ({CorrectedTimeout}s)`)
    end

    -- > Wait for component Initial if it has not finished yet. Duration of added wait to carry over to Initial wait timeout.
    return AwaitComponentInitial(os.clock() - BeginTime)
end

local GetComponentFromDescendantParams = TG.Params(TG.Instance(), ValidComponentClass)
--- Obtains a component instance from an Instance or any of its ascendants.
function Rosyn.GetComponentFromDescendant<T>(Object: Instance, ComponentClass: T & ValidComponentClass): T?
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

local GetInstancesOfClassParams = TG.Params(ValidComponentClass)
--- Obtains Map of all Instances for which there exists a given component class on.
function Rosyn.GetInstancesOfClass(ComponentClass): {[Instance]: true}
    if (VALIDATE_PARAMS) then
        GetInstancesOfClassParams(ComponentClass)
    end

    return ReadOnlyProxy(_ComponentClassToInstances[ComponentClass])
end

local GetComponentsOfClassParams = TG.Params(ValidComponentClass)
--- Obtains Map of all components of a particular class.
function Rosyn.GetComponentsOfClass<T>(ComponentClass: T): {[T]: true}
    if (VALIDATE_PARAMS) then
        GetComponentsOfClassParams(ComponentClass)
    end

    return ReadOnlyProxy(_ComponentClassToComponents[ComponentClass])
end

local GetComponentsFromInstance = TG.Params(TG.Instance())
--- Obtains all components of any class which are associated to a specific Instance.
function Rosyn.GetComponentsFromInstance(Object: Instance): {[any]: ValidComponentClass}
    if (VALIDATE_PARAMS) then
        GetComponentsFromInstance(Object)
    end

    return ReadOnlyProxy(_InstanceToComponents[Object])
end

------------------------------------------- Internal -------------------------------------------

local AddComponentParams = TG.Params(TG.Instance(), ValidComponentClass)
--- Creates and wraps a component around an Instance, given a component class.
function Rosyn._AddComponent(Object: Instance, ComponentClass: ValidComponentClass)
    if (VALIDATE_PARAMS) then
        AddComponentParams(Object, ComponentClass)
    end

    local ComponentName = Rosyn._GetComponentClassName(ComponentClass)
    local DiagnosisTag = DIAGNOSIS_TAG_PREFIX .. ComponentName

    if (Rosyn.GetComponent(Object, ComponentClass)) then
        error(`Component {ComponentName} already present on {Object:GetFullName()}`)
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
            error(`Component constructor {ComponentName} yielded or threw an error on {Object:GetFullName()}`)
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

    local Initial = NewComponent.Initial

    if (Initial) then
        _ComponentsToInitialThread[NewComponent] = Async.SpawnTimeLimit(Rosyn._GetOption(ComponentClass, "InitialTimeout") :: number, function()
            Async.OnFinish(function(Success, Result)
                if (Success) then
                    return
                end

                _ComponentClassInitializationFailed:Fire(ComponentName, Object, Result, "")

                if (Result == "TIMEOUT") then
                    task.spawn(error, `Component {ComponentName} failed to initialize on {Object:GetFullName()} within {Rosyn._GetOption(ComponentClass, "InitialTimeout")} seconds`)
                    return
                end

                task.spawn(error, `Component {ComponentName} failed to initialize on {Object:GetFullName()}`)
            end)

            NewComponent:Initial()
        end)
    end

    local AddedSignal = Rosyn.GetAddedSignal(ComponentClass)
    AddedSignal:Fire(Object)
end

local RemoveComponentParams = TG.Params(TG.Instance(), ValidComponentClass)
--- Removes a component from an Instance, given a component class. Calls Destroy on component.
function Rosyn._RemoveComponent(Object: Instance, ComponentClass: ValidComponentClass)
    if (VALIDATE_PARAMS) then
        RemoveComponentParams(Object, ComponentClass)
    end

    local ComponentName = Rosyn._GetComponentClassName(ComponentClass)
    local DiagnosisTag = DIAGNOSIS_TAG_PREFIX .. ComponentName
    local ExistingComponent = Rosyn.GetComponent(Object, ComponentClass)

    if (not ExistingComponent) then
        error(`Component {ComponentName} not present on {Object:GetFullName()}`)
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

    -- Initial thread being nil implies this is just a raw table w/o the standard lifecycle.
    if (InitialThread) then
        Async.Await(InitialThread)

        -- Destroy component to let it clean stuff up.
        debug.profilebegin(DiagnosisTag .. DESTROY_SUFFIX)
            _ComponentsToInitialThread[ExistingComponent] = nil

            if (coroutine.status(task.spawn(ExistingComponent.Destroy, ExistingComponent)) ~= "dead") then
                error(`Component destructor {ComponentName} yielded or threw an error on {Object:GetFullName()}`)
            end

            Async.Cancel(InitialThread, "ROSYN_DESTROY") -- This will terminate all descendant threads spawned in Initial, on component removal / destruction.
        debug.profileend()
    end
end

local GetAddedSignalParams = TG.Params(ValidComponentClass)
--- Obtains or creates a Signal which will fire when a component has been instantiated.
function Rosyn.GetAddedSignal(ComponentClass: ValidComponentClass): XSignal<Instance>
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

local GetRemovingSignalParams = TG.Params(ValidComponentClass)
--- Obtains or creates a Signal which will fire when a component is about to be destroyed.
function Rosyn.GetRemovingSignal(ComponentClass: ValidComponentClass): XSignal<Instance>
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






--[[ local function MakeClass()
    local Class = {}
    Class.__index = Class
    Class.Type = "Class"

    function Class.new(Root)
        return setmetatable({
            Root = Root;
        }, Class)
    end

    function Class:Initial() end
    function Class:Destroy() end

    return Class
end

local function MakeTestInstance(Tags, Parent)
    local Test = Instance.new("Model")

    for _, Tag in Tags do
        game.CollectionService:AddTag(Test, Tag)
    end

    Test.Parent = Parent
    return Test
end

local Test1 = MakeClass()
local Test2 = MakeClass()

Rosyn.Register({
    Components = Rosyn.Setup.Tags({
        XYZ = Test1;
    });
})

Rosyn.Register({
    Components = Rosyn.Setup.Tags({
        XYZ = Test2;
    });
})

local Inst = MakeTestInstance({"XYZ"}, workspace)
print(Rosyn.GetComponent(Inst, Test1))
print(Rosyn.GetComponent(Inst, Test2))
Inst:Destroy() ]]

return Rosyn