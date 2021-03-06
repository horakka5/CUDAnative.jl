module CUDAnative

using CUDAapi
using CUDAdrv

using LLVM
using LLVM.Interop

using Adapt
using TimerOutputs
using DataStructures

using Libdl


## global state

const toolkit_dirs = Ref{Vector{String}}()

"""
    prefix()

Returns the installation prefix directories of the CUDA toolkit in use.
"""
prefix() = toolkit_dirs[]

const toolkit_version = Ref{VersionNumber}()

"""
    version()

Returns the version of the CUDA toolkit in use.
"""
version() = toolkit_version[]

"""
    release()

Returns the CUDA release part of the version as returned by [`version`](@ref).
"""
release() = VersionNumber(toolkit_version[].major, toolkit_version[].minor)

# version compatibility
const target_support = Ref{Vector{VersionNumber}}()
const ptx_support = Ref{Vector{VersionNumber}}()

# paths
const libdevice = Ref{String}()
const libcudadevrt = Ref{String}()
const nvdisasm = Ref{String}()


## source code includes

include("utils.jl")

# needs to be loaded _before_ the compiler infrastructure, because of generated functions
include("device/tools.jl")
include("device/pointer.jl")
include("device/array.jl")
include("device/cuda.jl")
include("device/llvm.jl")
include("device/runtime.jl")

include("cupti/CUPTI.jl")
include("nvtx/NVTX.jl")

include("init.jl")
include("compatibility.jl")

include("compiler.jl")
include("execution.jl")
include("exceptions.jl")
include("reflection.jl")

include("deprecated.jl")

export CUPTI, NVTX


## initialization

const __initialized__ = Ref(false)
functional() = __initialized__[]

function __init__()
    precompiling = ccall(:jl_generating_output, Cint, ()) != 0
    silent = parse(Bool, get(ENV, "JULIA_CUDA_SILENT", "false")) || precompiling
    verbose = parse(Bool, get(ENV, "JULIA_CUDA_VERBOSE", "false"))

    # if any dependent GPU package failed, expect it to have logged an error and bail out
    if !CUDAdrv.functional()
        verbose && @warn "CUDAnative.jl did not initialize because CUDAdrv.jl failed to"
        return
    end

    try
        ## target support

        # LLVM.jl

        llvm_version = LLVM.version()


        # Julia

        julia_llvm_version = Base.libllvm_version
        if julia_llvm_version != llvm_version
            error("LLVM $llvm_version incompatible with Julia's LLVM $julia_llvm_version")
        end

        if llvm_version >= v"8.0" #&& CUDAdrv.release() < v"10.2"
            # NOTE: corresponding functionality in irgen.jl
            silent || @warn "Incompatibility detected between CUDA and LLVM 8.0+; disabling debug info emission for CUDA kernels"
        end


        # CUDA

        toolkit_dirs[] = find_toolkit()

        path = find_cuda_binary("nvdisasm", toolkit_dirs[])
        if path === nothing
            error("Your CUDA installation does not provide the nvdisasm binary")
        else
            nvdisasm[] = path
        end

        toolkit_version[] = parse_toolkit_version(nvdisasm[])
        if release() < v"9"
            silent || @warn "CUDAnative.jl only supports CUDA 9.0 or higher (your toolkit provides CUDA $(release()))"
        elseif release() > CUDAdrv.release()
            silent || @warn """You are using CUDA toolkit $(release()) with a driver that only supports up to $(CUDAdrv.release()).
                               It is recommended to upgrade your driver."""
        end

        path = find_libdevice(toolkit_dirs[])
        if path === nothing
            error("Your CUDA installation does not provide libdevice")
        else
            libdevice[] = path
        end

        path = find_libcudadevrt(toolkit_dirs[])
        if path === nothing
            error("Your CUDA installation does not provide libcudadevrt")
        else
            libcudadevrt[] = path
        end

        path = find_cuda_library("nvtx", toolkit_dirs[], [v"1"])
        if path === nothing
            silent || @warn("Your CUDA installation does not provide the NVTX library, CUDAnative.NVTX will be unavailable")
        else
            NVTX.libnvtx[] = path
        end

        path = find_cuda_library("cupti", toolkit_dirs[], [toolkit_version[]])
        if path === nothing
            silent || @warn("Your CUDA installation does not provide the CUPTI library, CUDAnative.@code_sass will be unavailable")
        else
            CUPTI.libcupti[] = path
        end

        llvm_support = llvm_compat(llvm_version)
        cuda_support = cuda_compat()

        target_support[] = sort(collect(llvm_support.cap ∩ cuda_support.cap))
        isempty(target_support[]) && error("Your toolchain does not support any device capability")

        ptx_support[] = sort(collect(llvm_support.ptx ∩ cuda_support.ptx))
        isempty(ptx_support[]) && error("Your toolchain does not support any PTX ISA")

        @debug("CUDAnative supports devices $(verlist(target_support[])); PTX $(verlist(ptx_support[]))")


        ## actual initialization

        __init_compiler__()

        resize!(thread_contexts, Threads.nthreads())
        fill!(thread_contexts, nothing)
        CUDAdrv.initializer(maybe_initialize)

        __initialized__[] = true
    catch ex
        # don't actually fail to keep the package loadable
        if !silent
            if verbose
                @error "CUDAnative.jl failed to initialize" exception=(ex, catch_backtrace())
            else
                @info "CUDAnative.jl failed to initialize, GPU functionality unavailable (set JULIA_CUDA_SILENT or JULIA_CUDA_VERBOSE to silence or expand this message)"
            end
        end
    end
end

end
