# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
Tools for collecting and manipulating stack traces. Mainly used for building errors.
"""
module StackTraces


import Base: hash, ==, show
import Base.Serializer: serialize, deserialize

export StackTrace, StackFrame, stacktrace, catch_stacktrace

"""
    StackFrame

Stack information representing execution context, with the following fields:

- `func::Symbol`

  The name of the function containing the execution context.

- `linfo::Union{Some{Core.MethodInstance}, Void}`

  The MethodInstance containing the execution context (if it could be found).

- `file::Symbol`

  The path to the file containing the execution context.

- `line::Int`

  The line number in the file containing the execution context.

- `from_c::Bool`

  True if the code is from C.

- `inlined::Bool`

  True if the code is from an inlined frame.

- `pointer::UInt64`

  Representation of the pointer to the execution context as returned by `backtrace`.

"""
struct StackFrame # this type should be kept platform-agnostic so that profiles can be dumped on one machine and read on another
    "the name of the function containing the execution context"
    func::Symbol
    "the path to the file containing the execution context"
    file::Symbol
    "the line number in the file containing the execution context"
    line::Int
    "the MethodInstance containing the execution context (if it could be found)"
    linfo::Union{Some{Core.MethodInstance}, Void}
    "true if the code is from C"
    from_c::Bool
    "true if the code is from an inlined frame"
    inlined::Bool
    "representation of the pointer to the execution context as returned by `backtrace`"
    pointer::UInt64  # Large enough to be read losslessly on 32- and 64-bit machines.
end

StackFrame(func, file, line) = StackFrame(Symbol(func), Symbol(file), line,
                                          nothing, false, false, 0)

"""
    StackTrace

An alias for `Vector{StackFrame}` provided for convenience; returned by calls to
`stacktrace` and `catch_stacktrace`.
"""
const StackTrace = Vector{StackFrame}

const empty_sym = Symbol("")
const UNKNOWN = StackFrame(empty_sym, empty_sym, -1, nothing, true, false, 0) # === lookup(C_NULL)


#=
If the StackFrame has function and line information, we consider two of them the same if
they share the same function/line information.
=#
function ==(a::StackFrame, b::StackFrame)
    a.line == b.line && a.from_c == b.from_c && a.func == b.func && a.file == b.file && a.inlined == b.inlined
end

function hash(frame::StackFrame, h::UInt)
    h += 0xf4fbda67fe20ce88 % UInt
    h = hash(frame.line, h)
    h = hash(frame.file, h)
    h = hash(frame.func, h)
    h = hash(frame.from_c, h)
    h = hash(frame.inlined, h)
end

# provide a custom serializer that skips attempting to serialize the `outer_linfo`
# which is likely to contain complex references, types, and module references
# that may not exist on the receiver end
function serialize(s::AbstractSerializer, frame::StackFrame)
    Serializer.serialize_type(s, typeof(frame))
    serialize(s, frame.func)
    serialize(s, frame.file)
    write(s.io, frame.line)
    write(s.io, frame.from_c)
    write(s.io, frame.inlined)
    write(s.io, frame.pointer)
end

function deserialize(s::AbstractSerializer, ::Type{StackFrame})
    func = deserialize(s)
    file = deserialize(s)
    line = read(s.io, Int)
    from_c = read(s.io, Bool)
    inlined = read(s.io, Bool)
    pointer = read(s.io, UInt64)
    return StackFrame(func, file, line, nothing, from_c, inlined, pointer)
end


"""
    lookup(pointer::Union{Ptr{Void}, UInt}) -> Vector{StackFrame}

Given a pointer to an execution context (usually generated by a call to `backtrace`), looks
up stack frame context information. Returns an array of frame information for all functions
inlined at that point, innermost function first.
"""
function lookup(pointer::Ptr{Void})
    infos = ccall(:jl_lookup_code_address, Any, (Ptr{Void}, Cint), pointer - 1, false)
    isempty(infos) && return [StackFrame(empty_sym, empty_sym, -1, nothing, true, false, convert(UInt64, pointer))]
    res = Vector{StackFrame}(length(infos))
    for i in 1:length(infos)
        info = infos[i]
        @assert(length(info) == 7)
        li = info[4] === nothing ? nothing : Some(info[4])
        res[i] = StackFrame(info[1], info[2], info[3], li, info[5], info[6], info[7])
    end
    return res
end

lookup(pointer::UInt) = lookup(convert(Ptr{Void}, pointer))

# allow lookup on already-looked-up data for easier handling of pre-processed frames
lookup(s::StackFrame) = StackFrame[s]
lookup(s::Tuple{StackFrame,Int}) = StackFrame[s[1]]

"""
    stacktrace([trace::Vector{Ptr{Void}},] [c_funcs::Bool=false]) -> StackTrace

