use bumpalo::collections::Vec;
use bumpalo::Bump;
use roc_can::{
    def::Def,
    expr::{AccessorData, ClosureData, Expr, Field, WhenBranch},
};
use roc_types::subs::{
    AliasVariables, Descriptor, OptVariable, RecordFields, Subs, SubsSlice, UnionTags, Variable,
    VariableSubsSlice,
};

/// Deep copies the type variables in the type hosted by [`var`] into [`expr`].
/// Returns [`None`] if the expression does not need to be copied.
pub fn deep_copy_type_vars_into_expr<'a>(
    arena: &'a Bump,
    subs: &mut Subs,
    var: Variable,
    expr: &Expr,
) -> Option<(Variable, Expr)> {
    let substitutions = deep_copy_type_vars(arena, subs, var);

    if substitutions.is_empty() {
        return None;
    }

    let new_var = substitutions
        .iter()
        .find_map(|&(original, new)| if original == var { Some(new) } else { None })
        .expect("Variable marked as cloned, but it isn't");

    return Some((new_var, help(expr, &substitutions)));

    fn help(expr: &Expr, substitutions: &[(Variable, Variable)]) -> Expr {
        use Expr::*;

        macro_rules! sub {
            ($var:expr) => {
                substitutions
                    .iter()
                    .find_map(|&(original, new)| if original == $var { Some(new) } else { None })
                    .unwrap_or($var)
            };
        }

        let go_help = |e: &Expr| help(e, substitutions);

        match expr {
            Num(var, str, val, bound) => Num(sub!(*var), str.clone(), val.clone(), *bound),
            Int(v1, v2, str, val, bound) => Int(
                sub!(*v1),
                sub!(*v2),
                str.clone(),
                val.clone(),
                bound.clone(),
            ),
            Float(v1, v2, str, val, bound) => Float(
                sub!(*v1),
                sub!(*v2),
                str.clone(),
                val.clone(),
                bound.clone(),
            ),
            Str(str) => Str(str.clone()),
            SingleQuote(char) => SingleQuote(*char),
            List {
                elem_var,
                loc_elems,
            } => List {
                elem_var: sub!(*elem_var),
                loc_elems: loc_elems.iter().map(|le| le.map(go_help)).collect(),
            },
            Var(sym) => Var(*sym),
            When {
                loc_cond,
                cond_var,
                expr_var,
                region,
                branches,
                branches_cond_var,
                exhaustive,
            } => When {
                loc_cond: Box::new(loc_cond.map(go_help)),
                cond_var: sub!(*cond_var),
                expr_var: sub!(*expr_var),
                region: *region,
                branches: branches
                    .iter()
                    .map(
                        |WhenBranch {
                             patterns,
                             value,
                             guard,
                             redundant,
                         }| WhenBranch {
                            patterns: patterns.clone(),
                            value: value.map(go_help),
                            guard: guard.as_ref().map(|le| le.map(go_help)),
                            redundant: *redundant,
                        },
                    )
                    .collect(),
                branches_cond_var: sub!(*branches_cond_var),
                exhaustive: *exhaustive,
            },
            If {
                cond_var,
                branch_var,
                branches,
                final_else,
            } => If {
                cond_var: sub!(*cond_var),
                branch_var: sub!(*branch_var),
                branches: branches
                    .iter()
                    .map(|(c, e)| (c.map(go_help), e.map(go_help)))
                    .collect(),
                final_else: Box::new(final_else.map(go_help)),
            },

            LetRec(defs, body, var) => LetRec(
                defs.iter()
                    .map(
                        |Def {
                             loc_pattern,
                             loc_expr,
                             expr_var,
                             pattern_vars,
                             annotation,
                         }| Def {
                            loc_pattern: loc_pattern.clone(),
                            loc_expr: loc_expr.map(go_help),
                            expr_var: sub!(*expr_var),
                            pattern_vars: pattern_vars
                                .iter()
                                .map(|(s, v)| (*s, sub!(*v)))
                                .collect(),
                            annotation: annotation.clone(),
                        },
                    )
                    .collect(),
                Box::new(body.map(go_help)),
                sub!(*var),
            ),
            LetNonRec(def, body, var) => {
                let Def {
                    loc_pattern,
                    loc_expr,
                    expr_var,
                    pattern_vars,
                    annotation,
                } = &**def;
                let def = Def {
                    loc_pattern: loc_pattern.clone(),
                    loc_expr: loc_expr.map(go_help),
                    expr_var: sub!(*expr_var),
                    pattern_vars: pattern_vars.iter().map(|(s, v)| (*s, sub!(*v))).collect(),
                    annotation: annotation.clone(),
                };
                LetNonRec(Box::new(def), Box::new(body.map(go_help)), sub!(*var))
            }

            Call(f, args, called_via) => {
                let (fn_var, fn_expr, clos_var, ret_var) = &**f;
                Call(
                    Box::new((
                        sub!(*fn_var),
                        fn_expr.map(go_help),
                        sub!(*clos_var),
                        sub!(*ret_var),
                    )),
                    args.iter()
                        .map(|(var, expr)| (sub!(*var), expr.map(go_help)))
                        .collect(),
                    *called_via,
                )
            }
            RunLowLevel { op, args, ret_var } => RunLowLevel {
                op: *op,
                args: args
                    .iter()
                    .map(|(var, expr)| (sub!(*var), go_help(expr)))
                    .collect(),
                ret_var: sub!(*ret_var),
            },
            ForeignCall {
                foreign_symbol,
                args,
                ret_var,
            } => ForeignCall {
                foreign_symbol: foreign_symbol.clone(),
                args: args
                    .iter()
                    .map(|(var, expr)| (sub!(*var), go_help(expr)))
                    .collect(),
                ret_var: sub!(*ret_var),
            },

            Closure(ClosureData {
                function_type,
                closure_type,
                closure_ext_var,
                return_type,
                name,
                captured_symbols,
                recursive,
                arguments,
                loc_body,
            }) => Closure(ClosureData {
                function_type: sub!(*function_type),
                closure_type: sub!(*closure_type),
                closure_ext_var: sub!(*closure_ext_var),
                return_type: sub!(*return_type),
                name: *name,
                captured_symbols: captured_symbols
                    .iter()
                    .map(|(s, v)| (*s, sub!(*v)))
                    .collect(),
                recursive: *recursive,
                arguments: arguments
                    .iter()
                    .map(|(v, mark, pat)| (sub!(*v), *mark, pat.clone()))
                    .collect(),
                loc_body: Box::new(loc_body.map(go_help)),
            }),

            Record { record_var, fields } => Record {
                record_var: sub!(*record_var),
                fields: fields
                    .iter()
                    .map(
                        |(
                            k,
                            Field {
                                var,
                                region,
                                loc_expr,
                            },
                        )| {
                            (
                                k.clone(),
                                Field {
                                    var: sub!(*var),
                                    region: *region,
                                    loc_expr: Box::new(loc_expr.map(go_help)),
                                },
                            )
                        },
                    )
                    .collect(),
            },

            EmptyRecord => EmptyRecord,

            Access {
                record_var,
                ext_var,
                field_var,
                loc_expr,
                field,
            } => Access {
                record_var: sub!(*record_var),
                ext_var: sub!(*ext_var),
                field_var: sub!(*field_var),
                loc_expr: Box::new(loc_expr.map(go_help)),
                field: field.clone(),
            },

            Accessor(AccessorData {
                name,
                function_var,
                record_var,
                closure_var,
                closure_ext_var,
                ext_var,
                field_var,
                field,
            }) => Accessor(AccessorData {
                name: *name,
                function_var: sub!(*function_var),
                record_var: sub!(*record_var),
                closure_var: sub!(*closure_var),
                closure_ext_var: sub!(*closure_ext_var),
                ext_var: sub!(*ext_var),
                field_var: sub!(*field_var),
                field: field.clone(),
            }),

            Update {
                record_var,
                ext_var,
                symbol,
                updates,
            } => Update {
                record_var: sub!(*record_var),
                ext_var: sub!(*ext_var),
                symbol: *symbol,
                updates: updates
                    .iter()
                    .map(
                        |(
                            k,
                            Field {
                                var,
                                region,
                                loc_expr,
                            },
                        )| {
                            (
                                k.clone(),
                                Field {
                                    var: sub!(*var),
                                    region: *region,
                                    loc_expr: Box::new(loc_expr.map(go_help)),
                                },
                            )
                        },
                    )
                    .collect(),
            },

            Tag {
                variant_var,
                ext_var,
                name,
                arguments,
            } => Tag {
                variant_var: sub!(*variant_var),
                ext_var: sub!(*ext_var),
                name: name.clone(),
                arguments: arguments
                    .iter()
                    .map(|(v, e)| (sub!(*v), e.map(go_help)))
                    .collect(),
            },

            ZeroArgumentTag {
                closure_name,
                variant_var,
                ext_var,
                name,
            } => ZeroArgumentTag {
                closure_name: *closure_name,
                variant_var: sub!(*variant_var),
                ext_var: sub!(*ext_var),
                name: name.clone(),
            },

            OpaqueRef {
                opaque_var,
                name,
                argument,
                specialized_def_type,
                type_arguments,
                lambda_set_variables,
            } => OpaqueRef {
                opaque_var: sub!(*opaque_var),
                name: *name,
                argument: Box::new((sub!(argument.0), argument.1.map(go_help))),
                // These shouldn't matter for opaques during mono, because they are only used for reporting
                // and pretty-printing to the user. During mono we decay immediately into the argument.
                // NB: if there are bugs, check if not substituting here is the problem!
                specialized_def_type: specialized_def_type.clone(),
                type_arguments: type_arguments.clone(),
                lambda_set_variables: lambda_set_variables.clone(),
            },

            Expect(e1, e2) => Expect(Box::new(e1.map(go_help)), Box::new(e2.map(go_help))),

            RuntimeError(err) => RuntimeError(err.clone()),
        }
    }
}

