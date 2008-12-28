/*
* Copyright (C) 2008 Chase Kernan
* Email: chase.kernan@gmail.com
* 
* This program is free software: you can redistribute it and/or modify
* it under the terms of the GNU Lesser General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
* 
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU Lesser General Public License for more details.
* 
* You should have received a copy of the GNU Leeser General Public License
* along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

package fscript;

#if flash9

import format.abc.Data;
import format.abc.Context;
import format.abc.Writer;
import format.swf.Data;
import format.swf.Writer;
import hscript.Expr;
import flash.events.Event;

/**
* A local variable can either be just an identifier or a parameter (stored 
* in registers);
*/
enum Local {
    Param(reg : Int);
    Ident(realName : String);
}

/**
* The locals defined inside of a block.
*/
typedef Block = Hash<Local>;

/**
* The information needed to create a function closure.
*/
typedef SavedFunction = {
    var e : Expr;
    var blockState : List<Block>;
};

/**
* A replacement for the [Interp] class in the hscript library. Instead of 
* interpreting the program, it is instead compiled to flash AVM2 assembly code.
*/
class FInterp {
    
    /**
    * The class name used for the compiled code. 
    * 
    * DO NOT USE THIS VALUE AS A VARIABLE OR FUNCTION NAME.
    */
    public static var CLASS_NAME        = "FINTERP__";
    
    /**
    * The name used for the function that retrieves an iterator.
    * 
    * DO NOT USE THIS VALUE AS A VARIABLE OR FUNCTION NAME.
    */
    public static var GET_ITER_NAME     = "__finterp__getIter";
    
    /**
    * The name used for the function that handles try/catch blocks.
    * 
    * DO NOT USE THIS VALUE AS A VARIABLE OR FUNCTION NAME.
    */
    public static var TRY_CATCH_NAME     = "__finterp__tryCatch";
    
    /**
    * The name used for the execute function.
    * 
    * DO NOT USE THIS VALUE AS A VARIABLE OR FUNCTION NAME.
    */
    public static var EXECUTE_NAME      = "__finterp__execute";
    
    /**
    * The name used for an iterator expression.
    * 
    * DO NOT USE THIS VALUE AS A VARIABLE OR FUNCTION NAME.
    */
    public static var ITERATOR_NAME     = "__finterp__iterator";
    
    /**
    * The name used for an unnamed function.
    * 
    * DO NOT USE THIS VALUE AS A VARIABLE OR FUNCTION NAME.
    */
    public static var FUNCTION_NAME     = "__finterp__function";
    
    /**
    * The name used prepend a new variable inside of a block.
    * 
    * DO NOT USE THIS VALUE AS A VARIABLE OR FUNCTION NAME.
    */
    public static var BLOCK_VAR_NAME    = "__finterp__block";
    
    /**
    * The number of times that [FInterp::execute] has been called.
    * Used in the naming of the generated class.
    */
    private static var FINTERP_INSTANCES = 0;
    
    /**
    * The outside variables that the compiled program can access.
    */
    public var variables        : Hash<Dynamic>;
    
    /**
    * The current stack size.
    */
    public var stack           : Int;
    
    /**
    * The hxasm context for the compiler.
    */
    private var context         : Context;
    
    /**
    * The main execution method.
    */
    private var method          : Function;
    
    /**
    * Corresponds to [FINTERP_INSTANCES].
    * Used in the naming of the generated class.
    */
    private var instanceNum     : Int;
    
    /**
    * The maximum stack size of the currrent method.
    */
    private var maxStack        : Int;
    
    /**
    * The public namespace.
    * 
    * By default, all variables are public
    */
    private var pub             : Index<Namespace>;
    
    /**
    * The list of loop managers (acts as a stack).
    * 
    * Allows for loops inside of loops.
    */
    private var loopManagers    : List<LoopManager>;
    
    /**
    * The list of functions defined in the body of the program.
    */
    private var funcs           : List<SavedFunction>;
    
