/// Everything to do with functions.
module lumars.function_;

import bindbc.lua, lumars;

enum LuaFuncWrapperType
{
    isAliasFunc,
    isDelegate,
    isFunction
}

struct LuaVariadic 
{
    alias array this;
    LuaValue[] array;
}

struct LuaMultiReturn(T...)
{
    alias ValueTuple = T;
    alias values this;
    T values;

    this()(T values)
    {
        this.values = values;
    }
}

/++
 + Calls a `LuaFunc` or `LuaFuncWeak` in protected mode, which means an exception is thrown
 + if the function produces a LUA error.
 +
 + Notes:
 +  As with all functions that return a `LuaValue`, strings are copied onto the GC heap so are safe to
 +  copy around.
 +
 +  As with all functions that return a `LuaValue`, the "weak" variants of data types are never returned.
 +
 +  Calling this function on a `LuaFuncWeak` will permanently pop the function off the stack. This is because
 +  weak references don't have the ability to push their values.
 +
 + Params:
 +  results = The maximum number of results expected to be returned by the function.
 +            Any values that are not provided by the function are instead set to `LuaValue(LuaNil())`
 +
 + Returns:
 +  A static array of `LuaValue`s representing the values returned by the LUA function.
 + ++/
template pcall(size_t results)
{
    static if(results > 0)
    {
        LuaValue[results] pcall(LuaFuncT, Args...)(LuaFuncT func, Args args)
        {
            cast(void)func.push();

            static foreach(arg; args)
                func.lua.push(arg);

            if(func.lua.pcall(args.length, results, 0) != LuaStatus.ok)
            {
                const error = func.lua.get!string(-1);
                func.lua.pop(1);
                throw new Exception(error);
            }

            typeof(return) ret;
            static foreach(i; 1..results+1)
                ret[$-i] = func.lua.get!LuaValue(cast(int)-i);

            func.lua.pop(results);
            return ret;
        }
    }
    else
    {
        void pcall(LuaFuncT, Args...)(LuaFuncT func, Args args)
        {
            cast(void)func.push();

            static foreach(arg; args)
                func.lua.push(arg);

            if(func.lua.pcall(args.length, 0, 0) != LuaStatus.ok)
            {
                const error = func.lua.get!string(-1);
                func.lua.pop(1);
                throw new Exception(error);
            }
        }
    }
}

private mixin template LuaFuncFuncs()
{
    /++
     + Binds this lua function into a statically typed wrapper.
     +
     + Params:
     +  ReturnT = The singular return value (or void) produced by this function.
     +  Params  = The parameters that this function takes.
     + 
     + Returns:
     +  The statically typed wrapper.
     +
     + See_Also:
     +  `LuaBoundFunc`
     + ++/
    auto bind(alias ReturnT, Params...)()
    {
        auto bound = LuaBoundFunc!(typeof(this), ReturnT, Params).init;
        bound.func = this;
        return bound;
    }
}

/++
 + The struct used as the wrapper produced by the `LuaFunc.bind` and `LuaFuncWeak.bind` functions.
 +
 + This struct implements `opCall` so it can be used like a normal function.
 +
 + Params:
 +  LuaFuncT = Either `LuaFunc` or `LuaFuncWeak`.
 +  ReturnT  = The singular return value (or void) produced by this function.
 +  Params   = The parameters that this function takes.
 + ++/
struct LuaBoundFunc(alias LuaFuncT, alias ReturnT, Params...)
{
    /// The underlying function
    LuaFuncT func;

    /++
     + Allows this wrapper to be called like a normal function.
     +
     + Params:
     +  params = The parameters to pass through.
     +
     + Returns:
     +  Either nothing (`ResultT == void`) or the returned value, statically ensured to be of type `ReturnT`.
     + ++/
    ReturnT opCall(Params params)
    {
        static if(is(ReturnT == void))
            this.func.pcall!0(params);
        else
        {
            auto result = this.func.pcall!1(params)[0];
            this.func.lua.push(result);
            scope(exit) this.func.lua.pop(1);
            return this.func.lua.get!ReturnT(-1);
        }
    }

