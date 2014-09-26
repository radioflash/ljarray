# LJArray

LuaJIT module for dynamic-size cdata-arrays.

## Usage


    local ljarray = require'ljarray'

    -- obtain array-constructor-function
    local intarray = ljarray.int

    -- instantiate array (argument is initial array capacity)
    local v = intarray(10)

    print(#v) --> (-1) length operator is intended for Lua-for-loops

    for i=0,5 do
      v[i] = i
    end

    print(#v) --> 5 length operator returns highest valid index
    print(v[6]) --> out of bounds-access returns nil

## API

### array_constructor = ljarray(ct [,gc_element])


The table returned by require'ljarray' is callable and works as factory-
function. When a 'gc_element'- function is supplied, ljarray *always*
creates a new array_constructor on every call; constructors for 'plain'
arrays are cached, on the other hand, and subsequent calls with the same
'ct' parameter will return the same array_constructor.

Note: If you pass a non-string ct parameter, make sure its always the same
object or caching won't work.

### array = array_constructor([capacity])

Actually instantiates an array. Creates an empty array if no 'capacity'
parameter is supplied.

## Array methods

** `array:reserve(capacity)` **

Reserves space for at least 'capacity' elements.

** `array:shrink()` **

Shrinks array so that no more than the current element count fits in.

** `array:clear([gc_element])` **

Frees all elements.
If the 'gc_element' parameter is boolean 'false', no finalizer is called.
Otherwise, 'gc_element' is used a finalizer on all cleared array elements.
If 'gc_element' is nil, the finalizer supplied on array-type construction (if
any) is used.

Note: array may be used/refilled after 'clear'-ing.

** `#array` **

Returns the highest element-index, or -1 if the array is empty.
This is basically (array.cnt-1), but guaranteed to be a Lua-number.

** `array:insert([pos], element)` **

Inserts an element at 'pos'. 
'pos' defaults to #array + 1.
If there are elements after the insertion-position, they are moved.

Elements between the previous end of the array and 'pos' are implicitly
initialized.

** `array[pos] = element` **

Behavior is identical to array.insert, except that elements are finalized
and replaced (if a finalizer is set) instead of shoved back.

Like array.insert, this will trigger implicit initialization of elements
if 'pos' is bigger than #array + 1.

** `element = array[pos]` **

Returns the element at 'pos'. Returns nil if 'pos' is out-of-bounds.

** `tostring(array)` **

Prints element-type, current element count and current capacity.

## Garbage collection

Array is 'clear'-ed on finalization.

Note: If the array was supplied with a finalizer for its elements, it
will take ownership of any elements that are inserted, and disable any
finalizer on them (!!).
