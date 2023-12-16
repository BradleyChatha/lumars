module lumars.state;

import bindbc.lua, taggedalgebraic, lumars;
import taggedalgebraic : visit;
import std.typecons : Nullable, isTuple;
import std.traits : hasUDA, FieldNameTuple;
import std.meta : AliasSeq;

struct ShowInLua {}
struct HideFromLua {}
struct AsTable {}
struct AsUserData {}

template FieldIndex(T, string fieldName)
{
    enum FieldIndex = fieldIndexImpl!(T, fieldName, 0);
}

private template fieldIndexImpl(T, string fieldName, int i)
{
    static if (T.tupleof.length <= i)
    {
        static assert(false, "The given field \"" ~ fieldName ~ "\" doesn't exist in the type \"" ~ T.stringof ~ "\"");
        enum fieldIndexImpl = -1;
    }
    else static if (__traits(identifier, T.tupleof[i]) == fieldName)
    {
        enum fieldIndexImpl = i;
    }
    else
    {
        enum fieldIndexImpl = fieldIndexImpl!(T, fieldName, i + 1);
    }
}

template FieldType(T, string fieldName, int i = 0)
{
    static if (isTuple!T)
        alias FieldType = TupleFieldType!(T, fieldName, 0);
    else 
        alias FieldType = StructFieldType!(T, fieldName, 0);
}

template TupleFieldType(T, string fieldName, int i)
{
    static if (T.Types.length <= i)
    {
        static assert(false, "The given field \"" ~ fieldName ~ "\" doesn't exist in the type \"" ~ T.stringof ~ "\"");
    }
    else static if (T.fieldNames[i] == fieldName)
    {
        alias TupleFieldType = T.Types[i];
    }
    else
    {
        alias TupleFieldType = TupleFieldType!(T, fieldName, i + 1);
    }
}

template StructFieldType(T, string fieldName, int i)
{
    static if (T.tupleof.length <= i)
    {
        static assert(false, "The given field \"" ~ fieldName ~ "\" doesn't exist in the type \"" ~ T.stringof ~ "\"");
    }
    else static if (__traits(identifier, T.tupleof[i]) == fieldName)
    {
        alias StructFieldType = typeof(T.tupleof[i]);
    }
    else
    {
        alias StructFieldType = StructFieldType!(T, fieldName, i + 1);
    }
}

private auto getFieldValue(string fieldName, T)(T obj)
{
    static if (isTuple!T)
        return mixin("obj." ~ fieldName);
    else
        return obj.tupleof[FieldIndex!(T, fieldName)];
}

private void setFieldValue(string fieldName, T, U)(ref T obj, U value)
{
    static if (isTuple!T)
        mixin("obj." ~ fieldName ~ " = value;");
    else
        obj.tupleof[FieldIndex!(T, fieldName)] = value;
}

template isVisibleField(T, string fieldName)
{
    enum i = FieldIndex!(T, fieldName);
    enum isVisibleField = !hasUDA!(T.tupleof[i], HideFromLua) && (
        hasUDA!(T.tupleof[i], ShowInLua) || 
        __traits(getVisibility, T.tupleof[i]) == "public" ||  
        __traits(getVisibility, T.tupleof[i]) == "export"
    );
}

template VisibleFieldNameTuple(T)
{
    alias VisibleFieldNameTuple = AliasSeq!();
    static if (isTuple!T)
    {
        VisibleFieldNameTuple = T.fieldNames;
    }
    else
    {
        static foreach (member; FieldNameTuple!T)
            static if (isVisibleField!(T, member))
                VisibleFieldNameTuple = AliasSeq!(VisibleFieldNameTuple, member);
    }
}

unittest
{
    struct S
    {
        int a;
        @HideFromLua int b;
        private int c;
        @ShowInLua private int d;
        export int e;
        protected int f;
    }

    static assert(isVisibleField!(S, "a"));
    static assert(!isVisibleField!(S, "b"));
    static assert(!isVisibleField!(S, "c"));
    static assert(isVisibleField!(S, "d"));
    static assert(isVisibleField!(S, "e"));
    static assert(!isVisibleField!(S, "f"));

    alias vfnt = VisibleFieldNameTuple!S;
    static assert(vfnt == AliasSeq!("a", "d", "e"));

    import std.typecons : Tuple;

    alias T = Tuple!(int, "a", int, "b");
    T t;

    static assert(isVisibleField!(S, "a"));
    static assert(!isVisibleField!(S, "b"));

    alias vfnt2 = VisibleFieldNameTuple!T;
    static assert(vfnt2 == AliasSeq!("a", "b"));
}

/// Used to represent LUA's `nil`.
struct LuaNil {}

/// See `LuaValue`
union LuaValueUnion
{
    /// LUA `nil`
    LuaNil nil;

    /// A lua number
    lua_Number number;