    /**
    * The total number of functions defined inside the body of the program.
    * 
    * NOTE: This differs from [funcs.length].
    */
    private var numFuncs        : Int;
    
    /**
    * The locals of the program structured as a stack to emulate haXe blocks.
    */
    private var blocks          : List<Block>;
    
    /**
    * The number of blocks used so far.
    * 
    * Used to maintain unique identifiers.
    */
    private var blockCount      : Int;
    
    /**
    * The top-most block of the program.
    */
    private var firstBlock      : Block;
    
    /**
    * The name of the current FInterp-compiled class.
    */
    private var className       : String;
    
    /**
    * The internal function currently being compiled.
    * 
    * Null if the compiler is in the main block.
    */
    private var curFunc         : SavedFunction;
    
    /**
    * The block of variables associated with the current function.
    * 
    * Null if the compiler is in the main block.
    */
    private var curFuncBlock    : Block;
    
    /**
    * Creates a new FInterp instance.
    * 
    * This also sets the default variables to include [trace] and [IntIter].
    */
    public function new() {
        resetVariables();
    }
    
    /**
    * Resets the variables to their default values.
    * 
    * Default values include [trace] and [IntIter].
    */
    public function resetVariables() {
        variables   = new Hash();
        var me      = this;
        
        variables.set("trace",
            function(e) {
                var info = {fileName : "fscript", lineNumber : 0};
                haxe.Log.trace(Std.string(e), cast info);
            }
        );
        
        variables.set("IntIter", IntIter);
        
        variables.set(GET_ITER_NAME,
            function(obj : Dynamic) {
                if (Std.is(obj, Array)) {
                    return obj.iterator(); //need this separately
                }
                
                return untyped 
                    if (!Reflect.hasField(obj, "iterator")) obj
                    else                                    obj.iterator();
            }
        );
        
        variables.set(TRY_CATCH_NAME,
            function(tryFunc : Dynamic, args : Array<Dynamic>, 
                     catchFunc : Dynamic -> Void) : Dynamic {
                var c   = Type.resolveClass(me.className);
                
                try {
                    return Reflect.callMethod(c, tryFunc, args);
                } catch (e : Dynamic) {
                    return Reflect.callMethod(c, catchFunc, [e]);
                }
            }
        );
    }
    
    /**
    * Executes the given expression (usually parsed by [hscript.Parser]).
    * 
    * The last evaluated value is passed to the [onComplete] function when the
    * flash player finishes loading the compiled byte code.
    * 
    * NOTE: The variables are not reset between calls to [execute]. To reset 
    * them to their default values, call [resetVariables].
    */
    public function execute(e : Expr, onComplete : Dynamic -> Void) {
        blocks          = new List();
        blockCount      = 0;
        
        firstBlock      = enterBlock();

        for (variable in variables.keys()) {
            firstBlock.set(variable, Ident(variable));
        }
        
        loopManagers    = new List();
        funcs           = new List();
        numFuncs        = 0;
        
        instanceNum     = FINTERP_INSTANCES++;
        className       = CLASS_NAME + Std.string(instanceNum);
        
        context         = new Context();
		var interpClass = context.beginClass(className);
        interpClass.namespace = context.nsPublic;
        
        method          = context.beginMethod(EXECUTE_NAME, [],
                                              context.type("Object"), true);
        pub             = context.nsPublic;
        maxStack        = 1;
        stack           = 0;
        
        exprReturn(e);
        
        method.maxStack = maxStack;
        context.endMethod();
        
        //handle all of the functions defined in the program
        while (funcs.length > 0) {
            curFunc = funcs.pop();
            handleFunction(curFunc);
        }
        
        context.finalize();
        var as3Bytes    = new haxe.io.BytesOutput();
        format.abc.Writer.write(as3Bytes, context.getData());
        
        var out         = new haxe.io.BytesOutput();
        var swfWriter   = new format.swf.Writer(out);
        swfWriter.writeHeader({ version : 9, compressed : false, width : 400, 
                                height : 300, 
                                fps : format.swf.Tools.toFixed8(30), 
                                nframes : 1 });
                                
        swfWriter.writeTag(TSandBox(25));
        swfWriter.writeTag(TActionScript3(as3Bytes.getBytes()));
        swfWriter.writeTag(TShowFrame);
        swfWriter.writeEnd();
        
        var loader      = new flash.display.Loader();
        var me          = this;
        loader.contentLoaderInfo.addEventListener(Event.COMPLETE, 
            function(_) {
                var domain  = loader.contentLoaderInfo.applicationDomain;
                var c       = domain.getDefinition(me.className);
                
                for (v in me.variables.keys()) {
                    Reflect.setField(c, v, me.variables.get(v));
                }
                
                onComplete(Reflect.field(c, EXECUTE_NAME)());
            }
        );
        
        loader.loadBytes(out.getBytes().getData());
	}
    
