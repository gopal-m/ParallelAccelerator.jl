#=
Copyright (c) 2015, Intel Corporation
All rights reserved.

Redistribution and use in source and binary forms, with or without 
modification, are permitted provided that the following conditions are met:
- Redistributions of source code must retain the above copyright notice, 
  this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice, 
  this list of conditions and the following disclaimer in the documentation 
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE 
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) 
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF 
THE POSSIBILITY OF SUCH DAMAGE.
=#

module ParallelIR
export num_threads_mode

import CompilerTools.DebugMsg
DebugMsg.init()

using CompilerTools
using CompilerTools.LambdaHandling
using CompilerTools.Helper
using ..DomainIR
using CompilerTools.AliasAnalysis
import ..ParallelAccelerator
if ParallelAccelerator.getPseMode() == ParallelAccelerator.THREADS_MODE
using Base.Threads
end

import Base.show
import CompilerTools.AstWalker
import CompilerTools.ReadWriteSet
import CompilerTools.LivenessAnalysis
import CompilerTools.Loops
import CompilerTools.Loops.DomLoops

# uncomment this line when using Debug.jl
#using Debug

function ns_to_sec(x)
    x / 1000000000.0
end

num_threads_mode = 0
function PIRNumThreadsMode(x)
    global num_threads_mode = x
end


const ISCAPTURED = 1
const ISASSIGNED = 2
const ISASSIGNEDBYINNERFUNCTION = 4
const ISCONST = 8
const ISASSIGNEDONCE = 16
const ISPRIVATEPARFORLOOP = 32

unique_num = 1

"""
Ad-hoc support to mimic closures when we want the arguments to be processed during AstWalk.
"""
type DelayedFunc
  func :: Function
  args
end

function callDelayedFuncWith(f::DelayedFunc, args...)
    full_args = vcat(f.args, Any[args...])
    f.func(full_args...)
end


"""
Holds the information about a loop in a parfor node.
"""
type PIRLoopNest
    indexVariable :: SymbolNode
    lower
    upper
    step
end

"""
Holds the information about a reduction in a parfor node.
"""
type PIRReduction
    reductionVar  :: SymbolNode
    reductionVarInit
    reductionFunc
end

"""
Holds information about domain operations part of a parfor node.
"""
type DomainOperation
    operation
    input_args :: Array{Any,1}
end

"""
Holds a dictionary from an array symbol to an integer corresponding to an equivalence class.
All array symbol in the same equivalence class are known to have the same shape.
"""
type EquivalenceClasses
    data :: Dict{Symbol,Int64}

    function EquivalenceClasses()
        new(Dict{Symbol,Int64}())
    end
end

"""
At some point we realize that two arrays must have the same dimensions but up until that point
we might not have known that.  In which case they will start in different equivalence classes,
merge_to and merge_from, but need to be combined into one equivalence class.
Go through the equivalence class dictionary and for any symbol belonging to the merge_from
equivalence class, change it to now belong to the merge_to equivalence class.
"""
function EquivalenceClassesMerge(ec :: EquivalenceClasses, merge_to :: Symbol, merge_from :: Symbol)
    to_int   = EquivalenceClassesAdd(ec, merge_to)
    from_int = EquivalenceClassesAdd(ec, merge_from)

    # For each array in the dictionary.
    for i in ec.data
        # If it is in the "merge_from" class...
        if i[2] == merge_from
            # ...move it to the "merge_to" class.
            ec.data[i[1]] = merge_to
        end
    end
    nothing
end

"""
Add a symbol as part of a new equivalence class if the symbol wasn't already in an equivalence class.
Return the equivalence class for the symbol.
"""
function EquivalenceClassesAdd(ec :: EquivalenceClasses, sym :: Symbol)
    # If the symbol isn't already in an equivalence class.
    if !haskey(ec.data, sym)
        # Find the maximum equivalence class "m".
        a = collect(values(ec.data))
        m = length(a) == 0 ? 0 : maximum(a)
        # Create a new equivalence class with this symbol with class "m+1"
        ec.data[sym] = m + 1
    end
    ec.data[sym]
end

"""
Clear an equivalence class.
"""
function EquivalenceClassesClear(ec :: EquivalenceClasses)
    empty!(ec.data)
end

import Base.hash
import Base.isequal

type RangeExprs
    start_val
    skip_val
    last_val
end

"""
Holds the information from one Domain IR :range Expr.
"""
type RangeData
    start
    skip
    last
    exprs :: RangeExprs
    offset_temp_var :: SymNodeGen        # New temp variables to hold offset from iteration space for each dimension.

    function RangeData(s, sk, l, sv, skv, lv, temp_var)
        new(s, sk, l, RangeExprs(sv, skv, lv), temp_var)
    end
    function RangeData(re :: RangeExprs)
        new(nothing, nothing, nothing, re, :you_should_never_see_this_used)
    end
end

function hash(x :: RangeData)
    @dprintln(4, "hash of RangeData ", x)
    hash(x.exprs.last_val)
end
function isequal(x :: RangeData, y :: RangeData)
    @dprintln(4, "isequal of RangeData ", x, " ", y)
    isequal(x.exprs, y.exprs)
end
function isequal(x :: RangeExprs, y :: RangeExprs)
    isequal(x.start_val, y.start_val) &&
    isequal(x.skip_val, y.skip_val ) &&
    isequal(x.last_val, y.last_val)
end

function isStartOneRange(re :: RangeExprs)
    return re.start_val == 1
end

type MaskSelector
    value :: SymAllGen
end

function hash(x :: MaskSelector)
    ret = hash(x.value)
    @dprintln(4, "hash of MaskSelector ", x, " = ", ret)
    return ret
end
function isequal(x :: MaskSelector, y :: MaskSelector)
    @dprintln(4, "isequal of MaskSelector ", x, " ", y)
    isequal(x.value, y.value)
end

type SingularSelector
    value :: Union{SymAllGen,Number}
    offset_temp_var :: SymNodeGen        # New temp variables to hold offset from iteration space for each dimension.
end

function hash(x :: SingularSelector)
    @dprintln(4, "hash of SingularSelector ", x)
    hash(x.value)
end
function isequal(x :: SingularSelector, y :: SingularSelector)
    @dprintln(4, "isequal of SingularSelector ", x, " ", y)
    isequal(x.value, y.value)
end

typealias DimensionSelector Union{RangeData, MaskSelector, SingularSelector}

function hash(x :: Array{DimensionSelector,1})
    @dprintln(4, "Array{DimensionSelector,1} hash")
    sum([hash(i) for i in x])
end
function isequal(x :: Array{DimensionSelector,1}, y :: Array{DimensionSelector,1})
    @dprintln(4, "Array{DimensionSelector,1} isequal")
    if length(x) != length(y)
        return false
    end
    for i = 1:length(x)
        if !isequal(x[i], y[i])
             return false
        end
    end
    return true
end

function hash(x :: SymbolNode)
    ret = hash(x.name)
    @dprintln(4, "hash of SymbolNode ", x, " = ", ret)
    return ret
end
function isequal(x :: SymbolNode, y :: SymbolNode)
    return isequal(x.name, y.name) && isequal(x.typ, y.typ)
end

function hash(x :: Expr)
    @dprintln(4, "hash of Expr")
    return hash(x.head) + hash(x.args)
end
function isequal(x :: Expr, y :: Expr)
    return isequal(x.head, y.head) && isequal(x.args, y.args)
end

#function hash(x :: Array{Any,1})
#@dprintln(4, "hash array ", x)
#    return sum([hash(y) for y in x])
#end
function isequal(x :: Array{Any,1}, y :: Array{Any,1})
    if length(x) != length(y)
       return false
    end
    for i = 1:length(x)
        if !isequal(x[i], y[i])
            return false
        end
    end
    return true
end

"""
Type used by mk_parfor_args... functions to hold information about input arrays.
"""
type InputInfo
    array                                # The name of the array.
    dim                                  # The number of dimensions.
    out_dim                              # The number of indexed (non-const) dimensions.
    range :: Array{DimensionSelector,1}  # Empty if whole array, else one RangeData or BitArray mask per dimension.
    elementTemp                          # New temp variable to hold the value of this array/range at the current point in iteration space.
    pre_offsets :: Array{Expr,1}         # Assignments that go in the pre-statements that hold range offsets for each dimension.
    rangeconds :: Array{Expr,1}          # If selecting based on bitarrays, conditional for selecting elements

    function InputInfo()
        new(nothing, 0, 0, DimensionSelector[], nothing, Expr[], Expr[])
    end
    function InputInfo(arr)
        new(arr, 0, 0, DimensionSelector[], nothing, Expr[], Expr[])
    end
end

function show(io::IO, ii :: ParallelAccelerator.ParallelIR.InputInfo)
    println(io,"")
    println(io,"array   = ", ii.array)
    println(io,"dim     = ", ii.dim)
    println(io,"out_dim = ", ii.out_dim)
    println(io,"range   = ", length(ii.range), " ", ii.range)
    println(io,"eltemp  = ", ii.elementTemp)
    println(io,"pre     = ", ii.pre_offsets)
    println(io,"conds   = ", ii.rangeconds)
end

"""
The parfor AST node type.
While we are lowering domain IR to parfors and fusing we use this representation because it
makes it easier to associate related statements before and after the loop to the loop itself.
"""
type PIRParForAst
    first_input  :: InputInfo
    body                                      # holds the body of the innermost loop (outer loops can't have anything in them except inner loops)
    preParFor    :: Array{Any,1}              # do these statements before the parfor
    loopNests    :: Array{PIRLoopNest,1}      # holds information about the loop nests
    reductions   :: Array{PIRReduction,1}     # holds information about the reductions
    postParFor   :: Array{Any,1}              # do these statements after the parfor

    original_domain_nodes :: Array{DomainOperation,1}
    top_level_number :: Array{Int,1}
    rws          :: ReadWriteSet.ReadWriteSetType

    unique_id
    array_aliases :: Dict{SymGen, SymGen}

    # instruction count estimate of the body
    # To get the total loop instruction count, multiply this value by (upper_limit - lower_limit)/step for each loop nest
    # This will be "nothing" if we don't know how to estimate.  If not "nothing" then it is an expression which may
    # include calls.
    instruction_count_expr
    arrays_written_past_index :: Set{SymGen}
    arrays_read_past_index :: Set{SymGen}

    function PIRParForAst(fi, b, pre, nests, red, post, orig, t, unique, wrote_past_index, read_past_index)
        r = CompilerTools.ReadWriteSet.from_exprs(b)
        new(fi, b, pre, nests, red, post, orig, [t], r, unique, Dict{Symbol,Symbol}(), nothing, wrote_past_index, read_past_index)
    end

    function PIRParForAst(fi, b, pre, nests, red, post, orig, t, r, unique, wrote_past_index, read_past_index)
        new(fi, b, pre, nests, red, post, orig, [t], r, unique, Dict{Symbol,Symbol}(), nothing, wrote_past_index, read_past_index)
    end
end

function parforArrayInput(parfor :: PIRParForAst)
    return !parforRangeInput(parfor)
#    return isa(parfor.first_input, SymAllGen)
end
function parforRangeInput(parfor :: PIRParForAst)
    return isRange(parfor.first_input)
#    return isa(parfor.first_input, Array{DimensionSelector,1})
end

"""
Not currently used but might need it at some point.
Search a whole PIRParForAst object and replace one SymAllGen with another.
"""
function replaceParforWithDict(parfor :: PIRParForAst, gensym_map)
    parfor.body = CompilerTools.LambdaHandling.replaceExprWithDict!(parfor.body, gensym_map)
    parfor.preParFor = CompilerTools.LambdaHandling.replaceExprWithDict!(parfor.preParFor, gensym_map)
    for i = 1:length(parfor.loopNests)
        parfor.loopNests[i].lower = CompilerTools.LambdaHandling.replaceExprWithDict!(parfor.loopNests[i].lower, gensym_map)
        parfor.loopNests[i].upper = CompilerTools.LambdaHandling.replaceExprWithDict!(parfor.loopNests[i].upper, gensym_map)
        parfor.loopNests[i].step = CompilerTools.LambdaHandling.replaceExprWithDict!(parfor.loopNests[i].step, gensym_map)
    end
    for i = 1:length(parfor.reductions)
        parfor.reductions[i].reductionVarInit = CompilerTools.LambdaHandling.replaceExprWithDict!(parfor.reductions[i].reductionVarInit, gensym_map)
    end
    parfor.postParFor = CompilerTools.LambdaHandling.replaceExprWithDict!(parfor.postParFor, gensym_map)
end

"""
After lowering, it is necessary to make the parfor body top-level statements so that basic blocks
can be correctly identified and labels correctly found.  There is a phase in parallel IR where we 
take a PIRParForAst node and split it into a parfor_start node followed by the body as top-level
statements followed by parfor_end (also a top-level statement).
"""
type PIRParForStartEnd
    loopNests  :: Array{PIRLoopNest,1}      # holds information about the loop nests
    reductions :: Array{PIRReduction,1}     # holds information about the reductions
    instruction_count_expr
    private_vars :: Array{SymAllGen,1}
end

"""
State passed around while converting an AST from domain to parallel IR.
"""
type expr_state
    block_lives :: CompilerTools.LivenessAnalysis.BlockLiveness    # holds the output of liveness analysis at the block and top-level statement level
    top_level_number :: Int                          # holds the current top-level statement number...used to correlate with stmt liveness info
    # Arrays created from each other are known to have the same size. Store such correlations here.
    # If two arrays have the same dictionary value, they are equal in size.
    next_eq_class            :: Int
    array_length_correlation :: Dict{SymGen,Int}
    symbol_array_correlation :: Dict{Array{SymGen,1},Int}
    range_correlation        :: Dict{Array{DimensionSelector,1},Int}
    lambdaInfo :: CompilerTools.LambdaHandling.LambdaInfo
    max_label :: Int # holds the max number of all LabelNodes

    # Initialize the state for parallel IR translation.
    function expr_state(bl, max_label, input_arrays)
        init_corr = Dict{SymGen,Int}()
        # For each input array, insert into the correlations table with a different value.
        for i = 1:length(input_arrays)
            init_corr[input_arrays[i]] = i
        end
        new(bl, 0, length(input_arrays)+1, init_corr, Dict{Array{SymGen,1},Int}(), Dict{Array{DimensionSelector,1},Int}(), CompilerTools.LambdaHandling.LambdaInfo(), max_label)
    end
end

include("parallel-ir-stencil.jl")

"""
Overload of Base.show to pretty print for parfor AST nodes.
"""
function show(io::IO, pnode::ParallelAccelerator.ParallelIR.PIRParForAst)
    println(io,"")
    if pnode.instruction_count_expr != nothing
        println(io,"Instruction count estimate: ", pnode.instruction_count_expr)
    end
    if length(pnode.preParFor) > 0
        println(io,"Prestatements: ")
        for i = 1:length(pnode.preParFor)
            println(io,"    ", pnode.preParFor[i])
            if DEBUG_LVL >= 4
                dump(pnode.preParFor[i])
            end
        end
    end
    println(io,"PIR Body: ")
    for i = 1:length(pnode.body)
        println(io,"    ", pnode.body[i])
    end
    if DEBUG_LVL >= 4
        dump(pnode.body)
    end
    if length(pnode.loopNests) > 0
        println(io,"Loop Nests: ")
        for i = 1:length(pnode.loopNests)
            println(io,"    ", pnode.loopNests[i])
            if DEBUG_LVL >= 4
                dump(pnode.loopNests[i])
            end
        end
    end
    if length(pnode.reductions) > 0
        println(io,"Reductions: ")
        for i = 1:length(pnode.reductions)
            println(io,"    ", pnode.reductions[i])
        end
    end
    if length(pnode.postParFor) > 0
        println(io,"Poststatements: ")
        for i = 1:length(pnode.postParFor)
            println(io,"    ", pnode.postParFor[i])
            if DEBUG_LVL >= 4
                dump(pnode.postParFor[i])
            end
        end
    end
    if length(pnode.original_domain_nodes) > 0 && DEBUG_LVL >= 4
        println(io,"Domain nodes: ")
        for i = 1:length(pnode.original_domain_nodes)
            println(io,pnode.original_domain_nodes[i])
        end
    end
    if DEBUG_LVL >= 3
        println(io, pnode.rws)
    end
end

export PIRLoopNest, PIRReduction, from_exprs, PIRParForAst, AstWalk, PIRSetFuseLimit, PIRNumSimplify, PIRInplace, PIRRunAsTasks, PIRLimitTask, PIRReduceTasks, PIRStencilTasks, PIRFlatParfor, PIRNumThreadsMode, PIRShortcutArrayAssignment, PIRTaskGraphMode, PIRPolyhedral

"""
Given an array of outputs in "outs", form a return expression.
If there is only one out then the args of :return is just that expression.
If there are multiple outs then form a tuple of them and that tuple goes in :return args.
"""
function mk_return_expr(outs)
    if length(outs) == 1
        return TypedExpr(outs[1].typ, :return, outs[1])
    else
        tt = Expr(:tuple)
        tt.args = map( x -> x.typ, outs)
        temp_type = eval(tt)

        return TypedExpr(temp_type, :return, mk_tuple_expr(outs, temp_type))
    end
end

"""
Create an assignment expression AST node given a left and right-hand side.
The left-hand side has to be a symbol node from which we extract the type so as to type the new Expr.
"""
function mk_assignment_expr(lhs::SymAllGen, rhs, state :: expr_state)
    expr_typ = CompilerTools.LambdaHandling.getType(lhs, state.lambdaInfo)    
    @dprintln(2,"mk_assignment_expr lhs type = ", typeof(lhs))
    TypedExpr(expr_typ, symbol('='), lhs, rhs)
end