    /// A weak reference to some text. This text is managed by LUA and not D's GC so is unsafe to escape
    const(char)[] textWeak;

    /// GC-managed text
    string text;

    /// A bool
    bool boolean;

    /// A weak reference to a table currently on the LUA stack.
    LuaTableWeak tableWeak;

    /// A strong reference to a table which is in the LUA registry.
    LuaTable table;

    /// A weak reference to a function currently on the LUA stack.
    LuaFuncWeak funcWeak;

    /// A strong reference to a function which is in the LUA registry.
    LuaFunc func;

    void* userData;
}

/// An enumeration of various status codes LUA may return.
enum LuaStatus
{
    ok = 0,
    yield = LUA_YIELD,
    errRun = LUA_ERRRUN,
    errSyntax = LUA_ERRSYNTAX,
    errMem = LUA_ERRMEM,
    errErr = LUA_ERRERR,
}

/// A `TaggedUnion` of `LuaValueUnion` which is used to bridge the gap between D and Lua values.
alias LuaValue = TaggedUnion!LuaValueUnion;
alias LuaNumber = lua_Number;
alias LuaCFunc = lua_CFunction;

/++
 + A light wrapper around `lua_State` with some higher level functions for quality of life purposes.
 +
 + This struct cannot be copied, so put it on the heap or store it as a global.
 + ++/
struct LuaState
{
    import std.string : toStringz;
    import std.stdio : writefln, writeln, writef;

    @disable this(this){}

    private
    {
        lua_State*      _handle;
        LuaTablePseudo  _G;
    }
    package bool        _isWrapper;

    /// Creates a wrapper around the given `lua_state`, or creates a new state if the given value is null.
    @trusted
    this(lua_State* wrapAround)
    {
        if(wrapAround)
        {
            this._handle = wrapAround;
            this._isWrapper = true;
        }
        else
        {
            loadLuaIfNeeded();

            this._handle = luaL_newstate();
            luaL_openlibs(this.handle);
        }

        this._G = LuaTablePseudo(&this, LUA_GLOBALSINDEX);
    }

    /// For non-wrappers, destroy the lua state.
    @trusted @nogc
    ~this() nothrow
    {
        if(this._handle && !this._isWrapper)
            lua_close(this._handle);
    }

    @nogc
    LuaTablePseudo globalTable() nothrow
    {
        return this._G;
    }

    @nogc
    lua_CFunction atPanic(lua_CFunction func) nothrow
    {
        return lua_atpanic(this.handle, func);
    }

    @nogc
    void call(int nargs, int nresults) nothrow
    {
        lua_call(this.handle, nargs, nresults);
    }

    @nogc
    bool checkStack(int amount) nothrow
    {
        return lua_checkstack(this.handle, amount) != 0;
    }

    @nogc
    void concat(int nargs) nothrow
    {
        lua_concat(this.handle, nargs);
    }

    @nogc
    bool equal(int index1, int index2) nothrow
    {
        return lua_equal(this.handle, index1, index2) != 0;
    }

    @nogc
    void error() nothrow
    {
        lua_error(this.handle);
    }

    void error(const char[] msg) nothrow
    {
        luaL_error(this.handle, "%s", msg.toStringz);
    }

    LuaTableWeak pushMetatable(int ofIndex)
    {
        lua_getmetatable(this.handle, ofIndex);
        return LuaTableWeak(&this, -1);
    }

    LuaTable getMetatable(int ofIndex)
    {
        lua_getmetatable(this.handle, ofIndex);
        return LuaTable.makeRef(&this);
    }

    @nogc
    bool lessThan(int index1, int index2) nothrow
    {
        return lua_lessthan(this.handle, index1, index2) != 0;
    }

    @nogc
    bool rawEqual(int index1, int index2) nothrow
    {
        return lua_rawequal(this.handle, index1, index2) != 0;
    }

    @nogc
    void pushTable(int tableIndex) nothrow
    {
        return lua_gettable(this.handle, tableIndex);
    }

    @nogc
    void insert(int index) nothrow
    {
        return lua_insert(this.handle, index);
    }

    @nogc
    size_t len(int index) nothrow
    {
        return lua_objlen(this.handle, index);
    }

    @nogc
    LuaStatus pcall(int nargs, int nresults, int errFuncIndex) nothrow
    {
        return cast(LuaStatus)lua_pcall(this.handle, nargs, nresults, errFuncIndex);
    }

    @nogc
    void copy(int index) nothrow
    {
        lua_pushvalue(this.handle, index);
    }

    @nogc
    void rawGet(int tableIndex) nothrow
    {
        lua_rawget(this.handle, tableIndex);
    }

    @nogc
    void rawGet(int tableIndex, int indexIntoTable) nothrow
    {
        lua_rawgeti(this.handle, tableIndex, indexIntoTable);
    }