    /// Allows taking a pointer to the `opCall` function, so a LUA function can be passed around like a D one!
    alias asDelegate = opCall;
}

/++
 + A weak reference to a lua function that currently exists on the LUA stack.
 +
 + Notes:
 +  As with all weak references, while they're marginally more efficient, they're harder to use, and their
 +  pop and push functions are no-ops.
 + ++/
struct LuaFuncWeak 
{
    mixin LuaFuncFuncs;

    private
    {
        LuaState* _lua;
        int _index;
    }

    /++
     + Creates a new `LuaFuncWeak` that references a function at `index`.
     +
     + Throws:
     +  `Exception` if the value at `index` in the stack isn't a function.
     +
     + Params:
     +  lua   = The lua state to use.
     +  index = The index of the function.
     + ++/
    this(LuaState* lua, int index)
    {
        lua.enforceType(LuaValue.Kind.func, index);
        this._index = index;
        this._lua = lua;
    }

    /// This function is a no-op and exists to make generic code easier to write.
    ///
    /// Returns:
    ///  The index on the stack of the function being referenced.
    @safe @nogc 
    int push() nothrow pure const
    {
        return this._index;
    }

    /// This function is a no-op and exists to make generic code easier to write.
    void pop()
    {
        this.lua.enforceType(LuaValue.Kind.func, this._index);
    }

    /// Returns: The underlying `LuaState`.
    @property @safe @nogc
    LuaState* lua() nothrow pure
    {
        return this._lua;
    }
}

/++
 + A strong reference to a LUA function.
 +
 + Notes:
 +  This struct contains a ref-counted store used to keep track of both the `LuaState` as well as the table reference.
 +
 +  As with all strong references, the original value does not need to exist on the LUA stack, and this struct may be used
 +  to continously refer to the value. 
 + ++/
struct LuaFunc 
{
    import std.typecons : RefCounted;
    mixin LuaFuncFuncs;

    private
    {
        static struct State
        {
            LuaState* lua;
            int ref_;
            bool isWrapper;
            
            ~this()
            {
                if(this.lua && !this.isWrapper)
                    luaL_unref(this.lua.handle, LUA_REGISTRYINDEX, this.ref_);
            }
        }
        RefCounted!State _state;
    }

    /++
     + Creates a new `LuaFunc` using the function on the top of the LUA stack as the referenced value.
     + This function pops the original value off the stack.
     + ++/
    static LuaFunc makeRef(LuaState* lua)
    {
        lua.enforceType(LuaValue.Kind.func, -1);
        RefCounted!State state;
        state.lua = lua;
        state.ref_ = luaL_ref(lua.handle, LUA_REGISTRYINDEX);
        state.isWrapper = lua._isWrapper;

        return LuaFunc(state);
    }

    /++
     + Creates a new `LuaFunc` using the provided `func` as the referenced value.
     + ++/
    static LuaFunc makeNew(LuaState* lua, lua_CFunction func)
    {
        lua.push(func);
        return LuaFunc.makeRef(lua);
    }

    /++
     + Pushes the function onto the stack.
     +
     + Returns:
     +  The positive index of the pushed function.
     + ++/
    @nogc
    int push() nothrow
    {
        lua_rawgeti(this._state.lua.handle, LUA_REGISTRYINDEX, this._state.ref_);
        return this._state.lua.top;
    }
    
    /++
     + Pops the stack, ensuring that the top value is a function.
     + ++/
    void pop()
    {
        this._state.lua.enforceType(LuaValue.Kind.func, -1);
        this._state.lua.pop(1);
    }

    /// Returns: The underlying LUA state.
    LuaState* lua()
    {
        return this._state.lua;
    }
}