    /**
    * Enters a new block and returns the hash of locals.
    */
    function enterBlock() : Block {
        blockCount++;
        
        var block = new Hash<Local>();
        blocks.push(block);
        return block;
    }
    
    /**
    * Exits the current block and moves up the chain of locals.
    */
    function exitBlock() {
        blocks.pop();
    }
    
    /**
    * Makes a structual copy of a list (ie it does not copy the elements
    * themselves, just the list structure).
    */
    function copy<T>(list : List<T>) : List<T> {
        var c = new List<T>();
        for (elem in list) c.push(elem);
        return c;
    }
    
    /**
    * Returns the local definition with the given name.
    * 
    * This searches from the "lowest" block up to the "highest."
    * 
    * Throws an error if no such local exists or if a function tries to 
    * access another functions parameters.
    */
    function getLocal(name : String) : Local {
        for (block in blocks) {
            if (block.exists(name)) {
                var local   = block.get(name);
                
                if (curFunc != null && block != curFuncBlock) {
                    return switch(local) {
                        case Ident(_):  local;
                        case Param(_):
                            throw "Cannot access " + name + ". Cannot access" +
                                  "a different functions parameter's while " + 
                                  "inside of another function.";
                    };
                }
                
                return local;
            }
        }
        
        throw "No such local: " + name;
    }
    
    /**
    * Creates a new local at the current block level.
    * 
    * If [param] isn't supplied (default value of -1), then the local is an 
    * identifier, and a new mangled name is returned inside of an [Ident] enum.
    * Otherwise if the param register [param] is given, then [Param(param)] is
    * returned.
    */
    function addLocal(name : String, param = -1) : Local {
        var local = 
                if (param == -1)    Ident(BLOCK_VAR_NAME + blockCount + name)
                else                Param(param);
        blocks.first().set(name, local);
        
        return local;
    }
    
    /**
    * Evaluates the expression and returns the last value or null if no such 
    * value exists.
    * 
    * Decreases the stack by 1.
    */
    function exprReturn(e : Expr) {
        expr(e);
        
        if (stack < 1) context.op(ONull);
        
        context.op(ORet);
        decStack();
    }
    
    /**
    * Increases the stack size by [amount].
    * 
    * If the stack size is greater than the maximum stack size, then the
    * maximum stack size is set to the current stack size.
    * 
    * [amount] defaults to 1.
    */
    function incStack(amount = 1) {
        stack += amount;
        if (stack > maxStack) maxStack = stack;
    }
    
    /**
    * Decreases the stack size by [amount].
    * 
    * NOTE: If amount is less than 0, then [incStack] is called with the
    * positive value of amount.
    * 
    * [amount] defaults to 1.
    */
    function decStack(amount = 1) {
        incStack(-amount);
    }
    