    @nogc
    void rawSet(int tableIndex) nothrow
    {
        lua_rawset(this.handle, tableIndex);
    }

    @nogc
    void rawSet(int tableIndex, int indexIntoTable) nothrow
    {
        lua_rawseti(this.handle, tableIndex, indexIntoTable);
    }

    void getGlobal(const char[] name)
    {
        lua_getglobal(this.handle, name.toStringz);
    }

    void setGlobal(const char[] name)
    {
        lua_setglobal(this.handle, name.toStringz);
    }

    void register(const char[] name, LuaCFunc func) nothrow
    {
        lua_register(this.handle, name.toStringz, func);
    }

    /++
     + Registers the given D function into Lua, under a specific name within the global table.
     +
     + `Func` can be any normal D function. By default it is wrapped using `luaCWrapperSmart`
     + to allow a (mostly) seamless way of interfacing D and Lua together. Please see `luaCWrapperSmart`'s
     + documentation if you'd like to learn more.
     +
     + Params:
     +  Func = The function to wrap.
     +  name = The name to register the function under.
     + ++/
    void register(alias Func)(const char[] name)
    {
        this.register(name, &luaCWrapperSmart!Func);
    }

    /++
     + Similar to the other register functions, except this one will register the functions
     + into a single table, before registering the resulting table into the global table.
     +
     + In other words: If you want to make a "library" table then this is the function for you.
     +
     + `Args` must have an even number of elements, where each two elements are a pair.
     +
     + For each pair in `Args`, the first element is the name to register the function under, and
     + the last element is the function itself to register.
     +
     + For example, if you did: `register!("a", (){}, "b", (){})("library")`, then the result is
     + a global table called "library" with the functions "a" and "b" (e.g. `library.a()`).
     + ++/
    void register(Args...)(const char[] libname)
    if(Args.length % 2 == 0)
    {
        import std.traits : getUDAs;
        luaL_Reg[(Args.length / 2) + 1] reg;

        static foreach(i; 0..Args.length/2)
            reg[i] = luaL_Reg(Args[i*2].ptr, &luaCWrapperSmart!(Args[i*2+1]));

        luaL_register(this.handle, libname.toStringz, reg.ptr);
    }

    @nogc
    void remove(int index) nothrow
    {
        lua_remove(this.handle, index);
    }

    @nogc
    void replace(int index) nothrow
    {
        lua_replace(this.handle, index);
    }

    @nogc
    void setMetatable(int ofIndex) nothrow
    {
        lua_setmetatable(this.handle, ofIndex);
    }

    void checkArg(bool condition, int argNum, const(char)[] extraMsg = null) nothrow
    {
        luaL_argcheck(this.handle, condition ? 1 : 0, argNum, extraMsg ? extraMsg.toStringz : null);
    }

    bool callMetamethod(int index, const char[] method) nothrow
    {
        return luaL_callmeta(this.handle, index, method.toStringz) != 0;
    }

    @nogc
    void checkAny(int arg) nothrow
    {
        luaL_checkany(this.handle, arg);
    }

    @nogc
    ptrdiff_t checkInt(int arg) nothrow
    {
        return luaL_checkinteger(this.handle, arg);
    }

    @nogc
    const(char)[] checkStringWeak(int arg) nothrow
    {
        size_t len;
        const ptr = luaL_checklstring(this.handle, arg, &len);
        return ptr[0..len];
    }

    string checkString(int arg) nothrow
    {
        return checkStringWeak(arg).idup;
    }

    @nogc
    LuaNumber checkNumber(int arg) nothrow
    {
        return luaL_checknumber(this.handle, arg);
    }

    @nogc
    void checkType(LuaValue.Kind type, int arg) nothrow
    {
        int t;

        final switch(type) with(LuaValue.Kind)
        {
            case nil: t = LUA_TNIL; break;
            case number: t = LUA_TNUMBER; break;
            case textWeak:
            case text: t = LUA_TSTRING; break;
            case boolean: t = LUA_TBOOLEAN; break;
            case tableWeak:
            case table: t = LUA_TTABLE; break;
            case funcWeak:
            case func: t = LUA_TFUNCTION; break;
            case userData: t = LUA_TLIGHTUSERDATA; break;
        }

        luaL_checktype(this.handle, arg, t);
    }

    @nogc
    bool isType(T)(int index) nothrow
    {
        return this.type(index) == LuaState.luaValueKindFor!T;
    }