/// Deep copies the type variables in [`var`], returning a map of original -> new type variable for
/// all type variables copied.
fn deep_copy_type_vars<'a>(
    arena: &'a Bump,
    subs: &mut Subs,
    var: Variable,
) -> Vec<'a, (Variable, Variable)> {
    let mut copied = Vec::with_capacity_in(16, arena);

    let cloned_var = help(arena, subs, &mut copied, var);

    debug_assert!(match cloned_var {
        Some(_) => !copied.is_empty(),
        None => copied.is_empty(),
    });

    // we have tracked all visited variables, and can now traverse them
    // in one go (without looking at the UnificationTable) and clear the copy field
    let mut result = Vec::with_capacity_in(copied.len(), arena);
    for var in copied {
        let descriptor = subs.get_ref_mut(var);

        if let Some(copy) = descriptor.copy.into_variable() {
            result.push((var, copy));
            descriptor.copy = OptVariable::NONE;
        } else {
            debug_assert!(false, "{:?} marked as copied but it wasn't", var);
        }
    }

    return result;

    #[must_use]
    fn help(
        arena: &Bump,
        subs: &mut Subs,
        visited: &mut Vec<Variable>,
        var: Variable,
    ) -> Option<Variable> {
        use roc_types::subs::Content::*;
        use roc_types::subs::FlatType::*;

        let desc = subs.get_ref_mut(var);
        let content = desc.content;
        let rank = desc.rank;
        let mark = desc.mark;

        // Unlike `deep_copy_var` in solve, here we are cloning *all* flex and rigid vars.
        // So we only want to short-circuit if we've already done the cloning work for a particular
        // var.
        if let Some(copy) = desc.copy.into_variable() {
            return Some(copy);
        }

        macro_rules! descend_slice {
            ($slice:expr, $needs_clone:ident) => {
                for var_index in $slice {
                    let var = subs[var_index];
                    $needs_clone = $needs_clone || help(arena, subs, visited, var).is_some();
                }
            };
        }

        macro_rules! descend_var {
            ($var:expr, $needs_clone:ident) => {{
                let new_var = help(arena, subs, visited, $var).unwrap_or($var);
                $needs_clone = $needs_clone || new_var != $var;
                new_var
            }};
        }

        macro_rules! clone_var_slice {
            ($slice:expr) => {{
                let new_arguments = VariableSubsSlice::reserve_into_subs(subs, $slice.len());
                for (target_index, var_index) in (new_arguments.indices()).zip($slice) {
                    let var = subs[var_index];
                    let copy_var = subs.get_ref(var).copy.into_variable().unwrap_or(var);
                    subs.variables[target_index] = copy_var;
                }
                new_arguments
            }};
        }

        macro_rules! perform_clone {
            ($needs_clone:ident, $do_clone:expr) => {
                if $needs_clone {
                    // It may the case that while deep-copying nested variables of this type, we
                    // ended up copying the type itself (notably if it was self-referencing, in a
                    // recursive type). In that case, short-circuit with the known copy.
                    if let Some(copy) = subs.get_ref(var).copy.into_variable() {
                        return Some(copy);
                    }
                    // Perform the clone.
                    Some($do_clone)
                } else {
                    None
                }
            };
        }

        // Now we recursively copy the content of the variable.
        // We have already marked the variable as copied, so we
        // will not repeat this work or crawl this variable again.
        let opt_new_content = match content {
            // The vars for which we want to do something interesting.
            FlexVar(opt_name) => Some(FlexVar(opt_name)),
            FlexAbleVar(opt_name, ability) => Some(FlexAbleVar(opt_name, ability)),
            RigidVar(name) => Some(RigidVar(name)),
            RigidAbleVar(name, ability) => Some(RigidAbleVar(name, ability)),

            // Everything else is a mechanical descent.
            Structure(flat_type) => match flat_type {
                EmptyRecord | EmptyTagUnion | Erroneous(_) => None,
                Apply(symbol, arguments) => {
                    let mut needs_clone = false;
                    descend_slice!(arguments, needs_clone);

                    perform_clone!(needs_clone, {
                        let new_arguments = clone_var_slice!(arguments);
                        Structure(Apply(symbol, new_arguments))
                    })
                }
                Func(arguments, closure_var, ret_var) => {
                    let mut needs_clone = false;

                    descend_slice!(arguments, needs_clone);

                    let new_closure_var = descend_var!(closure_var, needs_clone);
                    let new_ret_var = descend_var!(ret_var, needs_clone);

                    perform_clone!(needs_clone, {
                        let new_arguments = clone_var_slice!(arguments);
                        Structure(Func(new_arguments, new_closure_var, new_ret_var))
                    })
                }
                Record(fields, ext_var) => {
                    let mut needs_clone = false;

                    let new_ext_var = descend_var!(ext_var, needs_clone);

                    descend_slice!(fields.variables(), needs_clone);

                    perform_clone!(needs_clone, {
                        let new_variables = clone_var_slice!(fields.variables());
                        let new_fields = {
                            RecordFields {
                                length: fields.length,
                                field_names_start: fields.field_names_start,
                                variables_start: new_variables.start,
                                field_types_start: fields.field_types_start,
                            }
                        };

                        Structure(Record(new_fields, new_ext_var))
                    })
                }
                TagUnion(tags, ext_var) => {
                    let mut needs_clone = false;

                    let new_ext_var = descend_var!(ext_var, needs_clone);

                    for variables_slice_index in tags.variables() {
                        let variables_slice = subs[variables_slice_index];
                        descend_slice!(variables_slice, needs_clone);
                    }

                    perform_clone!(needs_clone, {
                        let new_variable_slices =
                            SubsSlice::reserve_variable_slices(subs, tags.len());
                        let it = (new_variable_slices.indices()).zip(tags.variables());
                        for (target_index, index) in it {
                            let slice = subs[index];
                            let new_variables = clone_var_slice!(slice);
                            subs.variable_slices[target_index] = new_variables;
                        }

                        let new_union_tags =
                            UnionTags::from_slices(tags.tag_names(), new_variable_slices);

                        Structure(TagUnion(new_union_tags, new_ext_var))
                    })
                }
                RecursiveTagUnion(rec_var, tags, ext_var) => {
                    let mut needs_clone = false;

                    let new_ext_var = descend_var!(ext_var, needs_clone);
                    let new_rec_var = descend_var!(rec_var, needs_clone);

                    for variables_slice_index in tags.variables() {
                        let variables_slice = subs[variables_slice_index];
                        descend_slice!(variables_slice, needs_clone);
                    }

                    perform_clone!(needs_clone, {
                        let new_variable_slices =
                            SubsSlice::reserve_variable_slices(subs, tags.len());
                        let it = (new_variable_slices.indices()).zip(tags.variables());
                        for (target_index, index) in it {
                            let slice = subs[index];
                            let new_variables = clone_var_slice!(slice);
                            subs.variable_slices[target_index] = new_variables;
                        }

                        let new_union_tags =
                            UnionTags::from_slices(tags.tag_names(), new_variable_slices);

                        Structure(RecursiveTagUnion(new_rec_var, new_union_tags, new_ext_var))
                    })
                }
                FunctionOrTagUnion(tag_name, symbol, ext_var) => {
                    let mut needs_clone = false;
                    let new_ext_var = descend_var!(ext_var, needs_clone);
                    perform_clone!(needs_clone, {
                        Structure(FunctionOrTagUnion(tag_name, symbol, new_ext_var))
                    })
                }
            },

            RecursionVar {
                opt_name,
                structure,
            } => {
                let mut needs_clone = false;

                let new_structure = descend_var!(structure, needs_clone);

                perform_clone!(needs_clone, {
                    RecursionVar {
                        opt_name,
                        structure: new_structure,
                    }
                })
            }

            Alias(symbol, arguments, real_type_var, kind) => {
                let mut needs_clone = false;

                let new_real_type_var = descend_var!(real_type_var, needs_clone);
                descend_slice!(arguments.all_variables(), needs_clone);

                perform_clone!(needs_clone, {
                    let new_variables = clone_var_slice!(arguments.all_variables());
                    let new_arguments = AliasVariables {
                        variables_start: new_variables.start,
                        ..arguments
                    };

                    Alias(symbol, new_arguments, new_real_type_var, kind)
                })
            }

            RangedNumber(typ, range_vars) => {
                let mut needs_clone = false;

                let new_typ = descend_var!(typ, needs_clone);
                descend_slice!(range_vars, needs_clone);

                perform_clone!(needs_clone, {
                    let new_range_vars = clone_var_slice!(range_vars);

                    RangedNumber(new_typ, new_range_vars)
                })
            }
            Error => None,
        };

        if let Some(new_content) = opt_new_content {
            visited.push(var);

            let copy_descriptor = Descriptor {
                content: new_content,
                rank,
                mark,
                copy: OptVariable::NONE,
            };

            let copy = subs.fresh(copy_descriptor);
            // Set the copy on the original var
            subs.get_ref_mut(var).copy = copy.into();

            // We had to create a fresh var for this type, so anything that depends on it should be
            // freshened too, and use this fresh var.
            return Some(copy);
        }

        // Doesn't need to be freshened; use the old var.
        None
    }
}

