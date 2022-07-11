"""
The `Messages` module defines structs that represent [`HTTP.Request`](@ref)
and [`HTTP.Response`](@ref) Messages.

The `Response` struct has a `request` field that points to the corresponding
`Request`; and the `Request` struct has a `response` field.
The `Request` struct also has a `parent` field that points to a `Response`
in the case of HTTP redirects that occur and are followed.

The Messages module defines `IO` `read` and `write` methods for Messages
but it does not deal with URIs, creating connections, or executing requests.

The `read` methods throw `EOFError` exceptions if input data is incomplete.
and call parser functions that may throw `HTTP.ParsingError` exceptions.
The `read` and `write` methods may also result in low level `IO` exceptions.

### Sending Messages

Messages are formatted and written to an `IO` stream by
[`Base.write(::IO,::HTTP.Messages.Message)`](@ref) and/or
[`HTTP.Messages.writeheaders`](@ref).

### Receiving Messages

Messages are parsed from `IO` stream data by
[`HTTP.Messages.readheaders`](@ref).
This function calls [`HTTP.Parsers.parse_header_field`](@ref) and passes each
header-field to [`HTTP.Messages.appendheader`](@ref).

### Headers

Headers are represented by `Vector{Pair{String,String}}`. As compared to
`Dict{String,String}` this allows [repeated header fields and preservation of
order](https://tools.ietf.org/html/rfc7230#section-3.2.2).

Header values can be accessed by name using
[`HTTP.header`](@ref) and
[`HTTP.setheader`](@ref) (case-insensitive).

The [`HTTP.appendheader`](@ref) function handles combining
multi-line values, repeated header fields and special handling of
multiple `Set-Cookie` headers.

### Bodies

The `HTTP.Message` structs represent the message body by default as `Vector{UInt8}`.
If `IO` or iterator objects are passed as the body, they will be stored as is
in the `Request`/`Response` `body` field.
"""
module Messages

export Message, Request, Response,
       reset!, status, method, headers, uri, body, resource,
       iserror, isredirect, retryable, ischunked, issafe, isidempotent,
       header, hasheader, headercontains, setheader, defaultheader!, appendheader,
       mkheaders, readheaders, headerscomplete,
       readchunksize,
       writeheaders, writestartline,
       bodylength, unknown_length,
       payload, decode, statustext, sprintcompact

using URIs, CodecZlib
using ..Pairs, ..IOExtras, ..Parsers, ..Strings, ..Forms, ..Conditions

const nobody = UInt8[]
const unknown_length = typemax(Int)

sprintcompact(x) = sprint(show, x; context=:compact => true)

abstract type Message end

# HTTP Response
"""
    HTTP.Response(status, headers::HTTP.Headers, body; request=nothing)
    HTTP.Response(status, body)
    HTTP.Response(body)

Represents an HTTP response message with fields:

- `version::VersionNumber`
   [RFC7230 2.6](https://tools.ietf.org/html/rfc7230#section-2.6)

- `status::Int16`
   [RFC7230 3.1.2](https://tools.ietf.org/html/rfc7230#section-3.1.2)
   [RFC7231 6](https://tools.ietf.org/html/rfc7231#section-6)

- `headers::Vector{Pair{String,String}}`
   [RFC7230 3.2](https://tools.ietf.org/html/rfc7230#section-3.2)

- `body::Vector{UInt8}` or `body::IO`
   [RFC7230 3.3](https://tools.ietf.org/html/rfc7230#section-3.3)

- `request`, the `Request` that yielded this `Response`.

"""
mutable struct Response <: Message
    version::VersionNumber
    status::Int16
    headers::Headers
    body::Any # Usually Vector{UInt8} or IO
    request::Union{Message, Nothing} # Union{Request, Nothing}
end

function Response(status::Integer, headers, body; version::VersionNumber=v"1.1", request=nothing)
    b = isbytes(body) ? bytes(body) : something(body, nobody)
    @assert (request isa Request || request === nothing)
    return Response(version, status, mkheaders(headers), b, request)