    @nogc
    static LuaValue.Kind luaValueKindFor(T)() pure nothrow
    {
        import std.typecons : Nullable;
        import std.traits   : isNumeric, isDynamicArray, isAssociativeArray,
                              isPointer, KeyType, ValueType,
                              isInstanceOf, TemplateArgsOf;

        static if(is(T == string))
            return LuaValue.Kind.text;
        else static if(is(T == const(char)[]))
            return LuaValue.Kind.text;
        else static if(is(T : const(bool)))
            return LuaValue.Kind.boolean;
        else static if(isNumeric!T)
            return LuaValue.Kind.number;
        else static if(is(T == typeof(null)) || is(T == LuaNil))
            return LuaValue.Kind.nil;
        else static if(is(T == LuaTableWeak))
            return LuaValue.Kind.table;
        else static if(is(T == LuaTable))
            return LuaValue.Kind.table;
        else static if(isDynamicArray!T)
            return LuaValue.Kind.table;
        else static if(isAssociativeArray!T)
            return LuaValue.Kind.table;
        else static if(is(T == LuaCFunc))
            return LuaValue.Kind.func;
        else static if(is(T == LuaFuncWeak))
            return LuaValue.Kind.func;
        else static if(is(T == LuaFunc))
            return LuaValue.Kind.func;
        else static if(isInstanceOf!(Nullable, T))
            return luaValueKindFor!(TemplateArgsOf!T[0])();
        else static if(isPointer!T || is(T == class))
            return LuaValue.Kind.userData;
        else static if(is(T == struct))
            return LuaValue.Kind.table;
        else static assert(false, "Don't know how to convert any LUA values into type: "~T.stringof);
    }

    void doFile(const char[] file)
    {
        const status = luaL_dofile(this.handle, file.toStringz);
        if(status != LuaStatus.ok)
        {
            const error = this.get!string(-1);
            this.pop(1);
            throw new LuaException(error);
        }
    }

    void doFile(const char[] file, scope ref LuaTable table)
    {
        const loadStatus = luaL_loadfile(this.handle, file.toStringz);
        if(loadStatus != LuaStatus.ok)
        {
            const error = this.get!string(-1);
            this.pop(1);
            throw new LuaException(error);
        }

        table.push();
        const fenvResult = lua_setfenv(this.handle, -2);
        if(fenvResult == 0)
            throw new LuaException("Failed to set function environment");

        const callStatus = lua_pcall(this.handle, 0, 0, 0);
        if(callStatus != LuaStatus.ok)
        {
            const error = this.get!string(-1);
            this.pop(1);
            throw new LuaException(error);
        }
    }

    void doString(const char[] str)
    {
        const status = luaL_dostring(this.handle, str.toStringz);
        if(status != LuaStatus.ok)
        {
            const error = this.get!string(-1);
            this.pop(1);
            throw new LuaException(error);
        }
    }

    void doString(const char[] str, scope ref LuaTable table)
    {
        const loadStatus = luaL_loadstring(this.handle, str.toStringz);
        if(loadStatus != LuaStatus.ok)
        {
            const error = this.get!string(-1);
            this.pop(1);
            throw new LuaException(error);
        }

        table.push();
        const fenvResult = lua_setfenv(this.handle, -2);
        if(fenvResult == 0)
            throw new LuaException("Failed to set function environment");

        const callStatus = lua_pcall(this.handle, 0, 0, 0);
        if(callStatus != LuaStatus.ok)
        {
            const error = this.get!string(-1);
            this.pop(1);
            throw new LuaException(error);
        }
    }

    void loadFile(const char[] file)
    {
        const status = luaL_loadfile(this.handle, file.toStringz);
        if(status != LuaStatus.ok)
        {
            const error = this.get!string(-1);
            this.pop(1);
            throw new LuaException(error);
        }
    }

    void loadString(const char[] str)
    {
        const status = luaL_loadstring(this.handle, str.toStringz);
        if(status != LuaStatus.ok)
        {
            const error = this.get!string(-1);
            this.pop(1);
            throw new LuaException(error);
        }
    }

    @nogc
    ptrdiff_t optInt(int arg, ptrdiff_t default_) nothrow
    {
        return luaL_optinteger(this.handle, arg, default_);
    }

    @nogc
    LuaNumber optNumber(int arg, LuaNumber default_) nothrow
    {
        return luaL_optnumber(this.handle, arg, default_);
    }

    void printStack()
    {
        writeln("[LUA STACK]");
        foreach(i; 0..this.top)
        {
            const type = lua_type(this.handle, i+1);
            writef("\t[%s] \t", i+1);

            switch(type)
            {
                case LUA_TBOOLEAN: writefln("%s\t%s", "BOOL", this.get!bool(i+1)); break;
                case LUA_TFUNCTION: writefln("%s\t%s", "FUNC", lua_tocfunction(this.handle, i+1)); break;
                case LUA_TLIGHTUSERDATA: writefln("%s\t%s", "LIGHT", lua_touserdata(this.handle, i+1)); break;
                case LUA_TNIL: writefln("%s", "NIL"); break;
                case LUA_TNUMBER: writefln("%s\t%s", "NUM", this.get!lua_Number(i+1)); break;
                case LUA_TSTRING: writefln("%s\t%s", "STR", this.get!(const(char)[])(i+1)); break;
                case LUA_TTABLE: writefln("%s", "TABL"); break;
                case LUA_TTHREAD: writefln("%s\t%s", "THRD", lua_tothread(this.handle, i+1)); break;
                case LUA_TUSERDATA: writefln("%s\t%s", "USER", lua_touserdata(this.handle, i+1)); break;
                default: writefln("%s\t%s", "UNKN", type); break;
            }
        }
    }