#[cfg(test)]
mod test {
    use super::deep_copy_type_vars;
    use bumpalo::Bump;
    use roc_module::ident::TagName;
    use roc_module::symbol::Symbol;
    use roc_types::{
        subs::{
            Content, Content::*, Descriptor, FlatType::*, Mark, OptVariable, Rank, RecordFields,
            Subs, SubsIndex, UnionTags, Variable,
        },
        types::RecordField,
    };

    #[cfg(test)]
    fn new_var(subs: &mut Subs, content: Content) -> Variable {
        subs.fresh(Descriptor {
            content,
            rank: Rank::toplevel(),
            mark: Mark::NONE,
            copy: OptVariable::NONE,
        })
    }

    #[test]
    fn copy_flex_var() {
        let mut subs = Subs::new();
        let arena = Bump::new();

        let field_name = SubsIndex::push_new(&mut subs.field_names, "a".into());
        let var = new_var(&mut subs, FlexVar(Some(field_name)));

        let mut copies = deep_copy_type_vars(&arena, &mut subs, var);

        assert_eq!(copies.len(), 1);
        let (original, new) = copies.pop().unwrap();
        assert_ne!(original, new);

        assert_eq!(original, var);
        match subs.get_content_without_compacting(new) {
            FlexVar(Some(name)) => {
                assert_eq!(subs[*name].as_str(), "a");
            }
            it => assert!(false, "{:?}", it),
        }
    }

