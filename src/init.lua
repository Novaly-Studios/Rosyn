local CollectionService = game:GetService("CollectionService")
local TestService = game:GetService("TestService")

local CheckYield = require(script:WaitForChild("CheckYield"))
local TypeGuard = require(script.Parent:WaitForChild("TypeGuard"))
local Cleaner = require(script.Parent:WaitForChild("Cleaner"))
local XSignal = require(script.Parent:WaitForChild("XSignal"))

type XSignal<T> = XSignal.XSignal<T>

local ValidComponentClass = TypeGuard.Object():CheckMetatable(TypeGuard.Nil()):OfStructure({
    Type = TypeGuard.String():Optional();
    Structure = TypeGuard.Object():Optional();

    new = TypeGuard.Function();
    Initial = TypeGuard.Function();
    Destroy = TypeGuard.Function();
})
local ValidComponentInstance = TypeGuard.Object():CheckMetatable(ValidComponentClass)
local ValidComponentClassOrInstance = ValidComponentClass:Or(ValidComponentInstance)

local ValidGameObject = TypeGuard.Instance():IsDescendantOf(game)

local ERR_NO_INITIAL = "Component %s on %s does not contain an 'Initial' method"
local ERR_INIT_FAILED = "Component %s Initial call failed on %s\n%s\n"
local ERR_COMPONENT_NOT_PRESENT = "Component %s not present on %s"
local ERR_COMPONENT_NEW_YIELDED = "Component constructor %s yielded or threw an error on %s"
local ERR_ITEM_ALREADY_DESTROYED = "Already destroyed!"
local ERR_COMPONENT_ALREADY_PRESENT = "Component %s already present on %s"
local ERR_COMPONENT_DESTROY_YIELDED = "Component destructor %s yielded or threw an error on %s"
local WARN_COMPONENT_LIFECYCLE_ALREDY_ENDED = "Component lifecycle ended before Initial call completed - %s on %s"

local WARN_MULTIPLE_REGISTER = "Register attempted to create duplicate component: %s\n\n%s"
local WARN_NO_DESTROY_METHOD = "No Destroy method found on component %s - make sure Destroy cleans up any potential connections to events"
local WARN_TAG_DESTROY_CREATE = "CollectionService reported a destroyed tag before it was created: %s"
local WARN_COMPONENT_NOT_FOUND = "Component not found: %s"
local WARN_COMPONENT_INFINITE_WAIT = "Potential infinite wait on (\n\tObject = '%s';\n\tComponent = '%s';\n)\n%s"

local DESTROY_SUFFIX = ".Destroy"
local MEMORY_TAG_SUFFIX = ":Initial()"
local DIAGNOSIS_TAG_PREFIX = "Component."

local EMPTY_STRING = ""

local TIMEOUT_WARN = 10
local DEFAULT_TIMEOUT = 60

local VALIDATE_PARAMS = true
local WRAP_INITIAL_MEM_TAGS = true

local _InstanceToComponents = {}
local _ComponentClassToInstances = {}
local _ComponentClassToComponents = {}

local _ComponentClassAddedEvents = {}
local _ComponentClassRemovedEvents = {}
local _ComponentClassInitializedEvents = {}