/++
 + The bare minimum wrapper needed to allow LUA to call a D function.
 +
 + Notes:
 +  Any throwables will instead be converted into a lua_error.
 +
 + Params:
 +  Func = The D function to wrap. This function must take a `LuaState*` as its only parameter, and it can optionally return an int
 +         to signify how many values it has returned.
 + ++/
int luaCWrapperBasic(alias Func)(lua_State* state) nothrow
{
    import std.exception : assumeWontThrow;
    import std.format : format;
    scope LuaState wrapper;

    try wrapper = LuaState(state);
    catch(Throwable ex) // @suppress(dscanner.suspicious.catch_em_all)
        return 0;

    try
    {
        static if(is(typeof(Func(&wrapper)) == int))
            return Func(&wrapper);
        else
        {
            Func(&wrapper);
            return 0;
        }
    }
    catch(Throwable e) // Can't allow any Throwable to execute normally as the backtrace code will crash. // @suppress(dscanner.suspicious.catch_em_all)
    {
        wrapper.error(format!"A D function threw an exception: %s"(e.msg).assumeWontThrow);
        return 0;
    }
}

/++
 + A higher level wrapper that allows most D functions to be naturally interact with LUA.
 +
 + This is your go-to wrapper as it's capable of exposing most functions to LUA.
 +
 + Notes:
 +  Any throwables will instead be converted into a lua_error.
 +
 +  The return value (if any) of `Func` will automatically be converted into a LUA value.
 +
 +  The parameters of `Func` will automatically be converted from the values passed by LUA.
 +
 +  `Func` may optionally ask for the lua state by specifying `LuaState*` as its $(B first) parameter.
 +
 +  `Func` may be made variadic by specifying `LuaVariadic` as its $(B last) parameter.
 +
 + Params:
 +  Func = The D function to wrap.
 +  Type = User code shouldn't ever need to set this, please leave it as the default.
 +
 + Example:
 +  `luaState.register!(std.path.buildPath!(string[]))("buildPath")`
 + ++/
extern(C)
int luaCWrapperSmart(alias Func, LuaFuncWrapperType Type = LuaFuncWrapperType.isAliasFunc)(lua_State* state) nothrow
{
    return luaCWrapperBasic!(
        luaCWrapperSmartImpl!(Func, Type)
    )(state);
}

