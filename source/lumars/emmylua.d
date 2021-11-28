module lumars.emmylua;

import lumars;

struct EmmyLuaBuilder
{
    import std.array : Appender;

    private Appender!(char[]) _output;
    private string[] _tables;
    private string[] _typeNames;

    private void addTable(string name)
    {
        import std.algorithm : canFind;

        if(!name.length)
            return;

        if(!this._tables.canFind(name))
        {
            auto start = 0;
            auto cursor = 0;
            while(cursor < name.length)
            {
                if(name[cursor] == '.')
                {
                    auto slice = name[start..cursor];
                    if(!this._tables.canFind(slice))
                        this._tables ~= slice;
                    start = cursor+1;
                }
                cursor++;
            }

            this._tables ~= name;
        }
    }

    private void putDeclaration(string table, string name, string def)
    {
        if(table.length)
        {
            this._output.put(table);
            this._output.put('.');
        }
        this._output.put(name);
        this._output.put(" = ");
        if(table.length)
        {
            this._output.put(table);
            this._output.put('.');
        }
        this._output.put(name);
        this._output.put(" or ");
        this._output.put(def ? def : "nil");
        this._output.put('\n');
    }

    private void putDescription(string description)
    {
        if(description.length)
        {
            this._output.put("---");
            this._output.put(description);
            this._output.put('\n');
        }
    }

    private void putType(T)()
    {
        import std.algorithm : canFind;
        import std.traits : fullyQualifiedName, isDynamicArray, isSomeFunction;

        const fqn = fullyQualifiedName!T;
        if(this._typeNames.canFind(fqn) || is(T == LuaValue) || is(T == LuaNumber) || is(T == LuaTable))
            return;
        this._typeNames ~= fqn;

        static if(is(T == struct))
        {
            Appender!(char[]) suboutput;

            suboutput.put("---@class ");
            suboutput.put(getTypeName!T);
            suboutput.put('\n');

            static foreach(member; __traits(allMembers, T))
            {{
                alias Member = __traits(getMember, T, member);

                static if(__traits(compiles, mixin("T.init."~member~" = T.init."~member))) // Is it public and a variable?
                {
                    alias MemberT = typeof(mixin("T.init."~member));
                    static if(!isSomeFunction!MemberT) // Handles a weird edge case: T func(T)
                    {
                        suboutput.put("---@field public ");
                        suboutput.put(member);
                        suboutput.put(' ');
                        suboutput.put(getTypeName!MemberT);
                        suboutput.put('\n');
                    }
                }
            }}

            suboutput.put("local ");
            suboutput.put(getTypeName!T);
            suboutput.put('\n');
            this._output.put(suboutput.data);
        }
    }

    void addArray(T)(string table, string name, string description = "")
    {
        this.addTable(table);
        this.putType!T();
        this.putDescription(description);
        this._output.put("---@type ");
        this._output.put(getTypeName!T);
        this._output.put("[]\n");
        this.putDeclaration(table, name, "{}");
    }

    void addTable(Key, Value)(string table, string name, string description = "")
    {
        this.addTable(table);
        this.putType!Key();
        this.putType!Value();
        this.putDescription(description);
        this._output.put("---@type table<");
        this._output.put(getTypeName!Key);
        this._output.put(", ");
        this._output.put(getTypeName!Value);
        this._output.put(">\n");
        this.putDeclaration(table, name, "{}");
    }

    string toString() const
    {
        Appender!(char[]) tables;
        foreach(t; this._tables)
        {
            tables.put(t);
            tables.put(" = ");
            tables.put(t);
            tables.put(" or {}\n");
        }
        tables.put(this._output.data);
        return tables.data.idup;
    }
}
///
unittest
{
    static struct S
    {
        LuaNumber a;
        LuaValue b;
        string c;
    }

    EmmyLuaBuilder b;
    b.addArray!LuaNumber(null, "globalTable", "Some description");
    b.addArray!LuaValue("t1", "field", "Some field");
    b.addArray!string("t2.t", "field");
    b.addTable!(string, LuaValue)(null, "map");
    b.addArray!S(null, "s");
    b.addFunction!(
        (string _, LuaValue __, S ____)
        {
            return 200;
        }
    )(null, "test", "icles");
    alias f = LuaTable.makeNew;
    b.addFunction!f(null, "readText");
    b.addFunctions!(
        "writeln", (string[] s) {},
        "readln", () { return ""; }
    )("sh");

    import std.stdio : writeln;
    writeln(b.toString());
}

template addFunction(alias Func) // Have to do this otherwise I get the fucking crappy-ass "dual-context" error.
{
    void addFunction(ref EmmyLuaBuilder b, string table, string name, string description = "")
    {
        import std.array : Appender;
        import std.traits : ParameterIdentifierTuple, Parameters, ReturnType;

        b.addTable(table);

        Appender!(char[]) suboutput;

        suboutput.put("--@type fun(");
        alias idents = ParameterIdentifierTuple!Func;
        static foreach(i, param; Parameters!Func)
        {{
            static if(!is(param == LuaState*)) // Wrapped functions can ask for the LuaState. This is not a parameter passed by Lua code.
            {
                b.putType!param();

                const ident = idents[i].length ? idents[i] : "_";
                suboutput.put(ident);
                suboutput.put(':');
                suboutput.put(getTypeName!param);

                static if(i != Parameters!Func.length - 1)
                    suboutput.put(", ");
            }
        }}
        b.putType!(ReturnType!Func)();
        suboutput.put("):");
        suboutput.put(getTypeName!(ReturnType!Func));
        suboutput.put('\n');

        b.putDescription(description);
        b._output.put(suboutput.data);
        b.putDeclaration(table, name, "function() assert(false, 'not implemented') end");
    }
}

template addFunctions(Funcs...)
{
    void addFunctions(ref EmmyLuaBuilder b, string table)
    {
        static foreach(i; 0..Funcs.length/2)
            addFunction!(Funcs[i*2+1])(b, table, Funcs[i*2]);
    }
}

private:

string getTypeName(T)()
{
    import std.range : ElementType;
    import std.traits : isNumeric, isDynamicArray;

    static if(is(T == LuaValue))
        return "any";
    else static if(is(T == LuaNumber) || isNumeric!T)
        return "number";
    else static if(is(T == LuaTable))
        return "table";
    else static if(is(T == void) || is(T == typeof(null)))
        return "nil";
    else static if(isDynamicArray!T && !is(T == string))
        return getTypeName!(ElementType!T)~"[]";
    else
        return T.stringof;
}