--[[--
    Rosyn is an extension of CollectionService.
    Components are composed over Instances and any Instance
    can have multiple components. Multiple components of
    the same class/type cannot exist concurrently on an
    Instance.
    @classmod Rosyn

    @todo Optional "GetRegistry" approach with generics per component class
    @todo Detect circular dependencies on AwaitComponentInit
    @todo Add generics to GetComponent functions & similar
]]
local Rosyn = {
    -- Associations between Instances, component classes, and component instances, to ensure immediate lookup

    --- Map of tagged Instances as keys with values of Array<ComponentClass>
    -- @usage InstanceToComponents = {Instance = {ComponentClass1 = ComponentInstance1, ComponentClass2 = ComponentInstance2, ...}, ...}
    InstanceToComponents = _InstanceToComponents;
    --- Map of ComponentClasses as keys with values of Array<Instance>
    -- @usage ComponentClassToInstances = {ComponentClass = {Instance1 = true, Instance2 = true, ...}, ...}
    ComponentClassToInstances = _ComponentClassToInstances;
    --- Map of Uninitialized Component Classes as keys with values of Array<individual Class Instances>
    -- @usage ComponentClassToComponents = {ComponentClass = {ComponentInstance1 = true, ComponentInstance2 = true, ...}, ...}
    ComponentClassToComponents = _ComponentClassToComponents;

    -- Events related to component classes

    --- Map of initialized Component Classes with values of Component Added Signals
    -- @usage ComponentClassAddedEvents = {ComponentClass1 = Event1, ...}
    ComponentClassAddedEvents = _ComponentClassAddedEvents;
    --- Map of initialized Component Classes with values of Component Removed Signals
    -- @usage ComponentClassRemovedEvents = {ComponentClass1 = Event1, ...}
    ComponentClassRemovedEvents = _ComponentClassRemovedEvents;
    --- Map of initialized Component Classes with values of Component Initialized Signals
    -- @usage ComponentClassInitializedEvents = {ComponentClass1 = Event1, ...}
    ComponentClassInitializedEvents = _ComponentClassInitializedEvents;
    --- Signal for failed Component Class initialization
    -- @usage ComponentClassInitializationFailed:Fire(ComponentClassName: string, Instance: Instance, Error: string)
    ComponentClassInitializationFailed = XSignal.new();
};

local GetComponentNameParams = TypeGuard.Params(ValidComponentClassOrInstance)
--[[
    Attempts to get a unique ID from the component class or instance passed. A Type field in all component classes is the recommended approach.
    @param Component The component instance or class to obtain the name from.
]]
function Rosyn.GetComponentName(ComponentClassOrInstance): string
    if (VALIDATE_PARAMS) then
        GetComponentNameParams(ComponentClassOrInstance)
    end

    return ComponentClassOrInstance.Type or tostring(ComponentClassOrInstance)
end

local RegisterParams = TypeGuard.Params(TypeGuard.String(), TypeGuard.Array(ValidComponentClass):MinLength(0), ValidGameObject:Optional())
--[[--
    Registers component(s) to be automatically associated with instances with a certain tag.
    @param Tag The string of the CollectionService tag
    @param Components An array of ComponentClasses
    @param AncestorTarget The instance to look if any descendants added to it have the given Tag
]]
function Rosyn.Register(Tag: string, Components: {any}, AncestorTarget: Instance?)
    if (VALIDATE_PARAMS) then
        RegisterParams(Tag, Components, AncestorTarget)
    end

    AncestorTarget = AncestorTarget or game

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
            warn(WARN_NO_DESTROY_METHOD:format(Rosyn.GetComponentName(Component)))
        end

        if (not Component._DO_NOT_WRAP and not Cleaner.IsWrapped(Component)) then
            Cleaner.Wrap(Component)
        end
    end

    local Registered = {}
    local Trace = debug.traceback()

    local function HandleCreation(Item: Instance)
        if (Registered[Item]) then
            -- Sometimes GetTagged and GetInstanceAddedSignal can activate on the same frame, so debounce to prevent duplicate component warnings
            -- Thanks Roblox
            return
        end

        assert(Item.Parent ~= nil, ERR_ITEM_ALREADY_DESTROYED)

        if (not AncestorTarget:IsAncestorOf(Item)) then
            return
        end

        Registered[Item] = true

        for _, ComponentClass in Components do
            if (Rosyn.GetComponent(Item, ComponentClass)) then
                warn(WARN_MULTIPLE_REGISTER:format(Rosyn.GetComponentName(ComponentClass), Trace))
                continue
            end

            Rosyn._AddComponent(Item, ComponentClass)
        end
    end

    -- Pick up existing tagged Instances
    for _, Item in CollectionService:GetTagged(Tag) do
        task.spawn(HandleCreation, Item)
    end

    -- Creation
    CollectionService:GetInstanceAddedSignal(Tag):Connect(HandleCreation)

    -- Destruction
    CollectionService:GetInstanceRemovedSignal(Tag):Connect(function(Item)
        if (not AncestorTarget:IsAncestorOf(Item)) then
            return
        end

        Registered[Item] = nil

        local ComponentsForInstance = Rosyn.GetComponentsFromInstance(Item)

        if (ComponentsForInstance == nil or next(ComponentsForInstance) == nil) then
            warn(WARN_TAG_DESTROY_CREATE:format(Tag))
        end

        for _, ComponentClass in Components do
            if (not Rosyn.GetComponent(Item, ComponentClass)) then
                warn(WARN_COMPONENT_NOT_FOUND:format(Rosyn.GetComponentName(ComponentClass)))
                continue
            end

            Rosyn._RemoveComponent(Item, ComponentClass)
        end
    end)
