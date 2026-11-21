platform ""
    requires {
        main! : () => {}
    }
    exposes [Stdout, Stderr, Stdin, File, Arg, Clock, Random]
    packages {}
    provides { "roc_main": main_for_host! }
    hosted {
        "roc_arg_list": Arg.list!,
        "roc_clock_elapsed": Clock.elapsed!,
        "roc_clock_now": Clock.now!,
        "roc_file_read": File.read!,
        "roc_file_write": File.write!,
        "roc_random_u64": Random.u64!,
        "roc_stderr_line": Stderr.line!,
        "roc_stdin_line": Stdin.line!,
        "roc_stdin_read_all": Stdin.read_all!,
        "roc_stdout_line": Stdout.line!,
        "roc_stdout_write": Stdout.write!,
    }
    targets: {
        inputs_dir: "targets/",
        x64mac: { inputs: ["libhost.a", app] },
        arm64mac: { inputs: ["libhost.a", app] },
        x64musl: { inputs: ["rcrt1.o", "libhost.a", app, "libunwind.a", "libc.a"] },
        arm64musl: { inputs: ["rcrt1.o", "libhost.a", app, "libunwind.a", "libc.a"] },
        x64v1elf: { inputs: [app] },
    }

import Arg
import Clock
import File
import Random
import Stdout
import Stderr
import Stdin

main_for_host! : () => {}
main_for_host! = main!