Returns a stack trace in the form of a vector of `StackFrame`s. (By default stacktrace
doesn't return C functions, but this can be enabled.) When called without specifying a
trace, `stacktrace` first calls `backtrace`.
"""
function stacktrace(trace::Vector{Ptr{Void}}, c_funcs::Bool=false)
    stack = vcat(StackTrace(), map(lookup, trace)...)::StackTrace

    # Remove frames that come from C calls.
    if !c_funcs
        filter!(frame -> !frame.from_c, stack)
    end

    # Remove frame for this function (and any functions called by this function).
    remove_frames!(stack, :stacktrace)

    # is there a better way?  the func symbol has a number suffix which changes.
    # it's possible that no test is needed and we could just shift! all the time.
    # this line was added to PR #16213 because otherwise stacktrace() != stacktrace(false).
    # not sure why.  possibly b/c of re-ordering of base/sysimg.jl
    !isempty(stack) && startswith(string(stack[1].func),"jlcall_stacktrace") && shift!(stack)
    stack
end

stacktrace(c_funcs::Bool=false) = stacktrace(backtrace(), c_funcs)

"""
    catch_stacktrace([c_funcs::Bool=false]) -> StackTrace

Returns the stack trace for the most recent error thrown, rather than the current execution
context.
"""
catch_stacktrace(c_funcs::Bool=false) = stacktrace(catch_backtrace(), c_funcs)

"""
    remove_frames!(stack::StackTrace, name::Symbol)

Takes a `StackTrace` (a vector of `StackFrames`) and a function name (a `Symbol`) and
removes the `StackFrame` specified by the function name from the `StackTrace` (also removing
all frames above the specified function). Primarily used to remove `StackTraces` functions
from the `StackTrace` prior to returning it.
"""
function remove_frames!(stack::StackTrace, name::Symbol)
    splice!(stack, 1:findlast(frame -> frame.func == name, stack))
    return stack
end

function remove_frames!(stack::StackTrace, names::Vector{Symbol})
    splice!(stack, 1:findlast(frame -> frame.func in names, stack))
    return stack
end

"""
    remove_frames!(stack::StackTrace, m::Module)

Returns the `StackTrace` with all `StackFrame`s from the provided `Module` removed.
"""
function remove_frames!(stack::StackTrace, m::Module)
    filter!(f -> !from(f, m), stack)
    return stack
end

function show_spec_linfo(io::IO, frame::StackFrame)
    if frame.linfo === nothing
        if frame.func === empty_sym
            @printf(io, "ip:%#x", frame.pointer)
        else
            print_with_color(Base.have_color && get(io, :backtrace, false) ? Base.stackframe_function_color() : :nothing, io, string(frame.func))
        end
    else
        linfo = get(frame.linfo)
        if isa(linfo.def, Method)
            Base.show_tuple_as_call(io, linfo.def.name, linfo.specTypes)
        else
            Base.show(io, linfo)
        end
    end
end

function show(io::IO, frame::StackFrame; full_path::Bool=false)
    show_spec_linfo(io, frame)
    if frame.file !== empty_sym
        file_info = full_path ? string(frame.file) : basename(string(frame.file))
        print(io, " at ")
        Base.with_output_color(Base.have_color && get(io, :backtrace, false) ? Base.stackframe_lineinfo_color() : :nothing, io) do io
            print(io, file_info, ":")
            if frame.line >= 0
                print(io, frame.line)
            else
                print(io, "?")
            end
        end
    end
    if frame.inlined
        print(io, " [inlined]")
    end
end

"""
    from(frame::StackFrame, filter_mod::Module) -> Bool

Returns whether the `frame` is from the provided `Module`
"""
function from(frame::StackFrame, m::Module)
    finfo = frame.linfo
    result = false

    if finfo !== nothing
        frame_m = get(finfo).def
        isa(frame_m, Method) && (frame_m = frame_m.module)
        result = module_name(frame_m) === module_name(m)
    end

    return result
end

end