end

local GetComponentParams = TypeGuard.Params(ValidGameObject, ValidComponentClass)
--[[--
    Attempts to obtain a specific component from an Instance given a component class.
    @param Object The Instance to check for the passed ComponentClass
    @param ComponentClass The uninitialized ComponentClass to check for
    @return ComponentInstance or nil
]]
function Rosyn.GetComponent<T>(Object: Instance, ComponentClass: T): T
    if (VALIDATE_PARAMS) then
        GetComponentParams(Object, ComponentClass)
    end

    local ComponentsForObject = Rosyn.InstanceToComponents[Object]
    return ComponentsForObject and ComponentsForObject[ComponentClass] or nil
end


local AwaitComponentInitParams = TypeGuard.Params(ValidGameObject, ValidComponentClass, TypeGuard.Number():Optional())
--[[
    Waits for a component instance's asynchronous Initial method to complete and returns it. Throws errors for timeout and target Instance deparenting to prevent memory leaks.
    @todo Re-work to get rid of the _INITIALIZED field approach and use key associations in another table
    @todo Add exit code 3 -> component was removed from the Instance while waiting (can help user debug things better)
]]
function Rosyn.AwaitComponentInit<T>(Object: Instance, ComponentClass: T, Timeout: number?): T
    if (VALIDATE_PARAMS) then
        AwaitComponentInitParams(Object, ComponentClass, Timeout)
    end

    -- Best case - it's registered AND initialized already
    local Got = Rosyn.GetComponent(Object, ComponentClass)

    if (Got and Got._INITIALIZED) then
        return Got
    end

    -- Alternate case - wait for init or timeout or deparenting
    Timeout = Timeout or DEFAULT_TIMEOUT

    local Trace = debug.traceback()
    local OnInitialized = XSignal.new()
    local ComponentName = Rosyn.GetComponentName(ComponentClass)

    local InitializedConnection; InitializedConnection = Rosyn.GetInitializedEvent(ComponentClass):Connect(function(TargetInstance: Instance)
        if (TargetInstance ~= Object) then
            return
        end

        InitializedConnection:Disconnect()
        OnInitialized:Fire()
    end)

    local Warn = task.delay(TIMEOUT_WARN, function()
        warn(WARN_COMPONENT_INFINITE_WAIT:format(Object:GetFullName(), ComponentName, Trace))
    end)

    OnInitialized.Event:Wait(Timeout, true)
    InitializedConnection:Disconnect()
    task.cancel(Warn)

    return Rosyn.GetComponent(Object, ComponentClass)
end

local GetComponentFromDescendantParams = TypeGuard.Params(ValidGameObject, ValidComponentClass)
--[[
    Obtains a component instance from an Instance or any of its ascendants.
]]
function Rosyn.GetComponentFromDescendant<T>(Object: Instance, ComponentClass: T): T?
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
--[[--
    Obtains Map of all Instances for which there exists a given component class on.
    @todo Think of an efficient way to prevent external writes to the returned table.
]]
function Rosyn.GetInstancesOfClass(ComponentClass): {[Instance]: boolean}
    if (VALIDATE_PARAMS) then
        GetInstancesOfClassParams(ComponentClass)
    end

    return Rosyn.ComponentClassToInstances[ComponentClass] or {}