function mk_assignment_expr(lhs::ANY, rhs, state :: expr_state)
    throw(string("mk_assignment_expr lhs is not of type SymAllGen, is of this type instead: ", typeof(lhs)))
end


function mk_assignment_expr(lhs :: SymbolNode, rhs)
    TypedExpr(lhs.typ, symbol('='), lhs, rhs)
end

"""
Only used to create fake expression to force lhs to be seen as written rather than read.
"""
function mk_untyped_assignment(lhs, rhs)
    Expr(symbol('='), lhs, rhs)
end

function isWholeArray(inputInfo :: InputInfo) 
    return length(inputInfo.range) == 0 
end

function isRange(inputInfo :: InputInfo)
    return length(inputInfo.range) > 0
end

"""
Compute size of a range.
"""
function rangeSize(start, skip, last)
    # TODO: do something with skip!
    return last - start + 1
end

"""
Create an expression whose value is the length of the input array.
"""
function mk_arraylen_expr(x :: SymAllGen, dim :: Int64)
    TypedExpr(Int64, :call, TopNode(:arraysize), :($x), dim)
end

"""
Create an expression whose value is the length of the input array.
"""
function mk_arraylen_expr(x :: InputInfo, dim :: Int64)
    if dim <= length(x.range) 
        r = x.range[dim]
        if isa(x.range[dim], RangeData)
            # TODO: do something with skip!
            last  = isa(r.exprs.last_val, Expr)  ? r.last  : r.exprs.last_val
            start = isa(r.exprs.start_val, Expr) ? r.start : r.exprs.start_val
            ret = DomainIR.add(DomainIR.sub(last, start), 1)
            @dprintln(3, "mk_arraylen_expr for range = ", r, " last = ", last, " start = ", start, " ret = ", ret)
            return ret
        elseif isa(x.range[dim], SingularSelector)
            return 1
        end
    end

    return mk_arraylen_expr(x.array, dim)
end

"""
Create an expression that references something inside ParallelIR.
In other words, returns an expression the equivalent of ParallelAccelerator.ParallelIR.sym where sym is an input argument to this function.
"""
function mk_parallelir_ref(sym, ref_type=Function)
    #inner_call = TypedExpr(Module, :call, TopNode(:getfield), :ParallelAccelerator, QuoteNode(:ParallelIR))
    #TypedExpr(ref_type, :call, TopNode(:getfield), inner_call, QuoteNode(sym))
    TypedExpr(ref_type, :call, TopNode(:getfield), GlobalRef(ParallelAccelerator,:ParallelIR), QuoteNode(sym))
end

"""
Returns an expression that convert "ex" into a another type "new_type".
"""
function mk_convert(new_type, ex)
    TypedExpr(new_type, :call, TopNode(:convert), new_type, ex)
end

"""
Create an expression which returns the index'th element of the tuple whose name is contained in tuple_var.
"""
function mk_tupleref_expr(tuple_var, index, typ)
    TypedExpr(typ, :call, TopNode(:tupleref), tuple_var, index)
end

"""
Make a svec expression.
"""
function mk_svec_expr(parts...)
    TypedExpr(SimpleVector, :call, TopNode(:svec), parts...)
end

"""
Return an expression that allocates and initializes a 1D Julia array that has an element type specified by
"elem_type", an array type of "atype" and a "length".
"""
function mk_alloc_array_1d_expr(elem_type, atype, length)
    @dprintln(2,"mk_alloc_array_1d_expr atype = ", atype, " elem_type = ", elem_type, " length = ", length, " typeof(length) = ", typeof(length))
    ret_type = TypedExpr(Type{atype}, :call1, TopNode(:apply_type), :Array, elem_type, 1)
    new_svec = TypedExpr(SimpleVector, :call, TopNode(:svec), GlobalRef(Base, :Any), GlobalRef(Base, :Int))
    #arg_types = TypedExpr((Type{Any},Type{Int}), :call1, TopNode(:tuple), :Any, :Int)

    length_expr = get_length_expr(length)

    TypedExpr(
       atype,
       :call,
       TopNode(:ccall),
       QuoteNode(:jl_alloc_array_1d),
       ret_type,
       new_svec,
       #arg_types,
       atype,
       0,
       length_expr,
       0)
end

function get_length_expr(length::Union{SymbolNode,Int64})
    return length
end

function get_length_expr(length::Symbol)
    return SymbolNode(length, Int)
end

function get_length_expr(length::Any)
    throw(string("Unhandled length type in mk_alloc_array_1d_expr."))
end

"""
Return an expression that allocates and initializes a 2D Julia array that has an element type specified by
"elem_type", an array type of "atype" and two dimensions of length in "length1" and "length2".
"""
function mk_alloc_array_2d_expr(elem_type, atype, length1, length2)
    @dprintln(2,"mk_alloc_array_2d_expr atype = ", atype)
    ret_type  = TypedExpr(Type{atype}, :call1, TopNode(:apply_type), :Array, elem_type, 2)
    new_svec = TypedExpr(SimpleVector, :call, TopNode(:svec), GlobalRef(Base, :Any), GlobalRef(Base, :Int), GlobalRef(Base, :Int))
    #arg_types = TypedExpr((Type{Any},Type{Int},Type{Int}), :call1, TopNode(:tuple), :Any, :Int, :Int)

    TypedExpr(
       atype,
       :call,
       TopNode(:ccall),
       QuoteNode(:jl_alloc_array_2d),
       ret_type,
       new_svec,
       #arg_types,
       atype,
       0,
       SymbolNode(length1,Int),
       0,
       SymbolNode(length2,Int),
       0)
end

"""
Return an expression that allocates and initializes a 3D Julia array that has an element type specified by
"elem_type", an array type of "atype" and two dimensions of length in "length1" and "length2" and "length3".
"""
function mk_alloc_array_3d_expr(elem_type, atype, length1, length2, length3)
    @dprintln(2,"mk_alloc_array_3d_expr atype = ", atype)
    ret_type  = TypedExpr(Type{atype}, :call1, TopNode(:apply_type), :Array, elem_type, 3)
    new_svec = TypedExpr(SimpleVector, :call, TopNode(:svec), GlobalRef(Base, :Any), GlobalRef(Base, :Int), GlobalRef(Base, :Int), GlobalRef(Base, :Int))

    TypedExpr(
       atype,
       :call,
       TopNode(:ccall),
       QuoteNode(:jl_alloc_array_3d),
       ret_type,
       new_svec,
       atype,
       0,
       SymbolNode(length1,Int),
       0,
       SymbolNode(length2,Int),
       0,
       SymbolNode(length3,Int),
       0)
end

"""
Returns the element type of an Array.
"""
function getArrayElemType(array :: SymbolNode, state :: expr_state)
    return eltype(array.typ)
end

"""
Returns the element type of an Array.
"""
function getArrayElemType(array :: GenSym, state :: expr_state)
    atyp = CompilerTools.LambdaHandling.getType(array, state.lambdaInfo)
    return eltype(atyp)
end

"""
Return the number of dimensions of an Array.
"""
function getArrayNumDims(array :: SymbolNode, state :: expr_state)
    @assert array.typ.name == Array.name || array.typ.name == BitArray.name "Array expected"
    @dprintln(3, "getArrayNumDims from SymbolNode array = ", array, " ", array.typ, " ", ndims(array.typ))
    ndims(array.typ)
end

"""
Return the number of dimensions of an Array.
"""
function getArrayNumDims(array :: GenSym, state :: expr_state)
    gstyp = CompilerTools.LambdaHandling.getType(array, state.lambdaInfo)
    @assert gstyp.name == Array.name || gstyp.name == BitArray.name "Array expected"
    ndims(gstyp)
end

"""
Add a local variable to the current function's lambdaInfo.
Returns a symbol node of the new variable.
"""
function createStateVar(state, name, typ, access)
    new_temp_sym = symbol(name)
    CompilerTools.LambdaHandling.addLocalVar(new_temp_sym, typ, access, state.lambdaInfo)
    return SymbolNode(new_temp_sym, typ)
end

"""
Create a temporary variable that is parfor private to hold the value of an element of an array.
"""
function createTempForArray(array_sn :: SymAllGen, unique_id :: Int64, state :: expr_state, temp_type = nothing)
    key = toSymGen(array_sn) 
    if temp_type == nothing
        temp_type = getArrayElemType(array_sn, state)
    end
    return createStateVar(state, string("parallel_ir_temp_", key, "_", unique_id), temp_type, ISASSIGNEDONCE | ISASSIGNED | ISPRIVATEPARFORLOOP)
end


"""
Takes an existing variable whose name is in "var_name" and adds the descriptor flag ISPRIVATEPARFORLOOP to declare the
variable to be parfor loop private and eventually go in an OMP private clause.
"""
function makePrivateParfor(var_name :: Symbol, state)
    res = CompilerTools.LambdaHandling.addDescFlag(var_name, ISPRIVATEPARFORLOOP, state.lambdaInfo)
    assert(res)
end

"""
Returns true if all array references use singular index variables and nothing more complicated involving,
for example, addition or subtraction by a constant.
"""
function simpleIndex(dict)
    # For each entry in the dictionary.
    for k in dict
        # Get the corresponding array of seen indexing expressions.
        array_ae = k[2]
        # For each indexing expression.
        for i = 1:length(array_ae)
            ae = array_ae[i]
            @dprintln(3,"typeof(ae) = ", typeof(ae), " ae = ", ae)
            for j = 1:length(ae)
                # If the indexing expression isn't simple then return false.
                if (!isa(ae[j], Number) &&
                    !isa(ae[j], SymAllGen) &&
                    (typeof(ae[j]) != Expr ||
                    ae[j].head != :(::)   ||
                    typeof(ae[j].args[1]) != Symbol))
                    return false
                end
            end
        end
    end
    # All indexing expressions must have been fine so return true.
    return true
end



"""
Form a SymbolNode with the given typ if possible or a GenSym if that is what is passed in.
"""
function toSymNodeGen(x :: Symbol, typ)
    return SymbolNode(x, typ)
end

function toSymNodeGen(x :: SymbolNode, typ)
    return x
end

function toSymNodeGen(x :: GenSym, typ)
    return x
end

function toSymNodeGen(x, typ)
    xtyp = typeof(x)
    throw(string("Found object type ", xtyp, " for object ", x, " in toSymNodeGen and don't know what to do with it."))
end

"""
Returns the next usable label for the current function.
"""
function next_label(state :: expr_state)
    state.max_label = state.max_label + 1
    return state.max_label
end

"""
Given an array whose name is in "x", allocate a new equivalence class for this array.
"""
function addUnknownArray(x :: SymGen, state :: expr_state)
    @dprintln(3, "addUnknownArray x = ", x, " next = ", state.next_eq_class)
    m = state.next_eq_class
    state.next_eq_class += 1
    state.array_length_correlation[x] = m + 1
end

"""
Given an array of RangeExprs describing loop nest ranges, allocate a new equivalence class for this range.
"""
function addUnknownRange(x :: Array{DimensionSelector,1}, state :: expr_state)
    m = state.next_eq_class
    state.next_eq_class += 1
    state.range_correlation[x] = m + 1
end

"""
If we somehow determine that two sets of correlations are actually the same length then merge one into the other.
"""
function merge_correlations(state, unchanging, eliminate)
    # For each array in the dictionary.
    for i in state.array_length_correlation
        # If it is in the "eliminate" class...
        if i[2] == eliminate
            # ...move it to the "unchanging" class.
            state.array_length_correlation[i[1]] = unchanging
        end
    end
    # The symbol_array_correlation shares the equivalence class space so
    # do the same re-numbering here.
    for i in state.symbol_array_correlation
        if i[2] == eliminate
            state.symbol_array_correlation[i[1]] = unchanging
        end
    end
    # The range_correlation shares the equivalence class space so
    # do the same re-numbering here.
    for i in state.range_correlation
        if i[2] == eliminate
            state.range_correlation[i[1]] = unchanging
        end
    end

    nothing
end

"""
If we somehow determine that two arrays must be the same length then 
get the equivalence classes for the two arrays and merge those equivalence classes together.
"""
function add_merge_correlations(old_sym :: SymGen, new_sym :: SymGen, state :: expr_state)
    @dprintln(3, "add_merge_correlations ", old_sym, " ", new_sym)
    print_correlations(3, state)
    old_corr = getOrAddArrayCorrelation(old_sym, state)
    new_corr = getOrAddArrayCorrelation(new_sym, state)
    merge_correlations(state, old_corr, new_corr)
    @dprintln(3, "add_merge_correlations post")
    print_correlations(3, state)
end

"""
Return a correlation set for an array.  If the array was not previously added then add it and return it.
"""
function getOrAddArrayCorrelation(x :: SymGen, state :: expr_state)
    if !haskey(state.array_length_correlation, x)
        @dprintln(3,"Correlation for array not found = ", x)
        addUnknownArray(x, state)
    end
    state.array_length_correlation[x]
end

function simplify_internal(x :: ANY, state, top_level_number :: Int64, is_top_level :: Bool, read :: Bool)
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

"""
Do some simplification to expressions that are part of ranges.
For example, the range 2:s-1 becomes a length (s-1)-2 which this function in turn transforms to s-3.
"""
function simplify_internal(x :: Expr, state, top_level_number :: Int64, is_top_level :: Bool, read :: Bool)
    is_sub = DomainIR.isSubExpr(x)
    is_add = DomainIR.isAddExpr(x)
    @dprintln(3, "simplify_internal ", x, " is_sub = ", is_sub, " is_add = ", is_add)
    # We only do any simpilfication to addition or subtraction statements at the moment.
    if is_sub || is_add
        # Recursively translate the ops to this operator first.
        x.args[2] = AstWalk(x.args[2], simplify_internal, nothing)
        x.args[3] = AstWalk(x.args[3], simplify_internal, nothing)
        # Extract the two operands to this operation.
        op1 = x.args[2]
        op2 = x.args[3]
        # We only support simplification when operand1 is itself an addition or subtraction operator.
        op1_sub = DomainIR.isSubExpr(op1)
        op1_add = DomainIR.isAddExpr(op1)
        @dprintln(3, "op1 = ", op1, " op2 = ", op2)
        # If operand1 is an addition or subtraction operator and operand2 is a number then keep checking if we can simplify.
        if (op1_sub || op1_add) && isa(op2, Number)
            # Get the two operands to the operand1.
            op1_op1 = op1.args[2]
            op1_op2 = op1.args[3]
            @dprintln(3, "op1_op1 = ", op1_op1, " op1_op2 = ", op1_op2)
            # We can do some simplification if the second operand2 here is also a number.
            if isa(op1_op2, Number)
                @dprintln(3, "simplify will modify")
                # If we have like operations then we can combine the second operands by addition.
                if is_sub == op1_sub
                    new_number = op1_op2 + op2
                    @dprintln(3, "same ops so added to get ", new_number)
                else
                    # Consider, (s-1)+2 and (s+1)-2, where the operations are different.
                    # In both case, we can do 1-2 (op2 is 2, op1_op2 is 1).
                    # This would become (s-(-1)) and (s+(-1)) respectively.
                    new_number = op1_op2 - op2
                    @dprintln(3, "diff ops so subtracted to get ", new_number)
                end

                # If we happen to get a zero then we can eliminate both operations.
                if new_number == 0
                    @dprintln(3, "new_number is 0 so eliminating both operations")
                    return op1_op1
                elseif new_number < 0
                    # Canonicalize so that op2 is always positive by switching the operation from add to sub or vice versa if necessary.
                    @dprintln(3, "new_number < 0 so switching op1 from add to sub or vice versa")
                    op1_sub = !op1_sub
                    new_number = abs(new_number)
                end

                # Form a sub or add expression to replace the current node.
                if op1_sub
                    ret = DomainIR.sub_expr(op1_op1, new_number)
                else
                    ret = DomainIR.add_expr(op1_op1, new_number)
                end
                @dprintln(3,"new simplified expr is ", ret)
                return ret
            end
        end
    end
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

"""
Convert one RangeData to some length expression and then simplify it.
"""
function form_and_simplify(rd :: RangeData)
    re = rd.exprs
    @dprintln(3, "form_and_simplify ", re)
    # Number of iteration is (last-start)/skip.  This is only approximate due to the non-linear effects of integer div.
    # We don't attempt to equate different ranges with different skips.
    last_minus_start = DomainIR.sub_expr(re.last_val, re.start_val)
    if re.skip_val != 1
        with_skip = DomainIR.sdiv_int_expr(last_minus_start, re.skip_val)
    else
        with_skip = last_minus_start
    end
    @dprintln(3, "before simplify = ", with_skip)
    ret = AstWalk(with_skip, simplify_internal, nothing)
    @dprintln(3, "after simplify = ", ret)
    return ret
end

function form_and_simplify(x :: ANY)
    return x
end

"""
For each entry in ranges, form a range length expression and simplify them.
"""
function form_and_simplify(ranges :: Array{DimensionSelector,1})
    return [form_and_simplify(x) for x in ranges]
end

"""
We can only do exact matches in the range correlation dict but there can still be non-exact matches
where the ranges are different but equivalent in length.  In this function, we can the dictionary
and look for equivalent ranges.
"""
function nonExactRangeSearch(ranges :: Array{DimensionSelector,1}, range_correlations)
    # Get the simplified form of the range we are looking for.
    simplified = form_and_simplify(ranges)
    @dprintln(3, "searching for simplified expr ", simplified)
    # For each range correlation in the dictionary.
    for kv in range_correlations
        key = kv[1]
        correlation = kv[2]

        @dprintln(3, "Before form_and_simplify(key)")
        # Simplify the current dictionary entry to enable comparison.
        simplified_key = form_and_simplify(key)
        @dprintln(3, "comparing ", simplified, " against simplified_key ", simplified_key)
        # If the simplified form of the incoming range and the dictionary entry are equal now then the ranges are equivalent.
        if isequal(simplified, simplified_key)
            @dprintln(3, "simplified and simplified key are equal")
            return correlation
        else
            @dprintln(3, "simplified and simplified key are not equal")
        end
    end
    # No equivalent range entry in the dictionary.
    return nothing
