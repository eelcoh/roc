## Requests and responses.
Http := [].{
    ## A request, as the platform received it. `path` starts with `/`
    ## (`/links`), `query` is the text after `?` (empty when there is none),
    ## header names are lower case, and `body` holds its bytes (at most 1 MiB).
    Request : {
        method : Str,
        path : Str,
        query : Str,
        headers : List((Str, Str)),
        body : List(U8),
    }

    ## A response. A header name or value the platform can't send (a line
    ## break in it, for instance) or a status outside 100 to 999 turns the
    ## whole response into a 500, so a request can never inject a header.
    Response : {
        status : U16,
        headers : List((Str, Str)),
        body : List(U8),
    }
}