end

local GetComponentsOfClassParams = TypeGuard.Params(ValidComponentClass)
--[[--
    Obtains Map of all components of a particular class.
    @todo Think of an efficient way to prevent external writes to the returned table.
]]
function Rosyn.GetComponentsOfClass<T>(ComponentClass: T): {[T]: boolean}
    if (VALIDATE_PARAMS) then
        GetComponentsOfClassParams(ComponentClass)
    end

    return Rosyn.ComponentClassToComponents[ComponentClass] or {}
end

local GetComponentsFromInstance = TypeGuard.Params(ValidGameObject)
--[[--
    Obtains all components of any class which are associated to a specific Instance.
    @todo Think of an efficient way to prevent external writes to the returned table.
]]
function Rosyn.GetComponentsFromInstance(Object: Instance): {[any]: any}
    if (VALIDATE_PARAMS) then
        GetComponentsFromInstance(Object)
    end

    return Rosyn.InstanceToComponents[Object] or {}
end

------------------------------------------- Internal -------------------------------------------

local AddComponentParams = TypeGuard.Params(ValidGameObject, ValidComponentClass)
--[[--
    Creates and wraps a component around an Instance, given a component class.
    @usage Private Method
]]
function Rosyn._AddComponent(Object: Instance, ComponentClass)
    if (VALIDATE_PARAMS) then
        AddComponentParams(Object, ComponentClass)
    end

    local ComponentName = Rosyn.GetComponentName(ComponentClass)
    local DiagnosisTag = DIAGNOSIS_TAG_PREFIX .. ComponentName
    assert(Rosyn.GetComponent(Object, ComponentClass) == nil, ERR_COMPONENT_ALREADY_PRESENT:format(ComponentName, Object:GetFullName()))

    -- Uses TypeGuard to check the structure of the Instance
    local Structure = ComponentClass.Structure

    if (Structure) then
        Structure:Assert(Object)
    end

    debug.profilebegin(DiagnosisTag)
        ---------------------------------------------------------------------------------------------------------
        local Yielded, NewComponent = CheckYield(function()
            return ComponentClass.new(Object)
        end)

        assert(not Yielded, ERR_COMPONENT_NEW_YIELDED:format(ComponentName, Object:GetFullName()))

        local InstanceToComponents = Rosyn.InstanceToComponents
        local ComponentClassToInstances = Rosyn.ComponentClassToInstances
        local ComponentClassToComponents = Rosyn.ComponentClassToComponents

        -- InstanceToComponents = {Instance = {ComponentClass1 = ComponentInstance1, ComponentClass2 = ComponentInstance2, ...}, ...}
        local ExistingComponentsForInstance = InstanceToComponents[Object]

        if (not ExistingComponentsForInstance) then
            ExistingComponentsForInstance = {}
            InstanceToComponents[Object] = ExistingComponentsForInstance
        end

        ExistingComponentsForInstance[ComponentClass] = NewComponent

        -- ComponentClassToInstances = {ComponentClass = {Instance1 = true, Instance2 = true, ...}, ...}
        local ExistingInstancesForComponentClass = ComponentClassToInstances[ComponentClass]

        if (not ExistingInstancesForComponentClass) then
            ExistingInstancesForComponentClass = {}
            ComponentClassToInstances[ComponentClass] = ExistingInstancesForComponentClass
        end

        ExistingInstancesForComponentClass[Object] = true

        -- ComponentClassToComponents = {ComponentClass = {ComponentInstance1 = true, ComponentInstance2 = true, ...}, ...}
        local ExistingComponentsForComponentClass = ComponentClassToComponents[ComponentClass]

        if (not ExistingComponentsForComponentClass) then
            ExistingComponentsForComponentClass = {}
            ComponentClassToComponents[ComponentClass] = ExistingComponentsForComponentClass
        end

        ExistingComponentsForComponentClass[NewComponent] = true
        ---------------------------------------------------------------------------------------------------------
    debug.profileend()

    Rosyn.GetAddedEvent(ComponentClass):Fire(Object)

    -- Initialise component in separate coroutine
    task.spawn(function()
        -- We can't use microprofiler tags because Initial is allowed to yield.
        -- Monitor for memory issues instead, because Initial is likely to contain various event connections.
        assert(NewComponent.Initial, ERR_NO_INITIAL:format(ComponentName, Object:GetFullName()))

        xpcall(function()
            NewComponent:Initial()
        end, function(ErrorMessage)
            -- Remove Rosyn and empty lines from the stack trace.
            local ErrorStack = debug.traceback(nil, 2)
            ErrorStack = string.gsub(ErrorStack, script:GetFullName() .. ":?[%d]*", EMPTY_STRING)
            ErrorStack = string.gsub(ErrorStack, "\n\n", EMPTY_STRING)

            Rosyn.ComponentClassInitializationFailed:Fire(ComponentName, Object, ErrorMessage, ErrorStack)
            TestService:Error(ERR_INIT_FAILED:format(ComponentName, Object:GetFullName(), ErrorMessage .. "\n" .. ErrorStack))
        end)

        if (table.isfrozen(NewComponent)) then
            warn(WARN_COMPONENT_LIFECYCLE_ALREDY_ENDED:format(ComponentName, Object:GetFullName()))
            return
        end

        NewComponent._INITIALIZED = true
        Rosyn.GetInitializedEvent(ComponentClass):Fire(Object)
        -- TODO: maybe we pcall and timeout the Initial and ensure Destroy is always called after
        -- Otherwise we have to use the "retroactive" cleaner pattern
    end)