end

"""
Gets (or adds if absent) the range correlation for the given array of RangeExprs.
"""
function getOrAddRangeCorrelation(array, ranges :: Array{DimensionSelector,1}, state :: expr_state)
    @dprintln(3, "getOrAddRangeCorrelation for ", array, " with ranges = ", ranges, " and hash = ", hash(ranges))
    print_correlations(3, state)

    # We can't match on array of RangeExprs so we flatten to Array of Any
    all_mask = true
    for i = 1:length(ranges)
        all_mask = all_mask & isa(ranges[i], MaskSelector)
    end

    if !haskey(state.range_correlation, ranges)
        @dprintln(3,"Exact match for correlation for range not found = ", ranges)
        # Look for an equivalent but non-exact range in the dictionary.
        nonExactCorrelation = nonExactRangeSearch(ranges, state.range_correlation)
        if nonExactCorrelation == nothing
            @dprintln(3, "No non-exact match so adding new range")
            range_corr = addUnknownRange(ranges, state)
            # If all the dimensions are selected based on masks then the iteration space
            # is that of the entire array and so we can establish a correlation between the
            # DimensionSelector and the whole array.
            if all_mask
                @dprintln(3, "All dimension selectors are masks so establishing correlation to main array.")
                masked_array_corr = getOrAddArrayCorrelation(toSymGen(array), state)
                merge_correlations(state, masked_array_corr, range_corr)
            end
        else
            # Found an equivalent range.
            @dprintln(3, "Adding non-exact range match to class ", nonExactCorrelation)
            state.range_correlation[ranges] = nonExactCorrelation
        end
        print_correlations(3, state)
    end
    state.range_correlation[ranges]
end

"""
A new array is being created with an explicit size specification in dims.
"""
function getOrAddSymbolCorrelation(array :: SymGen, state :: expr_state, dims :: Array{SymGen,1})
    if !haskey(state.symbol_array_correlation, dims)
        # We haven't yet seen this combination of dims used to create an array.
        @dprintln(3,"Correlation for symbol set not found, dims = ", dims)
        if haskey(state.array_length_correlation, array)
            return state.symbol_array_correlation[dims] = state.array_length_correlation[array]
        else
            # Create a new array correlation number for this array and associate that number with the dim sizes.
            return state.symbol_array_correlation[dims] = addUnknownArray(array, state)
        end
    else
        @dprintln(3,"Correlation for symbol set found, dims = ", dims)
        # We have previously seen this combination of dim sizes used to create an array so give the new
        # array the same array length correlation number as the previous one.
        return state.array_length_correlation[array] = state.symbol_array_correlation[dims]
    end
end

"""
If we need to generate a name and make sure it is unique then include an monotonically increasing number.
"""
function get_unique_num()
    ret = unique_num
    global unique_num = unique_num + 1
    ret
end

# ===============================================================================================================================

include("parallel-ir-mk-parfor.jl")

"""
The AstWalk callback function for getPrivateSet.
For each AST in a parfor body, if the node is an assignment or loop head node then add the written entity to the state.
"""
function getPrivateSetInner(x::Expr, state :: Set{SymAllGen}, top_level_number :: Int64, is_top_level :: Bool, read :: Bool)
    # If the node is an assignment node or a loop head node.
    if isAssignmentNode(x) || isLoopheadNode(x)
        lhs = x.args[1]
        assert(isa(lhs, SymAllGen))
        if isa(lhs, GenSym)
            push!(state, lhs)
        else
            sname = getSName(lhs)
            red_var_start = "parallel_ir_reduction_output_"
            red_var_len = length(red_var_start)
            sstr = string(sname)
            if length(sstr) >= red_var_len
                if sstr[1:red_var_len] == red_var_start
                    # Skip this symbol if it begins with "parallel_ir_reduction_output_" signifying a reduction variable.
                    return CompilerTools.AstWalker.ASTWALK_RECURSE
                end
            end
            push!(state, sname)
        end
    end
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

function getPrivateSetInner(x::ANY, state :: Set{SymAllGen}, top_level_number :: Int64, is_top_level :: Bool, read :: Bool)
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

"""
Go through the body of a parfor and collect those Symbols, GenSyms, etc. that are assigned to within the parfor except reduction variables.
"""
function getPrivateSet(body :: Array{Any,1})
    @dprintln(3,"getPrivateSet")
    printBody(3, body)
    private_set = Set{SymAllGen}()
    for i = 1:length(body)
        AstWalk(body[i], getPrivateSetInner, private_set)
    end
    @dprintln(3,"private_set = ", private_set)
    return private_set
end

# ===============================================================================================================================

"""
Convert a compressed LambdaStaticData format into the uncompressed AST format.
"""
uncompressed_ast(l::LambdaStaticData) =
isa(l.ast,Expr) ? l.ast : ccall(:jl_uncompress_ast, Any, (Any,Any), l, l.ast)

"""
AstWalk callback to count the number of static times that a symbol is assigne within a method.
"""
function count_assignments(x, symbol_assigns :: Dict{Symbol, Int}, top_level_number, is_top_level, read)
    if isAssignmentNode(x) || isLoopheadNode(x)
        lhs = x.args[1]
        # GenSyms don't have descriptors so no need to count their assignment.
        if !hasSymbol(lhs)
            return CompilerTools.AstWalker.ASTWALK_RECURSE
        end
        sname = getSName(lhs)
        if !haskey(symbol_assigns, sname)
            symbol_assigns[sname] = 0
        end
        symbol_assigns[sname] = symbol_assigns[sname] + 1
    end
    return CompilerTools.AstWalker.ASTWALK_RECURSE 
end

"""
Just call the AST walker for symbol for parallel IR nodes with no state.
"""
function pir_live_cb_def(x)
    pir_live_cb(x, nothing)
end

"""
Process a :lambda Expr.
"""
function from_lambda(lambda :: Expr, depth, state)
    # :lambda expression
    assert(lambda.head == :lambda)
    @dprintln(4,"from_lambda starting")

    # Save the current lambdaInfo away so we can restore it later.
    save_lambdaInfo  = state.lambdaInfo
    state.lambdaInfo = CompilerTools.LambdaHandling.lambdaExprToLambdaInfo(lambda)
    body = CompilerTools.LambdaHandling.getBody(lambda)

    # Process the lambda's body.
    @dprintln(3,"state.lambdaInfo.var_defs = ", state.lambdaInfo.var_defs)
    body = get_one(from_expr(body, depth, state, false))
    @dprintln(4,"from_lambda after from_expr")
    @dprintln(3,"After processing lambda body = ", state.lambdaInfo)
    @dprintln(3,"from_lambda: after body = ")
    printBody(3, body)

    # Count the number of static assignments per var.
    symbol_assigns = Dict{Symbol, Int}()
    AstWalk(body, count_assignments, symbol_assigns)

    # After counting static assignments, update the lambdaInfo for those vars
    # to say whether the var is assigned once or multiple times.
    CompilerTools.LambdaHandling.updateAssignedDesc(state.lambdaInfo, symbol_assigns)

    body = CompilerTools.LambdaHandling.eliminateUnusedLocals!(state.lambdaInfo, body, ParallelAccelerator.ParallelIR.AstWalk)

    # Write the lambdaInfo back to the lambda AST node.
    lambda = CompilerTools.LambdaHandling.lambdaInfoToLambdaExpr(state.lambdaInfo, body)
    @dprintln(3,"new lambda = ", lambda)

    state.lambdaInfo = save_lambdaInfo

    @dprintln(4,"from_lambda ending")
    return lambda
end

"""
Is a node an assignment expression node.
"""
function isAssignmentNode(node :: Expr)
    return node.head == :(=)
end

function isAssignmentNode(node::Any)
    return false
end

"""
Is a node a loophead expression node (a form of assignment).
"""
function isLoopheadNode(node :: Expr)
    return node.head == :loophead
end

function isLoopheadNode(node)
    return false
end

"""
Is this a parfor node not part of an assignment statement.
"""
function isBareParfor(node :: Expr)
    return node.head == :parfor
end

function isBareParfor(node)
    return false
end


function isParforAssignmentNodeInner(lhs::SymAllGen, rhs::Expr)
    if rhs.head==:parfor
        @dprintln(4,"Found a parfor assignment node.")
        return true
    end
    return false
end

function isParforAssignmentNodeInner(lhs::Any, rhs::Any)
    return false
end

"""
Is a node an assignment expression with a parfor node as the right-hand side.
"""
function isParforAssignmentNode(node::Expr)
    @dprintln(4,"isParforAssignmentNode")
    @dprintln(4,node)

    if isAssignmentNode(node)
        assert(length(node.args) >= 2)
        lhs = node.args[1]
        @dprintln(4,lhs)
        rhs = node.args[2]
        @dprintln(4,rhs)
        return isParforAssignmentNodeInner(lhs, rhs)
    else
        @dprintln(4,"node is not an assignment Expr")
    end

    return false
end

function isParforAssignmentNode(node::Any)
    @dprintln(4,"node is not an Expr")
    return false
end

"""
Get the parfor object from either a bare parfor or one part of an assignment.
"""
function getParforNode(node)
    if isBareParfor(node)
        return node.args[1]
    else
        return node.args[2].args[1]
    end
end

"""
Get the right-hand side of an assignment expression.
"""
function getRhsFromAssignment(assignment)
    assignment.args[2]
end

"""
Get the left-hand side of an assignment expression.
"""
function getLhsFromAssignment(assignment)
    assignment.args[1]
end

"""
Returns true if the domain operation mapped to this parfor has the property that the iteration space
is identical to the dimenions of the inputs.
"""
function iterations_equals_inputs(node :: ParallelAccelerator.ParallelIR.PIRParForAst)
    assert(length(node.original_domain_nodes) > 0)

    first_domain_node = node.original_domain_nodes[1]
    first_type = first_domain_node.operation
    if first_type == :map   ||
        first_type == :map!  ||
        first_type == :mmap  ||
        first_type == :mmap! ||
        first_type == :reduce
        @dprintln(3,"iteration count of node equals length of inputs")
        return true
    else
        @dprintln(3,"iteration count of node does not equal length of inputs")
        return false
    end
end

"""
Returns a Set with all the arrays read by this parfor.
"""
function getInputSet(node :: ParallelAccelerator.ParallelIR.PIRParForAst)
    ret = Set(collect(keys(node.rws.readSet.arrays)))
    @dprintln(3,"Input set = ", ret)
    ret
end

"""
Get the real outputs of an assignment statement.
If the assignment expression is normal then the output is just the left-hand side.
If the assignment expression is augmented with a FusionSentinel then the real outputs
are the 4+ arguments to the expression.
"""
function getLhsOutputSet(lhs, assignment)
    ret = Set()

    typ = typeof(lhs)

    # Created by fusion.
    if isFusionAssignment(assignment)
        # For each real output.
        for i = 4:length(assignment.args)
            assert(typeof(assignment.args[i]) == SymbolNode)
            @dprintln(3,"getLhsOutputSet FusionSentinal assignment with symbol ", assignment.args[i].name)
            # Add to output set.
            push!(ret,assignment.args[i].name)
        end
    else
        # LHS could be Symbol or SymbolNode.
        if typ == SymbolNode
            push!(ret,lhs.name)
            @dprintln(3,"getLhsOutputSet SymbolNode with symbol ", lhs.name)
        elseif typ == Symbol
            push!(ret,lhs)
            @dprintln(3,"getLhsOutputSet symbol ", lhs)
        else
            @dprintln(0,"Unknown LHS type ", typ, " in getLhsOutputSet.")
        end
    end

    ret
end

"""
Return an expression which creates a tuple.
"""
function mk_tuple_expr(tuple_fields, typ)
    # Tuples are formed with a call to :tuple.
    TypedExpr(typ, :call, TopNode(:tuple), tuple_fields...)
end

"""
Forms a SymbolNode given a symbol in "name" and get the type of that symbol from the incoming dictionary "sym_to_type".
"""
function nameToSymbolNode(name :: Symbol, sym_to_type)
    return SymbolNode(name, sym_to_type[name])
end

function nameToSymbolNode(name :: GenSym, sym_to_type)
    return name
end

function nameToSymbolNode(name, sym_to_type)
    throw(string("Unknown name type ", typeof(name), " passed to nameToSymbolNode."))
end

function getAliasMap(loweredAliasMap, sym)
    if haskey(loweredAliasMap, sym)
        return loweredAliasMap[sym]
    else
        return sym
    end
end

function create_merged_output_from_map(output_map, unique_id, state, sym_to_type, loweredAliasMap)
    @dprintln(3,"create_merged_output_from_map, output_map = ", output_map, " sym_to_type = ", sym_to_type)
    # If there are no outputs then return nothing.
    if length(output_map) == 0
        return (nothing, [], true, nothing, [])    
    end

    # If there is only one output then all we need is the symbol to return.
    if length(output_map) == 1
        for i in output_map
            new_lhs = nameToSymbolNode(i[1], sym_to_type)
            new_rhs = nameToSymbolNode(getAliasMap(loweredAliasMap, i[2]), sym_to_type)
            return (new_lhs, [new_lhs], true, [new_rhs])
        end
    end

    lhs_order = Union{SymbolNode,GenSym}[]
    rhs_order = Union{SymbolNode,GenSym}[]
    for i in output_map
        push!(lhs_order, nameToSymbolNode(i[1], sym_to_type))
        push!(rhs_order, nameToSymbolNode(getAliasMap(loweredAliasMap, i[2]), sym_to_type))
    end
    num_map = length(lhs_order)

    # Multiple outputs.

    # First, form the type of the tuple for those multiple outputs.
    tt = Expr(:tuple)
    for i = 1:num_map
        push!(tt.args, CompilerTools.LambdaHandling.getType(rhs_order[i], state.lambdaInfo))
    end
    temp_type = eval(tt)

    ( createRetTupleType(lhs_order, unique_id, state), lhs_order, false, rhs_order )
end

"""
Pull the information from the inner lambda into the outer lambda.
"""
function mergeLambdaIntoOuterState(state, inner_lambda :: Expr)
    inner_lambdaInfo = CompilerTools.LambdaHandling.lambdaExprToLambdaInfo(inner_lambda)
    @dprintln(3,"mergeLambdaIntoOuterState")
    @dprintln(3,"state.lambdaInfo = ", state.lambdaInfo)
    @dprintln(3,"inner_lambdaInfo = ", inner_lambdaInfo)
    CompilerTools.LambdaHandling.mergeLambdaInfo(state.lambdaInfo, inner_lambdaInfo)
end

# Create a variable for a left-hand side of an assignment to hold the multi-output tuple of a parfor.
function createRetTupleType(rets :: Array{Union{SymbolNode, GenSym},1}, unique_id :: Int64, state :: expr_state)
    # Form the type of the tuple var.
    tt_args = [ CompilerTools.LambdaHandling.getType(x, state.lambdaInfo) for x in rets]
    temp_type = Tuple{tt_args...}

    new_temp_name  = string("parallel_ir_ret_holder_",unique_id)
    new_temp_snode = SymbolNode(symbol(new_temp_name), temp_type)
    @dprintln(3, "Creating variable for multiple return from parfor = ", new_temp_snode)
    CompilerTools.LambdaHandling.addLocalVar(new_temp_name, temp_type, ISASSIGNEDONCE | ISCONST | ISASSIGNED, state.lambdaInfo)

    new_temp_snode
end

# Takes the output of two parfors and merges them while eliminating outputs from
# the previous parfor that have their only use in the current parfor.
function create_arrays_assigned_to_by_either_parfor(arrays_assigned_to_by_either_parfor :: Array{Symbol,1}, allocs_to_eliminate, unique_id, state, sym_to_typ)
    @dprintln(3,"create_arrays_assigned_to_by_either_parfor arrays_assigned_to_by_either_parfor = ", arrays_assigned_to_by_either_parfor)
    @dprintln(3,"create_arrays_assigned_to_by_either_parfor allocs_to_eliminate = ", allocs_to_eliminate, " typeof(allocs) = ", typeof(allocs_to_eliminate))

    # This is those outputs of the prev parfor which don't die during cur parfor.
    prev_minus_eliminations = Symbol[]
    for i = 1:length(arrays_assigned_to_by_either_parfor)
        if !in(arrays_assigned_to_by_either_parfor[i], allocs_to_eliminate)
            push!(prev_minus_eliminations, arrays_assigned_to_by_either_parfor[i])
        end
    end
    @dprintln(3,"create_arrays_assigned_to_by_either_parfor: outputs from previous parfor that continue to live = ", prev_minus_eliminations)

    # Create an array of SymbolNode for real values to assign into.
    all_array = map(x -> SymbolNode(x,sym_to_typ[x]), prev_minus_eliminations)
    @dprintln(3,"create_arrays_assigned_to_by_either_parfor: all_array = ", all_array, " typeof(all_array) = ", typeof(all_array))

    # If there is only one such value then the left side is just a simple SymbolNode.
    if length(all_array) == 1
        return (all_array[1], all_array, true)
    end

    # Create a new var to hold multi-output tuple.
    (createRetTupleType(all_array, unique_id, state), all_array, false)
end

function getAllAliases(input :: Set{SymGen}, aliases :: Dict{SymGen, SymGen})
    @dprintln(3,"getAllAliases input = ", input, " aliases = ", aliases)
    out = Set()

    for i in input
        @dprintln(3, "input = ", i)
        push!(out, i)
        cur = i
        while haskey(aliases, cur)
            cur = aliases[cur]
            @dprintln(3, "cur = ", cur)
            push!(out, cur)
        end
    end

    @dprintln(3,"getAllAliases out = ", out)
    return out
