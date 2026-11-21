# json: Elm-style JSON for punk

`Decode` and `Encode` as Elm's `Json.Decode` and `Json.Encode`, written in
punk itself. Decoders are written by hand: what the JSON looks like is part of
the program, nothing is derived from a type.

```
app [main!] { pf: platform "../../../platforms/cli/main.roc", json: "../../../packages/json/main.roc" }

import json.Decode as D
import json.Encode as E

type alias Link = { url : Str, created : Int }

link : D.Decoder Link
link =
    D.map2 (fn url, created -> { url, created })
        (D.field "url" D.string)
        (D.field "created" D.int)

encodeLink : Link -> Str
encodeLink = fn l ->
    E.object [("url", E.string l.url), ("created", E.int l.created)]
        |> E.encode 0

-- D.decodeString link "{\"url\": \"https://x.org\", \"created\": 7}"
--     == Ok { url = "https://x.org", created = 7 }
```

| Module | What |
|--------|------|
| `Value` | the type `Value` (`JNull`, `JBool`, `JNumber Str`, `JString`, `JArray`, `JObject`), `Value.parse : Str -> Result Value Str`, `Value.encode : Int -> Value -> Str` |
| `Decode` | `Decoder a`, `Error`, `decodeString`, `decodeValue`, `errorToString`; `string int float bool null value`; `list keyValuePairs field at index maybe nullable oneOf`; `succeed fail map map2 ... map5 andThen` |
| `Encode` | `encode`, `string int float bool null list object dict` |

Differences from Elm:

- The modules are `Decode` and `Encode` of the package `json`
  (`import json.Decode as D`), not `Json.Decode`: Roc reserves the name `Json`.
- No `D.andMap` pipeline: punk functions take all their arguments at once, so
  `D.succeed f |> D.andMap ...` doesn't type. Use `map2` to `map5`, nest them,
  or `andThen` for more fields.
- A number keeps its text (`JNumber "2.5e3"`): `D.int` reads it as a 64-bit
  integer, `D.float` as an `F64`, so a large integer is never rounded.
- `Encode.float` gives `null` for NaN and the infinities, as Elm does.

The parser is strict JSON (RFC 8259): no comments, no trailing commas, no
leading zeros, `\u` escapes with surrogate pairs, and text that must be UTF-8.

`examples/punk/json/json.punk` shows all of it and is a golden test.
