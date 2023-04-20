local function anyfn(...) return ({} :: any) end
it = it or anyfn
expect = expect or anyfn
describe = describe or anyfn
afterAll = afterAll or anyfn
afterEach = afterEach or anyfn

return function()
    local CollectionService = game:GetService("CollectionService")
    local Workspace = game:GetService("Workspace")

    local Rosyn = require(script.Parent)
    local Async = require(script.Parent.Parent.Async)

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
        function Class:Destroy() end

        return Class
    end

    local function MakeTestInstance(Tags, Parent)
        local Test = Instance.new("Model")

        for _, Tag in Tags do
            CollectionService:AddTag(Test, Tag)
        end

        Test.Parent = Parent
        return Test
    end

    local function Count(Item)
        local Result = 0

        for _ in Item do
            Result += 1
        end

        return Result
    end

    afterEach(Rosyn._Invariant)

    afterAll(function()
        for _, Item in Workspace:GetChildren() do
            if (not Item:IsA("Model")) then
                continue
            end

            Item:Destroy()
        end
    end)

    describe("Rosyn.Register", function()
        it("should accept standard arguments", function()
            expect(function()
                Rosyn.Register({
                    Components = Rosyn.Setup.Tags({
                        ArgsTestTag1 = MakeClass();
                    });
                })
            end).never.to.throw()
        end)

        it("should asynchronously register", function()
            -- Test calling Register before and after Instance presence
            local Test = MakeClass()
            local DidInit = false

            function Test:Initial()
                expect(self.Root).to.never.equal(nil)
                DidInit = true
                task.wait(0.1)
            end

            local Tagged = MakeTestInstance({"AsyncTestTag1"}, Workspace)
            local Complete = false

            task.spawn(function()
                Rosyn.Register({
                    Components = Rosyn.Setup.Tags({
                        AsyncTestTag1 = Test;
                    });
                })

                Complete = true
            end)

            expect(Complete).to.equal(true)
            expect(DidInit).to.equal(true)
            Tagged:Destroy()
        end)

        it("should accept and correctly register ancestor target given that filter", function()
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

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    AncestorTestTag1 = Test1;
                });
                Filter = function(Object)
                    return Object:IsDescendantOf(Workspace)
                end;
            })

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    AncestorTestTag2 = Test2;
                });
                Filter = function(Object)
                    return Object:IsDescendantOf(game:GetService("ReplicatedStorage"))
                end;
            })

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

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    DestroyTestTag1 = Test;
                });
            })

            local Inst = MakeTestInstance({"DestroyTestTag1"}, Workspace)
            expect(DidDestroy).to.equal(false)
            Inst:Destroy()
            expect(DidDestroy).to.equal(true)
        end)

        it("should allow multiple points of registration for the same tag", function()
            local Test1 = MakeClass()
            local Test2 = MakeClass()
            local Inst = MakeTestInstance({"MultiComponentOneTag"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    MultiComponentOneTag = Test1;
                });
            })

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    MultiComponentOneTag = Test2;
                });
            })

            expect(Rosyn.GetComponent(Inst, Test1)).to.be.ok()
            expect(Rosyn.GetComponent(Inst, Test2)).to.be.ok()
        end)

        it("should allow multiple tags on the same Instance", function()
            local Test1 = MakeClass()
            local Test2 = MakeClass()
            local Inst = MakeTestInstance({"MultiTag1", "MultiTag2"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    MultiTag1 = Test1;
                });
            })

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    MultiTag2 = Test2;
                });
            })

            expect(Rosyn.GetComponent(Inst, Test1)).to.be.ok()
            expect(Rosyn.GetComponent(Inst, Test2)).to.be.ok()
        end)

        it("should accept a non-__index class", function()
            local Test = {}

            function Test.new()
                return {X = 1}
            end

            local Inst = MakeTestInstance({"BlankTable"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    BlankTable = Test;
                })
            })

            expect(Rosyn.GetComponent(Inst, Test)).to.be.ok()
            expect(Rosyn.GetComponent(Inst, Test).X).to.equal(1)
        end)

        it("should remove specific components for removal of tags, instead of all components", function()
            local Test1 = MakeClass()
            local Test2 = MakeClass()

            local Inst = MakeTestInstance({"TagsSetup1"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    TagsSetup1 = Test1;
                    TagsSetup2 = Test2;
                })
            })

            expect(Rosyn.GetComponent(Inst, Test1)).to.be.ok()
            expect(Rosyn.GetComponent(Inst, Test2)).never.to.be.ok()
            CollectionService:AddTag(Inst, "TagsSetup2")
            expect(Rosyn.GetComponent(Inst, Test1)).to.be.ok()
            expect(Rosyn.GetComponent(Inst, Test2)).to.be.ok()
            CollectionService:RemoveTag(Inst, "TagsSetup1")
            expect(Rosyn.GetComponent(Inst, Test1)).never.to.be.ok()
            expect(Rosyn.GetComponent(Inst, Test2)).to.be.ok()
            CollectionService:RemoveTag(Inst, "TagsSetup2")
            expect(Rosyn.GetComponent(Inst, Test1)).never.to.be.ok()
            expect(Rosyn.GetComponent(Inst, Test2)).never.to.be.ok()
        end)
    end)

    describe("Rosyn.GetComponent", function()
        it("should return nil where no component present", function()
            local Test = MakeClass()
            expect(Rosyn.GetComponent(Workspace, Test)).never.to.be.ok()
        end)

        it("should return a component when component present", function()
            local Test1 = MakeClass()
            local Test2 = MakeClass()
            local Inst = MakeTestInstance({"GetComponent1"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    GetComponent1 = {Test1, Test2};
                });
            })

            expect(Rosyn.GetComponent(Inst, Test1)).to.be.ok()
            expect(Rosyn.GetComponent(Inst, Test2)).to.be.ok()
        end)
    end)

    describe("Rosyn.ExpectComponent", function()
        it("should throw an error where no component present", function()
            local Test = MakeClass()

            expect(function()
                Rosyn.ExpectComponent(Workspace, Test)
            end).to.throw()
        end)

        it("should return a component when component present", function()
            local Test1 = MakeClass()
            local Test2 = MakeClass()
            local Inst = MakeTestInstance({"ExpectComponent1"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    ExpectComponent1 = {Test1, Test2};
                });
            })

            expect(Rosyn.ExpectComponent(Inst, Test1)).to.be.ok()
            expect(Rosyn.ExpectComponent(Inst, Test2)).to.be.ok()
        end)
    end)

    describe("Rosyn.AwaitComponentInit", function()
        it("should immediately return component when present", function()
            local Test1 = MakeClass()
            local Inst = MakeTestInstance({"AwaitComponentInit1"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    AwaitComponentInit1 = {Test1};
                });
            })

            expect(Rosyn.AwaitComponentInit(Inst, Test1)).to.be.ok()
        end)

        it("should await component", function()
            local Test1 = MakeClass()
            local Inst = MakeTestInstance({"AwaitComponentInit2"}, Workspace)

            task.delay(1, function()
                Rosyn.Register({
                    Components = Rosyn.Setup.Tags({
                        AwaitComponentInit2 = {Test1};
                    });
                })
            end)

            local Result = Rosyn.AwaitComponentInit(Inst, Test1)
            expect(Result).to.be.ok()
        end)

        it("should timeout and throw an error", function()
            local Test1 = MakeClass()
            local Inst = MakeTestInstance({"AwaitComponentInit3"}, Workspace)
            local Time = os.clock()

            expect(function()
                Rosyn.AwaitComponentInit(Inst, Test1, 0.2)
            end).to.throw()

            expect((os.clock() - Time) >= 0.2).to.equal(true)
        end)

        it("should timeout on Initial yield", function()
            local Test1 = MakeClass()
            local Inst = MakeTestInstance({"AwaitComponentInit4"}, Workspace)

            function Test1:Initial()
                task.wait(0.2)
            end

            expect(function()
                Rosyn.AwaitComponentInit(Inst, Test1, 0.1)
            end).to.throw()
        end)

        it("should correctly wait for Initial", function()
            local Test1 = MakeClass()

            function Test1:Initial()
                task.wait(0.1)
            end

            local Inst = MakeTestInstance({"AwaitComponentInit5"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    AwaitComponentInit5 = {Test1};
                });
            })

            local DidImmediatelyGet = false

            task.spawn(function()
                Rosyn.AwaitComponentInit(Inst, Test1, 1)
                DidImmediatelyGet = true
            end)

            expect(DidImmediatelyGet).to.equal(false)
            expect(Rosyn.AwaitComponentInit(Inst, Test1, 5)).to.be.ok()
            expect(Rosyn.AwaitComponentInit(Inst, Test1, 5)).to.equal(Rosyn.GetComponent(Inst, Test1))
        end)

        it("should correctly wait for Initial in a chain", function()
            local Inst = MakeTestInstance({"AwaitComponentInit6"}, Workspace)
            local Accumulation = 0

            local Test1 = MakeClass()

            function Test1:Initial()
                task.wait(0.1)
                Accumulation += 1
            end

            local Test2 = MakeClass()

            function Test2:Initial()
                Rosyn.AwaitComponentInit(Inst, Test1)
                task.wait(0.1)
                Accumulation += 1
            end

            local Test3 = MakeClass()

            function Test3:Initial()
                Rosyn.AwaitComponentInit(Inst, Test2)
                Accumulation += 1
            end

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    AwaitComponentInit6 = {Test1, Test2, Test3};
                });
            })

            expect(Accumulation).to.equal(0)
            task.wait(0.1)
            expect(Accumulation).to.equal(1)
            task.wait(0.1)
            expect(Accumulation).to.equal(3)
        end)

        it("should correctly wait for Initial in a chain with errors", function()
            local Inst = MakeTestInstance({"AwaitComponentInit7"}, Workspace)
            local Accumulation = 0

            local Test1 = MakeClass()

            function Test1:Initial()
                task.wait(0.1)
                Accumulation += 1
                error("Test")
            end

            local Test2 = MakeClass()

            function Test2:Initial()
                Accumulation += 1
                Rosyn.AwaitComponentInit(Inst, Test1)
                Accumulation += 1
            end

            local Test3 = MakeClass()

            function Test3:Initial()
                Accumulation += 1
                Rosyn.AwaitComponentInit(Inst, Test2)
                Accumulation += 1
            end

            expect(Accumulation).to.equal(0)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    AwaitComponentInit7 = {Test1, Test2, Test3};
                });
            })

            task.wait(0.1)
            expect(Accumulation).to.equal(3)
        end)

        it("should respond to Initial timeouts correctly", function()
            local Test = MakeClass()
            Test.Options = {
                InitialTimeout = 0.1;
            }

            function Test:Initial()
                task.wait(0.2)
            end

            local Inst = MakeTestInstance({"AwaitComponentInit8"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    AwaitComponentInit8 = {Test};
                });
            })

            expect(function()
                Rosyn.AwaitComponentInit(Inst, Test, 0.2)
            end).to.throw()
        end)
    end)

    describe("Rosyn.GetComponentFromDescendant", function()
        it("should return nil where no component present", function()
            local Inst = MakeTestInstance({}, Workspace)
            local Test1 = MakeClass()
            expect(Rosyn.GetComponentFromDescendant(Inst, Test1)).never.to.be.ok()
        end)

        it("should return a component when component present", function()
            local Inst1 = MakeTestInstance({"DescendantTest1"}, Workspace)
            local Inst2 = MakeTestInstance({}, Inst1)
            local Test1 = MakeClass()

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    DescendantTest1 = {Test1};
                });
            })

            expect(Rosyn.GetComponentFromDescendant(Inst1, Test1)).to.be.ok()
            expect(Rosyn.GetComponentFromDescendant(Inst2, Test1)).to.be.ok()
        end)
    end)

    describe("Rosyn.GetInstancesOfClass", function()
        it("should obtain all Instances which have a specific component class", function()
            local Instances = {}
            local Test1 = MakeClass()

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    GetInstancesOfClass1 = {Test1};
                });
            })

            for _ = 1, 5 do
                local Object = MakeTestInstance({"GetInstancesOfClass1"}, Workspace)
                Instances[Object] = true
            end

            local GotInstances = Rosyn.GetInstancesOfClass(Test1)
            local InstanceCount = Count(GotInstances)
            expect(InstanceCount == 5).to.equal(true)

            for Item in GotInstances do
                expect(Instances[Item]).to.be.ok()
            end
        end)
    end)

    describe("Rosyn.GetComponentsOfClass", function()
        it("should return components of a correct class", function()
            local Instances = {}
            local Test1 = MakeClass()

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    GetComponentsOfClass1 = {Test1};
                });
            })

            for _ = 1, 5 do
                local Object = MakeTestInstance({"GetComponentsOfClass1"}, Workspace)
                Instances[Object] = true
            end

            local GotComponents = Rosyn.GetComponentsOfClass(Test1)
            local ComponentCount = Count(GotComponents)
            expect(ComponentCount == 5).to.equal(true)

            for Component in GotComponents do
                expect(Instances[Component.Root]).to.be.ok()
            end
        end)
    end)

    describe("Rosyn.GetComponentsFromInstance", function()
        it("should return the components on a given Instance", function()
            local Test1 = MakeClass()
            local Test2 = MakeClass()
            local Inst = MakeTestInstance({"GetComponentsFromInstance1", "GetComponentsFromInstance2"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    GetComponentsFromInstance1 = {Test1};
                });
            })

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    GetComponentsFromInstance2 = {Test2};
                });
            })

            local Components = Rosyn.GetComponentsFromInstance(Inst)
            expect(Count(Components) == 2).to.equal(true)
            expect(Components[Test1]).to.be.ok()
            expect(Components[Test1]).to.equal(Rosyn.GetComponent(Inst, Test1))
            expect(Components[Test2]).to.be.ok()
            expect(Components[Test2]).to.equal(Rosyn.GetComponent(Inst, Test2))
        end)

        it("should return the components on a given Instance, even if uninitialized", function()
            local Test1 = MakeClass()

            function Test1:Initial()
                task.wait(0.2)
            end

            local Inst = MakeTestInstance({"GetComponentsFromInstance3"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    GetComponentsFromInstance3 = {Test1};
                });
            })

            local Components = Rosyn.GetComponentsFromInstance(Inst)
            expect(Count(Components) == 1).to.equal(true)
            expect(Components[Test1]).to.be.ok()
            expect(Components[Test1]).to.equal(Rosyn.GetComponent(Inst, Test1))
        end)
    end)
    
    describe("Component.Initial", function()
        it("should timeout the Initial thread times out, and terminate the thread", function()
            local Test = MakeClass()
            Test.Options = {
                InitialTimeout = 0.1;
            }

            local Thread

            function Test:Initial()
                Thread = coroutine.running()
                task.wait(1)
            end

            local Inst = MakeTestInstance({"InitialTimeout1"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    InitialTimeout1 = {Test};
                });
            })

            task.wait(0.1)

            expect(coroutine.status(Thread)).to.equal("dead")
            expect(function()
                Rosyn.AwaitComponentInit(Inst, Test)
            end).to.throw("timed out")
        end)

        it("should throw an error if the component's Initial threw an error", function()
            local Test = MakeClass()

            function Test:Initial()
                error("Test error")
            end

            local Inst = MakeTestInstance({"InitialError1"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    InitialError1 = {Test};
                });
            })

            expect(function()
                Rosyn.AwaitComponentInit(Inst, Test)
            end).to.throw("threw an error")
        end)

        it("should return the component if Initial completed successfully", function()
            local Test = MakeClass()

            function Test:Initial()
                task.wait(0.1)
            end

            local Inst = MakeTestInstance({"InitialSuccess1"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    InitialSuccess1 = {Test};
                });
            })

            local Component = Rosyn.AwaitComponentInit(Inst, Test)
            expect(Component).to.be.ok()
            expect(Component).to.equal(Rosyn.GetComponent(Inst, Test))
        end)

        it("should timeout if the component was not added to the Instance on time", function()
            local Test = MakeClass()
            local Inst = MakeTestInstance({"InstanceTimeout1"}, Workspace)

            expect(function()
                Rosyn.AwaitComponentInit(Inst, Test, 0.1)
            end).to.throw("on time")
        end)

        it("should throw an error if the component is removed while it is initializing", function()
            local Test = MakeClass()

            function Test:Initial()
                task.wait(0.5)
            end

            local Inst = MakeTestInstance({"InstanceRemoved1"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    InstanceRemoved1 = {Test};
                });
            })

            task.delay(0.1, function()
                Inst:Destroy()
            end)

            expect(function()
                Rosyn.AwaitComponentInit(Inst, Test, 0.2)
            end).to.throw("removed")
        end)

        it("should throw an error if the Initial thread has already thrown", function()
            local Test = MakeClass()

            function Test:Initial()
                error("Test error")
            end

            local Inst = MakeTestInstance({"InitialError1"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    InitialError1 = {Test};
                });
            })

            task.wait()

            expect(function()
                Rosyn.AwaitComponentInit(Inst, Test)
            end).to.throw("threw an error")
        end)

        it("should throw an error if the Initial thread has already timed out", function()
            local Test = MakeClass()
            Test.Options = {
                InitialTimeout = 0.1;
            }

            function Test:Initial()
                task.wait(0.5)
            end

            local Inst = MakeTestInstance({"InitialError2"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    InitialError2 = {Test};
                });
            })

            task.wait(0.2)

            expect(function()
                Rosyn.AwaitComponentInit(Inst, Test)
            end).to.throw("timed out")
        end)

        it("should not terminate all Async-spawned threads from the Initial thread on timeout", function()
            local Test = MakeClass()
            Test.Options = {
                InitialTimeout = 0;
            }

            local Stage
            local Thread

            function Test:Initial()
                Async.Spawn(function()
                    Thread = coroutine.running()
                    Stage = 1
                    task.wait()
                    task.wait()
                    Stage = 2
                end)
            end

            MakeTestInstance({"AsyncNoTerminate"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    AsyncNoTerminate = {Test};
                });
            })

            expect(Stage).to.equal(1)
            expect(coroutine.status(Thread)).to.equal("suspended")
            task.wait()
            task.wait()
            expect(Stage).to.equal(2)
            expect(coroutine.status(Thread)).to.equal("dead")
        end)
    end)

    describe("Component.Destroy", function()
        it("should fire after Initial thread yielding", function()
            local DidDestroy = false
            local Test = MakeClass()

            function Test:Initial()
                task.wait(0.2)
            end

            function Test:Destroy()
                DidDestroy = true
            end

            local Inst = MakeTestInstance({"DestroySequence1"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    DestroySequence1 = {Test};
                });
            })

            Inst:Destroy()
            expect(DidDestroy).to.equal(false)
            task.wait(0.2)
            expect(DidDestroy).to.equal(true)
        end)

        it("should fire after Initial thread throwing", function()
            local DidDestroy = false
            local Test = MakeClass()

            function Test:Initial()
                error("Test")
            end

            function Test:Destroy()
                DidDestroy = true
            end

            local Inst = MakeTestInstance({"DestroySequence2"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    DestroySequence2 = {Test};
                });
            })

            Inst:Destroy()
            expect(DidDestroy).to.equal(true)
        end)

        it("should fire after Initial thread success", function()
            local DidDestroy = false
            local Test = MakeClass()

            function Test:Initial()
            end

            function Test:Destroy()
                DidDestroy = true
            end

            local Inst = MakeTestInstance({"DestroySequence3"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    DestroySequence3 = {Test};
                });
            })

            Inst:Destroy()
            expect(DidDestroy).to.equal(true)
        end)

        it("should terminate all Async-spawned threads from the Initial thread on destroy", function()
            local Test = MakeClass()
            local Stage
            local Thread

            function Test:Initial()
                Async.Spawn(function()
                    Thread = coroutine.running()
                    Stage = 1
                    task.wait(0.1)
                    Stage = 2
                end)
            end

            local Inst = MakeTestInstance({"DestroyAsyncTerminate"}, Workspace)

            Rosyn.Register({
                Components = Rosyn.Setup.Tags({
                    DestroyAsyncTerminate = {Test};
                });
            })

            expect(Stage).to.equal(1)
            expect(coroutine.status(Thread)).to.equal("suspended")
            Inst:Destroy()
            task.wait(0.1)
            expect(Stage).to.equal(1)
            expect(coroutine.status(Thread)).to.equal("dead")
        end)
    end)

    describe("Rosyn.Register + Children", function()
        it("should register components on children", function()
            local Test = MakeClass()
            local Inst = MakeTestInstance({}, Workspace)
            local Child1 = MakeTestInstance({}, Inst)

            Rosyn.Register({
                Components = Rosyn.Setup.Children(Inst, Test);
            })

            expect(Rosyn.GetComponent(Child1, Test)).to.be.ok()

            local Child2 = MakeTestInstance({}, Inst)
            expect(Rosyn.GetComponent(Child2, Test)).to.be.ok()
        end)

        it("should call Destroy on destroyed Instances", function()
            local Test = MakeClass()
            local Destroyed = {}

            function Test:Destroy()
                Destroyed[self.Root] = true
            end

            local Inst = MakeTestInstance({}, Workspace)
            local Child1 = MakeTestInstance({}, Inst)

            Rosyn.Register({
                Components = Rosyn.Setup.Children(Inst, Test);
            })

            expect(Destroyed[Child1]).to.never.be.ok()
            Child1:Destroy()
            expect(Destroyed[Child1]).to.be.ok()

            local Child2 = MakeTestInstance({}, Inst)
            expect(Destroyed[Child2]).to.never.be.ok()
            Inst:Destroy()
            expect(Destroyed[Child2]).to.be.ok()
        end)
    end)

    describe("Rosyn.Register + Descendants", function()
        it("should register components on descendants", function()
            local Test = MakeClass()
            local Inst = MakeTestInstance({}, Workspace)
                local Child1 = MakeTestInstance({}, Inst)
                    local Child2 = MakeTestInstance({}, Child1)

            Rosyn.Register({
                Components = Rosyn.Setup.Descendants(Inst, Test);
            })

            expect(Rosyn.GetComponent(Child1, Test)).to.be.ok()
            expect(Rosyn.GetComponent(Child2, Test)).to.be.ok()

            local Child3 = MakeTestInstance({}, Child2)
            expect(Rosyn.GetComponent(Child3, Test)).to.be.ok()
        end)

        it("should call Destroy on destroyed Instances", function()
            local Test = MakeClass()
            local Destroyed = {}

            function Test:Destroy()
                Destroyed[self.Root] = true
            end

            local Inst = MakeTestInstance({}, Workspace)
                local Child1 = MakeTestInstance({}, Inst)
                    local Child2 = MakeTestInstance({}, Child1)

            Rosyn.Register({
                Components = Rosyn.Setup.Descendants(Inst, Test);
            })

            local Child3 = MakeTestInstance({}, Child2)
            expect(Destroyed[Child3]).to.never.be.ok()
            Child3:Destroy()
            expect(Destroyed[Child3]).to.be.ok()

            expect(Destroyed[Child2]).to.never.be.ok()
            Child2:Destroy()
            expect(Destroyed[Child2]).to.be.ok()

            expect(Destroyed[Child1]).to.never.be.ok()
            Child1:Destroy()
            expect(Destroyed[Child1]).to.be.ok()
        end)
    end)
end