local ffi = require'ffi'
local ljarray = require'ljarray'

----------------------------------------------------------------------------
-- simple integer array
----------------------------------------------------------------------------
local a = ljarray.int(100)
for i=1,5 do
  a:insert(i) --insert behaves like the default lua insert
end
a:remove(1)
for i=1,#a do
  io.write(tostring(a[i]))
end
io.write'\n'

----------------------------------------------------------------------------
-- nested array
----------------------------------------------------------------------------
ffi.cdef('typedef $ intarray;', ljarray.int)

-- 2nd parameter is a function that gets called on each element when the 
-- array itself is cleared or garbage collected.
-- Passing the element type by string results in nicer tostring-output.
-- Avoid passing the element type as ctype, and if you do, always pass the
-- exact same value (!!) otherwise a unique array-type (plus methods
-- and metatable) will be generated on *every* call of ljarray(<ctype>),
-- instead of just once.
local a = ljarray('intarray', ljarray.int.clear)()

a[1] = ljarray.int()
a[1][6] = 5 --a[0] is implicitly initialized
a[0][0] = 42
print(a)
print(a[1][6]) 
print(a[0][0])

----------------------------------------------------------------------------
-- 'Point'-struct with pointless finalizer.
----------------------------------------------------------------------------
ffi.cdef'typedef struct { double x, y; } Point;'
local Point = ffi.typeof('Point')

local free_point = function(p) print('point destructor', p) end
local new_point = function(ct)
  local p = ffi.new(ct) 
  print('point constructor', p)
  return p
end
ffi.metatype(Point, {__new = new_point, __gc = free_point})

local v = ljarray(Point, free_point)()

-- ljarrays with the ability to free their elements disable
-- the finalizer on elements that they aquire.
-- If this were not the case, array elements might be finalized
-- multiple times, or array content might be finalized even before
-- the array is garbage collected. 
-- Thus, 'el' will *not* be finalized when it goes out of scope (because
-- we copied its contents into our array, and those contents *are*
-- finalizede.g. when 'clear'-ing the array or when the array itself is
-- garbage-collected).
local el = Point()
-- implicit initialization of v[0] triggers point-constructor call:
v[1] = el
print'clear'
-- point-destructor gets called twice:
v:clear()
print'cleared'
v[0] = el
-- point-destructor gets called once (v cleans up its last remaining
-- element when garbage-collected):