end

# legacy constructor
Response(status::Integer, headers=[]; body=nobody, request=nothing) =
    Response(status, headers, body; request)

Response() = Request().response
Response(s::Int, body::AbstractVector{UInt8}) = Response(s; body=body)
Response(s::Int, body::AbstractString) = Response(s; body=bytes(body))
Response(body) = Response(200; body=body)

Base.convert(::Type{Response}, s::AbstractString) = Response(s)

function reset!(r::Response)
    r.version = v"1.1"
    r.status = 0
    if !isempty(r.headers)
        empty!(r.headers)
    end
    if r.body isa Vector{UInt8} && !isempty(r.body)
        empty!(r.body)
    end
end

status(r::Response) = getfield(r, :status)
headers(r::Response) = getfield(r, :headers)
body(r::Response) = getfield(r, :body)

# HTTP Request
const Context = Dict{Symbol, Any}

"""
    HTTP.Request(method, target, headers=[], body=nobody;
        version=v"1.1", url::URI=URI(), responsebody=nothing, parent=nothing, context=HTTP.Context())

Represents a HTTP Request Message with fields:

- `method::String`
   [RFC7230 3.1.1](https://tools.ietf.org/html/rfc7230#section-3.1.1)

- `target::String`
   [RFC7230 5.3](https://tools.ietf.org/html/rfc7230#section-5.3)

- `version::VersionNumber`
   [RFC7230 2.6](https://tools.ietf.org/html/rfc7230#section-2.6)

- `headers::HTTP.Headers`
   [RFC7230 3.2](https://tools.ietf.org/html/rfc7230#section-3.2)

- `body::Union{Vector{UInt8}, IO}`
   [RFC7230 3.3](https://tools.ietf.org/html/rfc7230#section-3.3)

- `response`, the `Response` to this `Request`

- `url::URI`, the full URI of the request

- `parent`, the `Response` (if any) that led to this request
  (e.g. in the case of a redirect).
   [RFC7230 6.4](https://tools.ietf.org/html/rfc7231#section-6.4)

- `context`, a `Dict{Symbol, Any}` store used by middleware to share state

"""
mutable struct Request <: Message
    method::String
    target::String
    version::VersionNumber
    headers::Headers
    body::Any # Usually Vector{UInt8} or some kind of IO
    response::Response
    url::URI
    parent::Union{Response, Nothing}
    context::Context
end

Request() = Request("", "")

function Request(method::String, target, headers=[], body=nobody;
                 version=v"1.1", url::URI=URI(), responsebody=nothing, parent=nothing, context=Context())
    b = isbytes(body) ? bytes(body) : body
    r = Request(method, target == "" ? "/" : target, version,
                mkheaders(headers), b, Response(0; body=responsebody),
                url, parent, context)
    r.response.request = r
    return r
end

"""
"request-target" per https://tools.ietf.org/html/rfc7230#section-5.3
"""
resource(uri::URI) = string( isempty(uri.path)     ? "/" :     uri.path,
                            !isempty(uri.query)    ? "?" : "", uri.query,
                            !isempty(uri.fragment) ? "#" : "", uri.fragment)

mkheaders(h::Headers) = h
mkheaders(h)::Headers = Header[string(k) => string(v) for (k,v) in h]

method(r::Request) = getfield(r, :method)
target(r::Request) = getfield(r, :target)
url(r::Request) = getfield(r, :url)
headers(r::Request) = getfield(r, :headers)
body(r::Request) = getfield(r, :body)

# HTTP Message state and type queries
"""
    issafe(::Request)

https://tools.ietf.org/html/rfc7231#section-4.2.1
"""
issafe(r::Request) = issafe(r.method)
issafe(method) = method in ["GET", "HEAD", "OPTIONS", "TRACE"]