end

local RemoveComponentParams = TypeGuard.Params(ValidGameObject, ValidComponentClass)
--[[--
    Removes a component from an Instance, given a component class. Calls Destroy on component.
    @usage Private Method
]]
function Rosyn._RemoveComponent(Object: Instance, ComponentClass)
    if (VALIDATE_PARAMS) then
        RemoveComponentParams(Object, ComponentClass)
    end

    local ComponentName = Rosyn.GetComponentName(ComponentClass)
    local DiagnosisTag = DIAGNOSIS_TAG_PREFIX .. ComponentName
    local ExistingComponent = Rosyn.GetComponent(Object, ComponentClass)
    assert(ExistingComponent, ERR_COMPONENT_NOT_PRESENT:format(ComponentName, Object:GetFullName()))

    debug.profilebegin(DiagnosisTag)
        ---------------------------------------------------------------------------------------------------------
        local InstanceToComponents = Rosyn.InstanceToComponents
        local ComponentClassToInstances = Rosyn.ComponentClassToInstances
        local ComponentClassToComponents = Rosyn.ComponentClassToComponents

        -- InstanceToComponents = {Instance = {ComponentClass1 = ComponentInstance1, ComponentClass2 = ComponentInstance2, ...}, ...}
        local ExistingComponentsForInstance = InstanceToComponents[Object]

        if (not ExistingComponentsForInstance) then
            ExistingComponentsForInstance = {}
            InstanceToComponents[Object] = ExistingComponentsForInstance
        end

        ExistingComponentsForInstance[ComponentClass] = nil

        if (next(ExistingComponentsForInstance) == nil) then
            InstanceToComponents[Object] = nil
        end

        -- ComponentClassToInstances = {ComponentClass = {Instance1 = true, Instance2 = true, ...}, ...}
        local ExistingInstancesForComponentClass = ComponentClassToInstances[ComponentClass]
        ExistingInstancesForComponentClass[Object] = nil

        if (next(ExistingInstancesForComponentClass) == nil) then
            ComponentClassToInstances[ComponentClass] = nil
        end

        -- ComponentClassToComponents = {ComponentClass = {ComponentInstance1 = true, ComponentInstance2 = true, ...}, ...}
        local ExistingComponentsForComponentClass = ComponentClassToComponents[ComponentClass]
        ExistingComponentsForComponentClass[ExistingComponent] = nil

        if (next(ExistingComponentsForComponentClass) == nil) then
            ComponentClassToComponents[ComponentClass] = nil
        end
        ---------------------------------------------------------------------------------------------------------
    debug.profileend()

    Rosyn.GetRemovedEvent(ComponentClass):Fire(Object)

    -- Destroy component to let it clean stuff up
    debug.profilebegin(DiagnosisTag .. DESTROY_SUFFIX)

    if (ExistingComponent.Destroy) then
        local Yielded = CheckYield(function()
            ExistingComponent:Destroy()
        end)
        assert(not Yielded, ERR_COMPONENT_DESTROY_YIELDED:format(ComponentName, Object:GetFullName()))
    end

    debug.profileend()
