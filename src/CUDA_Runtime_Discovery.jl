module CUDA_Runtime_Discovery

using Libdl


#
# discovery helpers
#

function resolve(path)
    resolves = 0
    while islink(path) && resolves < 10
        resolves += 1
        dir = dirname(path)
        path = resolve(joinpath(dir, readlink(path)))
    end

    return path
end

# return a list of valid directories, resolving symlinks and pruning duplicates
function valid_dirs(dirs)
    map!(resolve, dirs, dirs)
    filter(isdir, unique(dirs))
end

function join_versions(versions::Vector)
    isempty(versions) && return "no specific version"
    "version " * join(versions, " or ")
end

function join_locations(locations::Vector)
    isempty(locations) && return "in no specific location"
    "in " * join(locations, " or ")
end


## generic discovery routines

function library_names(name::String, versions::Vector=[])
    names = String[]

    # always look for an unversioned library first
    if Sys.iswindows()
        push!(names, "$(name)$(Sys.WORD_SIZE).$(Libdl.dlext)")

        # some libraries (e.g. CUTENSOR) are shipped without the word size-prefix
        push!(names, "$(name).$(Libdl.dlext)")
    elseif Sys.isapple()
        # macOS puts the version number before the dylib extension
        push!(names, "lib$(name).$(Libdl.dlext)")
    elseif Sys.isunix()
        # most UNIX distributions ship versioned libraries (also see JuliaLang/julia#22828)
        push!(names, "lib$(name).$(Libdl.dlext)")
    else
        push!(names, "lib$name.$(Libdl.dlext)")
    end

    # then consider versioned libraries
    for version in versions
        if Sys.iswindows()
            # Windows encodes the version in the filename
            if version isa VersionNumber
                append!(names, ["$(name)$(Sys.WORD_SIZE)_$(version.major)$(version.minor).$(Libdl.dlext)",
                                "$(name)$(Sys.WORD_SIZE)_$(version.major).$(Libdl.dlext)"])
            elseif version isa String
                push!(names, "$(name)$(Sys.WORD_SIZE)_$(version).$(Libdl.dlext)")
            end

            # some libraries (e.g. CUTENSOR) are shipped without the word size-prefix
            if version isa VersionNumber
                append!(names, ["$(name)_$(version.major)$(version.minor).$(Libdl.dlext)",
                                "$(name)_$(version.major).$(Libdl.dlext)"])
            elseif version isa String
                push!(names, "$(name)_$(version).$(Libdl.dlext)")
            end
        elseif Sys.isapple()
            # macOS puts the version number before the dylib extension
            if version isa VersionNumber
                append!(names, ["lib$(name).$(version.major).$(version.minor).$(Libdl.dlext)",
                                "lib$(name).$(version.major).$(Libdl.dlext)"])
            elseif version isa String
                push!(names, "lib$(name).$(version).$(Libdl.dlext)")
            end
        elseif Sys.isunix()
            # most UNIX distributions ship versioned libraries (also see JuliaLang/julia#22828)
            if version isa VersionNumber
                append!(names, ["lib$(name).$(Libdl.dlext).$(version.major).$(version.minor).$(version.patch)",
                                "lib$(name).$(Libdl.dlext).$(version.major).$(version.minor)",
                                "lib$(name).$(Libdl.dlext).$(version.major)"])
            elseif version isa String
                push!(names, "lib$(name).$(Libdl.dlext).$(version)")
            end
        end
    end

    return names
end

