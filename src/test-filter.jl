# NOTE: Since  the internals have changed in julia v1.3.0, we need VERSION checks inside
# these functions.

# Helper for `pmatch`: Mirrors Base.PCRE.exec
function _pexec(re, subject, offset, options, match_data)
    rc = ccall((:pcre2_match_8, Base.PCRE.PCRE_LIB), Cint,
               (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Csize_t, Cuint, Ptr{Cvoid}, Ptr{Cvoid}),
               re, subject, sizeof(subject), offset, options, match_data,
               @static if VERSION >= v"1.3-"
                   Base.PCRE.get_local_match_context()
               else
                   Base.PCRE.MATCH_CONTEXT[]
               end)
    # rc == -1 means no match, -2 means partial match.
    rc < -2 && error("PCRE.exec error: $(err_message(rc))")
    (rc >= 0 ||
        # Allow partial matches if they were requested in the options.
        ((options & Base.PCRE.PARTIAL_HARD != 0 || options & Base.PCRE.PARTIAL_SOFT != 0) && rc == -2))
end

# Helper to call `_pexec` w/ thread-safe match data: Mirrors Base.PCRE.exec_r_data
# Only used for Julia Version >= v"1.3-"
function _pexec_r_data(re, subject, offset, options)
    match_data = Base.PCRE.create_match_data(re)
    ans = _pexec(re, subject, offset, options, match_data)
    return ans, match_data
end

"""
   pmatch(r::Regex, s::AbstractString[, idx::Integer[, addopts]])

Variant of `Base.match` that supports partial matches (when `Base.PCRE.PARTIAL_HARD`
is set in `re.match_options`).
"""
function pmatch(re::Regex, str::Union{SubString{String}, String}, idx::Integer, add_opts::UInt32=UInt32(0))
    Base.compile(re)
    opts = re.match_options | add_opts
    @static if VERSION >= v"1.3-"
        # rc == -1 means no match, -2 means partial match.
        matched, data = _pexec_r_data(re.regex, str, idx-1, opts)
        if !matched
            Base.PCRE.free_match_data(data)
            return nothing
        end
        n = div(Base.PCRE.ovec_length(data), 2) - 1
        p = Base.PCRE.ovec_ptr(data)
        mat = SubString(str, unsafe_load(p, 1)+1, prevind(str, unsafe_load(p, 2)+1))
        cap = Option{SubString{String}}[unsafe_load(p,2i+1) == Base.PCRE.UNSET ? nothing :
                                            SubString(str, unsafe_load(p,2i+1)+1,
                                                      prevind(str, unsafe_load(p,2i+2)+1)) for i=1:n]
        off = Int[ unsafe_load(p,2i+1)+1 for i=1:n ]
        result = RegexMatch(mat, cap, unsafe_load(p,1)+1, off, re)
        Base.PCRE.free_match_data(data)
        return result
    else  #  Julia VERSION < v"1.3"
        # rc == -1 means no match, -2 means partial match.
        matched = _pexec(re.regex, str, idx-1, opts, re.match_data)
        if !matched
            return nothing
        end
        ovec = re.ovec
        n = div(length(ovec),2) - 1
        mat = SubString(str, ovec[1]+1, prevind(str, ovec[2]+1))
        cap = Option{SubString{String}}[ovec[2i+1] == PCRE.UNSET ? nothing :
                                            SubString(str, ovec[2i+1]+1,
                                                      prevind(str, ovec[2i+2]+1)) for i=1:n]
        off = Int[ ovec[2i+1]+1 for i=1:n ]
        RegexMatch(mat, cap, ovec[1]+1, off, re)
    end
end

pmatch(r::Regex, s::AbstractString) = pmatch(r, s, firstindex(s))
pmatch(r::Regex, s::AbstractString, i::Integer) = throw(ArgumentError(
    "regex matching is only available for the String type; use String(s) to convert"
))

"""
    partial(str::AbstractString)

Constructs a regular expression to perform partial matching.
"""
partial(str::AbstractString) = Regex(str, Base.DEFAULT_COMPILER_OPTS,
    Base.DEFAULT_MATCH_OPTS | Base.PCRE.PARTIAL_HARD)

"""
    exact(str::AbstractString)

Constructs a regular expression to perform exact maching.
"""
exact(str::AbstractString) = Regex(str)