    /**
    * Ensures that the stack is [amount] greater than [relativeTo].
    * 
    * If the stack size is greater than [relativeTo], then successive [OPop]
    * operations are called until its the correct size. If its less than
    * [relativeTo] then [null] values are added to the stack.
    * 
    * [adjust] defaults to true. If adjust is false, then the recorded stack
    * size value isn't changed, even though [OPop] or [ONull]'s are added. This
    * is useful for breaks and continues.
    */
    function setStackTo(amount : Int, relativeTo : Int, adjust = true) {
        if (stack > relativeTo) {
            
            for (i in amount...(stack - relativeTo)) {
                if (stack > 1)  context.ops([OSwap, OPop]);
                else            context.op(OPop);
                
                if (adjust)     stack--;
            }
            
        } else {
            
            for (i in -amount...(relativeTo - stack)) context.op(OInt(0));
                    
            if (adjust) incStack(relativeTo - stack + amount);
            
        }
    }
    
    /**
    * Evaluates the expression and all (if any) of its children.
    */
    function expr(e : Expr) {
        switch (e) {
            
            /**
            * Evaluates a constant.
            * 
            * Increases the stack by 1.
            */
            case EConst(c):
                incStack();
                
                switch(c) {
                    case CInt(v):       context.op(OInt(v));
                    case CFloat(f):     context.op(OFloat(context.float(f)));
                    case CString(s):    context.op(OString(context.string(s)));
                }
            
            /**
            * Puts the variable with name [id] on top of the stack.
            * 
            * Increases the stack by 1.
            */
            case EIdent(id):
                incStack();
                
                switch (id) {
                    case "true":    context.op(OTrue);
                    case "false":   context.op(OFalse);
                    case "null":    context.op(ONull);
                    
                    default:
                        
                        switch (getLocal(id)) {
                            
                            case Ident(n):
                                context.op(OThis);
                                incStack();
                                
                                var ref     = NName(context.string(n), pub);
                                var name    = context.name(ref);
                                context.op(OGetProp(name)); 
                                decStack();
                                
                            case Param(reg):
                                context.op(OReg(reg));
                                
                        }
                }
            
            /**
            * Creates the variable [n] with the value [e].
            * 
            * Has no effect on the stack.
            */
            case EVar(n,e):
                context.op(OThis);
                incStack();
                
                expr(e);
                
                var realName = switch(addLocal(n)) {
                    case Ident(rn):     rn;
                    default:            throw "Expecting Ident";
                }
                
                var ref     = NName(context.string(realName), pub);
                var name    = context.name(ref);
                context.op(OSetProp(name));
                decStack(2);
            
            /**
            * Evaluates [e].
            */
            case EParent(e):
                expr(e);
            
            /**
            * Evaluates every given expression, but only keeps the last one on
            * top of the stack.
            * 
            * TODO: Handle scope
            * 
            * Increases the stack by 1.
            */
            case EBlock(exprs):
                enterBlock();
                
                var initStack = stack;
                for (e in exprs) expr(e);
                
                setStackTo(1, initStack);
                exitBlock();
                
            /**
            * Places the field [f] of [e] on top of the stack.
            * 
            * Increases the stack by 1.
            */
            case EField(e,f):
                expr(e);
                
                var ref     = NName(context.string(f), pub);
                var name    = context.name(ref);
                context.op(OGetProp(name));
                
            /**
            * Handles every operation taking 2 values.
            * 
            * NOTE: The "and" (&&) and "or" (||) operations evaluate the second
            * expression only if its neccessary.
            * 
            * Increases the stack by 1.
            */
            case EBinop(op,e1,e2):
                switch(op) {
                    case "||":      handleOr(e1, e2);
                    case "&&":      handleAnd(e1, e2);
                    case "=":       assign(e1, e2);
                    
                    case "...":     expr(ENew("IntIter", [e1, e2]));
                    
                    case "+=":      handleAssignBinop("+", e1, e2);
                    case "-=":      handleAssignBinop("-", e1, e2);
                    case "*=":      handleAssignBinop("*", e1, e2);
                    case "/=":      handleAssignBinop("/", e1, e2);
                    case "%=":      handleAssignBinop("%", e1, e2);
                    case "^=":      handleAssignBinop("^", e1, e2);
                    case "&=":      handleAssignBinop("&", e1, e2);
                    case "|=":      handleAssignBinop("|", e1, e2);
                    case "<<=":     handleAssignBinop("<<", e1, e2);
                    case ">>=":     handleAssignBinop(">>", e1, e2);
                    case ">>>=":    handleAssignBinop(">>>", e1, e2);
                        
                    default:
                        expr(e1);
                        expr(e2);
                        handleBinop(op);
                }
            
            /**
            * Handles every unary operator.
            * 
            * See [incDec] for the "++" and "--" operators.
            * 
            * Increases the stack by 1.
            */
            case EUnop(op,prefix,e):
                if (op == "++" || op == "--") incDec(op, prefix, e);
                else {
                    expr(e);
                
                    context.op(OOp(switch(op) {
                        case "!":   OpNot;
                        case "-":   OpNeg;
                        case "~":   OpBitNot;
                        
                        default:    throw "Unknown unop: " + op;
                    }));    
                }
             
            /**
            * Calls the function given in expression [e] with the given 
            * [params].
            * 
            * Increases the stack by 1.
            */
            case ECall(e, params):
                expr(e);
                
                switch(e) {
                    //if the function belongs to another object, the caller
                    //needs to be that object
                    case EField(oe,f): expr(oe);
                    
                    //otherwise its the "this" object
                    default: 
                        context.op(OThis);
                        incStack();
                }
                
                for (param in params) expr(param);
            
                context.op(OCallStack(params.length));
                decStack(1 + params.length);
                
            /**
            * Recreates an "if" structure by evaluating [econd].
            * 
            * If [e2] is provided, then it acts as an if-else construct
            * and will return a given by either the first or the second block.
            * 
            * If [e2] isn't provided, the stack remains the same, otherwise the
            * stack is increased by 1.
            */
            case EIf(econd, e1, e2):
                //TODO: cleanup
                //most of the messiness in here is a result of the type coercions
                //that flash requires as well as the need to balance the stacks
                //when jumping.
                
                if (e2 != null) {
                    if (stack != 0) context.op(OAsAny);
                    
                    context.op(OObject(0));
                    incStack();
                }
            
                expr(econd);
                var jumpIf          = context.jump(JFalse);
                decStack();
                
                if (e2 != null) {
                    context.op(OPop);
                    decStack();
                }
                
                var initStack       = stack;
                
                expr(e1);
                
                setStackTo(if (e2 == null) 0 else 1, initStack);
                
                if (e2 != null) {
                    context.op(OAsAny);
                    
                    var jumpElse    = context.jump(JAlways);
                    jumpIf();
                    
                    context.op(OPop);
                    decStack();
                    
                    var initStack = stack;
                    
                    expr(e2);
                    
                    setStackTo(1, initStack);
                    context.op(OAsAny);
                    
                    jumpElse();
                } else {
                    jumpIf();
                }
            
            
            /**
            * Creates a while construct similar to [while(econd) e].
            * 
            * Each loop adds another loopManager to the [loopManagers] stack
            * so that loops within loops are possible and breaks/continues 
            * correspond to the correct loops.
            * 
            * This has no effect on the stack size when completed.
            */
            case EWhile(econd,e):
                enterBlock();
                
                var manager = new LoopManager(context, this);
                loopManagers.push(manager);
                
                expr(econd);
                manager.addForwardJump(JFalse);
                decStack();
                
                manager.startLoop();
                
                expr(e);
                
                setStackTo(0, manager.initStack);
                manager.addBackwardJump(JAlways);
                
                manager.finalize();
                loopManagers.remove(manager);
                
                exitBlock();
            
            /**
            * Breaks the loop in which the statement was found.
            * 
            * Resets the stack to its size before the while loop. 
            */
            case EBreak:
                var lm = loopManagers.first();
                setStackTo(0, lm.initStack, false);
                lm.addForwardJump(JAlways);
                
            /**
            * Immeadiately evaluates the next iteration of a while loop.
            * 
            * Resets the stack to its size before the while loop.
            */
            case EContinue:
                var lm = loopManagers.first();
                setStackTo(0, lm.initStack, false);
                lm.addBackwardJump(JAlways);
            
            /**
            * Evaluates a haXe style for loop.
            * 
            * Internally uses a while loop to loop through the given iterator.
            * 
            * Has no effect on the stack size when completed.
            */
            case EFor(n,it,e):
                var itName = ITERATOR_NAME + n;
                
                /*expr(EVar(itName, 
                    EIf(ECall(EField(it, "hasOwnProperty"), 
                                         [EConst(CString("iterator"))]),
                        ECall(EField(it, "iterator"), []),
                        it)));
                */
                expr(EVar(itName, ECall(EIdent(GET_ITER_NAME), [it])));
                
                expr(EWhile(
                    ECall(EField(EIdent(itName), "hasNext"), []),
                    
                    EBlock([EVar(n, ECall(EField(EIdent(itName), "next"), [])),
                            e])
                ));
            
            /**
            * Adds a new instance of the given class [c] to the stack.
            * 
            * If the given name [c] doesn't exist in [variables] then this 
            * tries to look for it using [Type.resolveClass].
            * 
            * The [params] are passed to the constructor function.
            * 
            * Increases the stack by 1.
            */
            case ENew(c,params):
                if (!variables.exists(c)) {
                    variables.set(c, Type.resolveClass(c));
                    firstBlock.set(c, Ident(c));
                }
                expr(EIdent(c));
                
                for (e in params) expr(e);
                
                context.op(OConstruct(params.length));
                decStack(params.length);
            
            /**
            * Returns from a function.
            * 
            * If [e] isn't provided, then the [ORetVoid] op code is added,
            * otherwise it evaluates and returns [e].
            * 
            * This has no effect on the stack size.
            */
            case EReturn(e):
                if (e == null) context.op(ORetVoid);
                else {
                    expr(e);
                    context.op(ORet);
                    decStack();
                }
                
            /**
            * Adds an array containing [arr] elements to the top of the stack.
            * 
            * Increases the stack size by 1.
            */
            case EArrayDecl(arr):
                for (e in arr) expr(e);
                context.op(OArray(arr.length));
                decStack(arr.length - 1);
                
            /**
            * Accesses [index] of array [e].
            * 
            * Increases the stack size by 1.
            */
            case EArray(e, index):
                expr(e);
                expr(index);
                
                context.op(OGetProp(context.arrayProp));
                decStack(1);
            
            /**
            * Creates a new function with params [params] and body [fe]. If a
            * name isn't supplied it's named [FUNCTION_NAME + numFuncs].
            * 
            * The function's body isn't evaluated right away, but instead 
            * defered until the main execution function is completed.
            */
            case EFunction(params, fe, name):
                if (name != null) {
                    for (func in funcs) {
                        
                        var fname = switch (func.e) {
                            
                            case EFunction(_, _, name): name;
                            default:                    null;
                            
                        };
                        
                        if (fname == name) {
                            expr(EIdent(name));
                            return;
                        } 
                    }
                }
            
                var n = if (name == null) FUNCTION_NAME + numFuncs
                           else name;
                           
                firstBlock.set(n, Ident(n));
                
                expr(EIdent(n));
                funcs.add( { e          : EFunction(params, fe, n),
                             blockState : copy(blocks) } );
                
                
            
            /**
            * Evaluates and throw's [e].
            * 
            * Has no effect on the stack size.
            */
            case EThrow(e):
                expr(e);
                context.op(OThrow);
                decStack();
                
            /**
            * Handles a try/catch block through an external haXe function.
            * 
            * Increases the stack by 1.
            */
            case ETry(te, n,ecatch):
                var tryName     = "try" + FUNCTION_NAME + numFuncs++;
                var catchName   = "catch" + FUNCTION_NAME + numFuncs++;
                
                var params      = if (curFunc == null) [] else {
                    switch (curFunc.e) {
                        case EFunction(p, _, _):   p;
                        default:                        
                            throw "Should be EFunction.";
                    }
                };
                
                var tryFunc     = EFunction(params, te, tryName);
                var catchFunc   = EFunction([n], ecatch, catchName);
                
                var exprParams  = new Array<Expr>();
                for (param in params) exprParams.push(EIdent(param));
                
                expr(ECall(EIdent(TRY_CATCH_NAME), 
                           [tryFunc, EArrayDecl(exprParams), catchFunc]));
            
            default: 
                throw "Not supported: " + e;
        }
    }
    
