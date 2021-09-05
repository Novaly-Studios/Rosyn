return function()
    local Workspace = game:GetService("Workspace")
    local CollectionService = game:GetService("CollectionService")
    local ComponentSystem = require(script.Parent)
    ComponentSystem.SuppressWarnings = true

    local function MakeClass()
        local Class = {}
        Class.__index = Class
        Class.Type = "Class"

        function Class.new(Root)
            return setmetatable({
                Root = Root;
            }, Class)
        end

        function Class:Initial() end

        return Class
    end

    local function MakeTestInstance(Tags, Parent)
        local Test = Instance.new("Model")

        for _, Tag in pairs(Tags) do
            CollectionService:AddTag(Test, Tag)
        end

        Test.Parent = Parent
        return Test
    end

    local function Count(Item)
        local Result = 0

        for _ in pairs(Item) do
            Result += 1
        end

        return Result
    end

    afterEach(function()
        expect(ComponentSystem._Invariant()).to.equal(true)
    end)

    afterAll(function()
        for _, Item in pairs(Workspace:GetChildren()) do
            if (not Item:IsA("Model")) then
                continue
            end

            Item:Destroy()
        end
    end)

    describe("ComponentSystem.Register", function()
        it("should accept standard arguments", function()
            local Test = MakeClass()
            ComponentSystem.Register("ArgsTestTag1", {Test})
        end)

        it("should asynchronously register", function()
            -- Test calling Register before and after Instance presence
            local Test = MakeClass()
            local DidInit = false

            function Test:Initial()
                expect(self.Root).to.never.equal(nil)
                DidInit = true
                task.wait(2)
            end

            local Tagged = MakeTestInstance({"AsyncTestTag1"}, Workspace)
            local Time = os.clock()

                ComponentSystem.Register("AsyncTestTag1", {Test})
                expect((os.clock() - Time) < 1/120).to.equal(true)

            expect(DidInit).to.equal(true)
            Tagged:Destroy()
        end)

        it("should accept and correctly register ancestor target", function()
            local DidTest1 = false
            local DidTest2 = false

            local Test1 = MakeClass()

            function Test1:Initial()
                DidTest1 = true
            end

            local Test2 = MakeClass()

            function Test2:Initial()
                DidTest2 = false
            end

            ComponentSystem.Register("AncestorTestTag1", {Test1}, Workspace)
            ComponentSystem.Register("AncestorTestTag2", {Test2}, game:GetService("ReplicatedStorage"))
            MakeTestInstance({"AncestorTestTag1"}, Workspace):Destroy()
            MakeTestInstance({"AncestorTestTag2"}, Workspace):Destroy()

            expect(DidTest1).to.equal(true)
            expect(DidTest2).to.equal(false)
        end)

        it("should call destroy on objects when the associated Instance is removed", function()
            local DidDestroy = false
            local Test = MakeClass()

            function Test:Destroy()
                DidDestroy = true
            end

            ComponentSystem.Register("DestroyTestTag1", {Test})
            local Inst = MakeTestInstance({"DestroyTestTag1"}, Workspace)
            Inst:Destroy()
            expect(DidDestroy).to.equal(true)
        end)

        it("should allow multiple points of registration for the same tag", function()
            local Test1 = MakeClass()
            local Test2 = MakeClass()

            local Inst = MakeTestInstance({"MultiComponentOneTag"}, Workspace)
            ComponentSystem.Register("MultiComponentOneTag", {Test1})
            ComponentSystem.Register("MultiComponentOneTag", {Test2})

            expect(ComponentSystem.GetComponent(Inst, Test1)).to.be.ok()
            expect(ComponentSystem.GetComponent(Inst, Test2)).to.be.ok()

            Inst:Destroy()
        end)

        it("should allow multiple tags on the same Instance", function()
            local Test1 = MakeClass()
            local Test2 = MakeClass()

            local Inst = MakeTestInstance({"MultiTag1", "MultiTag2"}, Workspace)
            ComponentSystem.Register("MultiTag1", {Test1})
            ComponentSystem.Register("MultiTag2", {Test2})

            expect(ComponentSystem.GetComponent(Inst, Test1)).to.be.ok()
            expect(ComponentSystem.GetComponent(Inst, Test2)).to.be.ok()

            Inst:Destroy()
        end)
    end)

    describe("ComponentSystem.GetComponent", function()
        it("should return nil where no component present", function()
            local Test = MakeClass()
            expect(ComponentSystem.GetComponent(Workspace, Test)).never.to.be.ok()
        end)

        it("should return a component when component present", function()
            local Test1 = MakeClass()
            local Test2 = MakeClass()
            local Inst = MakeTestInstance({"GetComponent1"}, Workspace)

            ComponentSystem.Register("GetComponent1", {Test1, Test2})
            expect(ComponentSystem.GetComponent(Inst, Test1)).to.be.ok()
            expect(ComponentSystem.GetComponent(Inst, Test2)).to.be.ok()

            Inst:Destroy()
        end)
    end)

    describe("ComponentSystem.AwaitComponent", function()
        it("should immediately return component when present", function()
            local Test1 = MakeClass()
            local Inst = MakeTestInstance({"AwaitComponent1"}, Workspace)

            ComponentSystem.Register("AwaitComponent1", {Test1})
            expect(ComponentSystem.AwaitComponent(Inst, Test1)).to.be.ok()

            Inst:Destroy()
        end)

        it("should await component", function()
            local Test1 = MakeClass()
            local Inst = MakeTestInstance({"AwaitComponent2"}, Workspace)

            coroutine.wrap(function()
                task.wait(1)
                ComponentSystem.Register("AwaitComponent2", {Test1})
            end)()

            expect(ComponentSystem.AwaitComponent(Inst, Test1)).to.be.ok()
            Inst:Destroy()
        end)

        it("should timeout and throw an error", function()
            local Test1 = MakeClass()
            local Inst = MakeTestInstance({"AwaitComponent3"}, Workspace)
            local Time = os.clock()

            expect(function()
                ComponentSystem.AwaitComponent(Inst, Test1, 2)
            end).to.throw()

            expect((os.clock() - Time) >= 2).to.equal(true)

            Inst:Destroy()
        end)
    end)

    describe("ComponentSystem.AwaitComponentInit", function()
        it("should immediately return component when present", function()
            local Test1 = MakeClass()
            local Inst = MakeTestInstance({"AwaitComponentInit1"}, Workspace)

            ComponentSystem.Register("AwaitComponentInit1", {Test1})
            expect(ComponentSystem.AwaitComponentInit(Inst, Test1)).to.be.ok()

            Inst:Destroy()
        end)

        it("should await component", function()
            local Test1 = MakeClass()
            local Inst = MakeTestInstance({"AwaitComponentInit2"}, Workspace)

            coroutine.wrap(function()
                task.wait(1)
                ComponentSystem.Register("AwaitComponentInit2", {Test1})
            end)()

            expect(ComponentSystem.AwaitComponentInit(Inst, Test1)).to.be.ok()
            Inst:Destroy()
        end)

        it("should timeout and throw an error", function()
            local Test1 = MakeClass()
            local Inst = MakeTestInstance({"AwaitComponentInit3"}, Workspace)
            local Time = os.clock()

            expect(function()
                ComponentSystem.AwaitComponentInit(Inst, Test1, 2)
            end).to.throw()

            expect((os.clock() - Time) >= 2).to.equal(true)

            Inst:Destroy()
        end)

        it("should timeout on Initial yield", function()
            local Test1 = MakeClass()
            local Inst = MakeTestInstance({"AwaitComponentInit4"}, Workspace)

            function Test1:Initial()
                task.wait(2)
            end

            expect(function()
                ComponentSystem.AwaitComponentInit(Inst, Test1, 1)
            end).to.throw()
        end)

        it("should correctly wait for Initial", function()
            local Test1 = MakeClass()

            function Test1:Initial()
                task.wait(2)
            end

            local Inst = MakeTestInstance({"AwaitComponentInit4"}, Workspace)
            ComponentSystem.Register("AwaitComponentInit4", {Test1})

            local DidImmediatelyGet = false

            task.spawn(function()
                ComponentSystem.AwaitComponentInit(Inst, Test1, 1)
                DidImmediatelyGet = true
            end)

            expect(DidImmediatelyGet).to.equal(false)
            expect(ComponentSystem.AwaitComponentInit(Inst, Test1, 5)).to.be.ok()
            expect(ComponentSystem.AwaitComponentInit(Inst, Test1, 5)).to.equal(ComponentSystem.GetComponent(Inst, Test1))
        end)

        it("should correctly wait for Initial in a chain", function()
            local Inst = MakeTestInstance({"AwaitComponentInit5"}, Workspace)
            local Chained = false

                local Test1 = MakeClass()

                function Test1:Initial()
                    task.wait(2)
                end

                local Test2 = MakeClass()

                function Test2:Initial()
                    ComponentSystem.AwaitComponentInit(Inst, Test1)
                    task.wait(1)
                end

                local Test3 = MakeClass()

                function Test3:Initial()
                    ComponentSystem.AwaitComponentInit(Inst, Test2)
                    Chained = true
                end

            ComponentSystem.Register("AwaitComponentInit5", {Test1, Test2, Test3})

            expect(Chained).to.equal(false)
            task.wait(2.5)
            expect(Chained).to.equal(false)
            task.wait(1)
            expect(Chained).to.equal(true)
        end)

        it("should correctly wait for Initial in a chain with errors", function()
            local Inst = MakeTestInstance({"AwaitComponentInit5"}, Workspace)
            local Chained = false

                local Test1 = MakeClass()

                function Test1:Initial()
                    task.wait(2)
                    error("Test")
                end

                local Test2 = MakeClass()

                function Test2:Initial()
                    ComponentSystem.AwaitComponentInit(Inst, Test1)
                    task.wait(1)
                end

                local Test3 = MakeClass()

                function Test3:Initial()
                    ComponentSystem.AwaitComponentInit(Inst, Test2)
                    Chained = true
                end

            ComponentSystem.Register("AwaitComponentInit5", {Test1, Test2, Test3})

            expect(Chained).to.equal(false)
            task.wait(2.5)
            expect(Chained).to.equal(false)
            task.wait(1)
            expect(Chained).to.equal(true)
        end)
    end)

    describe("ComponentSystem.GetComponentFromDescendant", function()
        it("should return nil where no component present", function()
            local Inst = MakeTestInstance({})
            local Test1 = MakeClass()
            expect(ComponentSystem.GetComponentFromDescendant(Inst, Test1)).never.to.be.ok()

            Inst:Destroy()
        end)

        it("should return a component when component present", function()
            local Inst1 = MakeTestInstance({"DescendantTest1"}, Workspace)
            local Inst2 = MakeTestInstance({}, Inst1)

            local Test1 = MakeClass()
            ComponentSystem.Register("DescendantTest1", {Test1})

            expect(ComponentSystem.GetComponentFromDescendant(Inst1, Test1)).to.be.ok()
            expect(ComponentSystem.GetComponentFromDescendant(Inst2, Test1)).to.be.ok()

            Inst1:Destroy()
        end)
    end)

    describe("ComponentSystem.GetInstancesOfClass", function()
        it("should obtain all Instances which have a specific component class", function()
            local Instances = {}
            local Test1 = MakeClass()
            ComponentSystem.Register("GetInstancesOfClass1", {Test1})

            for _ = 1, 5 do
                local Object = MakeTestInstance({"GetInstancesOfClass1"}, Workspace)
                Instances[Object] = true
            end

            local GotInstances = ComponentSystem.GetInstancesOfClass(Test1)
            local InstanceCount = Count(GotInstances)
            expect(InstanceCount == 5).to.equal(true)

            for Item in pairs(GotInstances) do
                expect(Instances[Item]).to.be.ok()
                Item:Destroy()
            end
        end)
    end)

    describe("ComponentSystem.GetComponentsOfClass", function()
        it("should return components of a correct class", function()
            local Instances = {}
            local Test1 = MakeClass()
            ComponentSystem.Register("GetComponentsOfClass1", {Test1})

            for _ = 1, 5 do
                local Object = MakeTestInstance({"GetComponentsOfClass1"}, Workspace)
                Instances[Object] = true
            end

            local GotComponents = ComponentSystem.GetComponentsOfClass(Test1)
            local ComponentCount = Count(GotComponents)
            expect(ComponentCount == 5).to.equal(true)

            for Component in pairs(GotComponents) do
                expect(Instances[Component.Root]).to.be.ok()
                Component.Root:Destroy()
            end
        end)
    end)

    describe("ComponentSystem.GetComponentsFromInstance", function()
        -- TODO
    end)
end