private int luaCWrapperSmartImpl(
    alias Func,
    LuaFuncWrapperType Type = LuaFuncWrapperType.isAliasFunc
)(
    LuaState* lua
)
{
    import std.format : format;
    import std.traits : Parameters, ReturnType, isInstanceOf;
    import std.meta   : AliasSeq;

    alias Params = Parameters!Func;
    static if(Params.length)
        const ParamsLength =
            Params.length
            - (is(Params[0] == LuaState*) ? 1 : 0)
            - (is(Params[$-1] == LuaVariadic) ? 1 : 0);
    else
        const ParamsLength = 0;

    enum HasVariadic = Params.length > 0 && is(Params[$-1] == LuaVariadic);

    Params params;

    const argsGiven = lua.top();
    if(!HasVariadic && argsGiven != ParamsLength)
        throw new LuaArgumentException("Expected exactly %s args, but was given %s.".format(ParamsLength, argsGiven));
    else if(HasVariadic && argsGiven < ParamsLength)
        throw new LuaArgumentException("Expected at least %s args, but was given %s.".format(ParamsLength, argsGiven));
    
    static if(is(Params[0] == LuaState*))
    {
        params[0] = lua;
        static foreach(i; 0..ParamsLength)
            params[i+1] = lua.get!(Params[i+1])(i+1);
    }
    else
    {
        static foreach(i; 0..ParamsLength)
            params[i] = lua.get!(Params[i])(i+1);
    }

    static if(HasVariadic)
    foreach(i; 0..argsGiven-ParamsLength)
        params[$-1] ~= lua.get!LuaValue(cast(int)(i+ParamsLength+1));

    alias RetT = ReturnType!Func;

    static if(Type == LuaFuncWrapperType.isDelegate)
    {
        alias FuncWithContext = RetT function(Params, void*);

        auto context = lua_touserdata(lua.handle, lua_upvalueindex(1));
        auto func    = lua_touserdata(lua.handle, lua_upvalueindex(2));
        auto dFunc   = cast(FuncWithContext)func;
        
        static if(is(RetT == void))
        {
            dFunc(params, context);
            return 0;
        }
        else static if(isInstanceOf!(LuaMultiReturn, RetT))
        {
            auto multiRet = dFunc(params, context);
            static foreach(i; 0..multiRet.ValueTuple.length)
                lua.push(multiRet[i]);
            return multiRet.ValueTuple.length;
        }
        else static if(is(RetT == LuaVariadic))
        {
            auto multiRet = dFunc(params, context);
            foreach(value; multiRet)
                lua.push(value);
            return cast(int)multiRet.length;
        }
        else
        {
            lua.push(dFunc(params, context));
            return 1;
        }
    }
    else static if(Type == LuaFuncWrapperType.isFunction)
    {
        auto func = cast(Func)lua_touserdata(lua.handle, lua_upvalueindex(1));
        static if(is(RetT == void))
        {
            func(params);
            return 0;
        }
        else static if(isInstanceOf!(LuaMultiReturn, RetT))
        {
            auto multiRet = func(params);
            static foreach(i; 0..multiRet.ValueTuple.length)
                lua.push(multiRet[i]);
            return multiRet.ValueTuple.length;
        }
        else static if(is(RetT == LuaVariadic))
        {
            auto multiRet = func(params);
            foreach(value; multiRet)
                lua.push(value);
            return cast(int)multiRet.length;
        }
        else
        {
            lua.push(func(params));
            return 1;
        }
    }
    else
    {
        static if(is(RetT == void))
        {
            Func(params);
            return 0;
        }
        else static if(isInstanceOf!(LuaMultiReturn, RetT))
        {
            auto multiRet = Func(params);
            static foreach(i; 0..multiRet.ValueTuple.length)
                lua.push(multiRet[i]);
            return multiRet.ValueTuple.length;
        }
        else static if(is(RetT == LuaVariadic))
        {
            auto multiRet = Func(params);
            foreach(value; multiRet)
                lua.push(value);
            return cast(int)multiRet.length;
        }
        else
        {
            lua.push(Func(params));
            return 1;
        }
    }
}

/++
 + A function that wraps around other functions in order to provide runtime overloading support.
 +
 + Notes:
 +  Parameter binding logic is exactly the same as `luaCWrapperSmart`.
 +
 +  From the 0th `Overload` to the last, this function will exhaustively call each function until one successfully
 +  has its arguments bound.
 +
 +  If no overloads could succesfully be matched, then an exception will be thrown.
 +
 +  All overloads must provide the same return type. I hope to make this more flexible in the future.
 +
 +  To be more specific, a function fails to bind its arguments if it throws `LuaTypeException` or `LuaArgumentException`.
 +  So please be aware of this when writing overloads.
 + ++/
auto luaOverloads(Overloads...)(LuaState* state, LuaVariadic)
{
    static foreach(Overload; Overloads)
    {{
        bool compilerThinksThisIsUnreachable = true;
        if(compilerThinksThisIsUnreachable)
        {
            try return luaCWrapperSmartImpl!Overload(state);
            catch(LuaTypeException) {}
            catch(LuaArgumentException) {}
        }
    }}

    throw new Exception("No overload matched the given arguments.");
}

unittest
{
    auto l = LuaState(null);
    l.doString("return function(...) return ... end");
    auto f = l.get!LuaFuncWeak(-1);
    auto result = f.pcall!1("Henlo!");
    assert(result[0].textValue == "Henlo!");
}

