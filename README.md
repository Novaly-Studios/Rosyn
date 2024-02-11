# Rosyn

Wraps Lua objects over Instances, automates lifecycle, and handles yielding component dependencies in a memory-safe manner.

## Example Usage

### 1. Lifecycle

```lua
local Test = {}
Test.__index = Test

function Test.new(Root: Instance)
    return setmetatable({
        Root = Root;
    }, Test)
end

function Test:Initial()
    print("Initial call on", self.Root:GetFullName())
end

function Test:Destroy()
    print("Destroy call")
end

Rosyn.Register({
    Components = Rosyn.Setup.Tags({
        TestTag = Test;
    });
})

local TestInstance = Instance.new("Model")
TestInstance:AddTag("TestTag")
TestInstance.Name = "TestInstance"
TestInstance.Parent = workspace
-- Output "Initial call on Workspace.TestInstance"
TestInstance:Destroy()
-- Output "Destroy call"
```

### 2. Initial Chaining / Dependencies

```lua
local Test1 = [class]
local Test2 = [class]

function Test1:Initial()
    print("Test1 Begin")
    task.wait(1)
    print("Test1 Initial")
end

function Test1:Print()
    print("HHH")
end

function Test2:Initial()
    local Test1Component = Rosyn.AwaitComponentInit(self.Root, Test1)
    Test1Component:Print()
    print("Test2 Initial")
end

Rosyn.Register({
    Components = Rosyn.Setup.Tags({
        TestTag1 = Test1;
        TestTag2 = Test2;
    });
})

local TestInstance = Instance.new("Model")
TestInstance:AddTag("TestTag1")
TestInstance:AddTag("TestTag2")
TestInstance.Parent = workspace
-- Output "Test1 Begin"
-- 1s passes
-- Output "Test1 Initial"
-- Output "HHH"
-- Output "Test2 Initial"
```

## Warning

With Roblox deferred events now enabled by default, `Rosyn.GetComponent` will return nil if called before defer points when an Instance is cloned / created / tagged. `Rosyn.AwaitComponentInit(Instance, Component, 0)` is advised to avoid this mistake and will yield until the next frame.