end

function isAllocation(expr :: Expr)
    return expr.head == :call && 
    expr.args[1] == TopNode(:ccall) && 
    (expr.args[2] == QuoteNode(:jl_alloc_array_1d) || expr.args[2] == QuoteNode(:jl_alloc_array_2d) || expr.args[2] == QuoteNode(:jl_alloc_array_3d) || expr.args[2] == QuoteNode(:jl_new_array))
end

function isAllocation(expr)
    return false
end

# Takes one statement in the preParFor of a parfor and a set of variables that we've determined we can eliminate.
# Returns true if this statement is an allocation of one such variable.
function is_eliminated_allocation_map(x :: Expr, all_aliased_outputs :: Set)
    @dprintln(4,"is_eliminated_allocation_map: x = ", x, " typeof(x) = ", typeof(x), " all_aliased_outputs = ", all_aliased_outputs)
    @dprintln(4,"is_eliminated_allocation_map: head = ", x.head)
    if x.head == symbol('=')
        assert(typeof(x.args[1]) == SymbolNode)
        lhs = x.args[1]
        rhs = x.args[2]
        if isAllocation(rhs)
            @dprintln(4,"is_eliminated_allocation_map: lhs = ", lhs)
            if !in(lhs.name, all_aliased_outputs)
                @dprintln(4,"is_eliminated_allocation_map: this will be removed => ", x)
                return true
            end
        end
    end

    return false
end

function is_eliminated_allocation_map(x, all_aliased_outputs :: Set)
    @dprintln(4,"is_eliminated_allocation_map: x = ", x, " typeof(x) = ", typeof(x), " all_aliased_outputs = ", all_aliased_outputs)
    return false
end

function is_dead_arrayset(x, all_aliased_outputs :: Set)
    if isArraysetCall(x)
        array_to_set = x.args[2]
        if !in(toSymGen(array_to_set), all_aliased_outputs)
            return true
        end
    end

    return false
end

"""
Holds data for modifying arrayset calls.
"""
type sub_arrayset_data
    arrays_set_in_cur_body #remove_arrayset
    output_items_with_aliases
end

"""
Is a node an arrayset node?
"""
function isArrayset(x)
    if x == TopNode(:arrayset) || x == TopNode(:unsafe_arrayset)
        return true
    end
    return false
end

"""
Is a node an arrayref node?
"""
function isArrayref(x)
    if x == TopNode(:arrayref) || x == TopNode(:unsafe_arrayref)
        return true
    end
    return false
end

"""
Is a node a call to arrayset.
"""
function isArraysetCall(x :: Expr)
    return x.head == :call && isArrayset(x.args[1])
end

function isArraysetCall(x)
    return false
end

"""
Is a node a call to arrayref.
"""
function isArrayrefCall(x :: Expr)
    return x.head == :call && isArrayref(x.args[1])
end

function isArrayrefCall(x)
    return false
end

"""
AstWalk callback that does the work of substitute_arrayset on a node-by-node basis.
"""
function sub_arrayset_walk(x::Expr, cbd, top_level_number, is_top_level, read)
    use_dbg_level = 3
    dprintln(use_dbg_level,"sub_arrayset_walk ", x, " ", cbd.arrays_set_in_cur_body, " ", cbd.output_items_with_aliases)

    dprintln(use_dbg_level,"sub_arrayset_walk is Expr")
    if x.head == :call
        dprintln(use_dbg_level,"sub_arrayset_walk is :call")
        if x.args[1] == TopNode(:arrayset) || x.args[1] == TopNode(:unsafe_arrayset)
            # Here we have a call to arrayset.
            dprintln(use_dbg_level,"sub_arrayset_walk is :arrayset")
            array_name = x.args[2]
            value      = x.args[3]
            index      = x.args[4]
            assert(isa(array_name, SymNodeGen))
            # If the array being assigned to is in temp_map.
            if in(toSymGen(array_name), cbd.arrays_set_in_cur_body)
                return nothing
            elseif !in(toSymGen(array_name), cbd.output_items_with_aliases)
                return nothing
            else
                dprintln(use_dbg_level,"sub_arrayset_walk array_name will not substitute ", array_name)
            end
        end
    end

    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

function sub_arrayset_walk(x::ANY, cbd, top_level_number, is_top_level, read)
    use_dbg_level = 3
    dprintln(use_dbg_level,"sub_arrayset_walk ", x, " ", cbd.arrays_set_in_cur_body, " ", cbd.output_items_with_aliases)
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

"""
Modify the body of a parfor.
temp_map holds a map of array names whose arraysets should be turned into a mapped variable instead of the arrayset. a[i] = b. a=>c. becomes c = b
map_for_non_eliminated holds arrays for which we need to add a variable to save the value but we can't eiminate the arrayset. a[i] = b. a=>c. becomes c = a[i] = b
    map_drop_arrayset drops the arrayset without replacing with a variable.  This is because a variable was previously added here with a map_for_non_eliminated case.
    a[i] = b. becomes b
"""
function substitute_arrayset(x, arrays_set_in_cur_body, output_items_with_aliases)
    @dprintln(3,"substitute_arrayset ", x, " ", arrays_set_in_cur_body, " ", output_items_with_aliases)
    # Walk the AST and call sub_arrayset_walk for each node.
    return AstWalk(x, sub_arrayset_walk, sub_arrayset_data(arrays_set_in_cur_body, output_items_with_aliases))
end

"""
Get the variable which holds the length of the first input array to a parfor.
"""
function getFirstArrayLens(prestatements, num_dims)
    ret = Any[]

    # Scan the prestatements and find the assignment nodes.
    # If it is an assignment from arraysize.
    for i = 1:length(prestatements)
        x = prestatements[i]
        if (typeof(x) == Expr) && (x.head == symbol('='))
            lhs = x.args[1]
            rhs = x.args[2]
            if (typeof(lhs) == SymbolNode) && (typeof(rhs) == Expr) && (rhs.head == :call) && (rhs.args[1] == TopNode(:arraysize))
                push!(ret, lhs)
            end
        end
    end
    assert(length(ret) == num_dims)
    ret
end

"""
Holds the data for substitute_cur_body AST walk.
"""
type cur_body_data
    temp_map  :: Dict{SymGen, SymNodeGen}    # Map of array name to temporary.  Use temporary instead of arrayref of the array name.
    index_map :: Dict{SymGen, SymGen}        # Map index variables from parfor being fused to the index variables of the parfor it is being fused with.
    arrays_set_in_cur_body :: Set{SymGen}    # Used as output.  Collects the arrays set in the current body.
    replace_array_name_in_arrayset :: Dict{SymGen, SymGen}  # Map from one array to another.  Replace first array with second when used in arrayset context.
    state :: expr_state
end

"""
AstWalk callback that does the work of substitute_cur_body on a node-by-node basis.
"""
function sub_cur_body_walk(x::Expr,
                           cbd::cur_body_data,
                           top_level_number::Int64,
                           is_top_level::Bool,
                           read::Bool)
    dbglvl = 3
    dprintln(dbglvl,"sub_cur_body_walk ", x)

    dprintln(dbglvl,"sub_cur_body_walk xtype is Expr")
    if x.head == :call
        dprintln(dbglvl,"sub_cur_body_walk xtype is call")
        # Found a call to arrayref.
        if x.args[1] == TopNode(:arrayref) || x.args[1] == TopNode(:unsafe_arrayref)
            dprintln(dbglvl,"sub_cur_body_walk xtype is arrayref")
            array_name = x.args[2]
            index      = x.args[3]
            assert(isa(array_name, SymNodeGen))
            lowered_array_name = toSymGen(array_name)
            assert(isa(lowered_array_name, SymGen))
            dprintln(dbglvl, "array_name = ", array_name, " index = ", index, " lowered_array_name = ", lowered_array_name)
            # If the array name is in cbd.temp_map then replace the arrayref call with the mapped variable.
            if haskey(cbd.temp_map, lowered_array_name)
                dprintln(dbglvl,"sub_cur_body_walk IS substituting ", cbd.temp_map[lowered_array_name])
                return cbd.temp_map[lowered_array_name]
            end
        elseif x.args[1] == TopNode(:arrayset) || x.args[1] == TopNode(:unsafe_arrayset)
            array_name = x.args[2]
            assert(isa(array_name, SymNodeGen))
            push!(cbd.arrays_set_in_cur_body, toSymGen(array_name))
            if haskey(cbd.replace_array_name_in_arrayset, toSymGen(array_name))
                new_symgen = cbd.replace_array_name_in_arrayset[toSymGen(array_name)]
                x.args[2]  = toSymNodeGen(new_symgen, CompilerTools.LambdaHandling.getType(new_symgen, cbd.state.lambdaInfo))
            end
        end
    end

    dprintln(dbglvl,"sub_cur_body_walk not substituting")
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

function sub_cur_body_walk(x::Symbol,
                           cbd::cur_body_data,
                           top_level_number::Int64,
                           is_top_level::Bool,
                           read::Bool)
    dbglvl = 3
    dprintln(dbglvl,"sub_cur_body_walk ", x)

    dprintln(dbglvl,"sub_cur_body_walk xtype is Symbol")
    if haskey(cbd.index_map, x)
        # Detected the use of an index variable.  Change it to the first parfor's index variable.
        dprintln(dbglvl,"sub_cur_body_walk IS substituting ", cbd.index_map[x])
        return cbd.index_map[x]
    end

    dprintln(dbglvl,"sub_cur_body_walk not substituting")
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

function sub_cur_body_walk(x::SymbolNode,
                           cbd::cur_body_data,
                           top_level_number::Int64,
                           is_top_level::Bool,
                           read::Bool)
    dbglvl = 3
    dprintln(dbglvl,"sub_cur_body_walk ", x)

    dprintln(dbglvl,"sub_cur_body_walk xtype is SymbolNode")
    if haskey(cbd.index_map, x.name)
        # Detected the use of an index variable.  Change it to the first parfor's index variable.
        dprintln(dbglvl,"sub_cur_body_walk IS substituting ", cbd.index_map[x.name])
        x.name = cbd.index_map[x.name]
        return x
    end

    dprintln(dbglvl,"sub_cur_body_walk not substituting")
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end


function sub_cur_body_walk(x::ANY,
                           cbd::cur_body_data,
                           top_level_number::Int64,
                           is_top_level::Bool,
                           read::Bool)

    dbglvl = 3
    dprintln(dbglvl,"sub_cur_body_walk ", x)

    dprintln(dbglvl,"sub_cur_body_walk not substituting")
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

"""
Make changes to the second parfor body in the process of parfor fusion.
temp_map holds array names for which arrayrefs should be converted to a variable.  a[i].  a=>b. becomes b
    index_map holds maps between index variables.  The second parfor is modified to use the index variable of the first parfor.
    arrays_set_in_cur_body           # Used as output.  Collects the arrays set in the current body.
    replace_array_name_in_arrayset   # Map from one array to another.  Replace first array with second when used in arrayset context.
"""
function substitute_cur_body(x, 
    temp_map :: Dict{SymGen, SymNodeGen}, 
    index_map :: Dict{SymGen, SymGen}, 
    arrays_set_in_cur_body :: Set{SymGen}, 
    replace_array_name_in_arrayset :: Dict{SymGen, SymGen},
    state :: expr_state)
    @dprintln(3,"substitute_cur_body ", x)
    @dprintln(3,"temp_map = ", temp_map)
    @dprintln(3,"index_map = ", index_map)
    @dprintln(3,"arrays_set_in_cur_body = ", arrays_set_in_cur_body)
    @dprintln(3,"replace_array_name_in_array_set = ", replace_array_name_in_arrayset)
    # Walk the AST and call sub_cur_body_walk for each node.
    return DomainIR.AstWalk(x, sub_cur_body_walk, cur_body_data(temp_map, index_map, arrays_set_in_cur_body, replace_array_name_in_arrayset, state))
end

"""
Returns true if the input node is an assignment node where the right-hand side is a call to arraysize.
"""
function is_eliminated_arraylen(x::Expr)
    @dprintln(3,"is_eliminated_arraylen ", x)

    @dprintln(3,"is_eliminated_arraylen is Expr")
    if x.head == symbol('=')
        assert(typeof(x.args[1]) == SymbolNode)
        rhs = x.args[2]
        if isa(rhs, Expr) && rhs.head == :call
            @dprintln(3,"is_eliminated_arraylen is :call")
            if rhs.args[1] == TopNode(:arraysize)
                @dprintln(3,"is_eliminated_arraylen is :arraysize")
                return true
            end
        end
    end

    return false
end

function is_eliminated_arraylen(x::ANY)
    @dprintln(3,"is_eliminated_arraylen ", x)
    return false
end

"""
AstWalk callback that does the work of substitute_arraylen on a node-by-node basis.
replacement is an array containing the length of the dimensions of the arrays a part of this parfor.
If we see a call to create an array, replace the length params with those in the common set in "replacement".
"""
function sub_arraylen_walk(x::Expr, replacement, top_level_number, is_top_level, read)
    @dprintln(4,"sub_arraylen_walk ", x)

    if x.head == symbol('=')
        rhs = x.args[2]
        if isa(rhs, Expr) && rhs.head == :call
            if rhs.args[1] == TopNode(:ccall)
                if rhs.args[2] == QuoteNode(:jl_alloc_array_1d)
                    rhs.args[7] = replacement[1]
                elseif rhs.args[2] == QuoteNode(:jl_alloc_array_2d)
                    rhs.args[7] = replacement[1]
                    rhs.args[9] = replacement[2]
                end
            end
        end
    end

    @dprintln(4,"sub_arraylen_walk not substituting")

    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

function sub_arraylen_walk(x::ANY, replacement, top_level_number, is_top_level, read)
    @dprintln(4,"sub_arraylen_walk ", x)
    @dprintln(4,"sub_arraylen_walk not substituting")

    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

"""
replacement is an array containing the length of the dimensions of the arrays a part of this parfor.
If we see a call to create an array, replace the length params with those in the common set in "replacement".
"""
function substitute_arraylen(x, replacement)
    @dprintln(3,"substitute_arraylen ", x, " ", replacement)
    # Walk the AST and call sub_arraylen_walk for each node.
    return DomainIR.AstWalk(x, sub_arraylen_walk, replacement)
end

fuse_limit = -1
"""
Control how many parfor can be fused for testing purposes.
    -1 means fuse all possible parfors.
    0  means don't fuse any parfors.
    1+ means fuse the specified number of parfors but then stop fusing beyond that.
"""
function PIRSetFuseLimit(x)
    global fuse_limit = x
end

"""
Specify the number of passes over the AST that do things like hoisting and other rearranging to maximize fusion.
DEPRECATED.
"""
function PIRNumSimplify(x)
    println("PIRNumSimplify is deprecated.")
end

"""
Add to the map of symbol names to types.
"""
function rememberTypeForSym(sym_to_type :: Dict{SymGen, DataType}, sym :: SymGen, typ :: DataType)
    if typ == Any
        @dprintln(0, "rememberTypeForSym: sym = ", sym, " typ = ", typ)
    end
    assert(typ != Any)
    sym_to_type[sym] = typ
end

"""
Just used to hold a spot in an array to indicate the this is a special assignment expression with embedded real array output names from a fusion.
"""
type FusionSentinel
end

"""
Check if an assignement is a fusion assignment.
    In regular assignments, there are only two args, the left and right hand sides.
    In fusion assignments, we introduce a third arg that is marked by an object of FusionSentinel type.
"""
function isFusionAssignment(x :: Expr)
    if x.head != symbol('=')
        return false
    elseif length(x.args) <= 2
        return false
    else
        assert(typeof(x.args[3]) == FusionSentinel)
        return true
    end
end

"""
Returns true if any variable in the collection "vars" is used in any statement whose top level number is in "top_level_numbers".
    We use expr_state "state" to get the block liveness information from which we use "def" and "use" to determine if a variable
        usage is present.
"""
function isSymbolsUsed(vars, top_level_numbers :: Array{Int,1}, state)
    @dprintln(3,"isSymbolsUsed: vars = ", vars, " typeof(vars) = ", typeof(vars), " top_level_numbers = ", top_level_numbers)
    bl = state.block_lives

    for i in top_level_numbers
        tls = CompilerTools.LivenessAnalysis.find_top_number(i, bl)
        assert(tls != nothing)

        for v in vars
            if in(v, tls.def)
                @dprintln(3, "isSymbolsUsed: ", v, " defined in statement ", i)
                return true
            elseif in(v, tls.use)
                @dprintln(3, "isSymbolsUsed: ", v, " used in statement ", i)
                return true
            end
        end
    end

    @dprintln(3, "isSymbolsUsed: ", vars, " not used in statements ", top_level_numbers)
    return false
end

"""
Get the equivalence class of the first array who length is extracted in the pre-statements of the specified "parfor".
"""
function getParforCorrelation(parfor, state)
    return getCorrelation(parfor.first_input, state)
end

"""
Get the equivalence class of a domain IR input in inputInfo.
"""
function getCorrelation(sng :: SymAllGen, state :: expr_state)
    @dprintln(3, "getCorrelation for SymNodeGen = ", sng)
    return getOrAddArrayCorrelation(toSymGen(sng), state)
end

function getCorrelation(array :: SymAllGen, are :: Array{DimensionSelector,1}, state :: expr_state)
    @dprintln(3, "getCorrelation for Array{DimensionSelector,1} = ", are)
    return getOrAddRangeCorrelation(array, are, state)
end