    #[test]
    fn copy_rigid_var() {
        let mut subs = Subs::new();
        let arena = Bump::new();

        let field_name = SubsIndex::push_new(&mut subs.field_names, "a".into());
        let var = new_var(&mut subs, RigidVar(field_name));

        let mut copies = deep_copy_type_vars(&arena, &mut subs, var);

        assert_eq!(copies.len(), 1);
        let (original, new) = copies.pop().unwrap();
        assert_ne!(original, new);

        assert_eq!(original, var);
        match subs.get_content_without_compacting(new) {
            RigidVar(name) => {
                assert_eq!(subs[*name].as_str(), "a");
            }
            it => assert!(false, "{:?}", it),
        }
    }

    #[test]
    fn copy_flex_able_var() {
        let mut subs = Subs::new();
        let arena = Bump::new();

        let field_name = SubsIndex::push_new(&mut subs.field_names, "a".into());
        let var = new_var(&mut subs, FlexAbleVar(Some(field_name), Symbol::UNDERSCORE));

        let mut copies = deep_copy_type_vars(&arena, &mut subs, var);

        assert_eq!(copies.len(), 1);
        let (original, new) = copies.pop().unwrap();
        assert_ne!(original, new);

        assert_eq!(original, var);
        match subs.get_content_without_compacting(new) {
            FlexAbleVar(Some(name), Symbol::UNDERSCORE) => {
                assert_eq!(subs[*name].as_str(), "a");
            }
            it => assert!(false, "{:?}", it),
        }
    }

