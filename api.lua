mylib = mylib or {}
---@class S
---@field public a number
---@field public b any
local S
--@type fun(_:string, _:any):S
mylib.myfunc1 = mylib.myfunc1 or function() assert(false, 'not implemented') end
