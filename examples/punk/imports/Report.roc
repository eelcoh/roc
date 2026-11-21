## A plain Roc module that uses the punkroc module Math.punk: to Roc, a
## punkroc module is an ordinary module, with snake_case names.
import Math

Report := [].{
    summary : List(I64) -> Str
    summary = |xs| "sum of squares ${Math.sum_of_squares(xs).to_str()}, sum ${Math.add(1, 2).to_str()}"
}
