# Overview

Lumars is a high-level wrapper around LUA 5.1 that aims to be lightweight while providing high quality of life features.

This library has been in use for a while, and is _relatively_ stable. If you can be bothered, please open an issue alongside a minimised, idependent snippet of code
that I can add as a unittest, which will also make it easier for me to debug.

Also if you're using this library for a project, consider adding it (or asking me to add it) to the [Projects](#projects) section.

- [Overview](#overview)
- [Features](#features)
- [Quick Start](#quick-start)
  - [Hello World](#hello-world)
  - [Tables](#tables)
    - [New Table](#new-table)
    - [Iterate with ipairs](#iterate-with-ipairs)
    - [Iterate with statically typed ipairs](#iterate-with-statically-typed-ipairs)
    - [Iterate with pairs](#iterate-with-pairs)
    - [Iterate with statically typed pairs](#iterate-with-statically-typed-pairs)
    - [Array conversion](#array-conversion)
  - [Functions](#functions)
    - [Echo](#echo)
    - [Echo (Variadic)](#echo-variadic)
    - [Mapping function](#mapping-function)
    - [Overloaded functions](#overloaded-functions)
    - [Returning multiple values (statically)](#returning-multiple-values-statically)
    - [Returning multiple values (dynamically)](#returning-multiple-values-dynamically)
    - [Registering a library](#registering-a-library)
    - [Basic Functions](#basic-functions)
    - [Default parameters](#default-parameters)
  - [Structs](#structs)
  - [Executing a string or file with a different _G table](#executing-a-string-or-file-with-a-different-_g-table)
  - [nogc strings](#nogc-strings)
  - [EmmyLua Annotations (IDE autocomplete)](#emmylua-annotations-ide-autocomplete)
  - [Nullable support](#nullable-support)
  - [Tuple support](#tuple-support)
    - [Tuple parsing behaviour](#tuple-parsing-behaviour)
- [Projects](#projects)
- [Contributing](#contributing)

# Features

- Statically linked
- Bundled with prebuilt binaries for LuaJit for Windows, Linux, and MacOS (including Apple Silicon)
- Dynamic values using TaggedAlgebraic
- Ability to convert most D and Lua types to eachother (including structs)
- Provides a high level interface, but also allows manual manipulation of the stack
- Uses a struct-based API instead of classes, to minimise GC usage
  - Some types use ref counting in order to be easy to move around while still keeping lifetime guarentees
- Doesn't shy away from the GC, but does try to minimise usage of it
  - For example, if you don't mind managing the lifetime of a Lua stack variable, you can use `const(char)[]` instead of `string` to avoid copying strings onto the GC.
- Supports Lua 5.1 (mainly for LuaJit)
- Bind Lua functions to statically typed D functions
- Lambdas, functions, and delegates can all be exposed to Lua
- Utilities to generated EmmyLua-notated lua files for IDE autocomplete

# Quick Start

## Hello World

Create a new `LuaState`, passing in `null` so a new state is created. This struct is non-copyable so you might want to put it on the GC heap.

```d
import lumars;

void main()
{
    auto l = LuaState(null); // Or `new LuaState`
    // openlibs is automatically called

    l.doString(`print("Hello, world!")`);
}
```

Here's another way by using the built-in `print` function.

```d
import lumars;

void main()
{
    auto l = LuaState(null);

    auto print = l.globalTable.get!LuaFunc("print");
    print.pcall!0("Hello, world!");
    // !0 means "no return results"
}
```

And here's *another- way where we bind the Lua function into a D function:

```d
import lumars;

void main()
{
    auto l = LuaState(null);

    auto print = l.globalTable.get!LuaFunc("print").bind!(void, string);
    print("Hello, world!");

    // If you want to pass it around like a D func:
    alias Func = void delegate(string);
    Func f = &print.asDelegate;
}
```

## Tables

### New Table

```d
import lumars;

void main()
{
    auto l = LuaState(null);
    auto t = LuaTable.makeNew(&l);

    t["a"] = "bc";
    t[1] = 23;

    assert(t.get!string("a") == "bc");
    assert(t.get!int(1) == 23);
}
```

### Iterate with ipairs

```d
import std.conv : to;

auto l = LuaState(null);
l.doString(`t = { 1, 2, 3 }`);

auto t = l.globalTable.get!LuaTable("t");
auto sum = 0;
t.ipairs!((i, /*LuaValue*/ v)
{
    sum += v.value!LuaNumber.to!int; // LuaNumber is `double`
});
assert(sum == 6);
```

### Iterate with statically typed ipairs

```d
auto l = LuaState(null);
l.doString(`t = { 1, 2, 3 }`);

auto t = l.globalTable.get!LuaTable("t");
t.ipairs!(int, (i, /*int*/ v)
{
    assert(i == v);
});
```

### Iterate with pairs

```d
auto l = LuaState(null);
l.doString(`t = { a = "bc", [1] = 23 }`);

auto t = l.globalTable.get!LuaTable("t");
t.pairs!((k, v) // Both are LuaValue
{
    if(k.isText && k.value!string == "a")
        assert(v.value!string == "bc");
    else if(k.isNumber && k.value!LuaNumber == 1)
        assert(v.value!LuaNumber == 23);
    else
        assert(false);
});
```

### Iterate with statically typed pairs

```d
auto l = LuaState(null);
l.doString(`t = { a = "bc", easy = 123 }`);

auto t = l.globalTable.get!LuaTable("t");
t.pairs!(string, LuaValue, (/*string*/ k, /*LuaValue*/ v)
{
    if(k == "a")
        assert(v.value!string == "bc");
    else if(k == "easy")
        assert(v.value!LuaNumber == 123);
    else
        assert(false);
});
```

### Array conversion

```d
auto l = LuaState(null);
l.doString(`t = { 1, 2, 3, 4, 5 }`);

auto arr = l.globalTable.get!(int[])("t");
assert(arr == [1, 2, 3, 4, 5]);
```

## Functions

### Echo

```d
auto l = LuaState(null);
auto t = LuaTable.makeNew(&l);

t["echo"] = (string text){ writeln(text); };

auto f = t.get!LuaFunc("echo").bind!(void, string);
f("Hello, World!");
```

### Echo (Variadic)

```d
auto l = LuaState(null);

l.globalTable["echo"] = (LuaVariadic args) { foreach(arg; args) writeln(arg); };
l.doString(`echo("Henlo", "Warld!", 420, true)`);
```

### Mapping function

```d
import std.conv : to;

auto l = LuaState(null);

int[] map(int[] input, LuaFunc mapper)
{
    foreach(ref num; input)
    {
        LuaValue[1] result = mapper.pcall!1(num);
        num = result[0].value!LuaNumber.to!int; // Lua numbers are doubles
    }

    return input;
}

l.globalTable["map"] = &map;
l.doString(`
    local values = {1, 2, 3}
    local func   = function(n) return n - 2 end
    local result = map(values, func)
    assert(result[1] == 2 and result[2] == 4 and result[3] == 6)
`);
```

### Overloaded functions

```d
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
```

### Returning multiple values (statically)

A way of returning multiple values in a statically typed way, is to use `std.typecons.Tuple` as your return value:

```d
import std.typecons : tuple

auto multiReturn()
{
    return tuple(20, "40", true);
}

auto lua = new LuaState(null);
lua.register!multiReturn("multiReturn");
lua.doString(`
    local i, s, b = multiReturn()
    assert(i == 20)
    assert(s == "40")
    assert(b)
`);
```

### Returning multiple values (dynamically)

A way of returning multiple values in a dynamically typed way, is to use `LuaVariadic` as your return value:

```d
LuaVariadic multiReturn()
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
```

### Registering a library

You can use the `LuaState.register` function to easily create a Lua table full of functions (a.k.a a Library)

Here's two examples:

```d
import lumars, api, std.path, std.file, std.array;

void registerPathApi(LuaState* lua)
{
    lua.register!(
        "absolutePath",     (string path, string base)  => absolutePath(path, base),
        "absolutePathCwd",  (string path)               => absolutePath(path),
        "buildPath",        (string[] paths)            => buildNormalizedPath(paths),
        "defaultExtension", (string path, string ext)   => defaultExtension(path, ext),
        "dirName",          (string path)               => dirName(path),
        "expandTilde",      (string path)               => expandTilde(path),
        "extension",        (string path)               => extension(path),
        "getcwd",           ()                          => getcwd(),
        "globMatch",        (string path, string patt)  => globMatch(path, patt),
        "isAbsolute",       (string path)               => isAbsolute(path),
        "isValidFilename",  (string filename)           => isValidFilename(filename),
        "isValidPath",      (string path)               => isValidPath(path),
        "normalisePath",    (string path)               => asNormalizedPath(path).array,
        "relativePath",     (string path, string base)  => relativePath(path, base),
        "relativePathCwd",  (string path)               => relativePath(path),
        "setExtension",     (string path, string ext)   => setExtension(path, ext),
        "stripExtension",   (string path)               => stripExtension(path)
    )("sh.path");
}
```

```d
import lumars, api, std.file, std.exception, std.conv, std.algorithm, std.array;

void registerFsApi(LuaState* lua)
{
    lua.register!(
        "append", (LuaState* l, string file, LuaValue v) {
            enforce(v.isTable || v.isText, "Expected parameter 2 to be a table or a string.");
            if(v.isText)
                append(file, v.textValue);
            else
            {
                auto t = v.tableValue;
                if(t.length == 0)
                    return;
                t.push();
                scope(exit) l.pop(1);
                append(file, l.get!(ubyte[])(-1));
            }
        },
        "chdir",            chdir!string,
        "copy",             (string from, string to)    => copy(from, to),
        "dirEntries",       (string path, string mode)  => dirEntries(path, mode.to!SpanMode).map!(de => de.name).array,
        "dirEntriesGlob",   (string path, string pattern, string mode)  
                                                        => dirEntries(path, pattern, mode.to!SpanMode).map!(de => de.name).array,
        "exists",           exists!string,
        "getSize",          getSize!string,
        "isDir",            isDir!string,
        "isFile",           isFile!string,
        "mkdir",            mkdir!string,
        "mkdirRecurse",     mkdirRecurse,
        "readString",       (string file)               => readText(file),
        "readBytes",        (string str)                => cast(ubyte[])read(str),
        "remove",           std.file.remove!string,
        "rename",           rename!(string, string),
        "rmdir",            rmdir!string,
        "rmDirRecurse",     rmdirRecurse,
        "tempDir",          tempDir,
        "write", (LuaState* l, string file, LuaValue v) {
            enforce(v.isTable || v.isText, "Expected parameter 2 to be a table or a string.");
            if(v.isText)
                write(file, v.textValue);
            else
            {
                auto t = v.tableValue;
                if(t.length == 0)
                    return;
                t.push();
                scope(exit) l.pop(1);
                write(file, l.get!(ubyte[])(-1));
            }
        },
    )("sh.fs");
}
```

### Basic Functions

While Lumars provides a nice, user-friendly way to interface D and Lua functions together; sometimes you need to write
a function that needs to manually manipulate the Lua stack in order to do its job.

These are referred to as "Basic" functions, since they don't need any of the fancy wrapper logic given by default.

To create a basic function, simply annotate the function with `@LuaBasicFunction`:

```d
auto lua = LuaState(null);

@LuaBasicFunction
int basic(LuaState* lua)
{
    return lua.top(); // lua.top will be the amount of parameters we have. So return all params.
}
lua.register!basic("basic");

lua.doString(`
    assert(basic(1) == 1)

    a,b = basic(1, "2")
    assert(a == 1 and b == "2")
`);
```

### Default parameters

Lumars supports functions with default parameters. Simply... use them just like you would normally:

(Feature contribued by @Domain)

```d
auto lua = new LuaState(null);
lua.register!(
    "defaultParams", (int a, int b = 1, int c = 2) { return a+b+c; }
)("lib");

lua.doString(`
    assert(lib.defaultParams(1) == 4)
    assert(lib.defaultParams(1, 2) == 5)
    assert(lib.defaultParams(1, 3, 5) == 9)
`);
```

## Structs

Lumars can convert D structs to and from Lua.

When converting from Lua to D, any unknown fields are ignored, and any missing fields in the struct are set to their initial value.

In the future I'd like to introduce UDAs to customise behaviour, but for now this should be a sensible default.

```d
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
}

auto a = A(
    "bc",
    [B("c")],
    ["c": C("123")]
);

auto l = LuaState(null);

// *Anything- that .push can use is also useable by the likes of LuaTable.
// We're doing manual stack manip just because it's simpler for this case.
l.push(a);
scope(exit) l.pop(1);
auto luaa = l.get!A(-1);

assert(luaa.a == "bc");
assert(luaa.b.length == 1);
assert(luaa.b == [B("c")]);
assert(luaa.c.length == 1);
assert(luaa.c["c"] == C("123"));
```

Another example:

```d
struct Vector2D
{
    float x;
    float y;
}

auto l = LuaState(null);

l.doString(`
    function addVectors(vectA, vectB)
        return {
            x = vectA.x + vectB.x,
            y = vectA.y + vectB.y
        }
    end
`);

auto f = l.globalTable.get!LuaFunc("addVectors").bind!(Vector2D, Vector2D, Vector2D);
assert(f(
    Vector2D(1, 1),
    Vector2D(9, 9)
) == Vector2D(10, 10));
```

## Executing a string or file with a different _G table

For sandboxing reasons, among other reasons, it's useful to be able to run external Lua under with a different
environment table. Lumars supports this easily:

```d
unittest
{
    auto state   = LuaState(null);
    auto print   = state._G.get!LuaFunc("print");
    auto _G1     = LuaTable.makeNew(&state);
    _G1["abc"]   = 123;
    _G1["print"] = print;

    const code = "print(abc)";

    state.doString(code, _G1); // or doFile
}
```

## nogc strings

Anytime you need to access a string that's on the Lua stack, instead of specifying a string (e.g. `state.get!string(-1)`) you
can instead use `const(char)[]` which won't allocate any GC memory.

You do however have to keep in mind that the lifetime of the string is now attached to the lifetime of the stack variable, so
be careful.

## EmmyLua Annotations (IDE autocomplete)

One common annoyance when dealing with a mix of Lua and host language code, is the lack of autocompletion provided by your
IDE when programming.

To help solve this issue, Lumars can help you generate a Lua file filled with [EmmyLua](https://emmylua.github.io/annotation.html) annotations, allowing you to gain intelisense for any plugin that supports EmmyLua annotations.

It does a pretty ok job, but there's still a *lot* of room for improvement.

The easiest way to use it is like this:

```d
import lumars;
import std.meta : AliasSeq;

struct S
{
    int a;
    LuaValue b;
}

alias EXPORT = AliasSeq!(
    "myfunc1", (string s, LuaValue v) { return S.init; }
);

void registerFuncs(LuaState* lua)
{
    lua.register!EXPORT("mylib");

    EmmyLuaBuilder b;
    b.addFunctions!EXPORT("mylib");
    
    import std.file : write;
    write("api.lua", b.toString());
    /++
        mylib = mylib or {}
        ---@class S
        ---@field public a number
        ---@field public b any
        local S
        --@type fun(_:string, _:any):S
        mylib.myfunc1 = mylib.myfunc1 or function() assert(false, 'not implemented') end
    ++/
}
```

Then simply `require("api.lua")` in your lua code, et voila (hopefully).

## Nullable Support

Lumars natively supports Phobos' `Nullable` type.

If the `Nullable` is null: A Lua `nil` is used.

If the `Nullable` isn't null: The underlying value is used.

Most of the code should transparently support `Nullable`.

## Tuple Support

Lumars natively supports Phobos' `Tuple` type.

You can use this to easily return multiple values from a function in D.

You can also use this to easily parse multiple Lua values into a single D value.

Currently `Nullable` isn't supported within tuples very well.

Currently partial parsing (i.e. the tuple expects 2 values but only 1 is available) of tuples isn't supported, and will generate an exception, outside of the special case described below.

### Tuple Parsing behaviour

Normally Lumars will try to parse the top `n` (where `n` is the number of values in the tuple) values from the stack into the tuple, and if that fails either due to type mismatches, incorrect number of values, etc. then an exception is generated.

If:

* Lumars fails to parse `n` values from the top of the stack into a Tuple

* And the failure occurs for the 0th value

* And the 0th value is a table

* And the tuple has named fields (e.g. `Tuple!(int, "foo", int, "bar")`)

* Then Lumars will attempt to parse the 0th value into the tuple as if it were a struct.

```d
import std.typecons : Tuple;

Tuple!(int, string, bool) multiReturn()
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

alias Employee = Tuple!(int, "ID", string, "Name", bool, "FullTime");

lua.doString(`
    function employee1()
        return 15305, "Domain", true
    end

    function employee2()
        return { ID = 15605, Name = "Range", FullTime = false }
    end
`);

auto f = lua.globalTable.get!LuaFunc("employee1").bind!(Employee);
auto g = lua.globalTable.get!LuaFunc("employee2").bind!(Employee);
auto employee1 = f();
auto employee2 = g();
assert(employee1.ID == 15305);
assert(employee1.Name == "Domain");
assert(employee1.FullTime);
assert(employee2.ID == 15605);
assert(employee2.Name == "Range");
assert(!employee2.FullTime);
```

# Projects

- [Inochi Session](https://github.com/Inochi2D/inochi-session): A tool used to do live streaming with Inochi2D puppets, uses Lumars for plugins and expression bindings.

# Contributing

I'm perfectly fine with anyone wanting to contribute.

I'd especially love it if you open an issue if you come across any bugs.

I'd also love it if you ever think "how do I do X?" and open an issue for it so I can add it to this README.