function getCorrelation(inputInfo :: InputInfo, state :: expr_state)
    num_dim_inputs = findSelectedDimensions([inputInfo], state)
    @dprintln(3, "getCorrelation for inputInfo num_dim_inputs = ", num_dim_inputs)
    if isRange(inputInfo)
        return getCorrelation(inputInfo.array, inputInfo.range[1:num_dim_inputs], state)
    else
        return getCorrelation(inputInfo.array, state)
    end
end

"""
Creates a mapping between variables on the left-hand side of an assignment where the right-hand side is a parfor
and the arrays or scalars in that parfor that get assigned to the corresponding parts of the left-hand side.
Returns a tuple where the first element is a map for arrays between left-hand side and parfor and the second
element is a map for reduction scalars between left-hand side and parfor.
is_multi is true if the assignment is a fusion assignment.
parfor_assignment is the AST of the whole expression.
the_parfor is the PIRParForAst type part of the incoming assignment.
sym_to_type is an out parameter that maps symbols in the output mapping to their types.
"""
function createMapLhsToParfor(parfor_assignment, the_parfor, is_multi :: Bool, sym_to_type :: Dict{SymGen, DataType}, state :: expr_state)
    map_lhs_post_array     = Dict{SymGen, SymGen}()
    map_lhs_post_reduction = Dict{SymGen, SymGen}()

    if is_multi
        last_post = the_parfor.postParFor[end]
        assert(isa(last_post, Array)) 
        @dprintln(3,"multi postParFor = ", the_parfor.postParFor, " last_post = ", last_post)

        # In our special AST node format for assignment to make fusion easier, args[3] is a FusionSentinel node
        # and additional args elements are the real symbol to be assigned to in the left-hand side.
        for i = 4:length(parfor_assignment.args)
            corresponding_elem = last_post[i-3]

            assert(isa(parfor_assignment.args[i], SymNodeGen))
            rememberTypeForSym(sym_to_type, toSymGen(parfor_assignment.args[i]), CompilerTools.LambdaHandling.getType(parfor_assignment.args[i], state.lambdaInfo))
            rememberTypeForSym(sym_to_type, toSymGen(corresponding_elem), CompilerTools.LambdaHandling.getType(corresponding_elem, state.lambdaInfo))
            if isArrayType(CompilerTools.LambdaHandling.getType(parfor_assignment.args[i], state.lambdaInfo))
                # For fused parfors, the last post statement is a tuple variable.
                # That tuple variable is declared in the previous statement (end-1).
                # The statement is an Expr with head == :call and top(:tuple) as the first arg.
                # So, the first member of the tuple is at offset 2 which corresponds to index 4 of this loop, ergo the "i-2".
                map_lhs_post_array[toSymGen(parfor_assignment.args[i])]     = toSymGen(corresponding_elem)
            else
                map_lhs_post_reduction[toSymGen(parfor_assignment.args[i])] = toSymGen(corresponding_elem)
            end
        end
    else
        # There is no mapping if this isn't actually an assignment statement but really a bare parfor.
        if !isBareParfor(parfor_assignment)
            lhs_pa = getLhsFromAssignment(parfor_assignment)
            ast_lhs_pa_typ = typeof(lhs_pa)
            lhs_pa_typ = CompilerTools.LambdaHandling.getType(lhs_pa, state.lambdaInfo)
            if isa(lhs_pa, SymNodeGen)
                ppftyp = typeof(the_parfor.postParFor[end]) 
                assert(isa(the_parfor.postParFor[end], SymNodeGen))
                rememberTypeForSym(sym_to_type, toSymGen(lhs_pa), lhs_pa_typ)
                rhs = the_parfor.postParFor[end]
                rememberTypeForSym(sym_to_type, toSymGen(rhs), CompilerTools.LambdaHandling.getType(rhs, state.lambdaInfo))

                if isArrayType(lhs_pa_typ)
                    map_lhs_post_array[toSymGen(lhs_pa)]     = toSymGen(the_parfor.postParFor[end])
                else
                    map_lhs_post_reduction[toSymGen(lhs_pa)] = toSymGen(the_parfor.postParFor[end])
                end
            elseif typeof(lhs_pa) == Symbol
                throw(string("lhs_pa as a symbol no longer supported"))
            else
                @dprintln(3,"typeof(lhs_pa) = ", typeof(lhs_pa))
                assert(false)
            end
        end
    end

    map_lhs_post_array, map_lhs_post_reduction
end

"""
Given an "input" Symbol, use that Symbol as key to a dictionary.  While such a Symbol is present
in the dictionary replace it with the corresponding value from the dict.
"""
function fullyLowerAlias(dict :: Dict{SymGen, SymGen}, input :: SymGen)
    while haskey(dict, input)
        input = dict[input]
    end
    input
end

"""
Take a single-step alias map, e.g., a=>b, b=>c, and create a lowered dictionary, a=>c, b=>c, that
maps each array to the transitively lowered array.
"""
function createLoweredAliasMap(dict1)
    ret = Dict{SymGen, SymGen}()

    for i in dict1
        ret[i[1]] = fullyLowerAlias(dict1, i[2])
    end

    ret
end

run_as_tasks = 0
"""
Debugging feature to specify the number of tasks to create and to stop thereafter.
"""
function PIRRunAsTasks(x)
    global run_as_tasks = x
end

"""
Returns a single element of an array if there is only one or the array otherwise.
"""
function oneIfOnly(x)
    if isa(x,Array) && length(x) == 1
        return x[1]
    else
        return x
    end
end


"""
Returns true if the incoming AST node can be interpreted as a Symbol.
"""
function hasSymbol(ssn :: Symbol)
    return true
end

function hasSymbol(ssn :: SymbolNode)
    return true
end

function hasSymbol(ssn :: Expr)
    return ssn.head == :(::)
end

function hasSymbol(ssn)
    return false
end

"""
Get the name of a symbol whether the input is a Symbol or SymbolNode or :(::) Expr.
"""
function getSName(ssn :: Symbol)
    return ssn
end

function getSName(ssn :: SymbolNode)
    return ssn.name
end

function getSName(ssn :: Expr)
    @dprintln(0, "ssn.head = ", ssn.head)
    assert(ssn.head == :(::))
    return ssn.args[1]
end

function getSName(ssn :: GenSym)
    return ssn
end

function getSName(ssn)
    @dprintln(0, "getSName ssn = ", ssn, " stype = ", stype)
    throw(string("getSName called with something of type ", stype))
end

#"""
#Store information about a section of a body that will be translated into a task.
#"""
#type TaskGraphSection
#  start_body_index :: Int
#  end_body_index   :: Int
#  exprs            :: Array{Any,1}
#end

"""
Process an array of expressions.
Differentiate between top-level arrays of statements and arrays of expression that may occur elsewhere than the :body Expr.
"""
function from_exprs(ast::Array{Any,1}, depth, state)
    # sequence of expressions
    # ast = [ expr, ... ]
    # Is this the first node in the AST with an array of expressions, i.e., is it the top-level?
    top_level = (state.top_level_number == 0)
    if top_level
        return top_level_from_exprs(ast, depth, state)
    else
        return intermediate_from_exprs(ast, depth, state)
    end
end

"""
Process an array of expressions that aren't from a :body Expr.
"""
function intermediate_from_exprs(ast::Array{Any,1}, depth, state)
    # sequence of expressions
    # ast = [ expr, ... ]
    len  = length(ast)
    res = Any[]

    # For each expression in the array, process that expression recursively.
    for i = 1:len
        @dprintln(2,"Processing ast #",i," depth=",depth)

        # Convert the current expression.
        new_exprs = from_expr(ast[i], depth, state, false)
        assert(isa(new_exprs,Array))

        append!(res, new_exprs)  # Take the result of the recursive processing and add it to the result.
    end

    return res 
end

#include("parallel-ir-task.jl")
include("parallel-ir-top-exprs.jl")
include("parallel-ir-flatten.jl")


"""
Pretty print the args part of the "body" of a :lambda Expr at a given debug level in "dlvl".
"""
function printBody(dlvl, body :: Array{Any,1})
    for i = 1:length(body)
        dprintln(dlvl, "    ", body[i])
    end
end

function printBody(dlvl, body :: Expr)
    printBody(dlvl, body.args)
end

"""
Pretty print a :lambda Expr in "node" at a given debug level in "dlvl".
"""
function printLambda(dlvl, node :: Expr)
    assert(node.head == :lambda)
    dprintln(dlvl, "Lambda:")
    dprintln(dlvl, "Input parameters: ", node.args[1])
    dprintln(dlvl, "Metadata: ", node.args[2])
    body = node.args[3]
    if typeof(body) != Expr
        @dprintln(0, "printLambda got ", typeof(body), " for a body, len = ", length(node.args))
        @dprintln(0, node)
    end
    assert(body.head == :body)
    dprintln(dlvl, "typeof(body): ", body.typ)
    printBody(dlvl, body.args)
    if body.typ == Any
        @dprintln(1,"Body type is Any.")
    end
end

function pir_rws_cb(ast :: Expr, cbdata :: ANY)
    @dprintln(4,"pir_rws_cb")

    head = ast.head
    args = ast.args
    if head == :parfor
        @dprintln(4,"pir_rws_cb for :parfor")
        @dprintln(4,"ast = ", ast)
        expr_to_process = Any[]

        assert(typeof(args[1]) == ParallelAccelerator.ParallelIR.PIRParForAst)
        this_parfor = args[1]

        append!(expr_to_process, this_parfor.preParFor)
        for i = 1:length(this_parfor.loopNests)
            # force the indexVariable to be treated as an rvalue
            push!(expr_to_process, mk_untyped_assignment(this_parfor.loopNests[i].indexVariable, 1))
            push!(expr_to_process, this_parfor.loopNests[i].lower)
            push!(expr_to_process, this_parfor.loopNests[i].upper)
            push!(expr_to_process, this_parfor.loopNests[i].step)
        end
        assert(typeof(cbdata) == CompilerTools.LambdaHandling.LambdaInfo)
        fake_body = CompilerTools.LambdaHandling.lambdaInfoToLambdaExpr(cbdata, TypedExpr(nothing, :body, this_parfor.body...))
        @dprintln(3,"fake_body = ", fake_body)

        body_rws = CompilerTools.ReadWriteSet.from_expr(fake_body, pir_rws_cb, cbdata)
        push!(expr_to_process, body_rws)
        append!(expr_to_process, this_parfor.postParFor)

        return expr_to_process
    end

    # Aside from parfor nodes, the ReadWriteSet callback is the same as the liveness callback.
    return pir_live_cb(ast, cbdata)
end

function pir_rws_cb(ast :: ANY, cbdata :: ANY)
    @dprintln(4,"pir_live_cb")

    # Aside from parfor nodes, the ReadWriteSet callback is the same as the liveness callback.
    return pir_live_cb(ast, cbdata)
end

"""
A LivenessAnalysis callback that handles ParallelIR introduced AST node types.
For each ParallelIR specific node type, form an array of expressions that liveness
can analysis to reflect the read/write set of the given AST node.
If we read a symbol it is sufficient to just return that symbol as one of the expressions.
If we write a symbol, then form a fake mk_assignment_expr just to get liveness to realize the symbol is written.
"""
function pir_live_cb(ast :: Expr, cbdata :: ANY)
    @dprintln(4,"pir_live_cb")

    head = ast.head
    args = ast.args
    if head == :parfor
        @dprintln(4,"pir_live_cb for :parfor")
        expr_to_process = Any[]

        assert(typeof(args[1]) == ParallelAccelerator.ParallelIR.PIRParForAst)
        this_parfor = args[1]

        append!(expr_to_process, this_parfor.preParFor)
        for i = 1:length(this_parfor.loopNests)
            # force the indexVariable to be treated as an rvalue
            push!(expr_to_process, mk_untyped_assignment(this_parfor.loopNests[i].indexVariable, 1))
            push!(expr_to_process, this_parfor.loopNests[i].lower)
            push!(expr_to_process, this_parfor.loopNests[i].upper)
            push!(expr_to_process, this_parfor.loopNests[i].step)
        end
        #emptyLambdaInfo = CompilerTools.LambdaHandling.LambdaInfo()
        #fake_body = CompilerTools.LambdaHandling.lambdaInfoToLambdaExpr(emptyLambdaInfo, TypedExpr(nothing, :body, this_parfor.body...))
        assert(typeof(cbdata) == CompilerTools.LambdaHandling.LambdaInfo)
        fake_body = CompilerTools.LambdaHandling.lambdaInfoToLambdaExpr(cbdata, TypedExpr(nothing, :body, this_parfor.body...))
        @dprintln(3,"fake_body = ", fake_body)

        body_lives = CompilerTools.LivenessAnalysis.from_expr(fake_body, pir_live_cb, cbdata)
        live_in_to_start_block = body_lives.basic_blocks[body_lives.cfg.basic_blocks[-1]].live_in
        all_defs = Set()
        for bb in body_lives.basic_blocks
            all_defs = union(all_defs, bb[2].def)
        end
        # as = CompilerTools.LivenessAnalysis.AccessSummary(setdiff(all_defs, live_in_to_start_block), live_in_to_start_block)
        # FIXME: is this correct?
        as = CompilerTools.LivenessAnalysis.AccessSummary(all_defs, live_in_to_start_block)

        push!(expr_to_process, as)

        append!(expr_to_process, this_parfor.postParFor)

        return expr_to_process
    elseif head == :parfor_start
        @dprintln(4,"pir_live_cb for :parfor_start")
        expr_to_process = Any[]

        assert(typeof(args[1]) == PIRParForStartEnd)
        this_parfor = args[1]

        for i = 1:length(this_parfor.loopNests)
            # Force the indexVariable to be treated as an rvalue
            push!(expr_to_process, mk_untyped_assignment(this_parfor.loopNests[i].indexVariable, 1))
            push!(expr_to_process, this_parfor.loopNests[i].lower)
            push!(expr_to_process, this_parfor.loopNests[i].upper)
            push!(expr_to_process, this_parfor.loopNests[i].step)
        end

        return expr_to_process
    elseif head == :parfor_end
        # Intentionally do nothing
        return Any[]
    # task mode commented out
    #=
    elseif head == :insert_divisible_task
        # Is this right?  Do I need pir_range stuff here too?
        @dprintln(4,"pir_live_cb for :insert_divisible_task")
        expr_to_process = Any[]

        cur_task = args[1]
        assert(typeof(cur_task) == InsertTaskNode)

        for i = 1:length(cur_task.args)
            if cur_task.args[i].options == ARG_OPT_IN
                push!(expr_to_process, cur_task.args[i].value)
            else
                push!(expr_to_process, mk_untyped_assignment(cur_task.args[i].value, 1))
            end
        end

        return expr_to_process
    =#
    elseif head == :loophead
        @dprintln(4,"pir_live_cb for :loophead")
        assert(length(args) == 3)

        expr_to_process = Any[]
        push!(expr_to_process, mk_untyped_assignment(SymbolNode(args[1], Int64), 1))  # force args[1] to be seen as an rvalue
        push!(expr_to_process, args[2])
        push!(expr_to_process, args[3])

        return expr_to_process
    elseif head == :loopend
        # There is nothing really interesting in the loopend node to signify something being read or written.
        assert(length(args) == 1)
        return Any[]
    elseif head == :call
        if args[1] == TopNode(:unsafe_arrayref)
            expr_to_process = Any[]
            new_expr = deepcopy(ast)
            new_expr.args[1] = TopNode(:arrayref)
            push!(expr_to_process, new_expr)
            return expr_to_process
        elseif args[1] == TopNode(:safe_arrayref)
            expr_to_process = Any[]
            new_expr = deepcopy(ast)
            new_expr.args[1] = TopNode(:arrayref)
            push!(expr_to_process, new_expr)
            return expr_to_process
        elseif args[1] == TopNode(:unsafe_arrayset)
            expr_to_process = Any[]
            new_expr = deepcopy(ast)
            new_expr.args[1] = TopNode(:arrayset)
            push!(expr_to_process, new_expr)
            return expr_to_process
        end
    elseif head == :(=)
        @dprintln(4,"pir_live_cb for :(=)")
        if length(args) > 2
            expr_to_process = Any[]
            push!(expr_to_process, args[1])
            push!(expr_to_process, args[2])
            for i = 4:length(args)
                push!(expr_to_process, args[i])
            end
            return expr_to_process
        end
    end

    return DomainIR.dir_live_cb(ast, cbdata)
end

function pir_live_cb(ast :: ANY, cbdata :: ANY)
    @dprintln(4,"pir_live_cb")
    return DomainIR.dir_live_cb(ast, cbdata)
end

"""
Sometimes statements we exist in the AST of the form a=Expr where a is a Symbol that isn't live past the assignment
and we'd like to eliminate the whole assignment statement but we have to know that the right-hand side has no
side effects before we can do that.  This function says whether the right-hand side passed into it has side effects
or not.  Several common function calls that otherwise we wouldn't know are safe are explicitly checked for.
"""
function hasNoSideEffects(node :: Union{Symbol, SymbolNode, GenSym, LambdaStaticData, Number})
    return true
end

function hasNoSideEffects(node)
    return false
end

function hasNoSideEffects(node :: Expr)
    if node.head == :select || node.head == :ranges || node.head == :range || node.head == :tomask
        return all(Bool[hasNoSideEffects(a) for a in node.args])
    elseif node.head == :ccall
        func = node.args[1]
        if func == QuoteNode(:jl_alloc_array_1d) ||
            func == QuoteNode(:jl_alloc_array_2d)
            return true
        end
    elseif node.head == :call1
        func = node.args[1]
        if func == TopNode(:apply_type) ||
            func == TopNode(:tuple)
            return true
        end
    elseif node.head == :lambda
        return true
    elseif node.head == :new
        if node.args[1] <: Range
            return true
        end
    elseif node.head == :call
        func = node.args[1]
        if func == GlobalRef(Base, :box) ||
            func == TopNode(:box) ||
            func == TopNode(:tuple) ||
            func == TopNode(:getindex_bool_1d) ||
            func == TopNode(:arraysize) ||
            func == :getindex ||
            func == GlobalRef(Core.Intrinsics, :box) ||
            func == GlobalRef(Core.Intrinsics, :sub_int) ||
            func == GlobalRef(Core.Intrinsics, :add_int) ||
            func == GlobalRef(Core.Intrinsics, :mul_int) 
            return true
        end
    end

    return false