"""
    isidempotent(::Request)

https://tools.ietf.org/html/rfc7231#section-4.2.2
"""
isidempotent(r::Request) = isidempotent(r.method)
isidempotent(method) = issafe(method) || method in ["PUT", "DELETE"]
retry_non_idempotent(r::Request) = get(r.context, :retry_non_idempotent, false)
allow_retries(r::Request) = get(r.context, :allow_retries, false)

"""
    iserror(::Response)

Does this `Response` have an error status?
"""
iserror(r::Response) = iserror(r.status)
iserror(status) = status != 0 && status != 100 && status != 101 &&
                 (status < 200 || status >= 300) && !isredirect(status)

"""
    isredirect(::Response)

Does this `Response` have a redirect status?
"""
isredirect(r::Response) = isredirect(r.status)
isredirect(r::Request) = allow_redirects(r) && !redirectlimitreached(r)
isredirect(status) = status in (301, 302, 303, 307, 308)

# whether the redirect limit has been reached for a given request
# set in the RedirectRequest layer once the limit is reached
redirectlimitreached(r::Request) = get(r.context, :redirectlimitreached, false)
allow_redirects(r::Request) = get(r.context, :allow_redirects, false)

# whether the retry limit has been reached for a given request
# set in the RetryRequest layer once the limit is reached
retrylimitreached(r::Request) = get(r.context, :retrylimitreached, false)

"""
    retryable(::Request)

Whether a `Request` is eligible to be retried.
"""
function retryable end

retryable_requestbody(r::Request) = isbytes(r.body) || (r.body !== nothing && ismarked(r.body))
retryable(r::Request) = retryable_requestbody(r) && allow_retries(r) &&
    (isidempotent(r) || retry_non_idempotent(r)) && !retrylimitreached(r)
retryable(r::Response) = retryable(r.status)
retryable(status) = status in (403, 408, 409, 429, 500, 502, 503, 504, 599)

"""
    ischunked(::Message)

Does the `Message` have a "Transfer-Encoding: chunked" header?
"""
ischunked(m) = any(h->(field_name_isequal(h[1], "transfer-encoding") &&
                       endswith(lowercase(h[2]), "chunked")),
                   m.headers)

"""
    headerscomplete(::Message)

Have the headers been read into this `Message`?
"""
headerscomplete(r::Response) = r.status != 0 && r.status != 100
headerscomplete(r::Request) = r.method != ""

"""
"The presence of a message body in a response depends on both the
 request method to which it is responding and the response status code.
 Responses to the HEAD request method never include a message body [].
 2xx (Successful) responses to a CONNECT request method (Section 4.3.6 of
 [RFC7231]) switch to tunnel mode instead of having a message body.
 All 1xx (Informational), 204 (No Content), and 304 (Not Modified)
 responses do not include a message body.  All other responses do
 include a message body, although the body might be of zero length."
[RFC7230 3.3](https://tools.ietf.org/html/rfc7230#section-3.3)
"""
bodylength(r::Response)::Int =
                 r.request.method == "HEAD" ? 0 :
                               ischunked(r) ? unknown_length :
                     r.status in [204, 304] ? 0 :
    (l = header(r, "Content-Length")) != "" ? parse(Int, l) :
                                              unknown_length

"""
"The presence of a message body in a request is signaled by a
 Content-Length or Transfer-Encoding header field.  Request message
 framing is independent of method semantics, even if the method does
 not define any use for a message body."
[RFC7230 3.3](https://tools.ietf.org/html/rfc7230#section-3.3)
"""
bodylength(r::Request)::Int =
    ischunked(r) ? unknown_length :
                   parse(Int, header(r, "Content-Length", "0"))

# HTTP header-fields
Base.getindex(m::Message, k) = header(m, k)

"""
    Are `field-name`s `a` and `b` equal?

[HTTP `field-name`s](https://tools.ietf.org/html/rfc7230#section-3.2)
are ASCII-only and case-insensitive.
"""
field_name_isequal(a, b) = ascii_lc_isequal(a, b)

"""
    HTTP.header(::Message, key [, default=""]) -> String

Get header value for `key` (case-insensitive).
"""
header(m::Message, k, d="") = header(m.headers, k, d)
header(h::Headers, k::AbstractString, d="") =
    getbyfirst(h, k, k => d, field_name_isequal)[2]

