## Reading standard input.
Stdin := [].{
    ## The next line, without its line break. Empty at the end of the input.
    line! : () => Str
    ## Everything up to the end of the input, so `punk app.punk < input.txt` works.
    read_all! : () => Str
}