end

function from_assignment_fusion(args::Array{Any,1}, depth, state)
    lhs = args[1]
    rhs = args[2]
    @dprintln(3,"from_assignment lhs = ", lhs)
    @dprintln(3,"from_assignment rhs = ", rhs)
    if isa(rhs, Expr) && rhs.head == :lambda
        # skip handling rhs lambdas
        rhs = [rhs]
    else
        rhs = from_expr(rhs, depth, state, false)
    end
    @dprintln(3,"from_assignment rhs after = ", rhs)
    assert(isa(rhs,Array))
    assert(length(rhs) == 1)
    rhs = rhs[1]

    # Eliminate assignments to variables which are immediately dead.
    # The variable name.
    lhsName = toSymGen(lhs)
    # Get liveness information for the current statement.
    statement_live_info = CompilerTools.LivenessAnalysis.find_top_number(state.top_level_number, state.block_lives)
    @assert statement_live_info!=nothing "$(state.top_level_number) $(state.block_lives)"

    @dprintln(3,statement_live_info)
    @dprintln(3,"def = ", statement_live_info.def)

    # Make sure this variable is listed as a "def" for this statement.
    assert(CompilerTools.LivenessAnalysis.isDef(lhsName, statement_live_info))

    # If the lhs symbol is not in the live out information for this statement then it is dead.
    if !in(lhsName, statement_live_info.live_out) && hasNoSideEffects(rhs)
        @dprintln(3,"Eliminating dead assignment. lhs = ", lhs, " rhs = ", rhs)
        # Eliminate the statement.
        return [], nothing
    end

    @assert typeof(rhs)==Expr && rhs.head==:parfor "Expected :parfor assignment"
    out_typ = rhs.typ
    #@dprintln(3, "from_assignment rhs is Expr, type = ", out_typ, " rhs.head = ", rhs.head, " rhs = ", rhs)
    # If we have "a = parfor(...)" then record that array "a" has the same length as the output array of the parfor.
    the_parfor = rhs.args[1]
    for i = 4:length(args)
        rhs_entry = the_parfor.postParFor[end][i-3]
        assert(typeof(args[i]) == SymbolNode)
        assert(typeof(rhs_entry) == SymbolNode)
        if rhs_entry.typ.name == Array.name
            add_merge_correlations(toSymGen(rhs_entry), toSymGen(args[i]), state)
        end
    end

    return [toSNGen(lhs, out_typ); rhs], out_typ
end

"""
Process an assignment expression.
Starts by recurisvely processing the right-hand side of the assignment.
Eliminates the assignment of a=b if a is dead afterwards and b has no side effects.
    Does some array equivalence class work which may be redundant given that we now run a separate equivalence class pass so consider removing that part of this code.
"""
function from_assignment(lhs, rhs, depth, state)
    # :(=) assignment
    # ast = [ ... ]
    @dprintln(3,"from_assignment lhs = ", lhs)
    @dprintln(3,"from_assignment rhs = ", rhs)
    if isa(rhs, Expr) && rhs.head == :lambda
        # skip handling rhs lambdas
        rhs = [rhs]
    else
        rhs = from_expr(rhs, depth, state, false)
    end
    @dprintln(3,"from_assignment rhs after = ", rhs)
    assert(isa(rhs,Array))
    assert(length(rhs) == 1)
    rhs = rhs[1]

    # Eliminate assignments to variables which are immediately dead.
    # The variable name.
    lhsName = toSymGen(lhs)
    # Get liveness information for the current statement.
    statement_live_info = CompilerTools.LivenessAnalysis.find_top_number(state.top_level_number, state.block_lives)
    @assert statement_live_info!=nothing "$(state.top_level_number) $(state.block_lives)"

    @dprintln(3,statement_live_info)
    @dprintln(3,"def = ", statement_live_info.def)

    # Make sure this variable is listed as a "def" for this statement.
    assert(CompilerTools.LivenessAnalysis.isDef(lhsName, statement_live_info))

    # If the lhs symbol is not in the live out information for this statement then it is dead.
    if !in(lhsName, statement_live_info.live_out) && hasNoSideEffects(rhs)
        @dprintln(3,"Eliminating dead assignment. lhs = ", lhs, " rhs = ", rhs)
        # Eliminate the statement.
        return [], nothing
    end

    if typeof(rhs) == Expr
        out_typ = rhs.typ
        #@dprintln(3, "from_assignment rhs is Expr, type = ", out_typ, " rhs.head = ", rhs.head, " rhs = ", rhs)

        # If we have "a = parfor(...)" then record that array "a" has the same length as the output array of the parfor.
        if rhs.head == :parfor
            the_parfor = rhs.args[1]
            if !(isa(out_typ, Tuple)) && out_typ.name == Array.name # both lhs and out_typ could be a tuple
                @dprintln(3,"Adding parfor array length correlation ", lhs, " to ", rhs.args[1].postParFor[end])
                add_merge_correlations(toSymGen(the_parfor.postParFor[end]), lhsName, state)
            end
            # assertEqShape nodes can prevent fusion and slow things down regardless so we can try to remove them
            # statically if our array length correlations indicate they are in the same length set.
        elseif rhs.head == :assertEqShape
            if from_assertEqShape(rhs, state)
                return [], nothing
            end
        elseif rhs.head == :call
            @dprintln(3, "Detected call rhs in from_assignment.")
            @dprintln(3, "from_assignment call, arg1 = ", rhs.args[1])
            if length(rhs.args) > 1
                @dprintln(3, " arg2 = ", rhs.args[2])
            end
            if rhs.args[1] == TopNode(:ccall)
                if rhs.args[2] == QuoteNode(:jl_alloc_array_1d)
                    dim1 = rhs.args[7]
                    @dprintln(3, "Detected 1D array allocation. dim1 = ", dim1, " type = ", typeof(dim1))
                    if typeof(dim1) == SymbolNode
                        si1 = CompilerTools.LambdaHandling.getDesc(dim1.name, state.lambdaInfo)
                        if si1 & ISASSIGNEDONCE == ISASSIGNEDONCE
                            @dprintln(3, "Will establish array length correlation for const size ", dim1)
                            getOrAddSymbolCorrelation(lhsName, state, SymGen[dim1.name])
                        end
                    end
                elseif rhs.args[2] == QuoteNode(:jl_alloc_array_2d)
                    dim1 = rhs.args[7]
                    dim2 = rhs.args[9]
                    @dprintln(3, "Detected 2D array allocation. dim1 = ", dim1, " dim2 = ", dim2)
                    if typeof(dim1) == SymbolNode && typeof(dim2) == SymbolNode
                        si1 = CompilerTools.LambdaHandling.getDesc(dim1.name, state.lambdaInfo)
                        si2 = CompilerTools.LambdaHandling.getDesc(dim2.name, state.lambdaInfo)
                        if (si1 & ISASSIGNEDONCE == ISASSIGNEDONCE) && (si2 & ISASSIGNEDONCE == ISASSIGNEDONCE)
                            @dprintln(3, "Will establish array length correlation for const size ", dim1, " ", dim2)
                            getOrAddSymbolCorrelation(lhsName, state, SymGen[dim1.name, dim2.name])
                            print_correlations(3, state)
                        end
                    end
                end
            end
        end
    elseif typeof(rhs) == SymbolNode
        out_typ = rhs.typ
        if DomainIR.isarray(out_typ)
            # Add a length correlation of the form "a = b".
            @dprintln(3,"Adding array length correlation ", lhs, " to ", rhs.name)
            add_merge_correlations(toSymGen(rhs), lhsName, state)
        end
    else
        # Get the type of the lhs from its metadata declaration.
        out_typ = CompilerTools.LambdaHandling.getType(lhs, state.lambdaInfo)
    end

    return [toSNGen(lhs, out_typ); rhs], out_typ
end

"""
If we have the type, convert a Symbol to SymbolNode.
If we have a GenSym then we have to keep it.
"""
function toSNGen(x :: Symbol, typ)
    return SymbolNode(x, typ)
end

function toSNGen(x :: SymbolNode, typ)
    return x
end

function toSNGen(x :: GenSym, typ)
    return x
end

function toSNGen(x, typ)
    xtyp = typeof(x)
    throw(string("Found object type ", xtyp, " for object ", x, " in toSNGen and don't know what to do with it."))
end

"""
Process a call AST node.
"""
function from_call(ast::Array{Any,1}, depth, state)
    assert(length(ast) >= 1)
    fun  = ast[1]
    args = ast[2:end]
    @dprintln(2,"from_call fun = ", fun, " typeof fun = ", typeof(fun))
    if length(args) > 0
        @dprintln(2,"first arg = ",args[1], " type = ", typeof(args[1]))
    end
    # We don't need to translate Function Symbols but potentially other call targets we do.
    if typeof(fun) != Symbol
        fun = from_expr(fun, depth, state, false)
        assert(isa(fun,Array))
        assert(length(fun) == 1)
        fun = fun[1]
    end
    # Recursively process the arguments to the call.  
    args = from_exprs(args, depth+1, state)

    return [fun; args]
end

"""
Apply a function "f" that takes the :body from the :lambda and returns a new :body that is stored back into the :lambda.
"""
function processAndUpdateBody(lambda :: Expr, f :: Function, state)
    assert(lambda.head == :lambda) 
    lambda.args[3].args = f(lambda.args[3].args, state)
    return lambda
end

include("parallel-ir-simplify.jl")
include("parallel-ir-fusion.jl")


mmap_to_mmap! = 1
"""
If set to non-zero, perform the phase where non-inplace maps are converted to inplace maps to reduce allocations.
"""
function PIRInplace(x)
    global mmap_to_mmap! = x
end

hoist_allocation = 1
"""
If set to non-zero, perform the rearrangement phase that tries to moves alllocations outside of loops.
"""
function PIRHoistAllocation(x)
    global hoist_allocation = x
end

bb_reorder = 1
"""
If set to non-zero, perform the bubble-sort like reordering phase to coalesce more parfor nodes together for fusion.
"""
function PIRBbReorder(x)
    global bb_reorder = x
end 

shortcut_array_assignment = 0
"""
Enables an experimental mode where if there is a statement a = b and they are arrays and b is not live-out then 
use a special assignment node like a move assignment in C++.
"""
function PIRShortcutArrayAssignment(x)
    global shortcut_array_assignment = x
end

"""
Type for dependence graph creation and topological sorting.
"""
type StatementWithDeps
    stmt :: CompilerTools.LivenessAnalysis.TopLevelStatement
    deps :: Set{StatementWithDeps}
    dfs_color :: Int64 # 0 = white, 1 = gray, 2 = black
    discovery :: Int64
    finished  :: Int64

    function StatementWithDeps(s)
        new(s, Set{StatementWithDeps}(), 0, 0, 0)
    end
end

"""
Construct a topological sort of the dependence graph.
"""
function dfsVisit(swd :: StatementWithDeps, vtime :: Int64, topo_sort :: Array{StatementWithDeps})
    swd.dfs_color = 1 # color gray
    swd.discovery = vtime
    vtime += 1
    for dep in swd.deps
        if dep.dfs_color == 0
            vtime = dfsVisit(dep, vtime, topo_sort)
        end
    end
    swd.dfs_color = 2 # color black
    swd.finished  = vtime
    vtime += 1
    unshift!(topo_sort, swd)
    return vtime
end

"""
Returns true if the given "ast" node is a DomainIR operation.
"""

function isDomainNode(ast :: Expr)
    head = ast.head
    args = ast.args

    if head == :mmap || head == :mmap! || head == :reduce || head == :stencil!
        return true
    end

    for i = 1:length(args)
        if isDomainNode(args[i])
            return true
        end
    end

    return false
end

function isDomainNode(ast)
    return false
end


"""
Returns true if the given AST "node" must remain the last statement in a basic block.
This is true if the node is a GotoNode or a :gotoifnot Expr.
"""
function mustRemainLastStatementInBlock(node :: GotoNode)
    return true
end

function mustRemainLastStatementInBlock(node)
    return false
end

function mustRemainLastStatementInBlock(node :: Expr)
    return node.head == :gotoifnot  ||  node.head == :return
end

"""
Debug print the parts of a DomainLambda.
"""
function pirPrintDl(dbg_level, dl)
    dprintln(dbg_level, "inputs = ", dl.inputs)
    dprintln(dbg_level, "output = ", dl.outputs)
    dprintln(dbg_level, "linfo  = ", dl.linfo)
end

"""
Scan the body of a function in "stmts" and return the max label in a LabelNode AST seen in the body.
"""
function getMaxLabel(max_label, stmts :: Array{Any, 1})
    for i =1:length(stmts)
        if isa(stmts[i], LabelNode)
            max_label = max(max_label, stmts[i].label)
        end
    end
    return max_label
end

"""
Form a Julia :lambda Expr from a DomainLambda.
"""
function lambdaFromDomainLambda(domain_lambda, dl_inputs)
    @dprintln(3,"lambdaFromDomainLambda dl_inputs = ", dl_inputs)
    #  inputs_as_symbols = map(x -> CompilerTools.LambdaHandling.VarDef(x.name, x.typ, 0), dl_inputs)
    type_data = CompilerTools.LambdaHandling.VarDef[]
    input_arrays = Symbol[]
    for di in dl_inputs
        push!(type_data, CompilerTools.LambdaHandling.VarDef(di.name, di.typ, 0))
        if isArrayType(di.typ)
            push!(input_arrays, di.name)
        end
    end
    #  @dprintln(3,"inputs = ", inputs_as_symbols)
    @dprintln(3,"types = ", type_data)
    @dprintln(3,"DomainLambda is:")
    pirPrintDl(3, domain_lambda)
    newLambdaInfo = CompilerTools.LambdaHandling.LambdaInfo()
    CompilerTools.LambdaHandling.addInputParameters(type_data, newLambdaInfo)
    stmts = domain_lambda.genBody(newLambdaInfo, dl_inputs)
    newLambdaInfo.escaping_defs = copy(domain_lambda.linfo.escaping_defs)
    ast = CompilerTools.LambdaHandling.lambdaInfoToLambdaExpr(newLambdaInfo, Expr(:body, stmts...))
    # copy escaping defs from domain lambda since mergeDomainLambda doesn't do it (for good reasons)
    return (ast, input_arrays) 
end

"""
A routine similar to the main parallel IR entry put but designed to process the lambda part of
domain IR AST nodes.
"""
function nested_function_exprs(max_label, domain_lambda, dl_inputs)
    @dprintln(2,"nested_function_exprs max_label = ", max_label)
    @dprintln(2,"domain_lambda = ", domain_lambda, " dl_inputs = ", dl_inputs)
    (ast, input_arrays) = lambdaFromDomainLambda(domain_lambda, dl_inputs)
    @dprintln(1,"Starting nested_function_exprs. ast = ", ast, " input_arrays = ", input_arrays)

    start_time = time_ns()

    @dprintln(1,"Starting liveness analysis.")
    lives = CompilerTools.LivenessAnalysis.from_expr(ast, DomainIR.dir_live_cb, nothing)
    @dprintln(1,"Finished liveness analysis.")

    @dprintln(1,"Liveness Analysis time = ", ns_to_sec(time_ns() - start_time))

    mtm_start = time_ns()

    if mmap_to_mmap! != 0
        @dprintln(1, "starting mmap to mmap! transformation.")
        uniqSet = AliasAnalysis.analyze_lambda(ast, lives, pir_alias_cb, nothing)
        @dprintln(3, "uniqSet = ", uniqSet)
        mmapInline(ast, lives, uniqSet)
        lives = CompilerTools.LivenessAnalysis.from_expr(ast, DomainIR.dir_live_cb, nothing)
        uniqSet = AliasAnalysis.analyze_lambda(ast, lives, pir_alias_cb, nothing)
        mmapToMmap!(ast, lives, uniqSet)
        @dprintln(1, "Finished mmap to mmap! transformation.")
        @dprintln(3, "AST = ", ast)
    end

    @dprintln(1,"mmap_to_mmap! time = ", ns_to_sec(time_ns() - mtm_start))

    # We pass only the non-array params to the rearrangement code because if we pass array params then
    # the code will detect statements that depend only on array params and move them to the top which
    # leaves other non-array operations after that and so prevents fusion.
    @dprintln(3,"All params = ", ast.args[1])
    non_array_params = Set{SymGen}()
    for param in ast.args[1]
        if !in(param, input_arrays) && CompilerTools.LivenessAnalysis.countSymbolDefs(param, lives) == 0
            push!(non_array_params, param)
        end
    end
    @dprintln(3,"Non-array params = ", non_array_params)

    # Find out max_label.
    body = ast.args[3]
    assert(isa(body, Expr) && is(body.head, :body))
    max_label = getMaxLabel(max_label, body.args)

    eq_start = time_ns()

    new_vars = expr_state(lives, max_label, input_arrays)
    @dprintln(3,"Creating equivalence classes.")
    AstWalk(ast, create_equivalence_classes, new_vars)
    @dprintln(3,"Done creating equivalence classes.")

    @dprintln(1,"Creating equivalence classes time = ", ns_to_sec(time_ns() - eq_start))

    rep_start = time_ns()

    changed = true
    while changed
        @dprintln(1,"Removing statement with no dependencies from the AST with parameters = ", ast.args[1])
        rnd_state = RemoveNoDepsState(lives, non_array_params)
        ast = AstWalk(ast, remove_no_deps, rnd_state)
        @dprintln(3,"ast after no dep stmts removed = ", ast)

        @dprintln(3,"top_level_no_deps = ", rnd_state.top_level_no_deps)

        @dprintln(1,"Adding statements with no dependencies to the start of the AST.")
        ast = addStatementsToBeginning(ast, rnd_state.top_level_no_deps)
        @dprintln(3,"ast after no dep stmts re-inserted = ", ast)

        @dprintln(1,"Re-starting liveness analysis.")
        lives = CompilerTools.LivenessAnalysis.from_expr(ast, DomainIR.dir_live_cb, nothing)
        @dprintln(1,"Finished liveness analysis.")

        changed = rnd_state.change
    end

    @dprintln(1,"Rearranging passes time = ", ns_to_sec(time_ns() - rep_start))

    @dprintln(1,"Doing conversion to parallel IR.")
    @dprintln(3,"ast = ", ast)

    new_vars.block_lives = lives

    # Do the main work of Parallel IR.
    ast = from_expr(ast, 1, new_vars, false)
    assert(isa(ast,Array))
    assert(length(ast) == 1)
    ast = ast[1]

    @dprintln(3,"Final ParallelIR = ", ast)

    #throw(string("STOPPING AFTER PARALLEL IR CONVERSION"))
    (new_vars.max_label, ast, ast.args[3].args, new_vars.block_lives)