"""
    HTTP.headers(m::Message, key) -> Vector{String}

Get all headers with key `k` or empty if none
"""
headers(h::Headers, k::AbstractString) =
    map(x -> x[2], filter(x -> field_name_isequal(x[1], k), h))
headers(m::Message, k::AbstractString) =
    headers(headers(m), k)

"""
    HTTP.hasheader(::Message, key) -> Bool

Does header value for `key` exist (case-insensitive)?
"""
hasheader(m, k::AbstractString) = header(m, k) != ""

"""
    HTTP.hasheader(::Message, key, value) -> Bool

Does header for `key` match `value` (both case-insensitive)?
"""
hasheader(m, k::AbstractString, v::AbstractString) =
    field_name_isequal(header(m, k), lowercase(v))

"""
    HTTP.headercontains(::Message, key, value) -> Bool

Does the header for `key` (interpreted as comma-separated list) contain `value` (both case-insensitive)?
"""
headercontains(m, k::AbstractString, v::AbstractString) =
    any(field_name_isequal.(strip.(split(header(m, k), ",")), v))

"""
    HTTP.setheader(::Message, key => value)

Set header `value` for `key` (case-insensitive).
"""
setheader(m::Message, v) = setheader(m.headers, v)
setheader(h::Headers, v::Header) = setbyfirst(h, v, field_name_isequal)
setheader(h::Headers, v::Pair) =
    setbyfirst(h, Header(SubString(v.first), SubString(v.second)),
               field_name_isequal)

"""
    defaultheader!(::Message, key => value)

Set header `value` in message for `key` if it is not already set.
"""
function defaultheader!(m, v::Pair)
    # return nothing as default to allow users passing "" as empty header
    # and not being overwritten by default headers
    if header(m, first(v), nothing) === nothing
        setheader(m, v)
    end
    return
end

"""
    HTTP.appendheader(::Message, key => value)

Append a header value to `message.headers`.

If `key` is the same as the previous header, the `value` is [appended to the
value of the previous header with a comma
delimiter](https://stackoverflow.com/a/24502264)

`Set-Cookie` headers are not comma-combined because [cookies often contain
internal commas](https://tools.ietf.org/html/rfc6265#section-3).
"""
function appendheader(m::Message, header::Header)
    c = m.headers
    k,v = header
    if k != "Set-Cookie" && length(c) > 0 && k == c[end][1]
        c[end] = c[end][1] => string(c[end][2], ", ", v)
    else
        push!(m.headers, header)
    end
    return
end

# HTTP payload body
function payload(m::Message)::Vector{UInt8}
    enc = lowercase(first(split(header(m, "Transfer-Encoding"), ", ")))
    return enc in ["", "identity", "chunked"] ? m.body : decode(m, enc)
end

payload(m::Message, ::Type{String}) =
    hasheader(m, "Content-Type", "ISO-8859-1") ? iso8859_1_to_utf8(payload(m)) :
                                                 String(payload(m))

"""
    HTTP.decode(r::Union{Request, Response}) -> Vector{UInt8}

For a gzip encoded request/response body, decompress it and return
the decompressed body.
"""
function decode(m::Message, encoding::String="gzip")::Vector{UInt8}
    if encoding == "gzip"
        return transcode(GzipDecompressor, m.body)
    end
    return m.body
end

# Writing HTTP Messages to IO streams
"""
    HTTP.httpversion(::Message)

e.g. `"HTTP/1.1"`
"""
httpversion(m::Message) = "HTTP/$(m.version.major).$(m.version.minor)"

"""
    writestartline(::IO, ::Message)

e.g. `"GET /path HTTP/1.1\\r\\n"` or `"HTTP/1.1 200 OK\\r\\n"`
"""
function writestartline(io::IO, r::Request)
    write(io, "$(r.method) $(r.target) $(httpversion(r))\r\n")
    return