    /**
    * Performs the simple op [op] on [e1] and [e2], then assigns the
    * result to [e1].
    * 
    * Increases the stack by 1 (after the operation is complete, [e1] is left
    * on top of the stack).
    */
    function handleAssignBinop(op, e1, e2) {
        expr(EBinop(op, e1, e2));
        
        context.op(ODup);
        incStack();
        
        assignTopTo(e1);
    }
    
    /**
    * Performs operation [op] on the 2 uppermost elements of the stack.
    * 
    * Decreases the stack by 1.
    */
    function handleBinop(op) {
        context.op(OOp(switch (op) {
                
            case "+":       OpAdd;
            case "-":       OpSub;
            case "*":       OpMul;
            case "/":       OpDiv;
            case "%":       OpMod;
            case "&":       OpAnd;
            case "|":       OpOr;
            case "^":       OpXor;
            case "<<":      OpShl;
            case ">>":      OpShr;
            case ">>>":     OpUShr; //is this right?
            case "==":      OpEq;
            
            case "!=": 
                context.op(OOp(OpEq));
                OpNot;
                
            case ">=":      OpGte;
            case "<=":      OpLte;
            case ">":       OpGt;
            case "<":       OpLt;
            
            default:        throw "Unknown operation: " + op;
        }));
        
        decStack();
    }
    
