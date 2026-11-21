## The app's configuration, as the wiring gives it.
Config := [].{
    ## The configuration as text, the same for every request: JSON, which the
    ## app reads with `json.Decode` (as Elm's flags). What is in it is up to
    ## the app and its wiring.
    text! : () => Str
}