    #[test]
    fn copy_rigid_able_var() {
        let mut subs = Subs::new();
        let arena = Bump::new();

        let field_name = SubsIndex::push_new(&mut subs.field_names, "a".into());
        let var = new_var(&mut subs, RigidAbleVar(field_name, Symbol::UNDERSCORE));

        let mut copies = deep_copy_type_vars(&arena, &mut subs, var);

        assert_eq!(copies.len(), 1);
        let (original, new) = copies.pop().unwrap();
        assert_ne!(original, new);

        assert_eq!(original, var);
        match subs.get_content_without_compacting(new) {
            RigidAbleVar(name, Symbol::UNDERSCORE) => {
                assert_eq!(subs[*name].as_str(), "a");
            }
            it => assert!(false, "{:?}", it),
        }
    }

    #[test]
    fn types_without_type_vars_should_not_be_copied() {
        let mut subs = Subs::new();
        let arena = Bump::new();

        let cases = &[
            RecursionVar {
                structure: new_var(&mut subs, Structure(EmptyTagUnion)),
                opt_name: None,
            },
            Structure(Record(
                RecordFields::insert_into_subs(
                    &mut subs,
                    [("a".into(), RecordField::Required(Variable::BOOL))],
                ),
                Variable::EMPTY_RECORD,
            )),
            Structure(TagUnion(
                UnionTags::insert_into_subs(
                    &mut subs,
                    [(TagName::Tag("A".into()), [Variable::BOOL])],
                ),
                Variable::EMPTY_TAG_UNION,
            )),
            Structure(RecursiveTagUnion(
                Variable::EMPTY_TAG_UNION,
                UnionTags::insert_into_subs(
                    &mut subs,
                    [(TagName::Tag("A".into()), [Variable::BOOL])],
                ),
                Variable::EMPTY_TAG_UNION,
            )),
            Error,
        ];

        for &content in cases {
            let var = new_var(&mut subs, content);

            let copies = deep_copy_type_vars(&arena, &mut subs, var);

            assert!(copies.is_empty());
        }
    }