unittest
{
    auto l = LuaState(null);
    l.push(&luaCWrapperSmart!(
        (string a, int[] b, bool[string] c)
        {
            assert(a == "Hello");
            assert(b == [4, 2, 0]);
            assert(c["true"]);
            return true;
        }
    ));
    auto f = l.get!LuaFunc(-1);
    auto result = f.pcall!1("Hello", [4, 2, 0], ["true": true]);
    assert(result[0].booleanValue);
    
    auto f2 = f.bind!(bool, string, int[], bool[string])();
    assert(f2("Hello", [4, 2, 0], ["true": true]));

    alias F = bool delegate(string, int[], bool[string]);
    F f3 = &f2.asDelegate;
    assert(f3("Hello", [4, 2, 0], ["true": true]));
}

unittest
{
    static string func(string a, int b)
    {
        assert(a == "bc");
        assert(b == 123);
        return "doe ray me";
    }

    auto l = LuaState(null);
    l.push(&func);
    auto f = LuaFuncWeak(&l, -1);
    auto fb = f.bind!(string, string, int);
    assert(fb("bc", 123) == "doe ray me");
}

unittest
{
    version(LDC)
    {
        pragma(msg, "WARNING: This unittest is currently broken under LDC");
    }
    else
    {
        int closedValue;
        void del(string a)
        {
            assert(a == "bc");
            closedValue = 123;
        }

        auto l = LuaState(null);
        l.push(&del);
        auto f = LuaFuncWeak(&l, -1);
        f.pcall!0("bc");
        assert(closedValue == 123);
    }
}

unittest
{
    import std.exception : assertThrown, assertNotThrown;

    auto l = LuaState(null);
    l.register("test", &luaCWrapperSmart!((string s){  }));

    auto f = l.globalTable.get!LuaFunc("test");
    f.pcall!0().assertThrown;
    f.pcall!0("abc").assertNotThrown;
    f.pcall!0("abc", "123").assertThrown;
}

unittest
{
    static struct S
    {
        int i;

        void test(int value)
        {
            assert(value == i);
        }

        void bind(LuaState* l)
        {
            l.register!("test", function (int value) => S(200).test(value))("api");
        }
    }

    auto lua = new LuaState(null);
    S s;
    s.bind(lua);
    lua.doString("api.test(200)");
}

unittest
{
    auto lua = new LuaState(null);
    lua.register("test", &luaCWrapperSmart!((int a, string b, LuaVariadic c){
        assert(a == 1);
        assert(b == "2");
        assert(c.length == 3);
    }));
    lua.doString("test(1, '2', 3, true, {})");

    lua.register("test", &luaCWrapperSmart!((LuaState* l, int a, string b, LuaVariadic c){
        assert(a == 1);
        assert(b == "2");
        assert(c.length == 3);
    }));
    lua.doString("test(1, '2', 3, true, {})");
}

unittest
{
    auto lua = new LuaState(null);
    lua.register!(
        luaOverloads!(
            (int a) { assert(a == 1); },
            (string a) { assert(a == "2"); },
            (int a, string b) { assert(a == 1); assert(b == "2"); }
        )
    )("overloaded");
    lua.doString(`
        overloaded(1)
        overloaded("2")
        overloaded(1, "2")
    `);
}

unittest
{
    static LuaMultiReturn!(int, string, bool) multiReturn()
    {
        return typeof(return)(20, "40", true);
    }

    auto lua = new LuaState(null);
    lua.register!multiReturn("multiReturn");
    lua.doString(`
        local i, s, b = multiReturn()
        assert(i == 20)
        assert(s == "40")
        assert(b)
    `);
}

unittest
{
    static LuaVariadic multiReturn()
    {
        return LuaVariadic([LuaValue(20), LuaValue("40"), LuaValue(true)]);
    }

    auto lua = new LuaState(null);
    lua.register!multiReturn("multiReturn");
    lua.doString(`
        local i, s, b = multiReturn()
        assert(i == 20)
        assert(s == "40")
        assert(b)
    `);
}