    void push(T)(T value)
    {
        import std.conv : to;
        import std.traits : isNumeric, isDynamicArray, isAssociativeArray, isDelegate, isPointer, isFunction,
                            PointerTarget, KeyType, ValueType, FieldNameTuple, TemplateOf, TemplateArgsOf;

        static if(is(T == typeof(null)) || is(T == LuaNil))
            lua_pushnil(this.handle);
        else static if(is(T : const(char)[]))
            lua_pushlstring(this.handle, value.ptr, value.length);
        else static if(isNumeric!T)
            lua_pushnumber(this.handle, value.to!lua_Number);
        else static if(is(T : const(bool)))
            lua_pushboolean(this.handle, value ? 1 : 0);
        else static if(isDynamicArray!T)
        {
            alias ValueT = typeof(value[0]);

            lua_createtable(this.handle, 0, value.length.to!int);
            foreach(i, v; value)
            {
                this.push(v);
                lua_rawseti(this.handle, -2, cast(int)i+1);
            }
        }
        else static if(isAssociativeArray!T)
        {
            alias KeyT = KeyType!T;
            alias ValueT = ValueType!T;

            lua_createtable(this.handle, 0, value.length.to!int);
            foreach(k, v; value)
            {
                this.push(k);
                this.push(v);
                lua_rawset(this.handle, -3);
            }
        }
        else static if(is(T == LuaTable) || is(T == LuaFunc))
            value.push();
        else static if(is(T == LuaTableWeak) || is(T == LuaFuncWeak))
            this.copy(value.push());
        else static if(is(T : lua_CFunction))
            lua_pushcfunction(this.handle, value);
        else static if(isDelegate!T)
        {
            lua_pushlightuserdata(this.handle, value.ptr);
            lua_pushlightuserdata(this.handle, value.funcptr);
            lua_pushcclosure(this.handle, &luaCWrapperSmart!(T, LuaFuncWrapperType.isDelegate), 2);
        }
        else static if(isPointer!T && isFunction!(PointerTarget!T))
        {
            lua_pushlightuserdata(this.handle, value);
            lua_pushcclosure(this.handle, &luaCWrapperSmart!(T, LuaFuncWrapperType.isFunction), 1);
        }
        else static if(__traits(isSame, TemplateOf!T, Nullable))
        {
            if (value.isNull)
                lua_pushnil(this.handle);
            else
                push!(TemplateArgsOf!T)(value.get());
        }
        else static if(isPointer!T)
            lua_pushlightuserdata(this.handle, value);
        else static if(is(T == class))
            lua_pushlightuserdata(this.handle, cast(void*)value);
        else static if(is(T == struct))
        {
            lua_newtable(this.handle);

            static foreach(member; VisibleFieldNameTuple!T)
            {
                this.push(member);
                this.push(getFieldValue!member(value));
                lua_settable(this.handle, -3);
            }
        }
        else static assert(false, "Don't know how to push type: "~T.stringof);
    }

    void push(LuaValue value)
    {
        value.visit!(
            (_){ this.push(_); }
        );
    }

    @nogc
    int top() nothrow
    {
        return lua_gettop(this.handle);
    }

    @nogc
    void pop(int amount) nothrow
    {
        lua_pop(this.handle, amount);
    }

