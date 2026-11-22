platform ""
    requires {
        [Model : model, Msg : msg] for main : {
            init : (model, Cmd(msg)),
            update : Tui.Event(msg), model -> (model, Cmd(msg)),
            view : model -> View,
        }
    }
    exposes [Tui, Cmd, View, File, Clock]
    packages {}
    provides {
        "roc_tui_init": init_for_host,
        "roc_tui_update": update_for_host,
        "roc_tui_reply": reply_for_host,
    }
    hosted {}
    targets: {
        inputs_dir: "targets/",
        x64glibc: { inputs: [app], output: Archive },
        arm64glibc: { inputs: [app], output: Archive },
        x64musl: { inputs: [app], output: Archive },
        arm64musl: { inputs: [app], output: Archive },
        x64mac: { inputs: [app], output: Archive },
        arm64mac: { inputs: [app], output: Archive },
    }

import Tui
import Cmd
import View
import File
import Clock

## The app as the host holds it: its model, and the messages still to come
## for work the host is doing, under the ids the host was given.
State : {
    model : Model,
    waiting : List({ id : U64, reply : Cmd.Reply -> Msg }),
    next : U64,
}

## What the host gets back after each step: the work to do (one line each,
## see `Cmd.to_host`), the new state, and the screen (see `View.to_host`).
Step : { cmds : Str, state : Box(State), view : Str }

init_for_host : {} -> Step
init_for_host = |{}| {
    (model, cmd) = main.init
    step({ model, waiting: [], next: 0 }, cmd)
}

## A key, a paste or a resize (see `Tui.event_from_host`).
update_for_host : Box(State), U8, Str, U32, U8, U16, U16 -> Step
update_for_host = |boxed, kind, text, code, mods, width, height| {
    state = Box.unbox(boxed)
    (model, cmd) = (main.update)(Tui.event_from_host(kind, text, code, mods, width, height), state.model)
    step({ ..state, model }, cmd)
}

## The host's answer to the work it was given under `id`.
reply_for_host : Box(State), U64, Bool, Str -> Step
reply_for_host = |boxed, id, ok, text| {
    state = Box.unbox(boxed)
    match List.find_first(state.waiting, |w| w.id == id) {
        Ok(w) => {
            waiting = List.keep_if(state.waiting, |other| other.id != id)
            (model, cmd) = (main.update)(Msg((w.reply)({ ok, text })), state.model)
            step({ ..state, model, waiting }, cmd)
        }
        # An answer nobody waits for: nothing changes.
        Err(_) => step(state, Cmd.none())
    }
}

step : State, Cmd(Msg) -> Step
step = |state, cmd| {
    sent = Cmd.to_host(cmd, state.next)
    {
        cmds: Str.join_with(sent.lines, "\n"),
        state: Box.box({ ..state, waiting: List.concat(state.waiting, sent.waiting), next: sent.next }),
        view: View.to_host((main.view)(state.model)),
    }
}