"""
    find_library(name, versions; locations=String[])

Wrapper for Libdl.find_library, performing a more exhaustive search:

- variants of the library name (including version numbers, platform-specific tags, etc);
- various subdirectories of the `locations` list, and finally system library directories.

Returns the full path to the library.
"""
function find_library(name::String, versions::Vector=[];
                      locations::Vector{String}=String[])
    # figure out names
    all_names = library_names(name, versions)

    # figure out locations
    all_locations = String[]
    for location in locations
        push!(all_locations, location)
        push!(all_locations, joinpath(location, "lib"))
        if Sys.WORD_SIZE == 64
            push!(all_locations, joinpath(location, "lib64"))
            push!(all_locations, joinpath(location, "libx64"))
        end
        if Sys.iswindows()
            push!(all_locations, joinpath(location, "bin"))
            push!(all_locations, joinpath(location, "bin", Sys.WORD_SIZE==64 ? "x64" : "Win32"))
        end
        if Sys.islinux()
            arch = Sys.ARCH == :powerpc64le ? :ppc64le :
                   Sys.ARCH == :aarch64 ? :sbsa :
                   Sys.ARCH
            push!(all_locations, joinpath(location, "targets", "$arch-linux", "lib")) # NVHPC SDK
        end
    end

    @debug "Looking for library $name, $(join_versions(versions)), $(join_locations(locations))" all_names all_locations
    name_found = Libdl.find_library(all_names, all_locations)
    if isempty(name_found)
        @debug "Did not find $name"
        return nothing
    end

    # find the full path of the library (which Libdl.find_library doesn't guarantee to return)
    path = Libdl.dlpath(name_found)
    @debug "Found $(basename(path)) at $(dirname(path))"
    return path
end

"""
    find_binary(name; locations=String[])

Similar to `find_library`, performs an exhaustive search for a binary in various
subdirectories of `locations`, and finally PATH by using `Sys.which`.
"""
function find_binary(name::String; locations::Vector{String}=String[])
    # figure out locations
    all_locations = String[]
    for location in locations
        push!(all_locations, location)
        push!(all_locations, joinpath(location, "bin"))
    end
    # we look in PATH too by using `Sys.which` with unadorned names

    @debug "Looking for binary $name $(join_locations(locations))" all_locations
    all_paths = [name; [joinpath(location, name) for location in all_locations]]
    for path in all_paths
        try
            program_path = Sys.which(path)
            if program_path !== nothing
                @debug "Found $path at $program_path"
                return program_path
            end
        catch
            # some system disallow `stat` on certain paths
        end
    end

    @debug "Did not find $name"
    return nothing
end


## CUDA-specific discovery routines

const cuda_releases = [v"9.0", v"9.1", v"9.2",
                       v"10.0", v"10.1", v"10.2",
                       v"11.0", v"11.1", v"11.2", v"11.3", v"11.4", v"11.5", v"11.6", v"11.7", v"11.8",
                       v"12.0", v"12.1", v"12.2", v"12.3", v"12.4"]

# return possible versions of a CUDA library
function cuda_library_versions(name::String)
    # we don't know which version we're looking for (and we don't first want to figure
    # that out by, say, invoking a versionless binary like ptxas), so try all known versions

    # start out with all known CUDA releases
    versions = Any[cuda_releases...]

    # append some future releases
    last_major = last(versions).major
    for major in last_major:(last_major+2), minor in 1:10
        version = VersionNumber(major, minor)
        if !in(version, versions)
            push!(versions, version)
        end
    end

    # CUPTI is special, and uses a dot-separated, year-based versioning
    if name == "cupti"
        for year in 2020:2025, major in 1:5, minor in 0:3
            version = "$year.$major.$minor"
            push!(versions, version)
        end
    end

    versions
end

# simplified find_library/find_binary entry-points,
# looking up name aliases and known version numbers
# and passing the (optional) toolkit dirs as locations.
function find_cuda_library(toolkit_dirs::Vector{String}, library::String, versions::Vector)
    # figure out the location
    locations = copy(toolkit_dirs)
    ## CUPTI (and related libraries) are in the "extras" directory of the toolkit
    if library in ("cupti", "nvperf_host", "nvperf_target")
        toolkit_extras_dirs = filter(dir->isdir(joinpath(dir, "extras")), toolkit_dirs)
        cupti_dirs = map(dir->joinpath(dir, "extras", "CUPTI"), toolkit_extras_dirs)
        append!(locations, cupti_dirs)
    end
    ## NVVM-related libraries can be in a separate directory
    if library == "nvvm"
        for toolkit_dir in toolkit_dirs
            push!(locations, joinpath(toolkit_dir, "nvvm"))
        end
    end

    find_library(library, versions; locations)