end

function writestartline(io::IO, r::Response)
    write(io, "$(httpversion(r)) $(r.status) $(statustext(r.status))\r\n")
    return
end

"""
    writeheaders(::IO, ::Message)

Write `Message` start line and
a line for each "name: value" pair and a trailing blank line.
"""
function writeheaders(io::IO, m::Message)
    writestartline(io, m)
    for (name, value) in m.headers
        # match curl convention of not writing empty headers
        !isempty(value) && write(io, "$name: $value\r\n")
    end
    write(io, "\r\n")
    return
end

"""
    write(::IO, ::Message)

Write start line, headers and body of HTTP Message.
"""
function Base.write(io::IO, m::Message)
    writeheaders(io, m)
    write(io, m.body)
    return
end

function Base.String(m::Message)
    io = IOBuffer()
    write(io, m)
    String(take!(io))
end

# Reading HTTP Messages from IO streams

"""
    readheaders(::IO, ::Message)

Read headers (and startline) from an `IO` stream into a `Message` struct.
Throw `EOFError` if input is incomplete.
"""
function readheaders(io::IO, message::Message)
    bytes = String(readuntil(io, find_end_of_header))
    bytes = parse_start_line!(bytes, message)
    parse_header_fields!(bytes, message)
    return
end

parse_start_line!(bytes, r::Response) = parse_status_line!(bytes, r)

parse_start_line!(bytes, r::Request) = parse_request_line!(bytes, r)

function parse_header_fields!(bytes::SubString{String}, m::Message)

    h, bytes = parse_header_field(bytes)
    while !(h === Parsers.emptyheader)
        appendheader(m, h)
        h, bytes = parse_header_field(bytes)
    end
    return
end

"""
Read chunk-size from an `IO` stream.
After the final zero size chunk, read trailers into a `Message` struct.
"""
function readchunksize(io::IO, message::Message)::Int
    n = parse_chunk_size(readuntil(io, find_end_of_chunk_size))
    if n == 0
        bytes = readuntil(io, find_end_of_trailer)
        if bytes[2] != UInt8('\n')
            parse_header_fields!(SubString(String(bytes)), message)
        end
    end
    return n
end

# Debug message printing

"""
    set_show_max(x)

Set the maximum number of body bytes to be displayed by `show(::IO, ::Message)`
"""
set_show_max(x) = BODY_SHOW_MAX[] = x
const BODY_SHOW_MAX = Ref(1000)

"""
    bodysummary(bytes)

The first chunk of the Message Body (for display purposes).
"""
bodysummary(body) = isbytes(body) ? view(bytes(body), 1:min(nbytes(body), BODY_SHOW_MAX[])) : "[Message Body was streamed]"
function bodysummary(body::Form)
    if length(body.data) == 1 && isa(body.data[1], IOBuffer)
        return body.data[1].data[1:body.data[1].ptr-1]
    end
    return "[Message Body was streamed]"
end

function compactstartline(m::Message)
    b = IOBuffer()
    writestartline(b, m)
    strip(String(take!(b)))
end

# temporary replacement for isvalid(String, s), until the
# latter supports subarrays (JuliaLang/julia#36047):
isvalidstr(s) = ccall(:u8_isvalid, Int32, (Ptr{UInt8}, Int), s, sizeof(s)) ≠ 0

function Base.show(io::IO, m::Message)
    if get(io, :compact, false)
        print(io, compactstartline(m))
        if m isa Response
            print(io, " <= (", compactstartline(m.request::Request), ")")
        end
        return
    end
    println(io, typeof(m), ":")
    println(io, "\"\"\"")
    writeheaders(io, m)
    summary = bodysummary(m.body)
    validsummary = isvalidstr(summary)
    validsummary && write(io, summary)
    if !validsummary || something(nbytes(m.body), 0) > length(summary)
        println(io, "\n⋮\n$(nbytes(m.body))-byte body")
    end
    print(io, "\"\"\"")
    return
end

include("status_messages.jl")

end # module Messages