    #[test]
    fn copy_type_with_copied_reference() {
        let mut subs = Subs::new();
        let arena = Bump::new();

        let flex_var = new_var(&mut subs, FlexVar(None));

        let content = Structure(TagUnion(
            UnionTags::insert_into_subs(&mut subs, [(TagName::Tag("A".into()), [flex_var])]),
            Variable::EMPTY_TAG_UNION,
        ));

        let tag_var = new_var(&mut subs, content);

        let mut copies = deep_copy_type_vars(&arena, &mut subs, tag_var);

        assert_eq!(copies.len(), 2);
        let (original_flex, new_flex) = copies[0];
        assert_ne!(original_flex, new_flex);
        assert_eq!(original_flex, flex_var);

        let (original_tag, new_tag) = copies[1];
        assert_ne!(original_tag, new_tag);
        assert_eq!(original_tag, tag_var);

        match subs.get_content_without_compacting(new_tag) {
            Structure(TagUnion(union_tags, Variable::EMPTY_TAG_UNION)) => {
                let (tag_name, vars) = union_tags.iter_all().next().unwrap();
                match &subs[tag_name] {
                    TagName::Tag(upper) => assert_eq!(upper.as_str(), "A"),
                    _ => assert!(false, "{:?}", tag_name),
                }

                let vars = subs[vars];
                assert_eq!(vars.len(), 1);

                let var = subs[vars.into_iter().next().unwrap()];
                assert_eq!(var, new_flex);
            }
            it => assert!(false, "{:?}", it),
        }

        assert!(matches!(
            subs.get_content_without_compacting(new_flex),
            FlexVar(None)
        ));
    }
}