end

function addStatementsToBeginning(lambda :: Expr, stmts :: Array{Any,1})
    assert(lambda.head == :lambda)
    assert(typeof(lambda.args[3]) == Expr)
    assert(lambda.args[3].head == :body)
    lambda.args[3].args = [stmts; lambda.args[3].args]
    return lambda
end

doRemoveAssertEqShape = true
generalSimplification = true

function get_input_arrays(linfo::LambdaInfo)
    ret = Symbol[]
    input_vars = linfo.input_params
    @dprintln(3,"input_vars = ", input_vars)

    for iv in input_vars
        it = getType(iv, linfo)
        @dprintln(3,"iv = ", iv, " type = ", it)
        if it.name == Array.name
            @dprintln(3,"Parameter is an Array.")
            push!(ret, iv)
        end
    end

    ret
end

"""
The main ENTRY point into ParallelIR.
1) Do liveness analysis.
2) Convert mmap to mmap! where possible.
3) Do some code rearrangement (e.g., hoisting) to maximize later fusion.
4) Create array equivalence classes within the function.
5) Rearrange statements within a basic block to push domain operations to the bottom so more fusion.
6) Call the main from_expr to process the AST for the function.  This will
a) Lower domain IR to parallel IR AST nodes.
b) Fuse parallel IR nodes where possible.
c) Convert to task IR nodes if task mode enabled.
"""
function from_root(function_name, ast :: Expr)
    assert(ast.head == :lambda)
    @dprintln(1,"Starting main ParallelIR.from_expr.  function = ", function_name, " ast = ", ast)

    start_time = time_ns()

    # Create CFG from AST.  This will automatically filter out dead basic blocks.
    cfg = CompilerTools.CFGs.from_ast(ast)
    lambdaInfo = CompilerTools.LambdaHandling.lambdaExprToLambdaInfo(ast)
    input_arrays = get_input_arrays(lambdaInfo)
    body = CompilerTools.LambdaHandling.getBody(ast)
    # Re-create the body minus any dead basic blocks.
    body.args = CompilerTools.CFGs.createFunctionBody(cfg)
    # Re-create the lambda minus any dead basic blocks.
    ast = CompilerTools.LambdaHandling.lambdaInfoToLambdaExpr(lambdaInfo, body)
    @dprintln(1,"ast after dead blocks removed function = ", function_name, " ast = ", ast)

    #CompilerTools.LivenessAnalysis.set_debug_level(3)

    @dprintln(1,"Starting liveness analysis. function = ", function_name)
    lives = CompilerTools.LivenessAnalysis.from_expr(ast, DomainIR.dir_live_cb, nothing)

    #  udinfo = CompilerTools.UDChains.getUDChains(lives)
    @dprintln(3,"lives = ", lives)
    #  @dprintln(3,"udinfo = ", udinfo)
    @dprintln(1,"Finished liveness analysis. function = ", function_name)

    @dprintln(1,"Liveness Analysis time = ", ns_to_sec(time_ns() - start_time))

    mtm_start = time_ns()

    if mmap_to_mmap! != 0
        @dprintln(1, "starting mmap to mmap! transformation.")
        uniqSet = AliasAnalysis.analyze_lambda(ast, lives, pir_alias_cb, nothing)
        @dprintln(3, "uniqSet = ", uniqSet)
        mmapInline(ast, lives, uniqSet)
        lives = CompilerTools.LivenessAnalysis.from_expr(ast, DomainIR.dir_live_cb, nothing)
        uniqSet = AliasAnalysis.analyze_lambda(ast, lives, pir_alias_cb, nothing)
        mmapToMmap!(ast, lives, uniqSet)
        @dprintln(1, "Finished mmap to mmap! transformation. function = ", function_name)
        printLambda(3, ast)
    end

    @dprintln(1,"mmap_to_mmap! time = ", ns_to_sec(time_ns() - mtm_start))

    # We pass only the non-array params to the rearrangement code because if we pass array params then
    # the code will detect statements that depend only on array params and move them to the top which
    # leaves other non-array operations after that and so prevents fusion.
    @dprintln(3,"All params = ", ast.args[1])
    non_array_params = Set{SymGen}()
    for param in ast.args[1]
        if !in(param, input_arrays) && CompilerTools.LivenessAnalysis.countSymbolDefs(param, lives) == 0
            push!(non_array_params, param)
        end
    end
    @dprintln(3,"Non-array params = ", non_array_params, " function = ", function_name)

    # Find out max_label
    body = ast.args[3]
    assert(isa(body, Expr) && is(body.head, :body))
    max_label = getMaxLabel(0, body.args)
    @dprintln(3,"maxLabel = ", max_label, " body type = ", body.typ)

    rep_start = time_ns()

    changed = true
    while changed
        @dprintln(1,"Removing statement with no dependencies from the AST with parameters = ", ast.args[1], " function = ", function_name)
        rnd_state = RemoveNoDepsState(lives, non_array_params)
        ast = AstWalk(ast, remove_no_deps, rnd_state)
        @dprintln(3,"ast after no dep stmts removed = ", " function = ", function_name)
        printLambda(3, ast)

        @dprintln(3,"top_level_no_deps = ", rnd_state.top_level_no_deps)

        @dprintln(1,"Adding statements with no dependencies to the start of the AST.", " function = ", function_name)
        ast = addStatementsToBeginning(ast, rnd_state.top_level_no_deps)
        @dprintln(3,"ast after no dep stmts re-inserted = ", " function = ", function_name)
        printLambda(3, ast)

        @dprintln(1,"Re-starting liveness analysis.", " function = ", function_name)
        lives = CompilerTools.LivenessAnalysis.from_expr(ast, DomainIR.dir_live_cb, nothing)
        @dprintln(1,"Finished liveness analysis.", " function = ", function_name)
        @dprintln(3,"lives = ", lives)

        changed = rnd_state.change
    end

    @dprintln(1,"Rearranging passes time = ", ns_to_sec(time_ns() - rep_start))

    processAndUpdateBody(ast, removeNothingStmts, nothing)
    @dprintln(3,"ast after removing nothing stmts = ", " function = ", function_name)
    printLambda(3, ast)
    lives = CompilerTools.LivenessAnalysis.from_expr(ast, DomainIR.dir_live_cb, nothing)

    if generalSimplification
        ast   = AstWalk(ast, copy_propagate, CopyPropagateState(lives, Dict{Symbol,Symbol}()))
        lives = CompilerTools.LivenessAnalysis.from_expr(ast, DomainIR.dir_live_cb, nothing)
        @dprintln(3,"ast after copy_propagate = ", " function = ", function_name)
        printLambda(3, ast)
    end

    ast   = AstWalk(ast, remove_dead, RemoveDeadState(lives))
    lives = CompilerTools.LivenessAnalysis.from_expr(ast, DomainIR.dir_live_cb, nothing)
    @dprintln(3,"ast after remove_dead = ", " function = ", function_name)
    printLambda(3, ast)

    eq_start = time_ns()

    new_vars = expr_state(lives, max_label, input_arrays)
    @dprintln(3,"Creating equivalence classes.", " function = ", function_name)
    AstWalk(ast, create_equivalence_classes, new_vars)
    @dprintln(3,"Done creating equivalence classes.", " function = ", function_name)
    print_correlations(3, new_vars)

    @dprintln(1,"Creating equivalence classes time = ", ns_to_sec(time_ns() - eq_start))

    if doRemoveAssertEqShape
        processAndUpdateBody(ast, removeAssertEqShape, new_vars)
        @dprintln(3,"ast after removing assertEqShape = ", " function = ", function_name)
        printLambda(3, ast)
        lives = CompilerTools.LivenessAnalysis.from_expr(ast, DomainIR.dir_live_cb, nothing)
    end

    if bb_reorder != 0
        maxFusion(lives)
        # Set the array of statements in the Lambda body to a new array constructed from the updated basic blocks.
        ast.args[3].args = CompilerTools.CFGs.createFunctionBody(lives.cfg)
        @dprintln(3,"ast after maxFusion = ", " function = ", function_name)
        printLambda(3, ast)
        lives = CompilerTools.LivenessAnalysis.from_expr(ast, DomainIR.dir_live_cb, nothing)
    end

    @dprintln(1,"Doing conversion to parallel IR.", " function = ", function_name)
    printLambda(3, ast)

    new_vars.block_lives = lives
    @dprintln(3,"Lives before main Parallel IR = ")
    @dprintln(3,lives)

    # Do the main work of Parallel IR.
    ast = from_expr(ast, 1, new_vars, false)
    assert(isa(ast,Array))
    assert(length(ast) == 1)
    ast = ast[1]

    @dprintln(1,"Final ParallelIR function = ", function_name, " ast = ")
    printLambda(1, ast)

    remove_extra_allocs(ast)

    set_pir_stats(ast)

    #if pir_stop != 0
    #    throw(string("STOPPING AFTER PARALLEL IR CONVERSION"))
    #end
    ast
end

"""
Returns true if input is assignment expression with allocation
"""
function isAllocationAssignment(node::Expr)
    if node.head==:(=) && isAllocation(node.args[2])
        return true
    end
    return false
end

function isAllocationAssignment(node::ANY)
    return false
end

"""
Calculates statistics (number of allocations and parfors)
of the accelerated AST.
"""
function set_pir_stats(ast::Expr)
    body = CompilerTools.LambdaHandling.getBody(ast)
    allocs = 0
    parfors = 0
    # count number of high-level allocations and assignment
    for expr in body.args
        if isAllocationAssignment(expr)
            allocs += 1
        elseif isBareParfor(expr)
            parfors +=1
        end
    end
    # make stats available to user
    ParallelAccelerator.set_num_acc_allocs(allocs);
    ParallelAccelerator.set_num_acc_parfors(parfors);
    return
end

type rm_allocs_state
    defs::Set{SymGen}
    removed_arrs::Dict{SymGen,Array{Any,1}}
    lambdaInfo
end


"""
removes extra allocations
"""
function remove_extra_allocs(ast)
    @dprintln(3,"starting remove extra allocs")
    lambdaInfo = CompilerTools.LambdaHandling.lambdaExprToLambdaInfo(ast)
    lives = CompilerTools.LivenessAnalysis.from_expr(ast, rm_allocs_live_cb, lambdaInfo)
    #lives = CompilerTools.LivenessAnalysis.from_expr(ast, pir_live_cb, lambdaInfo)
    @dprintln(3,"remove extra allocations lives ", lives)
    defs = Set{SymGen}()
    for i in values(lives.basic_blocks)
        defs = union(defs, i.def)
    end
    @dprintln(3, "remove extra allocations defs ",defs)
    rm_state = rm_allocs_state(defs, Dict{SymGen,Array{Any,1}}(), lambdaInfo)
    AstWalk(ast, rm_allocs_cb, rm_state)

    return;
end

function toSynGemOrInt(a::SymbolNode)
    return a.name
end

function toSynGemOrInt(a::Union{Int,SymGen})
    return a
end


function rm_allocs_cb(ast::Expr, state::rm_allocs_state, top_level_number, is_top_level, read)
    head = ast.head
    args = ast.args
    if head == :(=) && isAllocation(args[2])
        arr = toSymGen(args[1])
        if in(arr, state.defs)
            return CompilerTools.AstWalker.ASTWALK_RECURSE
        end
        alloc_args = args[2].args[2:end]
        sh::Array{Any,1} = get_alloc_shape(alloc_args)
        shape = map(toSynGemOrInt,sh)
        @dprintln(3,"rm alloc shape ", shape)
        ast.args[2] = 0 #Expr(:call,TopNode(:tuple), shape...)
        updateLambdaType(arr, length(shape), state.lambdaInfo)
        state.removed_arrs[arr] = shape
        return ast
    elseif head==:call
        if length(args)>=2
            return rm_allocs_cb_call(state, args[1], args[2], args[3:end])
        end
        
    # remove extra arrays from parfor data structures
    elseif head==:parfor
        rm_allocs_cb_parfor(state, args[1])
    end
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

function rm_allocs_cb_call(state::rm_allocs_state, func::TopNode, arr::SymAllGen, rest_args::Array{Any,1})
    if func.name==:arraysize && in(arr, keys(state.removed_arrs))
        shape = state.removed_arrs[arr]
        return shape[rest_args[1]]
    elseif func.name==:unsafe_arrayref  && in(arr, keys(state.removed_arrs))
        return 0
    end
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

function rm_allocs_cb_call(state::rm_allocs_state, func::GlobalRef, arr::SymAllGen, rest_args::Array{Any,1})
    if (func==GlobalRef(Base,:arraylen) || func==GlobalRef(Core.Intrinsics, :arraylen)) && in(arr, keys(state.removed_arrs))
        shape = state.removed_arrs[arr]
        dim = length(shape)
        @dprintln(3, "arraylen found")
        if dim==1
            ast = shape[1]
        else
            mul = foldl((a,b)->"$a*$b", "", shape)
            ast = eval(parse(mul))
        end
        return ast
    end
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

function rm_allocs_cb_call(state::rm_allocs_state, func::ANY, arr::ANY, rest_args::Array{Any,1})
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end



function rm_allocs_cb_parfor(state::rm_allocs_state, parfor::PIRParForAst)
    if in(parfor.first_input, keys(state.removed_arrs))
        #TODO parfor.first_input = NoArrayInput
    end
    for arr in keys(parfor.rws.readSet.arrays)
        if in(arr, keys(state.removed_arrs))
            delete!(parfor.rws.readSet.arrays, arr)
        end
    end
    for arr in keys(parfor.rws.writeSet.arrays)
        if in(arr, keys(state.removed_arrs))
            delete!(parfor.rws.writeSet.arrays, arr)
        end
    end
end

function updateLambdaType(arr::Symbol, dim::Int, lambdaInfo)
    #typ = "Tuple{"*mapfoldl(x->"Int64",(a,b)->"$a,Int64", 1:dim)*"}"
    #lambdaInfo.var_defs[arr] = eval(parse(typ));
    lambdaInfo.var_defs[arr].typ = Int64; 
end

function updateLambdaType(arr::GenSym, dim::Int, lambdaInfo)
    #typ = "Tuple{"*mapfoldl(x->"Int64",(a,b)->"$a,Int64", 1:dim)*"}"
    #lambdaInfo.gen_sym_typs[arr.id+1] = eval(parse(typ));
    lambdaInfo.gen_sym_typs[arr.id+1] = Int64;
end

function rm_allocs_cb(ast :: ANY, cbdata :: ANY, top_level_number, is_top_level, read)
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

function get_alloc_shape(args)
    # tuple
    if args[1]==:(:jl_new_array) && length(args)==7
        return args[6].args[2:end]
    else
        shape_arr = Any[]
        i = 1
        while 6+(i-1)*2 <= length(args)
            push!(shape_arr, args[6+(i-1)*2])
            i+=1
        end
        return shape_arr
    end
    return Any[]
end

function rm_allocs_live_cb(ast :: Expr, cbdata :: ANY)
    head = ast.head
    args = ast.args
    @dprintln(3, "rm_allocs_live_cb called with ast ", ast)
    if head == :(=) && isAllocation(args[2])
        @dprintln(3, "rm_allocs_live_cb ignore allocation ", ast)
        return Any[args[2]]
    end
    return pir_live_cb(ast,cbdata)
end

function rm_allocs_live_cb(ast :: ANY, cbdata :: ANY)
    return pir_live_cb(ast,cbdata)
end


function from_expr(ast ::LambdaStaticData, depth, state :: expr_state, top_level)
    ast = uncompressed_ast(ast)
    return from_expr(ast, depth, state, top_level)
end

function from_expr(ast::Union{SymAllGen,TopNode,LineNumberNode,LabelNode,Char,
    GotoNode,DataType,ASCIIString,NewvarNode,Void,Module}, depth, state :: expr_state, top_level)
    #skip
    return [ast]
end

function from_expr(ast::GlobalRef, depth, state :: expr_state, top_level)
    mod = ast.mod
    name = ast.name
    typ = typeof(mod)
    @dprintln(2,"GlobalRef type ",typeof(mod))
    return [ast]
end


function from_expr(ast::QuoteNode, depth, state :: expr_state, top_level)
    value = ast.value
    #TODO: fields: value
    @dprintln(2,"QuoteNode type ",typeof(value))
    return [ast] 
end

function from_expr(ast::Tuple, depth, state :: expr_state, top_level)
    @assert isbitstuple(ast) "Only bits type tuples allowed in from_expr()"
    return [ast] 
