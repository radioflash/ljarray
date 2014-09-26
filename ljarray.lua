----------------------------------------------------------------------------
-- LuaJIT module for dynamic-size cdata-arrays.
--
-- Copyright (C) 2014 Wolfgang Pupp. All rights reserved.
-- Released under the MIT license. See Copyright Notice in LICENSE file.
----------------------------------------------------------------------------
-- 
-- LJArrays are very similar to C++ vectors. They:
--  - consist of LuaJIT 'cdata': Their elements are plain C primitives or 
--    structures.
--  - are homogenous: All elements have the same type, which is fixed
--    before the LJArray is instantiated (e.g. double or int).
--  - support dynamic resizing (element count may change after the LJArray
--    is instantiated); see 'clear', 'reserve' and 'shrink' methods.
--  - have a capacity (array.cap) different from their current element
--    count (array.cnt), to avoid excessive memory reallocation.
--
-- Length operator #:
-- The length operator (#array) emulates the behavior of ordinary Lua-
-- tables, returning the highest populated index (or -1) as a Lua-Number.
-- This is *not* the number of elements (array.cnt), which might be      
-- an uint64_t (size_t).
--
-- Garbage collection:
-- A finalizer for elements can be passed as 2nd parameter when the array-
-- type is created. Arrays with a finalizer disable the finalizer on new
-- elements they aquire (!!). This is to avoid finalizing data twice.
--
-- Implicit initialization (LJArrays consisting of struct/pointer only):
-- When values at indices above array.cnt are set/inserted, all
-- elements inbetween are implicitly initialized: If the element
-- type has a __new metafunction ("constructor"), then that constructor
-- is called for each implicitly initialized element.
--
-- Overhead and caching:
-- Requesting an array with a unique ctype results in generating the
-- array-ctype itself and a suitable metatable. The result is cached,
-- and the next time a LJArray of the same type is requested, only a table
-- lookup is necessary. Creating multiple ctypes for the same type should
-- be avoided (example v3 and v4). Examples v5 and v6 show how to do this
-- properly. Examples:
-- local v1 = ljarray'int'() --overhead (first request of this element type)
-- local v2 = ljarray'int'() --no overhead
-- local v3 = ljarray'struct {int x; int y;}'() --overhead (don't do this!)
-- local v4 = ljarray'struct {int x; int y;}'() --still overhead (!!)
-- local el_type = ffi.typeof'struct {int x; int y;}'
-- local v5 = ljarray(el_type)() --overhead
-- local v6 = ljarray(el_type)() --no overhead
--
-- Errors: 
-- When reallocation fails, an assertion is triggered (but the ljarray
-- is left in a consistent state).
--
-- API:
-- The return value of the ljarray-module is a combined factory-function and
-- lookup table. When called with a ct (a C type specification); preferably
-- a string describing the type, but may also be an instance of the desired
-- type, or a ctype (result of ffi.typeof).
-- 2nd parameter is a function that gets called on each element when the 
-- array itself is cleared or garbage collected.
------------------------------------------------------------------------------

local ffi = require'ffi'
local bit = require'bit'

local assert, rawget = assert, rawget
local tonumber, tostring, format = tonumber, tostring, string.format
local bor, rshift = bit.bor, bit.rshift
local C, new, fill, gc = ffi.C, ffi.new, ffi.fill, ffi.gc
local typeof, sizeof, metatype = ffi.typeof, ffi.sizeof, ffi.metatype

ffi.cdef[[
void * malloc (size_t size);
void * realloc (void *ptr, size_t size);
void * memmove (void *destination, const void *source, size_t num);
void free (void *ptr);
]]

local function size_roundup(size)
  size = size - 1
  size = bor(size, rshift(size, 1))
  size = bor(size, rshift(size, 2))
  size = bor(size, rshift(size, 4))
  size = bor(size, rshift(size, 8))
  size = bor(size, rshift(size, 16))
  size = bor(size, rshift(size, 32))
  return size + 1
end

local ljarray_new_type = function(lja_cache, ct, gc_element)
  local el_typename = tostring(ct)
  local el_type = typeof(ct)
  local el_size = sizeof(el_type)
  local el_gc = gc_element
  
  if not el_gc and rawget(lja_cache, ct) then
    return rawget(lja_cache, ct)
  end
  
  --take ownership of an element (remove finalizer if we have one ourselves)
  local function take_over(el)
    if el_gc then
      return gc(el, nil)
    end
    return el
  end
  
  local reserve = function(v, cap)
    if cap > v.cap then
      local bytecap = size_roundup(cap * el_size)
      local buf = C.realloc(v.data, bytecap)
      assert(buf ~= nil, "memory reallocation failed")
      v.data = buf
      v.cap = bytecap / el_size
    end
  end
  
  local free = function(v, gc_element)
    gc_element = gc_element ~= nil and gc_element or el_gc
    if gc_element ~= nil then
      local i = v.cnt
      if i > 0 then repeat
        i = i - 1
        gc_element(v.data[i])
      until i == 0 end
    end
    C.free(v.data)
    v.data = nil
    v.cnt = 0
    v.cap = 0
  end
  
  local methods = {
    reserve = reserve,
    insert = function(v, pos, el)
      if el == nil then
        el = pos
        pos = v.cnt > 0 and v.cnt or 1
      end
    
      if pos == v.cnt then
        reserve(v, v.cnt + 1)
        v.cnt = v.cnt + 1
      elseif pos < v.cnt then
        reserve(v, v.cnt + 1)
        C.memmove(v.data + pos + 1, v.data + pos, (v.cnt - pos) * el_size);
        v.cnt = v.cnt + 1
      elseif pos > v.cnt then
        reserve(v, pos+1)
        --implicitly initialized elements
        local i = v.cnt
        repeat
          v.data[i] = take_over(el_type())
          i = i + 1
        until i == pos
        v.cnt = pos + 1
      end
      v.data[pos] = take_over(el)
    end,
    remove = function(v, pos)
      if not pos then
        --remove last element
        pos = v.cnt - 1
        v.cnt = v.cnt - 1
        return v.data[pos]
      end
      if pos < 0 or pos >= v.cnt then
        return nil
      end
      local el = v.data[pos]
      if pos < v.cnt-1 then
        C.memmove(v.data + pos, v.data + pos + 1, (v.cnt - pos - 1) * el_size);
      end
      v.cnt = v.cnt - 1
      return el
    end,
    clear = free,
    shrink = function(v)
      if v.cap > v.cnt then
        local buf = C.realloc(v.data, v.cnt * el_size)
        assert(v.cnt == 0 or buf ~= nil)
        v.data = buf
        v.cap = v.cnt
      end
    end,
  }
  
  local con = metatype(typeof([[struct {
    $ *data;
    size_t cnt;
    size_t cap;
  }]], el_type), {
    __index = function(v, k)
      return methods[k] or k < v.cnt and v.data[k] or nil
    end,
    __newindex = function(v, k, el)
      v:reserve(k+1)
      
      if k < v.cnt and el_gc then
        el_gc(v.data[k])
        v.data[k] = take_over(el)
      elseif k == v.cnt then
        v.data[k] = take_over(el)
        v.cnt = k + 1
      elseif k > v.cnt then
        local i = v.cnt
        repeat
          v.data[i] = take_over(el_type())
          i = i + 1
        until i == k
        v.data[k] = take_over(el)
        v.cnt = k + 1
      end
    end,
    __new = function(vec_ct, cap)
      local v = new(vec_ct)
      if cap then
        v:reserve(cap)
      end
      return v
    end,
    __len = function(v)
      return tonumber(v.cnt)-1
    end,
    __gc = free,
    __tostring = function(v)
      return format('ljarray<%s>(cnt: %i, cap: %i)', el_typename,
          tonumber(v.cnt), tonumber(v.cap))
    end,
  })
  
  if el_gc then
    return con
  end
  lja_cache[ct] = con
  return con
end

local lja_cache = setmetatable({}, {
  __index = ljarray_new_type,
  __call = ljarray_new_type,
})

return lja_cache