    /**
    * Performs a logical "or" operation on [e1] and [e2] and puts the returned
    * value on top of the stack.
    * 
    * The operation is short-circuited so that if [e1] evaluates to true, [e2]
    * isn't evaluated at all.
    * 
    * Increases the stack size by 1.
    */
    function handleOr(e1, e2) {
        incStack();
        context.op(OTrue);
        
        expr(e1);
        var jump = context.jump(JTrue);
        decStack();
        
        context.op(OPop);
        decStack();
        
        expr(e2);
        jump();
    }
    
    /**
    * Performs a logical "and" operation on [e1] and [e2] and puts the returned
    * value on top of the stack.
    * 
    * The operation is short-circuited so that if [e1] evaluates to false, [e2]
    * isn't evaluated at all.
    * 
    * Increases the stack size by 1.
    */
    function handleAnd(e1, e2) {
        incStack();
        context.op(OFalse);
        
        expr(e1);
        var jump = context.jump(JFalse);
        decStack();
        
        context.op(OPop);
        decStack();
        
        expr(e2);
        jump();
    }
    
    /**
    * Performs either a "++" or "--" operation (specified by [op]) on [e].
    * 
    * If [prefix] is true, then either [++e] or [--e] is performed, otherwise
    * either [e++] or [e--] is performed. See the haXe language reference for
    * the difference.
    * 
    * Has no effect on the stack size.
    */
    function incDec(op, prefix, e) {
        expr(e);
        
        context.op(ODup);
        incStack();
        
        var opCode = OOp(if (op == "++") OpIncr else OpDecr);
        
        context.op(opCode);
        
        if (prefix) {
            context.op(OSwap);
            context.op(opCode);
        }
        
        assignTopTo(e);
    }
    