    T get(T)(int index)
    {
        import std.conv : to;
        import std.format : format;
        import std.traits : isNumeric, isDynamicArray, isAssociativeArray, isPointer, KeyType, ValueType, TemplateOf, TemplateArgsOf, FieldNameTuple;
        import std.typecons : isTuple;

        static if(is(T == string))
        {
            if(this.isType!LuaNil(index))
                return null;

            this.enforceType(LuaValue.Kind.text, index);
            size_t len;
            auto ptr = lua_tolstring(this.handle, index, &len);
            return ptr[0..len].idup;
        }
        else static if(is(T == const(char)[]))
        {
            if(this.isType!LuaNil(index))
                return null;

            this.enforceType(LuaValue.Kind.text, index);
            size_t len;
            auto ptr = lua_tolstring(this.handle, index, &len);
            return ptr[0..len];
        }
        else static if(is(T : const(bool)))
        {
            this.enforceType(LuaValue.Kind.boolean, index);
            return lua_toboolean(this.handle, index) != 0;
        }
        else static if(isNumeric!T)
        {
            this.enforceType(LuaValue.Kind.number, index);
            return lua_tonumber(this.handle, index).to!T;
        }
        else static if(is(T == typeof(null)) || is(T == LuaNil))
        {
            this.enforceType(LuaValue.Kind.nil, index);
            return LuaNil();
        }
        else static if(is(T == LuaTableWeak))
        {
            this.enforceType(LuaValue.Kind.table, index);
            return T(&this, index);
        }
        else static if(is(T == LuaTable))
        {
            this.enforceType(LuaValue.Kind.table, index);
            this.copy(index);
            return T.makeRef(&this);
        }
        else static if(isDynamicArray!T)
        {
            if(this.isType!LuaNil(index))
                return null;

            this.enforceType(LuaValue.Kind.table, index);
            T ret;
            ret.length = lua_objlen(this.handle, index);

            this.push(null);
            const tableIndex = index < 0 ? index - 1 : index;
            while(this.next(tableIndex))
            {
                ret[this.get!size_t(-2) - 1] = this.get!(typeof(ret[0]))(-1);
                this.pop(1);
            }

            return ret;
        }
        else static if(isAssociativeArray!T)
        {
            if(this.isType!LuaNil(index))
                return null;

            this.enforceType(LuaValue.Kind.table, index);
            T ret;

            this.push(null);
            const tableIndex = index < 0 ? index - 1 : index;
            while(this.next(tableIndex))
            {
                ret[this.get!(KeyType!T)(-2)] = this.get!(ValueType!T)(-1);
                this.pop(1);
            }

            return ret;
        }
        else static if(is(T == LuaCFunc))
        {
            this.enforceType(LuaValue.Kind.func, index);
            return lua_tocfunction(this.handle, index);
        }
        else static if(is(T == LuaFuncWeak))
        {
            this.enforceType(LuaValue.Kind.func, index);
            return LuaFuncWeak(&this, index);
        }
        else static if(is(T == LuaFunc))
        {
            this.enforceType(LuaValue.Kind.func, index);
            this.copy(index);
            return T.makeRef(&this);
        }
        else static if(isPointer!T || is(T == class))
        {
            if(this.isType!LuaNil(index))
                return null;

            this.enforceType(LuaValue.Kind.userData, index);
            return cast(T)lua_touserdata(this.handle, index);
        }
        else static if(is(T == LuaValue))
        {
            switch(this.type(index))
            {
                case LuaValue.Kind.text: return LuaValue(this.get!string(index));
                case LuaValue.Kind.number: return LuaValue(this.get!lua_Number(index));
                case LuaValue.Kind.boolean: return LuaValue(this.get!bool(index));
                case LuaValue.Kind.nil: return LuaValue(this.get!LuaNil(index));
                case LuaValue.Kind.table: return LuaValue(this.get!LuaTable(index));
                case LuaValue.Kind.func: return LuaValue(this.get!LuaFunc(index));
                case LuaValue.Kind.userData: return LuaValue(this.get!(void*)(index));
                default: throw new LuaException("Don't know how to convert type into a LuaValue: "~this.type(index).to!string);
            }
        }
        else static if(__traits(isSame, TemplateOf!(T), Nullable))
        {
            if(this.isType!LuaNil(index))
                return T.init;
            return cast(T)get!(TemplateArgsOf!(T)[0])(index);
        }
        else static if (isTuple!T)
        {
            T ret;
            alias params = T.Types;
            int idx = 0;

            static foreach (i, p; params)
            {
                idx = cast(int)(i - params.length);
                if (params.length != lua_gettop(this.handle))
                {
                    static if(i == 0)
                    {
                        return getAsStruct!(T, T.fieldNames)(index); 
                    }
                }
                else if (this.isType!(params[i])(idx))
                {
                    ret[i] = this.get!(p)(idx);
                }
                else
                {
                    const firstArgIndex = cast(int)(-params.length);
                    static if(i == 0)
                    {
                        if(this.type(firstArgIndex) == LuaValue.Kind.table)
                            return getAsStruct!(T, T.fieldNames)(firstArgIndex);

                        throw new LuaTypeException(
                            format!(
                                "When parsing tuple %s, expected value %s to be %s, but it was %s. "
                                ~" Attempted to parse 0th value as a struct instead, but 0th value is not a table."
                            )(
                                T.stringof,
                                idx,
                                LuaState.luaValueKindFor!(params[i]),
                                this.type(firstArgIndex),
                            )
                        );
                    }
                    else
                    {
                        throw new LuaTypeException(
                            format!"When parsing tuple %s, expected value %s to be %s, but it was %s."(
                                T.stringof,
                                idx,
                                LuaState.luaValueKindFor!(params[i]),
                                this.type(firstArgIndex)
                            )
                        );
                    }
                }
            }

            return ret;
        }
        else static if(is(T == struct))
        {
            return getAsStruct!(T, VisibleFieldNameTuple!T)(index);
        }
        else static assert(false, "Don't know how to convert any LUA values into type: "~T.stringof);
    }

