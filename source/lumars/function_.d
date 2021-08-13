module lumars.function_;

import bindbc.lua, lumars, std;

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
                const error = func.lua.to!string(-1);
                func.lua.pop(1);
                throw new Exception(error);
            }

            typeof(return) ret;
            static foreach(i; 1..results+1)
                ret[$-i] = func.lua.to!LuaValue(cast(int)-i);

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
                const error = func.lua.to!string(-1);
                func.lua.pop(1);
                throw new Exception(error);
            }
        }
    }
}

private mixin template LuaFuncFuncs()
{
}

struct LuaFuncWeak 
{
    mixin LuaFuncFuncs;

    private
    {
        LuaState* _lua;
        int _index;
    }

    this(LuaState* lua, int index)
    {
        lua.enforceType(LuaValue.Kind.func, index);
        this._index = index;
        this._lua = lua;
    }

    @safe @nogc 
    int push() nothrow pure const
    {
        return this._index;
    }

    void pop()
    {
        this.lua.enforceType(LuaValue.Kind.func, this._index);
    }

    @property @safe @nogc
    LuaState* lua() nothrow pure
    {
        return this._lua;
    }
}

struct LuaFunc 
{
    mixin LuaFuncFuncs;

    private
    {
        static struct State
        {
            LuaState* lua;
            int ref_;
            
            ~this()
            {
                if(this.lua)
                    luaL_unref(this.lua.handle, LUA_REGISTRYINDEX, this.ref_);
            }
        }
        RefCounted!State _state;
    }

    static LuaFunc makeRef(LuaState* lua)
    {
        lua.enforceType(LuaValue.Kind.func, -1);
        RefCounted!State state;
        state.lua = lua;
        state.ref_ = luaL_ref(lua.handle, LUA_REGISTRYINDEX);

        return LuaFunc(state);
    }

    static LuaFunc makeNew(LuaState* lua, lua_CFunction func)
    {
        lua.push(func);
        return LuaFunc.makeRef(lua);
    }

    @nogc
    int push() nothrow
    {
        lua_rawgeti(this._state.lua.handle, LUA_REGISTRYINDEX, this._state.ref_);
        return this._state.lua.top;
    }

    void pop()
    {
        this._state.lua.enforceType(LuaValue.Kind.table, -1);
        this._state.lua.pop(1);
    }

    LuaState* lua()
    {
        return this._state.lua;
    }
}

int luaCWrapperBasic(alias Func)(lua_State* state) nothrow
{
    scope wrapper = LuaState(state);

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
    catch(Throwable e) // Can't allow any Throwable to execute normally as the backtrace code will crash.
    {
        wrapper.error(format!"A D function threw an exception: %s"(e.msg).assumeWontThrow);
        return 0;
    }
}

int luaCWrapperSmart(alias Func)(lua_State* state) nothrow
{
    return luaCWrapperBasic!((lua)
    {
        alias Params = Parameters!Func;
        Params params;
        
        static if(is(Params[0] == LuaState*))
        {
            params[0] = lua;
            static foreach(i; 1..Params.length)
                params[i] = lua.to!(Params[i])(i);
        }
        else
        {
            static foreach(i; 0..Params.length)
                params[i] = lua.to!(Params[i])(i+1);
        }

        alias RetT = ReturnType!Func;
        static if(is(RetT == void))
        {
            Func(params);
            return 0;
        }
        else
        {
            lua.push(Func(params));
            return 1;
        }
    })(state);
}

unittest
{
    auto l = LuaState(null);
    l.doString("return function(...) return ... end");
    auto f = l.to!LuaFuncWeak(-1);
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
    auto f = l.to!LuaFuncWeak(-1);
    auto result = f.pcall!1("Hello", [4, 2, 0], ["true": true]);
    assert(result[0].booleanValue);
}