    /**
    * Assigns [e2] to [e1] and then puts the updated value of [e1] on top of 
    * the stack.
    * 
    * Increases the stack size by 1.
    */
    function assign(e1, e2) {
        expr(e2);
        
        context.op(ODup);
        incStack();
        
        assignTopTo(e1);
    }
    
    /**
    * Assigns the value of top of the stack to [e].
    * 
    * Throws an error if [e] is not [EIdent], [EField], or [EArray].
    * 
    * Decreases the stack by 1.
    */
    function assignTopTo(e) {
        switch (e) {
            
            /**
            * Assigns the top to the local variable [id].
            */
            case EIdent(id):
                switch (getLocal(id)) {
                            
                    case Ident(n):
                        context.op(OThis);
                        incStack();
                        
                        context.op(OSwap);
                                
                        var ref     = NName(context.string(n), pub);
                        var name    = context.name(ref);
                        context.op(OSetProp(name)); 
                        decStack(2);
                                
                    case Param(reg):
                        context.op(OSetReg(reg));
                                
                }
                
            /**
            * Assigns the top to field [f] of object [oe].
            */
            case EField(oe,f):
                expr(oe);
                
                context.op(OSwap);
                
                var ref     = NName(context.string(f), pub);
                var name    = context.name(ref);
                context.op(OSetProp(name));
                decStack(2);
                
            /**
            * Assigns the top to index [index] of array [ae].
            */
            case EArray(ae,index):
                expr(ae);
                context.op(OSwap);
                
                expr(index);
                context.op(OSwap);
                
                context.op(OSetProp(context.arrayProp));
                decStack(3);
                
            default:
                throw "Cannot assign to: " + e;
        }
    }
    