end
function find_cuda_binary(toolkit_dirs::Vector{String}, name::String)
    # figure out the location
    locations = toolkit_dirs
    ## compute-sanitizer is in the "extras" directory of the toolkit
    ## NVHPC has it in the top-level directory
    if name == "compute-sanitizer"
        toolkit_extras_dirs = filter(dir->isdir(joinpath(dir, "extras")), toolkit_dirs)
        sanitizer_dirs = map(dir->joinpath(dir, "extras", "compute-sanitizer"), toolkit_extras_dirs)

        toolkit_sanitizer_dirs = filter(dir->isdir(joinpath(dir, "compute-sanitizer")), toolkit_dirs)
        sanitizer_dirs_other =  map(dir->joinpath(dir, "compute-sanitizer"), toolkit_sanitizer_dirs)

        append!(locations, sanitizer_dirs)
        append!(locations, sanitizer_dirs_other)
    end

    find_binary(name; locations)
end

# check if the basename of the given path is version like, i.e. 12.1
function has_version_like_name(path)
    dirname = basename(path)
    occursin('.', dirname) || return false
    for s in eachsplit(dirname, '.')
        isnothing(tryparse(Int, s)) && return false
    end
    return true
end

function get_version_preference()
    prefs = get(Base.get_preferences(), "CUDA_Runtime_jll", nothing)
    isnothing(prefs) && return nothing
    return get(prefs, "version", nothing)
end

function get_cuda_path_from_nvhpc_root(nvhpc_root)
    # try to go from NVHPC_ROOT -> NVHPC_ROOT/cuda/X.Y
    nvhpc_cuda = joinpath(nvhpc_root, "cuda")
    if ispath(nvhpc_cuda)
        ver = get_version_preference()
        if !isnothing(ver)
            p = joinpath(nvhpc_cuda, ver)
            if ispath(p)
                @debug "Deduced CUDA toolkit path $p from environment variable NVHPC_ROOT + set version preference ($ver) for CUDA_Runtime_jll"
                return p
            else
                @debug "Couldn't deduce a valid CUDA toolkit path from environment variable NVHPC_ROOT + set version preference ($ver) for CUDA_Runtime_jll"
            end
        end

        paths = filter(has_version_like_name, readdir(nvhpc_cuda, join=true))
        if length(paths) > 1
            @debug "Couldn't deduce a unique CUDA toolkit path from environment variable NVHPC_ROOT"
        else
            p = only(paths)
            @debug "Deduced CUDA toolkit path $p from environment variable NVHPC_ROOT"
            return p
        end
    else
        @debug "Couldn't deduce CUDA toolkit path from environment variable NVHPC_ROOT"
    end
    return nothing
end

"""
    find_toolkit()::Vector{String}

Look for directories where (parts of) the CUDA toolkit might be installed. This returns a
(possibly empty) list of paths that can be used as an argument to other discovery functions.

The behavior of this function can be overridden by defining the `CUDA_PATH`, `CUDA_HOME` or
`CUDA_ROOT` environment variables, which should point to the root of the CUDA toolkit.
"""
function find_toolkit()
    dirs = String[]

    # look for environment variables to override discovery
    envvars = ["CUDA_PATH", "CUDA_HOME", "CUDA_ROOT", "NVHPC_ROOT"]
    filter!(var -> haskey(ENV, var) && ispath(ENV[var]), envvars)
    @debug "Looking for CUDA toolkit via environment variables $(join(envvars, ", "))"

    if !isempty(envvars)
        paths = unique(map(envvars) do var
            if var == "NVHPC_ROOT"
                p = get_cuda_path_from_nvhpc_root(ENV["NVHPC_ROOT"])
                if !isnothing(p)
                    return p
                end
            end
            return ENV[var]
        end)
        if length(paths) > 1
            @warn "Multiple CUDA environment variables set to different values: $(join(paths, ", "))"
        end

        append!(dirs, paths)
        return dirs
    end

    # look for the compiler binary (in the case PATH points to the installation)
    ptxas_path = find_binary("ptxas")
    if ptxas_path !== nothing
        ptxas_dir = dirname(ptxas_path)
        if occursin(r"^bin(32|64)?$", basename(ptxas_dir))
            ptxas_dir = dirname(ptxas_dir)
        end

        @debug "Looking for CUDA toolkit via ptxas binary" path=ptxas_path dir=ptxas_dir
        push!(dirs, ptxas_dir)
    end

    # look for the runtime library (in the case LD_LIBRARY_PATH points to the installation)
    libcudart_path = find_library("cudart")
    if libcudart_path !== nothing
        libcudart_dir = dirname(libcudart_path)
        if occursin(r"^(lib|bin)(32|64)?$", basename(libcudart_dir))
            libcudart_dir = dirname(libcudart_dir)
        end

        @debug "Looking for CUDA toolkit via CUDA runtime library" path=libcudart_path dir=libcudart_dir
        push!(dirs, libcudart_dir)
    end

    # look in default installation directories
    default_dirs = String[]
    if Sys.iswindows()
        # CUDA versions are installed in separate directories under a single base dir
        program_files = ENV[Sys.WORD_SIZE == 64 ? "ProgramFiles" : "ProgramFiles(x86)"]
        basedir = joinpath(program_files, "NVIDIA GPU Computing Toolkit", "CUDA")
        if isdir(basedir)
            entries = map(dir -> joinpath(basedir, dir), readdir(basedir))
            append!(default_dirs, entries)
        end
    else
        # CUDA versions are installed in unversioned dirs, or suffixed with the version
        basedirs = ["/usr/local/cuda", "/opt/cuda"]
        for ver in cuda_releases, dir in basedirs
            push!(default_dirs, "$dir-$(ver.major).$(ver.minor)")
        end
        append!(default_dirs, basedirs)
        push!(default_dirs, "/usr/lib/nvidia-cuda-toolkit")
        push!(default_dirs, "/usr/share/cuda")
    end
    reverse!(default_dirs) # we want to search starting from the newest CUDA version
    default_dirs = valid_dirs(default_dirs)
    if !isempty(default_dirs)
        @debug "Looking for CUDA toolkit via default installation directories" dirs=default_dirs
        append!(dirs, default_dirs)
    end

    # filter
    dirs = valid_dirs(dirs)
    if isempty(dirs)
        @debug "Could not find CUDA toolkit"
    else
        @debug "Found CUDA toolkit at $(join(dirs, ", "))"
    end
    return dirs