    T getAsStruct(T, Names ...)(int index)
    {
        this.enforceType(LuaValue.Kind.table, index);
        T ret;

        this.push(null);
        const tableIndex = index < 0 ? index - 1 : index;
        While: while(this.next(tableIndex))
        {
            const field = this.get!(const(char)[])(-2);

            static foreach(member; Names)
            {
                if(field == member)
                {
                    setFieldValue!(member)(ret, get!(FieldType!(T, member))(-1));
                    //mixin("ret."~member~"= this.get!(typeof(ret."~member~"))(-1);");
                    this.pop(1);
                    continue While;
                }
            }

            this.pop(1);
        }
        return ret;
    }

    unittest
    {
        static struct MyStruct
        {
            int number;
            string text;

            int getNumber() const
            {
                return number;
            }

            string getText() const
            {
                return text;
            }
        }

        auto lua = LuaState(null);
        auto before = MyStruct(1, "foo");

        lua.push(before);

        auto table = lua.get!LuaTable(-1);
        assert(table.get!int("number") == 1);
        assert(table.get!(const(char)[])("text") == "foo");
        assert(table.get!string("text") == "foo");

        auto after = lua.get!MyStruct(-1);

        assert(before == after);

        lua.pop(1);
    }

    @nogc
    bool next(int index) nothrow
    {
        this.assertIndex(index);
        return lua_next(this.handle, index) != 0;
    }

    void enforceType(LuaValue.Kind expected, int index)
    {
        import std.exception : enforce;
        import std.format    : format;
        const type = this.type(index);
        enforce!LuaTypeException(type == expected, "Expected value at stack index %s to be of type %s but it is %s".format(
            index, expected, type
        ));
    }

    @nogc
    LuaValue.Kind type(int index) nothrow
    {
        assert(this.top > 0, "Stack is empty.");
        this.assertIndex(index);
        const type = lua_type(this.handle, index);

        switch(type)
        {
            case LUA_TBOOLEAN: return LuaValue.Kind.boolean;
            case LUA_TNIL: return LuaValue.Kind.nil;
            case LUA_TNUMBER: return LuaValue.Kind.number;
            case LUA_TSTRING: return LuaValue.Kind.text;
            case LUA_TTABLE: return LuaValue.Kind.table;
            case LUA_TFUNCTION: return LuaValue.Kind.func;
            case LUA_TLIGHTUSERDATA: return LuaValue.Kind.userData;

            default:
                return LuaValue.Kind.nil;
        }
    }

    /++
     + Attempts to call `debug.traceback`. A string is expected to be on top of the stack,
     + otherwise the function will abort the attempt.
     +
     + Otherwise, the string on top of the stack is consumed and a new string will be pushed containing
     + the traceback (if possible).
     +
     + Args:
     +  level = Same as the `level` parameter for `debug.traceback`. Essentially, how many functions to not include in the traceback
     + ++/
    void traceback(int level = 2)
    {
        if(!this.isType!string(-1))
            return;

        const str = this.get!string(-1);
        this.pop(1);

        bool found;
        auto debugTable = this.globalTable.tryGet!LuaTable("debug", found);
        if(!found)
        {
            this.push(str~"\n"~"[Could not produce traceback: `debug` does not exist in _G table]");
            return;
        }

        auto tracebackFunc = debugTable.tryGet!LuaFunc("traceback", found);
        if(!found)
        {
            this.push(str~"\n"~"[Could not produce traceback: `traceback` does not exist in `debug` table]");
            return;
        }

        this.push(tracebackFunc);
        this.push(str);
        this.push(level);
        this.call(2, 1);
    }

    @property @safe @nogc
    inout(lua_State*) handle() nothrow pure inout
    {
        return this._handle;
    }

    @nogc
    private void assertIndex(int index) nothrow
    {
        if(index > 0)
            assert(this.top >= index, "Index out of bounds");
        else
            assert(this.top + index >= 0, "Index out of bounds");
    }
}

private void loadLuaIfNeeded()
{
    version(BindLua_Static){}
    else
    {
        const ret = loadLua();
        if(ret != luaSupport) {
            if(ret == LuaSupport.noLibrary)
                throw new LuaException("Lua library not found.");
            else if(ret == LuaSupport.badLibrary)
                throw new LuaException("Lua library is corrupt or for a different platform.");
            else
                throw new LuaException("Lua library is the wrong version, or some unknown error occured.");
        }
    }
}

import std.exception : basicExceptionCtors;
class LuaException : Exception
{
    mixin basicExceptionCtors;
}
class LuaTypeException : LuaException
{
    mixin basicExceptionCtors;
}
class LuaArgumentException : LuaException
{
    mixin basicExceptionCtors;
}
class LuaStackException : LuaException
{
    mixin basicExceptionCtors;
}

