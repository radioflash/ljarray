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
--  - are homogenous: All elements have the same type, which is fixed when
--    the LJArray is instantiated (e.g. double or int)
--  - support dynamic resizing (element count may change after the LJArray
--    is instantiated)
--  - have a capacity (array.cap) different from their current element
--    count (array.cnt), to avoid excessive memory reallocation.
--
-- Note:
-- The length operator emulates the behavior of ordinary Lua-tables,      
-- returning the highest populated index (or -1) as a Lua-Number.      
-- This is *not* the number of elements (array.cnt), which might be      
-- an uint64_t (size_t).
--
-- Implicit initialization (LJArrays consisting of struct/pointer only):
-- When values at indices above array.cnt are set/inserted, all
-- elements inbetween are implicitly initialized: If the element
-- type has a __new metafunction ("constructor"), then this this
-- constructor is called for each implicitly initialized element.
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
------------------------------------------------------------------------------

local ffi = require'ffi'
local bit = require'bit'

local assert = assert
local tonumber, tostring, format = tonumber, tostring, string.format
local bor, rshift = bit.bor, bit.rshift
local C, new, fill = ffi.C, ffi.new, ffi.fill
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
    gc_element = gc_element or el_gc
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
        pos = v.cnt
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
          v.data[i] = el_type()
          i = i + 1
        until i == pos
        v.cnt = pos + 1
      end
      v.data[pos] = el
    end,
    set_element_gc = function(v, f)
      el_gc = f
    end,
    free = free,
    shrink = function(v)
      if v.cap > v.cnt then
        local buf = C.realloc(v.data, v.cnt * el_size)
        assert(v.cnt == 0 or buf ~= nil)
        v.data = buf
        v.cap = v.cnt
      end
    end,
  }
  
  lja_cache[el_type] = metatype(typeof([[struct {
    $ *data;
    size_t cnt;
    size_t cap;
  }]], el_type), {
    __index = function(v, k)
      return methods[k] or v.data[k]
    end,
    __newindex = function(v, k, el)
      v:reserve(k+1)
      
      v.data[k] = el
      if k == v.cnt then
        v.cnt = k + 1
      elseif k > v.cnt then
        local i = v.cnt
        repeat
          v.data[i] = el_type()
          i = i + 1
        until i == k
        v.cnt = k + 1
      end
    end,
    __call = index,
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
  return lja_cache[el_type]
end

local lja_cache = setmetatable({}, {
  __index = ljarray_new_type,
  __call = ljarray_new_type,
})

return lja_cache