end


#
# load-time initialization
#

function get_binary(dirs, name; optional=false)
    path = find_cuda_binary(dirs, name)
    if path !== nothing
        return path
    else
        optional || error("Could not find binary '$name' in your local CUDA installation.")
        return nothing
    end
end

function get_library(dirs, name; optional=false)
    # start by looking for an unversioned library
    path = find_cuda_library(dirs, name, [])

    # if that fails, try all known versions
    if path === nothing
        versions = cuda_library_versions(name)
        path = find_cuda_library(dirs, name, versions)
    end

    if path !== nothing
        Libdl.dlopen(path)
        return path
    else
        optional || error("Could not find library '$name' in your local CUDA installation.")
        return nothing
    end
end

const available = Ref{Bool}(false)
is_available() = available[]

export libcudart, libcupti, libnvperf_host, libnvperf_target,
       libcufft, libcublas, libcublasLt, libcusparse, libcusolver, libcusolverMg, libcurand

function __init__()
    dirs = find_toolkit()
    isempty(dirs) && return

    try
        # binaries
        global compute_sanitizer_path = get_binary(dirs, "compute-sanitizer")

        # libraries
        global libcudart = get_library(dirs, "cudart")
        global libcufft = get_library(dirs, "cufft")
        global libcublas = get_library(dirs, "cublas")
        global libcublasLt = get_library(dirs, "cublasLt")
        global libcusparse = get_library(dirs, "cusparse")
        global libcusolver = get_library(dirs, "cusolver")
        global libcusolverMg = get_library(dirs, "cusolverMg")
        global libcurand = get_library(dirs, "curand")
        global libcupti = get_library(dirs, "cupti")
        global libnvperf_host = get_library(dirs, "nvperf_host")
        global libnvperf_target = get_library(dirs, "nvperf_target")

        available[] = true
    catch err
        @error """Could not (fully) discover the local CUDA toolkit; one or more pieces may be missing.
                  See the exception below. For even more information, run with `JULIA_DEBUG=CUDA_Runtime_Discovery`.

                  It may be helpful to set the CUDA_PATH/CUDA_HOME/CUDA_ROOT environment variable
                  and point it to the root of your CUDA toolkit installation.""" exception=(err, catch_backtrace())
    end
end

for binary in ["compute-sanitizer"]
    name = Symbol(binary)
    path = Symbol(binary, "_path")
    @eval begin
        $name(; kwargs...) = Cmd([$path, kwargs...])
        $name(f::Function) = f($path)
    end
end

end # module CUDA_Runtime_Discovery