unittest
{
    auto l = LuaState(null);
    l.push(null);
    assert(l.type(-1) == LuaValue.Kind.nil);
    assert(l.get!LuaValue(-1).kind == LuaValue.Kind.nil);
    assert(l.get!string(-1) == null);
    assert(l.get!(const(char)[])(-1) == null);
    l.pop(1);

    l.push(LuaNil());
    assert(l.type(-1) == LuaValue.Kind.nil);
    assert(l.get!LuaValue(-1).kind == LuaValue.Kind.nil);
    assert(l.get!string(-1) == null);
    assert(l.get!(const(char)[])(-1) == null);
    l.pop(1);

    l.push(false);
    assert(l.get!LuaValue(-1).kind == LuaValue.Kind.boolean);
    assert(!l.get!bool(-1));
    l.pop(1);

    l.push(20);
    assert(l.get!LuaValue(-1).kind == LuaValue.Kind.number);
    assert(l.get!int(-1) == 20);
    l.pop(1);

    l.push("abc");
    assert(l.get!LuaValue(-1).kind == LuaValue.Kind.text);
    assert(l.get!string(-1) == "abc");
    assert(l.get!(const(char)[])(-1) == "abc");
    l.pop(1);

    l.push(["abc", "one"]);
    assert(l.get!(string[])(-1) == ["abc", "one"]);
    l.pop(1);

    l.push([LuaValue(200), LuaValue("abc")]);
    assert(l.get!(LuaValue[])(-1) == [LuaValue(200), LuaValue("abc")]);
    l.pop(1);

    l.push(LuaNil());
    assert(l.get!(Nullable!bool)(-1) == Nullable!(bool).init);
    l.pop(1);

    Nullable!bool nb;
    l.push(nb);
    assert(l.get!(Nullable!bool)(-1) == Nullable!(bool).init);
    l.pop(1);

    l.push(123);
    assert(l.get!(Nullable!int)(-1) == 123);
    l.pop(1);

    Nullable!int ni = 234;
    l.push(ni);
    assert(l.get!(Nullable!int)(-1) == 234);
    l.pop(1);
}

unittest
{
    auto l = LuaState(null);
    l.register!(() => 123)("abc");
    l.doString("assert(abc() == 123)");
}

unittest
{
    auto l = LuaState(null);
    l.register!(
        "funcA", () => "a",
        "funcB", () => "b"
    )("lib");
    l.doString("assert(lib.funcA() == 'a') assert(lib.funcB() == 'b')");
}

unittest
{
    auto l = LuaState(null);
    l.doString("abba = 'chicken tikka'");
    assert(l.globalTable.get!string("abba") == "chicken tikka");
    l.globalTable["baab"] = "tikka chicken";
    assert(l.globalTable.get!string("baab") == "tikka chicken");
}

unittest
{
    static struct B
    {
        string a;
    }

    static struct C
    {
        string a;
    }

    static struct A
    {
        string a;
        B[] b;
        C[string] c;
        @HideFromLua int d;
        private int e;
        @ShowInLua private int f;
        export int g;

        public int E() { return e; }
        public int F() { return f; }
    }

    auto a = A(
        "bc",
        [B("c")],
        ["c": C("123")],
        123,
        456,
        789,
        1024
    );

    auto l = LuaState(null);

    import std.typecons : Tuple;

    alias T = Tuple!(int, "a", string, "b");
    T t;
    t.a = 123;
    t.b = "abc";
    l.push(t);

    auto luab = l.get!T(-1);
    assert(luab.a == 123);
    assert(luab.b == "abc");

    l.push(a);

    auto luaa = l.get!A(-1);
    assert(luaa.a == "bc");
    assert(luaa.b.length == 1);
    assert(luaa.b == [B("c")]);
    assert(luaa.c.length == 1);
    assert(luaa.c["c"] == C("123"));
    assert(a.d == 123);
    assert(a.E == 456);
    assert(a.F == 789);
    assert(luaa.d != a.d);
    assert(luaa.e != a.E);
    assert(luaa.f == a.F);
    assert(luaa.g == 1024);

    l.globalTable["a"] = a;
    l.doString("assert(a.d == nil)");
    l.doString("assert(a.e == nil)");
    l.doString("assert(a.f == 789)");
    l.doString("a.f = 135");
    
    auto b = l.globalTable.get!A("a");
    assert(b.F == 135);


}

unittest
{
    auto state = LuaState(null);
    auto print = state._G.get!LuaFunc("print");
    auto _G1 = LuaTable.makeNew(&state);
    auto _G2 = LuaTable.makeNew(&state);
    _G1["abc"] = 123;
    _G1["print"] = print;
    _G2["abc"] = 321;
    _G2["print"] = print;

    const code = "print(abc)";

    state.doString(code, _G1);
    state.doString(code, _G2);
}
