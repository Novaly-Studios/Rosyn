declare class ComponentInstance extends ComponentClass {
}

export abstract class ComponentClass {
    constructor(root: Instance)
    
    Type: string
    Initial: () => void
    Destroy: () => void
}

export declare namespace Rosyn {
    
    /**
     * Attempts to get a unique ID from the component class or instance passed. A Type field in all
     * @param component The component or instance to get the name of
     * @returns The name of the given component class or component instance
     */
    export function GetComponentName(component: ComponentClass | Instance): string

    /**
     * Registers component(s) to be automatically associated with instances with a certain tag.
     * 
     * @param tag The CollectionService tag for the component to be applied to
     * @param components Array of ComponentClasses for the tag to be applied to
     * @param ancestorTarget The ancestor that the Rosyn checks for Instances with the given tag
     */
    export function Register(tag: string, components: [ComponentClass], ancestorTarget: Instance): void

    /**
     * 
     * @param object The instance to get the component from
     * @param componentClass The component class
     */
    export function GetComponent(object: Instance, componentClass: ComponentClass): ComponentInstance

    /**
     * Waits for a component instance's construction on a given Instance and returns it. 
     * Throws errors for timeout and target 
     * Instance deparenting to prevent memory leaks.
     * 
     * @param object 
     * @param componentClass 
     * @param timeout 
     */
    export function AwaitComponent(object: Instance, componentClass: ComponentClass, timeout?: number): void | ComponentInstance

    /**
     * Waits for a component instance's asynchronous Initial method to complete and returns it. 
     * Throws errors for timeout and target 
     * Instance deparenting to prevent memory leaks.
     * 
     * @param object 
     * @param componentClass 
     * @param timeout 
     */
    export function AwaitComponentInit(object: Instance, componentClass: ComponentClass, timeout?: number): void | ComponentInstance
    
    /**
     * Obtains a component instance from an Instance or any of its ascendants.
     * 
     * @param object 
     * @param componentClass 
     */
    export function GetComponentFromDescendant(object: Instance, componentClass: ComponentClass): void | ComponentInstance

    /**
     * 
     * @param componentClass
     * @returns A map of all Instances of a particular class. 
     */
    export function GetInstancesOfClass(componentClass: ComponentClass): Map<Instance, boolean>

    /**
     * 
     * @param componentClass
     * @returns A map of all components of a particular class. 
     */
    export function GetComponentsOfClass(componentClass: ComponentClass): Map<ComponentInstance, boolean>
    
    /**
     * 
     * @param object 
     * @returns All components of any class which are associated to a specific Instance.
     */
    export function GetComponentsFromInstance(object: Instance): Map<ComponentClass, ComponentInstance>
}