    /**
    * Handles the function [func] defined inside of the program.
    * 
    * The return value and every paramter is specified to be of type [Object].
    * This also resets [stack] and [maxStack].
    * 
    * NOTE: The function should have already been assigned a name by [expr].
    */
    function handleFunction(func : SavedFunction) {
        switch(func.e) {
            
            case EFunction(params, fe, name):
                var obj         = context.type("Object");
                var targs       = new Array<Null<IName>>();
                
                for (param in params) targs.push(obj);
                
                var m           = context.beginMethod(name, targs, obj, true);
                maxStack        = 0;
                stack           = 0;
                pub             = context.nsPublic; //is this needed?
                
                var old         = copy(blocks);
                blocks          = func.blockState;
                curFuncBlock    = enterBlock();
                
                //registers 1 through [params.length] are params
                var register    = 1; 
                for (param in params) addLocal(param, register++);
                
                exprReturn(fe);
                
                exitBlock();
                blocks          = old;
                m.maxStack      = maxStack;
                context.endMethod();
            
            default: throw "Expecting function expression, got " + func.e;
        }
    }
    
}

/**
* Handles while loops.
*/
class LoopManager {
    
    /**
    * The stack size at the start of the loop.
    */
    public var initStack        : Int;
    
    /**
    * The current hxasm context.
    */
    private var context         : Context;
    
    /**
    * The function provided by [context] to perform a backwards jump to the 
    * beginning of the loop.
    */
    private var backJumper      : JumpStyle -> Void;
    
    /**
    * List of points where the loop should end (generally breaks).
    * 
    * [context] provides the function itself which is called when [finalize] is
    * called.
    */
    private var forwardJumps    : List<Void -> Void>;
    
    /**
    * The current instance of [FInterp].
    */
    private var instance        : FInterp;
    
    /**
    * Creates a new loop manager for [instance] with the given hxasm [context].
    */
    public function new(context, instance) {
        this.context = context;
        this.instance = instance;
        
        backJumper = context.backwardJump();
        forwardJumps = new List();
    }
    
    /**
    * To be called at the start of the loop body.
    * 
    * Sets [initStack] to [instance.stack].
    */
    public function startLoop() {
        initStack = instance.stack;
    }
    
    /**
    * Adds a jump to the start of the loop, using jump style [style].
    * 
    * Used for continues primarily.
    */
    public function addBackwardJump(style) {
        backJumper(style);
    }
    
    /**
    * Adds a jump to the end of the loop, using jump style [style].
    * 
    * Used for breaks primarily.
    */
    public function addForwardJump(style) {
        forwardJumps.push(context.jump(style));
    }
    
    /**
    * To be called after the loop body.
    * 
    * Correctly sets all of the forward jumps.
    */
    public function finalize() {
        for (jump in forwardJumps) jump();
    }
}

#end