end

function from_expr(ast::Number, depth, state :: expr_state, top_level)
    @assert isbits(ast) "only bits (plain) types supported in from_expr()"
    return [ast] 
end

"""
The main ParallelIR function for processing some node in the AST.
"""
function from_expr(ast ::Expr, depth, state :: expr_state, top_level)
    if is(ast, nothing)
        return [nothing]
    end
    @dprintln(2,"from_expr depth=",depth," ")
    @dprint(2,"Expr ")
    head = ast.head
    args = ast.args
    typ  = ast.typ
    @dprintln(2,head, " ", args)
    if head == :lambda
        ast = from_lambda(ast, depth, state)
        @dprintln(3,"After from_lambda = ", ast)
        return [ast]
    elseif head == :body
        @dprintln(3,"Processing body start")
        args = from_exprs(args,depth+1,state)
        @dprintln(3,"Processing body end")
    elseif head == :(=)
        @dprintln(3,"Before from_assignment typ is ", typ)
        if length(args)>=3
            @assert isa(args[3], FusionSentinel) "Parallel-IR invalid fusion assignment"
            args, new_typ = from_assignment_fusion(args, depth, state)
        else
            @assert length(args)==2 "Parallel-IR invalid assignment"
            args, new_typ = from_assignment(args[1], args[2], depth, state)
        end
        if length(args) == 0
            return []
        end
        if new_typ != nothing
            typ = new_typ
        end
    elseif head == :return
        args = from_exprs(args,depth,state)
    elseif head == :call
        args = from_call(args,depth,state)
        # TODO: catch domain IR result here
    elseif head == :call1
        args = from_call(args, depth, state)
        # TODO?: tuple
    elseif head == :line
        # remove line numbers
        return []
        # skip
    elseif head == :mmap
        head = :parfor
        # Make sure we get what we expect from domain IR.
        # There should be two entries in the array, another array of input array symbols and a DomainLambda type
        if(length(args) < 2)
            throw(string("mk_parfor_args_from_mmap! input_args length should be at least 2 but is ", length(args)))
        end
        # first arg is input arrays, second arg is DomainLambda
        domain_oprs = [DomainOperation(:mmap, args)]
        args = mk_parfor_args_from_mmap(args[1], args[2], domain_oprs, state)
        @dprintln(1,"switching to parfor node for mmap, got ", args)
    elseif head == :mmap!
        head = :parfor
        # Make sure we get what we expect from domain IR.
        # There should be two entries in the array, another array of input array symbols and a DomainLambda type
        if(length(args) < 2)
            throw(string("mk_parfor_args_from_mmap! input_args length should be at least 2 but is ", length(args)))
        end
        # third arg is withIndices
        with_indices = length(args) >= 3 ? args[3] : false
        # first arg is input arrays, second arg is DomainLambda
        domain_oprs = [DomainOperation(:mmap!, args)]
        args = mk_parfor_args_from_mmap!(args[1], args[2], with_indices, domain_oprs, state)
        @dprintln(1,"switching to parfor node for mmap!")
    elseif head == :reduce
        head = :parfor
        args = mk_parfor_args_from_reduce(args, state)
        @dprintln(1,"switching to parfor node for reduce")
    elseif head == :parallel_for
        head = :parfor
        args = mk_parfor_args_from_parallel_for(args, state)
        @dprintln(1,"switching to parfor node for parallel_for")
    elseif head == :copy
        # turn array copy back to plain Julia call
        head = :call
        args = vcat(:copy, args)
    elseif head == :arraysize
        # turn array size back to plain Julia call
        head = :call
        args = vcat(TopNode(:arraysize), args)
    elseif head == :alloc
        # turn array alloc back to plain Julia ccall
        head = :call
        args = from_alloc(args)
    elseif head == :stencil!
        head = :parfor
        ast = mk_parfor_args_from_stencil(typ, head, args, state)
        @dprintln(1,"switching to parfor node for stencil")
        return ast
    elseif head == :copyast
        @dprintln(2,"copyast type")
        # skip
    elseif head == :assertEqShape
        if top_level && from_assertEqShape(ast, state)
            return []
        end
    elseif head == :gotoifnot
        assert(length(args) == 2)
        args[1] = get_one(from_expr(args[1], depth, state, false))
    elseif head == :new
        args = from_exprs(args,depth,state)
    elseif head == :tuple
        for i = 1:length(args)
            args[i] = get_one(from_expr(args[i], depth, state, false))
        end
    elseif head == :getindex
        args = from_exprs(args,depth,state)
    elseif head == :assert
        args = from_exprs(args,depth,state)
    elseif head == :boundscheck
        # skip
    elseif head == :meta
        # skip
    elseif head == :type_goto
        # skip
    else
        throw(string("ParallelAccelerator.ParallelIR.from_expr: unknown Expr head :", head))
    end
    ast = Expr(head, args...)
    @dprintln(3,"New expr type = ", typ, " ast = ", ast)
    ast.typ = typ
    return [ast]
end

function from_alloc(args::Array{Any,1})
    elemTyp = args[1]
    sizes = args[2]
    n = length(sizes)
    assert(n >= 1 && n <= 3)
    name = symbol(string("jl_alloc_array_", n, "d"))
    appTypExpr = TypedExpr(Type{Array{elemTyp,n}}, :call, TopNode(:apply_type), GlobalRef(Base,:Array), elemTyp, n)
    #tupExpr = Expr(:call1, TopNode(:tuple), :Any, [ :Int for i=1:n ]...)
    #tupExpr.typ = ntuple(i -> (i==1) ? Type{Any} : Type{Int}, n+1)
    new_svec = TypedExpr(SimpleVector, :call, TopNode(:svec), GlobalRef(Base, :Any), [ GlobalRef(Base, :Int) for i=1:n ]...)
    realArgs = Any[QuoteNode(name), appTypExpr, new_svec, Array{elemTyp,n}, 0]
    #realArgs = Any[QuoteNode(name), appTypExpr, tupExpr, Array{elemTyp,n}, 0]
    for i=1:n
        push!(realArgs, sizes[i])
        push!(realArgs, 0)
    end
    return vcat(TopNode(:ccall), realArgs)
end


"""
Take something returned from AstWalk and assert it should be an array but in this
context that the array should also be of length 1 and then return that single element.
"""
function get_one(ast::Array)
    assert(length(ast) == 1)
    ast[1]
end

"""
Wraps the callback and opaque data passed from the user of ParallelIR's AstWalk.
"""
type DirWalk
    callback
    cbdata
end

"""
Return one element array with element x.
"""
function asArray(x)
    ret = Any[]
    push!(ret, x)
    return ret
end

"""
AstWalk callback that handles ParallelIR AST node types.
"""
function AstWalkCallback(x :: Expr, dw :: DirWalk, top_level_number :: Int64, is_top_level :: Bool, read :: Bool)
    @dprintln(3,"PIR AstWalkCallback starting")
    ret = dw.callback(x, dw.cbdata, top_level_number, is_top_level, read)
    @dprintln(3,"PIR AstWalkCallback ret = ", ret)
    if ret != CompilerTools.AstWalker.ASTWALK_RECURSE
        return ret
    end

    head = x.head
    args = x.args
    #    typ  = x.typ
    if head == :parfor
        cur_parfor = args[1]
        for i = 1:length(cur_parfor.preParFor)
            x.args[1].preParFor[i] = AstWalk(cur_parfor.preParFor[i], dw.callback, dw.cbdata)
        end
        for i = 1:length(cur_parfor.loopNests)
            x.args[1].loopNests[i].indexVariable = AstWalk(cur_parfor.loopNests[i].indexVariable, dw.callback, dw.cbdata)
            # There must be some reason that I was faking an assignment expression although this really shouldn't happen in an AstWalk. In liveness callback yes, but not here.
            AstWalk(mk_assignment_expr(cur_parfor.loopNests[i].indexVariable, 1), dw.callback, dw.cbdata)
            x.args[1].loopNests[i].lower = AstWalk(cur_parfor.loopNests[i].lower, dw.callback, dw.cbdata)
            x.args[1].loopNests[i].upper = AstWalk(cur_parfor.loopNests[i].upper, dw.callback, dw.cbdata)
            x.args[1].loopNests[i].step  = AstWalk(cur_parfor.loopNests[i].step, dw.callback, dw.cbdata)
        end
        for i = 1:length(cur_parfor.reductions)
            x.args[1].reductions[i].reductionVar     = AstWalk(cur_parfor.reductions[i].reductionVar, dw.callback, dw.cbdata)
            x.args[1].reductions[i].reductionVarInit = AstWalk(cur_parfor.reductions[i].reductionVarInit, dw.callback, dw.cbdata)
            x.args[1].reductions[i].reductionFunc    = AstWalk(cur_parfor.reductions[i].reductionFunc, dw.callback, dw.cbdata)
        end
        for i = 1:length(cur_parfor.body)
            x.args[1].body[i] = AstWalk(cur_parfor.body[i], dw.callback, dw.cbdata)
        end
        for i = 1:length(cur_parfor.postParFor)-1
            x.args[1].postParFor[i] = AstWalk(cur_parfor.postParFor[i], dw.callback, dw.cbdata)
        end
        # update read write set in case of symbol replacement like unused variable elimination
        old_set = copy(x.args[1].rws.readSet.scalars)
        for sym in old_set
            o_sym = AstWalk(sym, dw.callback, dw.cbdata)
            delete!(x.args[1].rws.readSet.scalars,sym)
            push!(x.args[1].rws.readSet.scalars,o_sym)
        end
        old_set = copy(x.args[1].rws.writeSet.scalars)
        for sym in old_set
            o_sym = AstWalk(sym, dw.callback, dw.cbdata)
            delete!(x.args[1].rws.writeSet.scalars,sym)
            push!(x.args[1].rws.writeSet.scalars,o_sym)
        end
        old_set = [k for k in keys(x.args[1].rws.readSet.arrays)]
        for sym in old_set
            val = x.args[1].rws.readSet.arrays[sym]
            o_sym = AstWalk(sym, dw.callback, dw.cbdata)
            delete!(x.args[1].rws.readSet.arrays,sym)
            x.args[1].rws.readSet.arrays[o_sym] = val
        end
        old_set = [k for k in keys(x.args[1].rws.writeSet.arrays)]
        for sym in old_set
            val = x.args[1].rws.writeSet.arrays[sym]
            o_sym = AstWalk(sym, dw.callback, dw.cbdata)
            delete!(x.args[1].rws.writeSet.arrays,sym)
            x.args[1].rws.writeSet.arrays[o_sym] = val
        end

        return x
    elseif head == :parfor_start || head == :parfor_end
        @dprintln(3, "parfor_start or parfor_end walking, dw = ", dw)
        @dprintln(3, "pre x = ", x)
        cur_parfor = args[1]
        for i = 1:length(cur_parfor.loopNests)
            x.args[1].loopNests[i].indexVariable = AstWalk(cur_parfor.loopNests[i].indexVariable, dw.callback, dw.cbdata)
            AstWalk(mk_assignment_expr(cur_parfor.loopNests[i].indexVariable, 1), dw.callback, dw.cbdata)
            x.args[1].loopNests[i].lower = AstWalk(cur_parfor.loopNests[i].lower, dw.callback, dw.cbdata)
            x.args[1].loopNests[i].upper = AstWalk(cur_parfor.loopNests[i].upper, dw.callback, dw.cbdata)
            x.args[1].loopNests[i].step  = AstWalk(cur_parfor.loopNests[i].step, dw.callback, dw.cbdata)
        end
        for i = 1:length(cur_parfor.reductions)
            x.args[1].reductions[i].reductionVar     = AstWalk(cur_parfor.reductions[i].reductionVar, dw.callback, dw.cbdata)
            x.args[1].reductions[i].reductionVarInit = AstWalk(cur_parfor.reductions[i].reductionVarInit, dw.callback, dw.cbdata)
            x.args[1].reductions[i].reductionFunc    = AstWalk(cur_parfor.reductions[i].reductionFunc, dw.callback, dw.cbdata)
        end
        for i = 1:length(cur_parfor.private_vars)
            x.args[1].private_vars[i] = AstWalk(cur_parfor.private_vars[i], dw.callback, dw.cbdata)
        end
        @dprintln(3, "post x = ", x)
        return x
    elseif head == :insert_divisible_task
        cur_task = args[1]
        for i = 1:length(cur_task.args)
            x.args[1].value = AstWalk(cur_task.args[i].value, dw.callback, dw.cbdata)
        end
        return x
    elseif head == :loophead
        for i = 1:length(args)
            x.args[i] = AstWalk(x.args[i], dw.callback, dw.cbdata)
        end
        return x
    elseif head == :loopend
        for i = 1:length(args)
            x.args[i] = AstWalk(x.args[i], dw.callback, dw.cbdata)
        end
        return x
    end

    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

# task mode commeted out
#=
function AstWalkCallback(x :: pir_range_actual, dw :: DirWalk, top_level_number :: Int64, is_top_level :: Bool, read :: Bool)
    @dprintln(4,"PIR AstWalkCallback starting")
    ret = dw.callback(x, dw.cbdata, top_level_number, is_top_level, read)
    @dprintln(4,"PIR AstWalkCallback ret = ", ret)
    if ret != CompilerTools.AstWalker.ASTWALK_RECURSE
        return ret
    end

    for i = 1:length(x.dim)
        x.lower_bounds[i] = AstWalk(x.lower_bounds[i], dw.callback, dw.cbdata)
        x.upper_bounds[i] = AstWalk(x.upper_bounds[i], dw.callback, dw.cbdata)
    end
    return x
end
=#

function AstWalkCallback(x :: DelayedFunc, dw :: DirWalk, top_level_number :: Int64, is_top_level :: Bool, read :: Bool)
    @dprintln(4,"PIR AstWalkCallback starting")
    ret = dw.callback(x, dw.cbdata, top_level_number, is_top_level, read)
    @dprintln(4,"PIR AstWalkCallback ret = ", ret)
    if ret != CompilerTools.AstWalker.ASTWALK_RECURSE
        return ret
    end
    if isa(dw.cbdata, rm_allocs_state) # skip traversal if it is for rm_allocs
        return x
    end
    for i = 1:length(x.args)
        y = x.args[i]
        if isa(y, Array)
            for j=1:length(y)
                y[j] = AstWalk(y[j], dw.callback, dw.cbdata)
            end
        else
            x.args[i] = AstWalk(x.args[i], dw.callback, dw.cbdata)
        end
    end
    return x
end

function AstWalkCallback(x :: ANY, dw :: DirWalk, top_level_number :: Int64, is_top_level :: Bool, read :: Bool)
    @dprintln(4,"PIR AstWalkCallback starting")
    ret = dw.callback(x, dw.cbdata, top_level_number, is_top_level, read)
    @dprintln(4,"PIR AstWalkCallback ret = ", ret)
    if ret != CompilerTools.AstWalker.ASTWALK_RECURSE
        return ret
    end
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

"""
ParallelIR version of AstWalk.
Invokes the DomainIR version of AstWalk and provides the parallel IR AstWalk callback AstWalkCallback.

Parallel IR AstWalk calls Domain IR AstWalk which in turn calls CompilerTools.AstWalker.AstWalk.
For each AST node, CompilerTools.AstWalker.AstWalk calls Domain IR callback to give it a chance to handle the node if it is a Domain IR node.
Likewise, Domain IR callback first calls Parallel IR callback to give it a chance to handle Parallel IR nodes.
The Parallel IR callback similarly first calls the user-level callback to give it a chance to process the node.
If a callback returns "nothing" it means it didn't modify that node and that the previous code should process it.
The Parallel IR callback will return "nothing" if the node isn't a Parallel IR node.
The Domain IR callback will return "nothing" if the node isn't a Domain IR node.
"""
function AstWalk(ast::Any, callback, cbdata)
    dw = DirWalk(callback, cbdata)
    DomainIR.AstWalk(ast, AstWalkCallback, dw)
end

"""
An AliasAnalysis callback (similar to LivenessAnalysis callback) that handles ParallelIR introduced AST node types.
For each ParallelIR specific node type, form an array of expressions that AliasAnalysis
    can analyze to reflect the aliases of the given AST node.
    If we read a symbol it is sufficient to just return that symbol as one of the expressions.
    If we write a symbol, then form a fake mk_assignment_expr just to get liveness to realize the symbol is written.
"""
function pir_alias_cb(ast::Expr, state, cbdata)
    @dprintln(4,"pir_alias_cb")

    head = ast.head
    args = ast.args
    if head == :parfor
        @dprintln(3,"pir_alias_cb for :parfor")
        expr_to_process = Any[]

        assert(typeof(args[1]) == ParallelAccelerator.ParallelIR.PIRParForAst)
        this_parfor = args[1]

        AliasAnalysis.increaseNestLevel(state);
        AliasAnalysis.from_exprs(state, this_parfor.preParFor, pir_alias_cb, cbdata)
        AliasAnalysis.from_exprs(state, this_parfor.body, pir_alias_cb, cbdata)
        ret = AliasAnalysis.from_exprs(state, this_parfor.postParFor, pir_alias_cb, cbdata)
        AliasAnalysis.decreaseNestLevel(state);

        return ret[end]

    elseif head == :call
        if args[1] == TopNode(:unsafe_arrayref)
            return AliasAnalysis.NotArray 
        elseif args[1] == TopNode(:unsafe_arrayset)
            return AliasAnalysis.NotArray 
        end
    end

    return DomainIR.dir_alias_cb(ast, state, cbdata)
end

function pir_alias_cb(ast::ANY, state, cbdata)
    @dprintln(4,"pir_alias_cb")
    return DomainIR.dir_alias_cb(ast, state, cbdata)
end

end