end

local GetAddedEventParams = TypeGuard.Params(ValidComponentClass)
--[[
    Obtains or creates a Signal which will fire when a component has been instantiated.
    @todo Refactor these 3 since they have a lot of repeated code
]]
function Rosyn.GetAddedEvent(ComponentClass): XSignal<Instance>
    if (VALIDATE_PARAMS) then
        GetAddedEventParams(ComponentClass)
    end

    local ComponentClassAddedEvents = Rosyn.ComponentClassAddedEvents
    local AddedEvent = ComponentClassAddedEvents[ComponentClass]

    if (not AddedEvent) then
        AddedEvent = XSignal.new()
        ComponentClassAddedEvents[ComponentClass] = AddedEvent
    end

    return AddedEvent
end

local GetRemovedEventParams = TypeGuard.Params(ValidComponentClass)
--[[--
    Obtains or creates a Signal which will fire when a component has been destroyed.
]]
function Rosyn.GetRemovedEvent(ComponentClass): XSignal<Instance>
    if (VALIDATE_PARAMS) then
        GetRemovedEventParams(ComponentClass)
    end

    local ComponentClassRemovedEvents = Rosyn.ComponentClassRemovedEvents
    local RemovedEvent = ComponentClassRemovedEvents[ComponentClass]

    if (not RemovedEvent) then
        RemovedEvent = XSignal.new()
        ComponentClassRemovedEvents[ComponentClass] = RemovedEvent
    end

    return RemovedEvent
end

local GetInitializedEventParams = TypeGuard.Params(ValidComponentClass)
--[[--
    Obtains or creates a Signal which will fire when a component has passed its initialization phase.
]]
function Rosyn.GetInitializedEvent(ComponentClass): XSignal<Instance>
    if (VALIDATE_PARAMS) then
        GetInitializedEventParams(ComponentClass)
    end

    local ComponentClassInitializedEvents = Rosyn.ComponentClassInitializedEvents
    local InitializedEvent = ComponentClassInitializedEvents[ComponentClass]

    if (not InitializedEvent) then
        InitializedEvent = XSignal.new()
        ComponentClassInitializedEvents[ComponentClass] = InitializedEvent
    end

    return InitializedEvent
end

--[[--
    Condition which should be true at all times. For test writing. Ensures component counts for all registered components are equivalent in all associations.
    @usage Private Method
]]
function Rosyn._Invariant()
    local Counts = {}

    for Item in Rosyn.InstanceToComponents do
        local Components = Rosyn.GetComponentsFromInstance(Item)

        if (not Components) then
            continue
        end

        for _, Component in Components do
            Component = Component._COMPONENT_REF
            Counts[tostring(Component)] = (Counts[tostring(Component)] or 0) + 1
        end
    end

    -- Ensure it matches
    local OtherCounts = {}

    for ComponentClass, Instances in Rosyn.ComponentClassToComponents do
        for _ in Instances do
            OtherCounts[tostring(ComponentClass)] = (OtherCounts[tostring(ComponentClass)] or 0) + 1
        end
    end

    for Key, Value in OtherCounts do
        local SameObjectCount = Counts[Key]

        if (SameObjectCount) then
            if (SameObjectCount ~= Value) then
                return false
            end
        end
    end

    return true
end

return Rosyn